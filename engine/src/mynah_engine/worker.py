"""Single-thread, priority-ordered job runner for all MLX work.

MLX binds GPU streams to the thread that created them, so every model load and
inference call runs on this one thread. Jobs run lowest priority value first
(FIFO within a priority), so a dictation never waits behind queued meeting work.

Long background jobs call `checkpoint()` between tokens: it runs any queued
urgent jobs that allow it *inline* on this same thread (safe for MLX, and the
background job's state is simply paused on the stack), then raises `Cancelled`
if the background job was cancelled meanwhile.
"""

import heapq
import itertools
import queue
import threading
from concurrent.futures import Future
from dataclasses import dataclass, field

URGENT, NORMAL, BACKGROUND = 0, 1, 2  # dictation/command/config, transcribe, summarize


class Cancelled(Exception):
    pass


@dataclass(order=True)
class _Job:
    priority: int
    seq: int
    fn: object = field(compare=False)
    args: tuple = field(compare=False)
    future: Future = field(compare=False)
    job_id: str | None = field(compare=False, default=None)
    inline_ok: bool = field(compare=False, default=False)


class PriorityWorker:
    def __init__(self, name: str = "mlx"):
        self._queue: queue.PriorityQueue[_Job] = queue.PriorityQueue()
        self._seq = itertools.count()
        self._lock = threading.Lock()
        self._cancelled: set[str] = set()
        self._current: list[_Job] = []  # stack: inline jobs nest inside a background job
        self._thread = threading.Thread(target=self._loop, name=name, daemon=True)
        self._thread.start()

    @property
    def thread_id(self) -> int | None:
        return self._thread.ident

    def submit(self, fn, *args, priority: int = URGENT, job_id: str | None = None,
               inline_ok: bool = False) -> Future:
        future: Future = Future()
        self._queue.put(_Job(priority, next(self._seq), fn, args, future, job_id, inline_ok))
        return future

    def run(self, fn, *args, priority: int = URGENT, job_id: str | None = None, inline_ok: bool = False):
        """Submit and wait for the result (re-raises the job's exception)."""
        return self.submit(fn, *args, priority=priority, job_id=job_id, inline_ok=inline_ok).result()

    def cancel(self, job_id: str) -> bool:
        """Cancel a queued job, or flag a running one for its next checkpoint().
        Returns False if no queued or running job has this id."""
        with self._lock:
            if any(j.job_id == job_id for j in self._current):
                self._cancelled.add(job_id)
                return True
            with self._queue.mutex:
                for job in self._queue.queue:
                    if job.job_id == job_id and not job.future.done():
                        job.future.set_exception(Cancelled(job_id))
                        return True
        return False

    def checkpoint(self) -> None:
        """Call from long jobs running on the worker thread."""
        while True:
            job = self._take_inline()
            if job is None:
                break
            self._execute(job)
        with self._lock:
            current = self._current[-1] if self._current else None
            if current and current.job_id and current.job_id in self._cancelled:
                self._cancelled.discard(current.job_id)
                raise Cancelled(current.job_id)

    def _take_inline(self) -> _Job | None:
        """Pop the head of the queue if it's an urgent, inline-safe job."""
        with self._queue.mutex:
            q = self._queue.queue
            if q and q[0].priority == URGENT and q[0].inline_ok:
                return heapq.heappop(q)
        return None

    def _execute(self, job: _Job) -> None:
        if job.future.done():  # cancelled while queued
            return
        with self._lock:
            self._current.append(job)
        try:
            job.future.set_result(job.fn(*job.args))
        except BaseException as e:  # noqa: BLE001 — delivered to the caller
            job.future.set_exception(e)
        finally:
            with self._lock:
                self._current.pop()
                if job.job_id:
                    self._cancelled.discard(job.job_id)

    def _loop(self) -> None:
        while True:
            self._execute(self._queue.get())

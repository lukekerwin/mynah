import threading
import time

import pytest

from mynah_engine.worker import BACKGROUND, NORMAL, URGENT, Cancelled, PriorityWorker


def blocked_worker():
    """A worker whose thread is held by a gate job, so later submissions queue up."""
    w = PriorityWorker()
    gate = threading.Event()
    w.submit(gate.wait)
    time.sleep(0.05)
    return w, gate


def test_priority_order_and_fifo_within_priority():
    w, gate = blocked_worker()
    order = []
    futures = [
        w.submit(order.append, "bg", priority=BACKGROUND),
        w.submit(order.append, "n1", priority=NORMAL),
        w.submit(order.append, "u1", priority=URGENT),
        w.submit(order.append, "n2", priority=NORMAL),
        w.submit(order.append, "u2", priority=URGENT),
    ]
    gate.set()
    for f in futures:
        f.result(timeout=2)
    assert order == ["u1", "u2", "n1", "n2", "bg"]


def test_all_jobs_run_on_one_thread():
    w = PriorityWorker()
    ids = {w.run(threading.get_ident, priority=p) for p in (URGENT, NORMAL, BACKGROUND)}
    assert ids == {w.thread_id}


def test_checkpoint_runs_inline_urgent_jobs_only():
    w = PriorityWorker()
    log = []
    started = threading.Event()
    proceed = threading.Event()

    def long_job():
        started.set()
        proceed.wait()
        w.checkpoint()
        log.append("bg-done")

    bg = w.submit(long_job, priority=BACKGROUND, job_id="s1")
    started.wait()
    inline = w.submit(log.append, "dictate", priority=URGENT, inline_ok=True)
    reload = w.submit(log.append, "reload", priority=URGENT)  # not inline-safe
    proceed.set()
    bg.result(timeout=2)
    inline.result(timeout=2)
    reload.result(timeout=2)
    assert log == ["dictate", "bg-done", "reload"]


def test_checkpoint_stops_at_non_inline_head():
    """Inline draining only takes from the head, so it never reorders past a reload."""
    w = PriorityWorker()
    log = []
    started, proceed = threading.Event(), threading.Event()

    def long_job():
        started.set()
        proceed.wait()
        w.checkpoint()
        log.append("bg-done")

    bg = w.submit(long_job, priority=BACKGROUND)
    started.wait()
    w.submit(log.append, "reload", priority=URGENT)
    late = w.submit(log.append, "dictate", priority=URGENT, inline_ok=True)
    proceed.set()
    bg.result(timeout=2)
    late.result(timeout=2)
    assert log == ["bg-done", "reload", "dictate"]


def test_cancel_queued_job():
    w, gate = blocked_worker()
    ran = []
    f = w.submit(ran.append, 1, priority=BACKGROUND, job_id="s1")
    assert w.cancel("s1")
    gate.set()
    with pytest.raises(Cancelled):
        f.result(timeout=2)
    w.run(lambda: None)  # drain
    assert ran == []


def test_cancel_running_job_raises_at_checkpoint():
    w = PriorityWorker()
    started = threading.Event()
    steps = []

    def long_job():
        started.set()
        for i in range(200):
            steps.append(i)
            w.checkpoint()
            time.sleep(0.01)

    f = w.submit(long_job, priority=BACKGROUND, job_id="s1")
    started.wait()
    assert w.cancel("s1")
    with pytest.raises(Cancelled):
        f.result(timeout=2)
    assert len(steps) < 200
    # the worker keeps going afterwards
    assert w.run(lambda: 42) == 42


def test_cancel_unknown_job():
    w = PriorityWorker()
    assert not w.cancel("nope")

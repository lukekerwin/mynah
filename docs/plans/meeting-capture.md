# Meeting Capture Implementation Plan

## Overview

Add meeting capture to Mynah. It detects a Microsoft Teams call, records the other participants
from Teams' own audio output plus the user's mic as a separate track, and transcribes it in
bursts during the call. Afterwards it produces a summary and action items in the background, and
shows meetings, search and a cross-meeting to-do list in a new Meetings window. Everything stays
on the Mac.

This is the first part of a local personal assistant, so the data goes into a structured SQLite
database owned by the app, not loose files.

Requirements: `docs/requirements/meeting-capture.md`.

## Current State Analysis

- **App** (`app/`): a SwiftPM executable target. It has no dependencies and no test target, and
  runs as a SwiftUI menu bar app (`MynahApp.swift`). `AppController` wires
  hotkey → `AudioRecorder` → `EngineClient` → paste.
- **`AudioRecorder`** (`AudioRecorder.swift:10-84`) holds all samples in a `[Float]` array. That
  suits dictation but not hour-long recordings.
- **Settings**: `SettingsStore` is a JSON file (`Settings.swift:41-111`). Its decoder falls back
  to defaults for missing keys (`:65-78`), so adding keys is backward compatible.
- **History**: an append-only JSONL file (`History.swift`). There's no database anywhere yet.
- **Engine** (`engine/src/mynah_engine/`): a `ThreadingHTTPServer` on 127.0.0.1 with a bearer
  token (`server.py:203-252`).
  - All MLX work runs on one `ThreadPoolExecutor(max_workers=1)` and is strictly FIFO
    (`server.py:53,60-61`). There's no way to give dictation priority.
  - `Asr.transcribe` returns only text (`asr.py:30-35`).
  - `Llm` has prefix KV caching (`cleanup.py:40-74`).
- **URLSession** request timeout is 120 s (`EngineClient.swift:108-112`), which is too short for
  summarization.
- **Info.plist** is generated in `scripts/build_app.sh:54-75`. `LSMinimumSystemVersion` is 14.0,
  and there's no `NSAudioCaptureUsageDescription`.
- **CI** (`.github/workflows/ci.yml`): the engine job runs `uv lock --check && uv run --frozen
  pytest -q`. The app job runs `scripts/build_app.sh` (a `swift build`). There are no Swift tests.

### Key Discoveries:

- **Core Audio process objects** (`kAudioHardwarePropertyProcessObjectList`, per-process
  `kAudioProcessPropertyBundleID` / `IsRunningInput` / `IsRunningOutput`) need **no permission**.
  - Listeners on the process list, on `kAudioProcessPropertyIsRunning`, and on the default
    input's `kAudioDevicePropertyDeviceIsRunningSomewhere` fire reliably.
  - Listeners on `IsRunningInput` / `IsRunningOutput` do **not** fire (tested on 15.5). So any
    event should trigger a re-read of those values.
  - Use the C API: the Swift wrappers are macOS 15+.
- **Teams processes:**
  - Bundle IDs are `com.microsoft.teams2` (`MSTeams`), `com.microsoft.teams2.modulehost`
    (`Microsoft Teams ModuleHost`, which likely owns call media) and `com.microsoft.teams2.helper`
    (WebView2).
  - Teams installs a virtual audio device, `MSTeamsAudioDevice.driver`, which must never be used
    as a capture or clock device.
  - Teams embeds a list of third-party recorder apps it flags as "risks", matched by name.
    "Mynah" isn't on it.
- **Process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap`, macOS 14.2+) inside a
  private aggregate device, read with `AudioDeviceCreateIOProcIDWithBlock`.
  - The audiotee approach (an aggregate with **no** hardware subdevice, and the tap set through
    `kAudioAggregateDevicePropertyTapList`) is less sensitive to output-device changes.
  - Teardown order: stop → destroy IO proc → destroy aggregate → destroy tap.
- **Permission:**
  - `NSAudioCaptureUsageDescription` is required in the real Info.plist.
  - The prompt appears on the first `AudioDeviceStart` of a tap aggregate.
  - There is **no public API to check status**, and **a denial produces all-zero buffers, not an
    error**. Mynah therefore detects "Teams output is running but our tap is silent".
  - The grant is tied to the code signature, so the self-signed "Flow Local Signing" identity is
    needed for it to survive rebuilds.
- **Voice processing (AEC)** in Mynah would duck Teams' playback and may interfere with Teams'
  mic, so it is not used. Echo is handled at the text level in the MVP.
- **Teams mute through Accessibility** is unreliable (unstable AX tree, no stable identifiers).
  It's kept best-effort, behind the proof-of-concept result.
- **Parakeet:**
  - `generate()` returns `AlignedResult.sentences`, each with `start`/`end`
    (`mlx_audio/stt/models/nemo/alignment.py:5-38`). There are token timestamps but no word ones.
  - Input must be an `mx.array` at 16 kHz.
  - Built-in `chunk_duration` uses fixed windows. We cut at pauses ourselves.
- **Silero VAD** already ships in the installed mlx-audio 0.5.9
  (`mlx_audio/vad/models/silero_vad/silero_vad.py:209-241`, loaded with
  `mlx_audio.vad.load("mlx-community/silero-vad")`). It's about 2 MB to download and adds no
  dependency.
- **Gemma 4 E4B:** 128K context (`max_position_embeddings 131072`). Its KV cache uses rotating
  512-token windows on sliding layers and full caches on the 1-in-6 global layers. `max_kv_size`
  is ignored for it. Models can be unloaded with `del` + `gc.collect()` + `mx.clear_cache()`.

## Desired End State

When Meetings is enabled in Settings and set up:

1. Joining a Teams call starts recording, or asks first, depending on the setting.
   - The menu bar shows a red icon and the elapsed time.
   - The menu offers Stop, Stop & Discard and Pause my mic.
2. During the call, both tracks are written to disk and transcribed in bursts of about 30 s.
   Dictation keeps working and always goes first.
3. About 1 minute after the call ends, a "Transcript ready" notification appears. The meeting
   shows in Meetings with a timestamped You / Others transcript, with echo lines hidden.
4. Once the Mac is idle and cool, a summary (TL;DR, key points, decisions, open questions) and
   action items are generated. Items appear under To-dos › Mine, linked to their transcript time.
5. Search finds words across all transcripts, summaries and items. Audio is deleted per the
   retention setting.
6. A force-quit during a call loses at most about 1 s of audio, and the meeting is recovered and
   processed on the next launch.

Verification: the automated tests below, plus the manual call scripts in each phase and the
Phase 7 performance run.

## What We're NOT Doing

- Splitting "Others" into individual speakers, voice profiles, or a people table. The schema
  leaves room; nothing is built.
- Auto-detecting anything other than Teams desktop (`com.microsoft.teams2*`). Other apps are
  manual only. Teams in a browser isn't auto-detected.
- Acoustic echo cancellation (AEC3 or Apple voice processing). Echo is removed at the text level
  only.
- A live transcript view, transcript editing, exports (Markdown, Obsidian, Reminders), calendar
  integration, or Q&A over meetings.
- Moving dictation history out of `history.jsonl`.
- Raising the app's macOS minimum (it stays 14.0). The feature is gated at runtime to 14.2+.
- Any network use beyond the one-time ~2 MB Silero VAD download when Meetings is enabled.

## Implementation Approach

**The app owns everything stateful:** detection, capture, files, the database, the job queue and
the UI. The engine stays a stateless model server with two new endpoints and a priority worker.

**Audio is written as 16 kHz mono 16-bit WAV during the call.** That's about 115 MB per hour per
track, and the format can be recovered after a crash just by fixing the header. When the meeting
ends it's compressed to AAC `.m4a` (about 14 MB per hour per track), or deleted, per retention.

**Transcription reads new audio back from the WAV file** at a per-track cursor, so nothing large
is held in memory. The engine finds speech with Silero VAD and returns segments with absolute
timestamps, plus a `consumed_s` value. Speech still in progress at the end of the window is held
back and sent again with the next window, so words are never cut mid-utterance.

### Data Flow

```
Teams process tap ──► TrackWriter(others.wav) ─┐
Mic (AVAudioEngine) ─► gate(dictation/pause/mute) ─► TrackWriter(you.wav) ─┤
                                                                            ▼
            MeetingSession: every 30 s per track, read [cursor, now) → POST /transcribe
                                                                            ▼
                        MeetingStore (GRDB): meeting, segment(+FTS), cursors
                                                                            ▼
     on end: final windows → EchoFilter → compress/delete audio → status=queued
                                                                            ▼
     SummaryRunner (idle + cool) → POST /summarize → summary + action_item(+FTS)
```

---

## Phase 0: Proof of Concept (go/no-go gate)

### Overview

A hidden debug menu that answers five unknowns on real calls before any product code is written:

1. which Teams process holds the audio,
2. whether the permission prompt works with self-signed builds,
3. how bad echo is on speakers,
4. whether the Teams mute button and meeting title can be read,
5. the CPU and temperature cost.

The probe code is written so it's reused later. `CoreAudioProcesses`, `ProcessTap` and
`TrackWriter` from this phase become the production components in Phase 3.

### Changes Required:

#### 1. Info.plist key

**File**: `scripts/build_app.sh`
**Changes**: add the usage string after `NSMicrophoneUsageDescription` (line 72).

```xml
<key>NSAudioCaptureUsageDescription</key><string>Mynah records the audio of calls you choose to capture so it can transcribe them locally on this Mac.</string>
```

#### 2. Core Audio process utilities

**File**: `app/Sources/Mynah/Meetings/CoreAudioProcesses.swift` (new)
**Changes**:
- Typed property readers using the C API: `getUInt32`, `getCFString`, `getObjectList`.
- A process snapshot:

```swift
struct AudioProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let runningInput: Bool
    let runningOutput: Bool
}

enum CoreAudioProcesses {
    static func snapshot() -> [AudioProcess]          // kAudioHardwarePropertyProcessObjectList + per-process reads
    static func defaultOutputDeviceUID() -> String?   // kAudioHardwarePropertyDefaultOutputDevice (NOT DefaultSystemOutputDevice)
}

/// Fires `onChange` (on the main queue, coalesced to ≤ 4 Hz) for: process-list changes,
/// kAudioProcessPropertyIsRunning on each process, IsRunningSomewhere on the default
/// input device, and default input/output device changes. Callers re-read `snapshot()`.
final class AudioActivityMonitor { var onChange: (() -> Void)?; func start(); func stop() }
```

- Read `UInt32` properties as `UInt32`, not `Int` (AudioCap's bug).
- Re-register per-process listeners whenever the process list changes.

#### 3. Process tap

**File**: `app/Sources/Mynah/Meetings/ProcessTap.swift` (new, `@available(macOS 14.2, *)`)
**Changes**:
- `ProcessTap(processes: [AudioObjectID])` with `start(onAudio:)`, `stop()` and
  `updateProcesses(_:)`.
- Setup:
  - `CATapDescription(stereoMixdownOfProcesses:)` with `isPrivate = true` and
    `muteBehavior = .unmuted`.
  - A private aggregate with tap auto-start and **no subdevices**. Set the tap list through
    `kAudioAggregateDevicePropertyTapList` (the audiotee approach).
  - If that yields no IO callbacks within 2 s, rebuild using the default output device as the
    main subdevice. Skip any device whose UID contains `MSTeamsAudioDevice`.
- `updateProcesses` sets `kAudioTapPropertyDescription` on the live tap. If that fails, it does a
  full rebuild.
- It listens for `kAudioTapPropertyFormat` and default-output changes, and on either does a full
  rebuild: stop → destroy IO proc → destroy aggregate → destroy tap → recreate.
- The IO block copies `inInputData` into a `RingBuffer` (below) and does nothing else. No
  allocation and no file I/O on the IO thread.

#### 4. Ring buffer and track writer

**File**: `app/Sources/Mynah/Meetings/TrackWriter.swift` (new)
**Changes**:
- `RingBuffer`: a preallocated `[Float]` holding 10 s at the source rate, guarded by
  `OSAllocatedUnfairLock`. The producer writes; the consumer drains.
- `TrackWriter(url:sourceFormat:)`:
  - A 250 ms `DispatchSourceTimer` on a utility-QoS serial queue drains the ring.
  - It downmixes to mono, resamples to 16 kHz with `AVAudioConverter` (as in
    `AudioRecorder.process`), converts to Int16 and appends to a WAV file.
  - It rewrites the RIFF/data size fields every 5 s and on `close()`.
- Exposes `samplesWritten` (16 kHz frames) and `peakSinceLastRead` (used for silence detection).
- Pure helpers go in the `MynahCore` library (Phase 2): `WAVHeader.make(dataBytes:)` and
  `WAVHeader.repair(url:)`. Phase 0 keeps them in the app target, and Phase 2 moves them.

#### 5. Debug menu and probes

**Files**: `app/Sources/Mynah/Meetings/MeetingProbe.swift` (new) and `MynahApp.swift`
**Changes**:
- If `UserDefaults.standard.bool(forKey: "MynahDebugMeetings")` is set, `MenuContent` shows a
  **Debug** submenu with these items:
  - **Log audio processes (toggle):** `AudioActivityMonitor`, logging every change of pid,
    bundleID, `runningInput` and `runningOutput` to `~/Library/Logs/Mynah/meetings.log`.
  - **Record Teams + mic (toggle):**
    - Taps all `com.microsoft.teams2*` processes, and records the mic through a second
      `AVAudioEngine`, to `~/Desktop/mynah-probe-<timestamp>/others.wav` and `you.wav`.
    - Every 10 s it logs:
      - `ProcessInfo.thermalState`,
      - CPU % for Mynah and for the engine pid (`proc_pid_rusage`),
      - Mynah's resident memory,
      - the tap's non-silent ratio.
    - If the tap's non-silent ratio stays at 0 while any Teams process has `runningOutput`,
      it logs `TAP SILENT — permission?`.
  - **Dump Teams accessibility tree:**
    - For each `com.microsoft.teams2*` pid, sets `AXManualAccessibility` and
      `AXEnhancedUserInterface`.
    - Walks windows to depth 25, writing role, title, description, identifier and
      value to `~/Desktop/mynah-probe-ax-<timestamp>.txt`.
- Meant to be run during a call while muted and while unmuted.

#### 6. Offline analysis script

**File**: `bench/meeting_probe.py` (new)
**Changes**:
- Input: a probe folder.
- Runs Silero VAD and Parakeet on `others.wav` and `you.wav`, and prints segments with times.
- Reports the real-time factor and per-window latency for 30 s windows.
- Runs the Phase 3 echo heuristic (implemented in the script, the same logic as `EchoFilter`)
  and reports how many "You" segments are flagged as echo.
- Uses the `bench/` environment, where mlx-audio is already a dependency. If it isn't, add it to
  `bench/pyproject.toml`.

### Go/No-Go Decisions (record the results in a `## Proof of Concept Results` section appended to this plan)

| Question | Pass | If it fails |
|---|---|---|
| A tap on `com.microsoft.teams2*` captures the remote voices, on both headphones and speakers | Others transcript is intelligible | Try tapping only ModuleHost, and the output-subdevice aggregate. If still failing, stop and re-plan (consider ScreenCaptureKit audio) |
| The permission prompt appears, and the grant survives relaunch and rebuild with `MYNAH_SIGN_IDENTITY` | Yes | Document it. The release build still works (the grant just resets on update) |
| Silent-tap detection fires when permission is denied (`tccutil reset AudioCapture com.lukekerwin.mynah`, deny) | Yes | Use the private `TCCAccessPreflight` (dlopen, AudioCap's approach) only for the status display |
| Text-level echo filter on a speakers recording | ≤ 10% of echo lines left | Ship anyway. Note "use headphones for best results" in Settings and the README, and add AEC to the roadmap |
| The mute button can be found in the AX dump, with consistent description text, in 2 calls | Yes | Don't ship AX mute (`TeamsMuteProbe` isn't built). Pause my mic only |
| The meeting title can be found in the AX dump | Yes | Default title "Teams call – <date>" |
| Mynah CPU < 5% of one core on average while recording; thermal state stays nominal or fair over a 30-minute video call | Yes | Profile with Instruments before continuing |
| Parakeet on a 30 s window takes < 1.0 s on an M2 Max | Yes | Use 60 s windows |

### Success Criteria:

#### Automated Verification:
- [x] The app builds: `scripts/build_app.sh`
- [x] Info.plist has the key: `plutil -p build/Mynah.app/Contents/Info.plist | grep NSAudioCaptureUsageDescription`
- [x] Engine tests still pass: `cd engine && uv run --frozen pytest -q`

#### Manual Verification:
- [ ] On `MYNAH_SIGN_IDENTITY="Flow Local Signing" scripts/build_app.sh --install`, with
      `defaults write com.lukekerwin.mynah MynahDebugMeetings -bool YES`, the Debug menu appears
- [ ] 2–3 real Teams calls recorded: headphones, speakers, and one with mute toggled
- [ ] `uv run python meeting_probe.py ~/Desktop/mynah-probe-…` (from `bench/`) produces
      transcripts for both tracks
- [ ] The results table is filled in and a go decision recorded before starting Phase 3

---

## Phase 1: Engine — Priority Worker, `/transcribe`, `/summarize`

### Overview

Make dictation always go first, and add the two model endpoints meetings need. Phase 1 can be
built in parallel with Phase 0.

### Changes Required:

#### 1. Priority worker

**File**: `engine/src/mynah_engine/worker.py` (new)

```python
URGENT, NORMAL, BACKGROUND = 0, 1, 2   # dictation/command/config, transcribe, summarize

class Cancelled(Exception): ...

class PriorityWorker:
    """One thread runs every MLX call (MLX binds GPU streams to their thread).
    Lower priority value runs first; FIFO within a priority.

    Long background jobs call `checkpoint()` between tokens: it runs any queued
    URGENT jobs inline on this same thread (safe for MLX) and raises Cancelled if
    the current job was cancelled."""

    def submit(self, fn, *args, priority=URGENT, job_id: str | None = None) -> Future: ...
    def run(self, fn, *args, priority=URGENT, job_id=None):  # blocking helper
        return self.submit(fn, *args, priority=priority, job_id=job_id).result()
    def cancel(self, job_id: str) -> bool: ...   # queued → removed; running → flag for checkpoint()
    def checkpoint(self) -> None: ...
```

- Implemented with `queue.PriorityQueue` of `(priority, seq, job)`.
- `checkpoint()` only drains jobs whose priority is `URGENT` **and** that were submitted with
  `inline_ok=True`. Dictate and command set it; `_load` (model reloads) never runs inline.

**File**: `engine/src/mynah_engine/server.py`
- `Engine.worker = PriorityWorker()`, and `Engine.run` forwards `priority` and `job_id`.
- `/dictate` and `/command` use `URGENT, inline_ok=True`.
- `configure` submits `_load` at `URGENT` (not inline).

#### 2. Timestamped transcription

**File**: `engine/src/mynah_engine/asr.py`
- Add `transcribe_aligned(audio, vocab) -> list[tuple[float, float, str]]`.
  - It uses `out.sentences` when present (Parakeet). Otherwise it returns
    `[(0, len/SR, out.text)]`.
  - Leave `transcribe()` unchanged.

**File**: `engine/src/mynah_engine/meeting.py` (new)

```python
VAD_REPO = "mlx-community/silero-vad"
MAX_REGION_S = 30.0      # longer speech regions are split at the quietest 100 ms frame
MERGE_GAP_S = 0.6        # regions closer than this are transcribed together
TAIL_GUARD_S = 0.4       # speech touching the window end is held back (non-final windows)

def plan_regions(speech: list[tuple[float, float]], window_s: float, final: bool
                 ) -> tuple[list[tuple[float, float]], float]:
    """Pure: merge/split VAD regions; return (regions to transcribe, consumed_s).
    consumed_s = start of a held-back trailing region, else window_s."""

class MeetingTranscriber:
    def __init__(self, engine): ...            # lazily loads Silero VAD on first use
    def transcribe(self, audio: np.ndarray, offset_s: float, vocab: list[str], final: bool) -> dict:
        # -> {"segments": [{"start", "end", "text"}], "consumed_s": float, "asr_ms": int}
```

- Segment times are `offset_s + region_start + sentence_start`.
- Text goes through `apply_vocab` (the personal dictionary) but **not** through LLM cleanup.
  Parakeet already punctuates, and this keeps each burst cheap.
- Regions under 0.3 s or below `SILENCE_RMS` are skipped.

**File**: `engine/src/mynah_engine/server.py`
- `POST /transcribe {"audio": b64, "offset_s": float, "vocab": [...], "final": bool}` runs at
  `NORMAL` priority.
- `POST /meeting/prepare` calls `ensure_downloaded(VAD_REPO, "Voice detector")` and loads the
  VAD at `NORMAL` priority. The app calls it when Meetings is enabled, so the download happens
  then.
- Update the module docstring's API list.

#### 3. Summarization

**File**: `engine/src/mynah_engine/summarize.py` (new)

```python
SUMMARY_SCHEMA = {  # documented in the system prompt; validated by normalize()
  "tldr": str, "key_points": [str], "decisions": [str], "open_questions": [str],
  "action_items": [{"text": str, "owner": "me" | "<name>" | "unassigned",
                    "due": "YYYY-MM-DD" | None, "time_s": float | None}],
}

def format_transcript(segments: list[dict], my_name: str | None) -> str:
    """'[12:04] You: …' / '[12:09] Others: …' lines; consecutive same-speaker lines merged."""

def split_sections(text: str, max_tokens: int, count_tokens) -> list[str]:
    """Split on line boundaries into ≤ max_tokens chunks (map step for long meetings)."""

def parse_json(raw: str) -> dict:
    """Extract the outermost {...}; json.loads; raise ValueError on failure."""

def normalize(d: dict, duration_s: float) -> dict:
    """Coerce types, drop empty items, clamp time_s to [0, duration], lower-case owner 'me'."""

class Summarizer:
    def __init__(self, engine): ...
    def summarize(self, segments, title, my_name, model_key, job_id) -> dict: ...
```

- **Prompting:** a system prompt with the schema and rules:
  - extract every commitment;
  - the owner is "me" when You commits, or when Others asks You and You agrees;
  - use a name mentioned in the transcript, otherwise "unassigned";
  - `time_s` is the `[mm:ss]` of the line the item comes from;
  - no invented content;
  - JSON only.

  Greedy decoding (temperature 0), with `max_tokens` of 2000.
- **Long meetings:** if the transcript exceeds 24k tokens, each section is summarized to the same
  schema (the map step), then the section JSONs are merged by a final call (the reduce step).
- **Robustness:** on `parse_json` failure, retry once with "Your previous output was not valid
  JSON. Output only the JSON object." If that also fails, raise, and the app marks the meeting
  Failed.
- **Preemption:** the token loop calls `engine.worker.checkpoint()` every 8 tokens, so dictation
  runs between tokens and cancellation is honored.
- **Model:** `model_key=None` uses the loaded cleanup LLM (`engine.llm`). Otherwise the requested
  `LLM_MODELS` key is loaded (`ensure_downloaded` first). After the job it's released with
  `del` + `gc.collect()` + `mx.clear_cache()`. Non-general (`style != "general"`) models are
  rejected.
- **Endpoints:**
  - `POST /summarize {"segments": [...], "title": str, "my_name": str | null,
    "model": key | null, "duration_s": float, "job_id": str}` runs at `BACKGROUND`. It returns
    the normalized dict plus `"model"` and `"llm_ms"`.
  - `POST /cancel {"job_id": str}` returns `{"cancelled": bool}`.
  - On cancellation the request returns HTTP 409 `{"error": "cancelled"}`.

#### 4. Tests

**Files**: `engine/tests/test_worker.py`, `test_meeting.py`, `test_summarize.py` (new). All
model-free.

- **`test_worker`:**
  - priority order;
  - FIFO within a priority;
  - `checkpoint()` runs inline-ok urgent jobs and skips non-inline ones;
  - `cancel` on queued and on running jobs (`Cancelled` raised at the next `checkpoint`);
  - all jobs run on the same thread id.
- **`test_meeting`:** `plan_regions`:
  - merges gaps under 0.6 s;
  - splits regions over 30 s;
  - holds back a tail that touches the window end when not final;
  - doesn't hold back on final;
  - an empty window gives `consumed_s == window_s`.
- **`test_summarize`:**
  - `format_transcript` merges and stamps lines;
  - `split_sections` respects the budget and line boundaries;
  - `parse_json` handles ```json fences, leading text and invalid input;
  - `normalize` coerces types and clamps times.

### Success Criteria:

#### Automated Verification:
- [x] Engine tests pass: `cd engine && uv run --frozen pytest -q`
- [x] Lockfile unchanged or updated consistently: `cd engine && uv lock --check`
- [x] App still builds: `scripts/build_app.sh`

#### Manual Verification:
- [x] Run the engine in development
      (`MYNAH_ENGINE_TOKEN=x uv run python -m mynah_engine --port 47821`, from `engine/`).
      `curl` `/transcribe` with a 30 s WAV from a Phase 0 probe; it returns sentence segments with
      plausible absolute times.
      *(Verified with synthetic `say` audio rather than a probe recording: sentence segments with correct absolute times, and the tail was held back across windows.)*
- [x] `/summarize` on a real probe transcript returns valid JSON with sensible action items.
      *(Verified on a synthetic two-speaker transcript: correct owners (me / Priya), decisions and open questions; 4.4 s.)*
- [x] While a `/summarize` is running, a dictation in the app returns in under 1 s.
      *(Measured against the engine directly: 0.67–1.48 s, vs 0.54 s idle. See Implementation Notes.)*
- [x] `/cancel` stops a running summary within about 1 s, with HTTP 409.
      *(0.11–0.35 s.)*
- [ ] Dictation latency is unchanged when idle (check `asr`/`llm` ms in the engine log against
      before).

---

## Phase 2: Storage Foundation (GRDB, schema, search, retention, Swift tests)

### Overview

Add the database that meetings, and later the rest of the assistant, live in. Also add the first
Swift test target.

### Changes Required:

#### 1. Package layout

**File**: `app/Package.swift`

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Mynah",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Pure logic + persistence; no AppKit. Unit-tested.
        .target(name: "MynahCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                path: "Sources/MynahCore"),
        .executableTarget(name: "Mynah", dependencies: ["MynahCore"], path: "Sources/Mynah"),
        .testTarget(name: "MynahCoreTests", dependencies: ["MynahCore"], path: "Tests/MynahCoreTests"),
    ]
)
```

- Pin the resolved GRDB version by committing `app/Package.resolved`.
- `build_app.sh` needs no changes: `swift build` resolves packages, and the release binary links
  GRDB statically.

#### 2. Records and schema

**File**: `app/Sources/MynahCore/MeetingModels.swift` (new). Codable GRDB records:

```swift
public enum MeetingStatus: String, Codable { case recording, transcribing, queued, summarizing, done, failed, noSpeech = "no_speech" }
public enum Track: String, Codable { case you, others }

public struct Meeting: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: String               // UUID string
    public var title: String
    public var titleEdited: Bool
    public var appBundleID: String
    public var appName: String
    public var source: String           // "auto" | "manual"
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var error: String?
    public var youCursorS: Double       // transcribed-through position per track
    public var othersCursorS: Double
    public var hasSpeech: Bool
    public var audioDeletedAt: Date?
}
public struct Segment: … { id: Int64?; meetingID: String; track: Track; startS: Double; endS: Double; text: String; hiddenReason: String? }
public struct MeetingSummary: … { meetingID: String; model: String; createdAt: Date; tldr: String;
                                  keyPoints: [String]; decisions: [String]; openQuestions: [String] }  // arrays stored as JSON text
public struct ActionItem: … { id: Int64?; meetingID: String?; source: String /* meeting|manual */;
                              text: String; ownerKind: String /* me|person|unassigned */; ownerName: String?;
                              dueDate: String?; timeS: Double?; status: String /* open|done */;
                              completedAt: Date?; userEdited: Bool; deleted: Bool;
                              extractionKey: String?; createdAt: Date; updatedAt: Date }
```

**File**: `app/Sources/MynahCore/MeetingStore.swift` (new)
- `DatabaseMigrator` with migration `"v1-meetings"`:
  - Tables: `meeting`, `segment` (FK → meeting `ON DELETE CASCADE`, index on
    `(meetingID, startS)`), `meetingSummary` (PK and FK meetingID, cascade), `actionItem` (FK →
    meeting, cascade, nullable for manual items).
  - FTS5 tables: `segmentFTS`, `summaryFTS` (tldr + key points + decisions + open questions as
    one text column) and `actionItemFTS`, each kept in sync with
    `create(virtualTable:using: FTS5()) { $0.synchronize(withTable:) … }` and the `porter`
    tokenizer.
  - Future speaker and people work adds tables and nullable columns in later migrations. Nothing
    is reserved now.
- Location: `~/Library/Application Support/Mynah/mynah.sqlite` (from `SettingsStore.directory`),
  opened as a `DatabasePool` (WAL mode).
- API (all synchronous, called off the main thread):
  - `createMeeting`, `updateStatus`, `appendSegments(_:track:cursor:)` (inserts segments and
    advances the cursor in one transaction), `markEcho(ids:)`, `saveSummary(_:items:)` (merge
    rules below), `delete(meetingID:)`, `search(_ query:) -> [SearchHit]`, plus action-item
    CRUD.
  - `meetingsObservation()` and `actionItemsObservation(filter:)` return GRDB
    `ValueObservation`s for SwiftUI.
- **Merge rules for `saveSummary`, when a summary is re-run:**
  1. Delete the meeting's items where `userEdited == false && status == "open" && deleted == false`.
  2. For each new item, compute `extractionKey` (lowercased, punctuation stripped, whitespace
     collapsed text).
  3. Skip it if any remaining item for the meeting (edited, done or tombstoned) has the same key.
  4. Insert the rest.

  Deleting an item in the UI sets `deleted = true` (a tombstone), which hides it but stops it
  from coming back on a re-run.

#### 3. Pure helpers (moved from Phase 0 and new)

**Files**: in `app/Sources/MynahCore/`:
- **`WAVHeader.swift`**: `make` and `repair`.
- **`EchoFilter.swift`**:

  ```swift
  /// A "You" segment is echo when ≥ 60% of its words (≥ 3 words) appear in "Others"
  /// segments overlapping [start − 1.5 s, end + 1.5 s].
  public enum EchoFilter { public static func echoIDs(you: [Segment], others: [Segment]) -> [Int64] }
  ```

- **`RetentionPolicy.swift`**:

  ```swift
  public enum AudioRetention: String, Codable, CaseIterable { case afterTranscript, days7, days30, forever }
  public static func audioDue(endedAt: Date, policy: AudioRetention, now: Date) -> Bool
  ```

- **`TranscriptFormatter.swift`**: merges "You" and "Others" segments in time order for display
  and for `/summarize`, skipping hidden segments.

#### 4. Tests

**Directory**: `app/Tests/MynahCoreTests/` (Swift Testing)
- **`MeetingStoreTests`** (in-memory `DatabaseQueue`):
  - migrations apply;
  - appending advances the cursor in the same transaction;
  - deleting a meeting cascades to segments, summary and items;
  - FTS finds words across all three tables;
  - re-running a summary keeps edited, done and tombstoned items and doesn't duplicate them.
- **`EchoFilterTests`**:
  - exact echo;
  - partial echo (above and below 60%);
  - no time overlap means not echo;
  - segments under 3 words are never echo.
- **`WAVHeaderTests`**: `repair` fixes sizes on a truncated file.
- **`RetentionPolicyTests`**: each policy at its boundaries.

#### 5. CI

**File**: `.github/workflows/ci.yml`. Add a step to the `app` job before the build:

```yaml
      - name: Swift unit tests
        working-directory: app
        run: swift test
```

### Success Criteria:

#### Automated Verification:
- [x] `cd app && swift test` passes
- [x] `scripts/build_app.sh` passes (the GRDB-linked release build)
- [x] `cd engine && uv run --frozen pytest -q` passes
- [x] `app/Package.resolved` exists (to be committed with this work)

#### Manual Verification:
- [ ] The app launches; `~/Library/Application Support/Mynah/mynah.sqlite` is created, and
      `sqlite3 … ".tables"` shows the tables and FTS tables
- [ ] Dictation still works (no regression from the package restructure)

---

## Phase 3: Capture Pipeline

### Overview

The production recording session: detection, both tracks, gating, bursts of transcription
during the call, finalization and crash recovery. There's no UI beyond what's needed to test it
(Phase 4 adds that).

### Changes Required:

#### 1. Teams detector

**File**: `app/Sources/Mynah/Meetings/MeetingDetector.swift` (new)

```swift
@MainActor
final class MeetingDetector {
    static let teamsPrefix = "com.microsoft.teams2"
    var onCallStarted: (() -> Void)?
    var onCallEnded: (() -> Void)?
    var graceSeconds: TimeInterval = 30
    /// Teams processes currently using input or output; passed to ProcessTap.updateProcesses.
    private(set) var teamsProcesses: [AudioProcess] = []
}
```

- Built on `AudioActivityMonitor`.
- **Started:** fires on the first snapshot where any Teams process has `runningInput`.
- **Ended:** fires when no Teams process has had `runningInput` for `graceSeconds`. A one-shot
  timer is cancelled if input resumes.
- Each snapshot updates `teamsProcesses`, so ModuleHost can appear mid-call.

#### 2. Mic track with gating

**File**: `app/Sources/Mynah/Meetings/MeetingMic.swift` (new)
- Its own `AVAudioEngine`, separate from the dictation `AudioRecorder`. Taps the default input in
  its native format and feeds a `RingBuffer`, then a `TrackWriter("you.wav")`.
- `var gate: OSAllocatedUnfairLock<GateState>` holds `dictating`, `paused` and `teamsMuted`.
  - While any of them is true, the IO block writes **zeros** instead of the samples. This keeps
    the two tracks' timelines aligned.
- Restarts itself on `AVAudioEngineConfigurationChange` (input device changed).
- Never enables voice processing.

**File**: `app/Sources/Mynah/AppController.swift`
- In `handlePress`, after `recorder.start()` succeeds, call `meetings.setDictating(true)`.
- In `finish()` and `cancel()`, call `meetings.setDictating(false)`.
- `meetings` is the `MeetingController`, owned by `AppController` (Phase 4).

#### 3. Teams mute probe (only if Phase 0 passed)

**File**: `app/Sources/Mynah/Meetings/TeamsMuteProbe.swift` (new)
- During a meeting, a 2 s timer walks the AX tree of each Teams pid for a button whose
  description or title matches the patterns recorded in Phase 0.
- It sets `gate.teamsMuted`. Unknown counts as not muted. The first time it's unknown, it logs
  "mute tracking unavailable" once.

#### 4. Session

**File**: `app/Sources/Mynah/Meetings/MeetingSession.swift` (new)

```swift
/// One recording. Owns both tracks, the transcription loop and finalization.
final class MeetingSession {
    init(meeting: Meeting, store: MeetingStore, engine: EngineClient, tapProcesses: [AudioObjectID],
         vocabulary: [String], directory: URL)
    func start() throws
    func updateTapProcesses(_ ids: [AudioObjectID])
    func stop(discard: Bool) async    // discard → delete files + meeting row
    var elapsed: TimeInterval { get }
    var othersSilentWhilePlaying: Bool { get }   // permission check signal
}
```

- **Directory:** `~/Library/Application Support/Mynah/Meetings/<meetingID>/` with `others.wav`
  and `you.wav`.
- **Transcription loop** (a utility-priority `Task`):
  - Every 30 s, alternating tracks 15 s apart, read from the WAV file between the stored cursor
    and the written end.
  - Call `engine.transcribe(samples:offset:vocab:final:false)`, then
    `store.appendSegments(…, cursor: offset + consumed_s)`.
  - If the engine isn't `.ready`, or a call fails, skip it. The cursor stays put, and the window
    can grow up to 120 s; beyond that it's processed in 120 s slices.
- **Silent-tap check:** if any Teams process has `runningOutput` for 60 s or more and the others
  track has **never produced a non-zero sample**, set `othersSilentWhilePlaying = true`.
  `MeetingController` surfaces this (Phase 4).
  - A denied permission gives exact zeros.
  - Teams keeps its output open through silence (the first probe showed this), so a
    level-threshold check gave false alarms.
- **`stop(discard: false)`:**
  1. Close the writers.
  2. Run final windows (`final: true`) for both tracks until the cursors reach the end.
  3. Run `EchoFilter.echoIDs` over the meeting's segments, then `store.markEcho`.
  4. Set `hasSpeech` to whether any visible segment exists.
  5. Status becomes `queued` if there's speech, otherwise `noSpeech`.
  6. Apply audio retention:
     - `afterTranscript`: delete the WAVs.
     - Otherwise, compress each WAV to `.m4a` (AAC, 16 kHz mono, 32 kbps, using `AVAudioFile`
       write settings) on a utility queue, then delete the WAV.
- **Discard:** stop the writers, delete the directory and `store.delete(meetingID:)`.

#### 5. Engine client additions

**File**: `app/Sources/Mynah/EngineClient.swift`

```swift
struct TranscribeResult: Decodable { var segments: [Seg]; var consumed_s: Double; var asr_ms: Int
                                     struct Seg: Decodable { var start: Double; var end: Double; var text: String } }
func transcribe(samples: [Float], offset: Double, vocab: [String], final: Bool) async throws -> TranscribeResult
func prepareMeetings() async throws
func summarize(segments: [[String: Any]], title: String, myName: String?, model: String?,
               duration: Double, jobID: String) async throws -> SummaryResult   // uses longSession
func cancel(jobID: String) async
```

- Add `private let longSession` with a 1800 s request timeout, used only for `/summarize`.

#### 6. Crash recovery

**File**: `app/Sources/Mynah/Meetings/MeetingController.swift` (created here, finished in
Phase 4)
- On launch, for each meeting with status `recording` or `transcribing`:
  1. `WAVHeader.repair` both files.
  2. Set `endedAt` to the file's last-modified time.
  3. Set status to `transcribing`.
  4. Once the engine is ready, run the same final-window and finalize steps as `stop`.

### Success Criteria:

#### Automated Verification:
- [x] `cd app && swift test` passes
- [x] `scripts/build_app.sh` passes

#### Manual Verification (temporary Debug items: "Start session now" / "Stop session"):
- [ ] A 10-minute Teams call on headphones: `segment` rows appear during the call. After stop,
      the transcript is complete within 60 s, and both `.m4a` files exist with no WAVs left.
- [ ] The same on speakers: the echo lines from "You" are hidden (`hiddenReason = 'echo'`), and
      no real "You" lines are hidden.
- [ ] Dictating into Teams chat during the call: the dictation is absent from the "You" track,
      and the dictation still pastes normally.
- [ ] Unplugging or plugging headphones mid-call: both tracks continue (any gap is under 2 s).
- [ ] `kill -9` of Mynah mid-call, then relaunch: the meeting is recovered, finalized and has a
      transcript.
- [ ] Quitting the engine mid-call (Help › Restart Engine): capture continues, and the backlog
      is transcribed after the engine is ready.

---

## Phase 4: App Integration (settings, setup, menu bar, notifications, manual record)

### Overview

Turn the session into the user-facing feature: enable and setup, auto or ask, the recording
indicator and controls, and manual recording of other apps.

### Changes Required:

#### 1. Settings

**File**: `app/Sources/Mynah/Settings.swift`. Add these fields, with `decodeIfPresent` defaults
in `init(from:)`:

```swift
var meetingsEnabled = false
var meetingsConsentAcknowledged = false
var meetingsAutoRecord = true              // false = Ask me
var meetingAudioRetention: AudioRetention = .days7
var meetingSummaryModel = "default"        // "default" = cleanup LLM, else an LLM_MODELS key (general style only)
var meetingMyName = ""                     // optional, helps owner attribution
var pauseMicShortcut = true                // ⌃⌥M toggles Pause my mic while recording
var teamsMuteDetection = true              // only shown if TeamsMuteProbe shipped
```

#### 2. Meeting controller

**File**: `app/Sources/Mynah/Meetings/MeetingController.swift`

```swift
@MainActor
final class MeetingController: ObservableObject {
    enum State: Equatable { case off, unavailable(String), idle, asking, recording(meetingID: String, since: Date, paused: Bool) }
    @Published private(set) var state: State
    @Published private(set) var permissionProblem: Bool     // silent tap while Teams plays
    func enable() async            // setup flow (below)
    func startManual(bundlePrefix: String, appName: String)
    func stop(discard: Bool)
    func togglePauseMic()
    func setDictating(_ on: Bool)
    func audioApps() -> [(bundleID: String, name: String)]   // processes with runningOutput, minus Mynah
}
```

- Created by `AppController` and passed `settings`, `engine` and the store.
- On macOS < 14.2 the state is `unavailable("Requires macOS 14.2 or later")`.
- **Auto mode:** on `onCallStarted`, create the meeting and session, then post a "Recording Teams
  call" notification.
- **Ask mode:** on `onCallStarted`, post a notification with Record and Ignore actions.
  - Record starts the session; the audio from the ask moment is lost (acceptable).
  - Ignore sets a flag so this call is skipped until `onCallEnded`.
- **Ending:** on `onCallEnded`, or the user's Stop, call `session.stop`. When finalizing
  completes, post "Transcript ready: <title>" and tell `SummaryRunner` to schedule (Phase 5).
- **Manual recordings** use a `ProcessTap` over every process whose bundle ID starts with the
  chosen prefix. The detector is ignored while one is active. If a Teams call starts during a
  manual recording, it doesn't start a second session.
- **Title:** use the AX meeting-window title if Phase 0 found a reliable pattern. Otherwise
  "Teams call – <date time>", or "<App> call – <date time>" for manual recordings.
- **Pause my mic shortcut:** ⌃⌥M, handled in `HotkeyMonitor`'s existing global keyDown monitor.
  Add an `onPauseMic` callback, checked only while recording and only when `pauseMicShortcut` is
  on.

#### 3. Setup flow

**File**: `app/Sources/Mynah/Meetings/MeetingSetupView.swift` (new). A sheet shown from
Settings › Meetings when it's turned on. Steps:
1. **Consent note:** recording laws vary; record only calls you're allowed to; meant for personal
   calls. An "I understand" checkbox sets `meetingsConsentAcknowledged`.
2. **Notifications:** `UNUserNotificationCenter.requestAuthorization`.
3. **System audio permission:** "Allow…" starts a `ProcessTap` over Mynah's own process for 1 s.
   That triggers the system prompt, after which the tap is stopped. The status text says it's
   verified on the first call. If a call later shows a silent tap, a banner in Settings and the
   menu explains how to enable it in System Settings › Privacy & Security › Screen & System
   Audio Recording.
4. **Voice detector download:** `engine.prepareMeetings()`, with progress taken from the
   existing `/health` download field.

#### 4. Settings tab

**File**: `app/Sources/Mynah/SettingsView.swift`. Add a `MeetingsTab` between Snippets and
Permissions with:
- the enable toggle (opens setup the first time);
- "When a Teams call starts: Record automatically / Ask me";
- "Keep meeting audio: Delete after transcript / 7 days / 30 days / Forever";
- the summary model picker: "Same as cleanup model (default)" plus downloaded general-style LLMs
  from `/models`;
- a "Your name (optional)" field;
- a "Pause my mic shortcut (⌃⌥M)" toggle;
- a Teams mute detection toggle (if shipped);
- the permission-problem banner;
- a "Use headphones for the cleanest transcript" tip;
- the macOS 14.2 unavailability text.

Raise the TabView frame height if needed.

#### 5. Menu bar

**File**: `app/Sources/Mynah/MynahApp.swift`
- `MenuIcon` also observes `MeetingController`. While recording it shows a **non-template** red
  `record.circle.fill` image (an `NSImage` with `isTemplate = false`, tinted red; MenuBarExtra
  template-renders SF Symbols otherwise) and `Text(timerInterval: since...Date.distantFuture)`
  for the elapsed time.
- Dictation states (`record.circle` / `ellipsis.circle`) take precedence while active.
- `MenuContent`:
  - while recording: "● Recording <title> — mm:ss", **Pause my mic** / Resume my mic, **Stop**,
    **Stop & Discard…** (with a confirm alert);
  - when idle and enabled: **Record meeting…**, a submenu built from `audioApps()`;
  - always: **Meetings…**, which opens the Phase 6 window;
  - the permission-problem warning line, when relevant.

#### 6. Notifications

**File**: `app/Sources/Mynah/Meetings/MeetingNotifications.swift` (new)
- `UNUserNotificationCenter` delegate with a `MEETING_ASK` category (Record and Ignore actions).
- Posts: started, ask, transcript ready, summary ready, failed.
- Clicking a notification opens the meeting in the Meetings window.

### Success Criteria:

#### Automated Verification:
- [x] `cd app && swift test` passes (add `SettingsStore.Data` decode tests: old JSON without the
      meeting keys decodes to the defaults; this needs `SettingsStore.Data` moved to `MynahCore`
      or a decode-only copy of the struct)
- [x] `scripts/build_app.sh` passes

#### Manual Verification:
- [ ] Fresh enable runs setup: the consent checkbox, the notification prompt, the system audio
      prompt and the VAD download all work
- [ ] Auto mode: joining a Teams call shows the red icon and timer plus a notification. Leaving
      it ends recording about 30 s later and posts "Transcript ready"
- [ ] Ask mode: Record starts, and Ignore suppresses the whole call
- [ ] Pause my mic (menu and ⌃⌥M): speech during the pause is absent from "You", and "Others"
      continues
- [ ] Stop & Discard leaves no meeting row and no files
- [ ] Record meeting… › FaceTime records a FaceTime call until Stop
- [ ] Denying System Audio Recording, then joining a call: the permission banner appears within
      about 30 s
- [ ] Meetings disabled: no detector runs, and Mynah's idle CPU is unchanged

---

## Phase 5: Summary Job Runner

### Overview

Generate summaries and action items in the background only when it won't affect the user, with
manual Summarize now and Retry.

### Changes Required:

**File**: `app/Sources/Mynah/Meetings/SummaryRunner.swift` (new)

```swift
@MainActor
final class SummaryRunner: ObservableObject {
    @Published private(set) var running: String?       // meetingID
    func schedule(after delay: TimeInterval = 180)        // called after finalize
    func summarizeNow(_ meetingID: String)                // bypasses idle/thermal checks, not dictation priority
    func retry(_ meetingID: String)
}
```

- **Eligibility**, checked by a 60 s timer, on `ProcessInfo.thermalStateDidChangeNotification`,
  and on meeting end. All of these must hold:
  - `engine.status == .ready`;
  - `MeetingController.state` isn't `recording` or `asking`;
  - `AppController.phase == .idle`;
  - `thermalState` is `.nominal` or `.fair`;
  - at least one meeting has status `queued` and the delay has passed.
- **Running a job:**
  1. Take the oldest `queued` meeting and set it to `summarizing`.
  2. Build segments with `TranscriptFormatter` (visible segments only).
  3. Call `engine.summarize(jobID: meetingID)`.
  4. On success, `store.saveSummary` (merge rules), then status `done` and a "Summary ready"
     notification.
  5. On HTTP 409 (cancelled), set status back to `queued`.
  6. On any other error, set status `failed` with the error message.
- **Interruption:** if a meeting starts or thermal goes to `.serious` or `.critical` while a job
  runs, call `engine.cancel(jobID:)`. The job becomes `queued` again and resumes later from the
  start. Summaries take about a minute, so restarting is cheap.
- **One job at a time**, enforced by `running`.
- `summarizeNow` and `retry` set the meeting to `queued` and run immediately if the engine is
  ready and no meeting is recording.

**File**: `app/Sources/Mynah/Meetings/Retention.swift` (new)
- `RetentionSweeper` runs on launch and every 6 h on a utility queue. It deletes the audio
  directory of each meeting where `RetentionPolicy.audioDue` is true, and sets `audioDeletedAt`.

### Success Criteria:

#### Automated Verification:
- [x] `cd app && swift test` passes (add `SummaryRunner` eligibility as a pure function
      `SummaryEligibility.canRun(...)` in `MynahCore`, with table tests)
- [x] `scripts/build_app.sh` passes

#### Manual Verification:
- [ ] After a call, the summary appears about 3 minutes later while idle
- [ ] Starting a dictation while it's summarizing: the dictation returns in under 1 s, and the
      summary still completes
- [ ] Starting a new Teams call while it's summarizing: the job is cancelled within about 1 s,
      re-queued, and completes after the call
- [ ] Simulated hot state (Debug item "Pretend thermal serious"): no job starts
- [ ] Summarize now works mid-afternoon with the Mac busy. Retry works after a forced failure
      (engine stopped)
- [ ] Setting retention to "7 days" and backdating `endedAt` in SQLite: the audio is deleted at
      the next sweep, and the transcript stays

---

## Phase 6: Meetings Window (list, detail, search, to-dos)

### Overview

The UI for browsing meetings and managing action items.

### Changes Required:

**Files**: `app/Sources/Mynah/Meetings/UI/` (new)
- **`MeetingsWindow.swift`:** `Window("Meetings", id: "meetings")` in `MynahApp`, with a
  `NavigationSplitView`. The sidebar has **Meetings** and **To-dos** sections.
- **`MeetingsListView.swift`:**
  - Rows show the title, date and time, duration, app icon and a status badge. Newest first.
  - Data comes from a GRDB `ValueObservation` bridged to an `ObservableObject`.
  - `.searchable` runs an FTS query (`store.search`). Results are grouped by meeting with a
    snippet, and selecting one scrolls to the matching segment.
- **`MeetingDetailView.swift`:**
  - The title (editable inline; sets `titleEdited`), then the summary sections.
  - The meeting's action items, using the same row view as To-dos.
  - The transcript: `LazyVStack` rows of `[mm:ss] You/Others: text`, with "You" visually
    distinct and hidden echo lines omitted.
  - The status (with a Summarize now / Retry button where it applies) and a progress state while
    transcribing or summarizing.
  - A toolbar menu: Rename, Delete audio now (disabled once deleted), Delete meeting… (with
    confirmation).
- **`ToDosView.swift`:**
  - Filters: **Mine** (default) or **All**, and **Open** or **Completed**.
  - Rows have a checkbox, text, owner, due date and a "from <meeting> @ mm:ss" link that opens
    the meeting at that time.
  - Editing text, owner or due date sets `userEdited = true`. Delete sets the tombstone.
  - An "Add to-do" button creates a manual item, optionally attached to a meeting.
- Open the window with `openWindow(id: "meetings")` plus `NSApp.activate`, matching
  `openSettings()` in `MynahApp.swift:127-130`. Notification clicks route here through
  `MeetingController.focus(meetingID:)`.

### Success Criteria:

#### Automated Verification:
- [x] `cd app && swift test` passes
- [x] `scripts/build_app.sh` passes

#### Manual Verification:
- [ ] The list updates live as a meeting moves from Recording to Transcribing, Queued,
      Summarizing and Done
- [ ] Search for a word spoken in a call shows the meeting, and clicking it jumps to the segment
- [ ] To-dos › Mine shows the user's items from several meetings. Ticking one off moves it to
      Completed
- [ ] Edit an item, then Retry the summary: the edit survives, and the item isn't duplicated
- [ ] Delete an item, then Retry: it doesn't come back
- [ ] Delete a meeting: its items and audio are gone, and other meetings are unaffected
- [ ] A transcript of over 1,000 segments scrolls smoothly

---

## Phase 7: Performance Validation, Documentation, Release

### Overview

Show that the feature meets the budget on real hardware, then document and ship it.

### Changes Required:

- **Performance run:** a 45-minute Teams video call on the M2 Max with Meetings on.
  - Use the Phase 0 stats logger (keep it as a hidden Debug toggle) and
    `sudo powermetrics --samplers gpu_power,thermal -i 10000` in Terminal.
  - Record the results in this plan under `## Performance Results`.
- **Budget (must meet):**

  | Metric | Target |
  |---|---|
  | Mynah app CPU while recording | ≤ 3% of one core on average |
  | Engine per 30 s window | ≤ 1 s, Parakeet |
  | Added memory while recording (app + engine) | ≤ 300 MB |
  | Thermal state | nominal/fair throughout |
  | Dictation latency mid-meeting | ≤ idle latency + 0.5 s |
  | Summary of a 1 h meeting (Gemma 4 E4B) | ≤ 3 min |
  | Transcript ready after hang-up | ≤ 60 s |

- If anything misses its target, profile it with Instruments (Time Profiler, plus System Trace
  for the IO thread) and fix it before release.
- **README** (`README.md`):
  - a "Meeting notes" feature section;
  - how detection and capture work (no mic for others, two tracks);
  - the System Audio Recording permission;
  - where data lives (`mynah.sqlite`, `Meetings/`);
  - the retention setting;
  - the headphones tip;
  - the consent note;
  - updated requirements (macOS 14.2+ for meetings).
- **Release:** bump `VERSION` (minor), update `.github/release-notes.md`, then tag (the existing
  release flow).

### Success Criteria:

#### Automated Verification:
- [ ] CI is green on the PR: the engine job (pytest) and the app job (`swift test` and the build)
- [ ] `scripts/make_dmg.sh` produces a DMG

#### Manual Verification:
- [ ] Every row of the performance table is recorded and within budget
- [ ] A fresh install from the DMG on a second user account runs end to end (setup → call →
      transcript → summary → to-do)
- [ ] With Meetings off: no meeting UI beyond the Settings tab, and idle CPU and memory match the
      previous release

---

## Testing Strategy

### Unit Tests:

- **Engine (pytest, no models):**
  - priority worker ordering, inline preemption and cancellation;
  - `plan_regions` merge, split and tail hold-back;
  - transcript formatting and section splitting;
  - JSON extraction and normalization.
- **App (Swift Testing, `MynahCore`):**
  - migrations, cascade deletes and FTS;
  - cursor-advance atomicity;
  - summary merge rules (edited, done and tombstoned items);
  - `EchoFilter` thresholds;
  - WAV header repair;
  - retention boundaries;
  - summary eligibility;
  - settings backward-compatible decode.

### Integration Tests:

- The engine endpoints are exercised with `curl` against Phase 0 probe recordings (manual, since
  CI has no models).
- A Debug item, "Replay probe folder as meeting", feeds a probe folder's WAVs through
  `MeetingSession` at 10× speed. This tests transcription bursts, finalization, echo filtering
  and summarization without a live call. It's used repeatedly in Phases 3–6.

### Manual Testing Steps:

1. Enable Meetings on a fresh settings file and complete setup.
2. Run a Teams call on headphones for about 10 minutes: talk, mute, dictate into chat, and use
   Pause my mic. Hang up.
3. Check that the transcript is ready within 60 s, has no dictation and no paused or muted
   speech, and lists You and Others in the right order.
4. Run a Teams call on speakers for about 10 minutes and check echo lines are hidden.
5. Wait for the summary and check that the action items include ones owned by "Me" and by others.
6. Edit, complete and delete items, then Retry the summary and check the merge rules.
7. Force-quit mid-call and check recovery on relaunch.
8. Record a FaceTime call manually.
9. Deny the permission and check the banner appears.
10. Check that retention deletes audio on schedule.

## Performance Considerations

- **Nothing heavy happens on real-time threads.** IO blocks only copy into preallocated ring
  buffers. Format conversion, file writes and WAV patching run on a utility-QoS queue every
  250 ms.
- **Memory stays bounded.** The audio windows sent to the engine are read back from disk and are
  at most 120 s (about 3.8 MB of Float32). No meeting-length buffers exist anywhere.
- **The engine stays light:**
  - Silero VAD is about 2 MB, loaded only once Meetings is enabled.
  - Parakeet is already resident.
  - The summary LLM is already resident by default, and a larger one is loaded only for its job.
  - `mx.clear_cache()` runs after each summary job.
- **No LLM work while a meeting is recording.** Summaries need idle plus nominal or fair thermal
  state, can be cancelled within about 1 s, and dictation preempts them between tokens.
- **The detector uses Core Audio listeners**, coalesced to at most 4 Hz, with no polling. The
  only timers are the 2 s AX mute probe (only during meetings, only if shipped), the 60 s summary
  eligibility check, and the 6 h retention sweep.
- **Disk:** WAVs during the call use about 230 MB/h for both tracks, then are compressed to
  about 30 MB/h (or deleted). The text data is small.

## Migration Notes

- New settings keys decode to defaults for existing users, and Meetings is off by default, so
  existing dictation users see no change other than a new Settings tab.
- `mynah.sqlite` is created on first launch of the new version. Dictation history stays in
  `history.jsonl`.
- `NSAudioCaptureUsageDescription` is added. The app's minimum macOS stays 14.0.
- **Package restructure:** `Sources/Mynah` stays an executable target and the new
  `Sources/MynahCore` is added. The `build_app.sh` paths (`--show-bin-path` + `Mynah`) are
  unchanged.
- **Rollback:** older versions ignore the unknown settings keys and the sqlite file. Deleting
  `mynah.sqlite` and `Meetings/` removes all meeting data.

## References

- Requirements: `docs/requirements/meeting-capture.md`
- Existing code:
  - `app/Sources/Mynah/AudioRecorder.swift:10-84` (converter pattern to reuse);
  - `app/Sources/Mynah/AppController.swift:101-174` (dictation phases and the hooks for
    `setDictating`);
  - `app/Sources/Mynah/EngineClient.swift:108-112,304-321` (session and endpoint patterns);
  - `app/Sources/Mynah/Settings.swift:65-78` (backward-compatible decode);
  - `app/Sources/Mynah/MynahApp.swift:37-136` (menu bar icon and menu);
  - `engine/src/mynah_engine/server.py:44-158,203-252` (Engine and handler);
  - `engine/src/mynah_engine/cleanup.py:40-74` (prefix cache and `stream_generate` loop);
  - `scripts/build_app.sh:54-75` (Info.plist).
- Apple: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps);
  headers `CoreAudio/AudioHardware.h`, `AudioHardwareTapping.h`, `CATapDescription.h`.
- Reference implementations: [insidegui/AudioCap](https://github.com/insidegui/AudioCap),
  [makeusabrew/audiotee](https://github.com/makeusabrew/audiotee).
- Apple forum threads on taps: 771864 (permission), 825780 (silent buffers, rebuild on device
  change), 751100 (voice processing across apps).
- Installed mlx-audio 0.5.9: `stt/models/parakeet/parakeet.py:164-279`,
  `stt/models/nemo/alignment.py:5-70`, `vad/models/silero_vad/silero_vad.py:209-241`.

---

## Implementation Notes (2026-10-16, Phases 0–2 built)

**Status.**
- Phases 0, 1 and 2 are implemented, and all automated checks pass: 34 pytest, 17 Swift Testing
  tests, and the release build.
- Phase 0's manual items need real Teams calls. They are the go/no-go gate for Phase 3.

**Where things are:**
- **Phase 0:**
  - `app/Sources/Mynah/Meetings/{CoreAudioProcesses,ProcessTap,TrackWriter,MeetingProbe}.swift`
    (`MeetingMic` is in `TrackWriter.swift`);
  - the Debug menu in `MynahApp.swift`;
  - `bench/meeting_probe.py`;
  - the probe log at `~/Library/Logs/Mynah/meetings.log`.
- **Phase 1:** `engine/src/mynah_engine/{worker,meeting,summarize}.py`, `asr.transcribe_aligned`,
  and the new routes in `server.py`.
- **Phase 2:**
  - the `MynahCore` target: `MeetingModels`, `MeetingStore`, `EchoFilter`, `WAVHeader`,
    `RetentionPolicy`, `TranscriptFormatter`, `RingBuffer`;
  - `app/Tests/MynahCoreTests`;
  - CI runs `swift test`;
  - `AppController.meetingStore` opens `mynah.sqlite` at launch.

**Deviations and findings:**
- **Prefill preemption.**
  - mlx-lm prefills the whole prompt in one step, which blocked a dictation for 7.4 s behind a
    long summary.
  - `Summarizer._generate` now prefills in 256-token steps, with `checkpoint()` between steps.
  - Measured: dictation during a summary takes 0.67–1.48 s, against 0.54 s idle. The 1 s target
    is met most of the time but not always. Revisit in Phase 7 (a smaller step, or pausing the
    summary while the hotkey is held).
- **Summary speed:** a 400-line (~40 min-equivalent) transcript summarized in 17.4 s with
  Gemma 4 E4B, well inside the 3-minute budget.
- **Transcription speed:** 30 s windows take 0.33–0.42 s (real-time factor about 0.01). The
  Silero VAD downloads on first `/meeting/prepare`.
- **Echo filter**, on a simulated speakers recording (35% echo, 60 ms delay, noise): it hid 9 of
  9 echo lines and kept 4 of 4 real lines. It still needs checking on a real speakers call.
- **`/summarize`** also accepts `meeting_date`, so due dates like "Friday" can be resolved.
- **`ProcessTap`** uses a *mono* mixdown tap (simpler than the stereo one in the sketch).
  - If no Teams process exists, the probe taps all system audio except Mynah, so it can be tried
    with any audio.
  - `start()` blocks for up to 2 s while it checks for callbacks, so it's called off the main
    thread.
- **Mic is permanently in use by Siri.** `com.apple.CoreSpeech` has `runningInput` set all the
  time (wake-word listening). Detection must keep matching the Teams bundle prefix and never use
  "any mic in use".
- **`RingBuffer` moved to `MynahCore`** (with tests). `WAVHeader` was written there directly
  instead of being moved in Phase 2.
- **Not exercised yet:** the tap itself and the System Audio Recording prompt. The first run
  should be a real Phase 0 session from the installed, signed app, not from a terminal (which
  would attribute the permission to the terminal app).

## Proof of Concept Results

### Session 1: 2026-10-16, ~2 min test meeting

The user joined from two devices in the same room. Folder:
`~/Desktop/mynah-probe-2026-10-16T18-00-44Z`. AX dumps: `mynah-probe-ax-…18-01-50Z.txt` (muted)
and `…18-02-20Z.txt` (unmuted).

| Question | Result |
|---|---|
| Which process holds call audio | **The main `com.microsoft.teams2` (MSTeams) process** opened both input and output when the call connected (not ModuleHost). `com.microsoft.teams2.helper` (WebView) plays short sounds such as ringing and join chimes. Tapping every `com.microsoft.teams2*` process covers both. ✅ |
| Tap captures remote voices | ✅ The tap-only aggregate worked first time (48 kHz). The remote side was transcribed correctly. Headphones vs speakers is still untested with a real second person. |
| Permission | ✅ The tap received real audio from the signed (Flow Local Signing) build installed with `--install`. |
| Silent-tap detection | ⚠️ The level-based check fired a **false alarm**: Teams keeps output open through silence. Changed to "only exact zeros for 60 s". A denied permission is still untested (`tccutil reset AudioCapture com.lukekerwin.mynah`). |
| Echo filter | ⏳ Inconclusive. With one person on two devices in one room, the mic hears the person's live voice as well as playback (1 of 14 "You" lines hidden). Needs a call with another person on speakers. |
| Mute through AX | ✅ **Readable and stable:** `AXButton desc="Unmute mic"` when muted and `desc="Mute mic"` when unmuted, in the `MSTeams` window. The self-view also reads `"…, Muted, …"` / `"…, Unmuted, …"`. These are English UI strings, so match `desc` prefix "Unmute mic" / "Mute mic" and treat anything else as unknown. **TeamsMuteProbe ships.** |
| Meeting title through AX | ✅ The window title is `"<Meeting name> \| Microsoft Teams"`, so take the part before `" \| Microsoft Teams"`. The AX tree is small (~120 nodes), so a 2 s poll is cheap. |
| CPU, memory, thermal | ✅ (short run) Mynah used 1.3–1.9% CPU while recording (3.9–5.6% during AX dumps), 35–38 MB memory, thermal nominal throughout, no dropped samples. The 30-min video run is still needed. |
| Transcription speed | ✅ 30 s windows took 0.27–0.57 s (real-time factor 0.010–0.014). |

**Decision (2026-10-16): GO.** The capture approach, permission, mute and title reading are all
proven. The user chose to build Phases 3–6 and then test and refine on real calls. The remaining
checks below move into Phase 7's validation instead of blocking Phase 3:
1. A call with another person, on speakers (echo).
2. A ~30-min video call (thermal).
3. Optionally, `tccutil reset AudioCapture com.lukekerwin.mynah`, then deny, to check silent-tap
   detection.

## Implementation Notes (2026-10-16, Phases 3–6 built)

All four phases are built. Automated checks pass: 25 Swift tests, 34 pytest, and the release
build. The manual checks for Phases 3–6 need real calls and are folded into the Phase 7
validation.

**Where things are** (all in `app/Sources/Mynah/Meetings/` unless noted):
- **Detection:** `MeetingDetector.swift`.
- **Teams window reading** (title, mute): `TeamsAccessibility.swift`.
- **Capture:** `MeetingSession.swift`.
- **Transcription, echo, retention, recovery:** `MeetingProcessor.swift`.
- **State machine:** `MeetingController.swift`.
- **Summary job:** `SummaryRunner.swift`.
- **Notifications:** `MeetingNotifications.swift`.
- **UI:**
  - `MeetingsWindow.swift`: list, search, detail, to-dos.
  - `MeetingSettingsView.swift`: Settings › Meetings tab plus the setup sheet.
  - In `MynahApp.swift`: `MeetingAwareIcon` and `MeetingMenuSection`.
- **Pure logic in `MynahCore/MeetingSupport.swift`:** `MeetingSettings`, `TeamsUI`, `WAVReader`,
  `SummaryEligibility`.

**Deviations and additions:**
- **Wall-clock alignment.** `TrackWriter` pads silence whenever a track falls more than 0.5 s
  behind real time (tap rebuild, device switch), so the two tracks stay on one timeline.
  Sample-rate changes rebuild the resampler (`updateSourceRate`).
- **Synchronized start.** Both rings are drained at the same instant before the writers start.
  The tap's 2 s self-check therefore doesn't offset the tracks.
- **Mute detection** (`TeamsAccessibility`) finds the call window by its "Leave" button, then
  reads "Unmute mic" / "Mute mic". It polls every 2 s and only for Teams recordings.
- **Manual recording** lists apps currently playing audio, grouped by the first three components
  of the bundle ID, plus **All System Audio** (a global tap excluding Mynah), which covers
  FaceTime, whose audio is played by `avconferenced`.
- **Settings** live under `settings.json` → `"meetings"` (`MeetingSettings`, which decodes
  backward-compatibly).
- **Summary timestamps.** The engine now asks for the `[mm:ss]` stamp *as text* (`"time"`) and
  converts it itself. Asking for seconds produced wrong times (95 s instead of 12 s).
- **Debug import.** Debug › Import Probe Recording as Meeting…, or launching with
  `-MynahImportProbe <folder>`, runs a probe folder through the real pipeline.
- **End-to-end check** (2026-10-16), using that import on the installed app:
  1. The real test-call recording became a transcript, with 1 echo line hidden. It summarized in
     2.0 s and ended with status `done`. The audio was compressed to about 600 KB for 107 s.
  2. A synthetic speakers meeting had 9 of 9 echo lines hidden, and the action item "Send the
     updated invoice by Friday…" landed in To-dos owned by Me.
- **Not exercised yet** (needs a live call or the UI):
  - automatic start and stop from Teams;
  - the Ask notification;
  - pause and mute gating;
  - the red menu bar icon;
  - interrupting a summary when a call starts;
  - the Meetings window interactions;
  - recovery after `kill -9`.

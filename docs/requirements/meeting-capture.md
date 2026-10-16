---
date: 2026-10-16
status: draft
author: Luke Kerwin
---

# Requirements: Meeting Capture (transcripts, summaries, action items)

## Problem Statement

Mynah already turns speech into text locally for dictation. Calls are where most commitments
and decisions happen, and today nothing is kept from them unless you pay for Teams Premium /
Copilot, which keeps the data in Microsoft's cloud.

Meeting Capture notices when a call starts and records the call audio on the Mac. It produces a
transcript, then later a summary and a list of action items. Everything stays on the machine in a
structured local store. This is the first part of a broader on-device personal assistant, so the
data must be stored so that later features can build on it (task list, search, Q&A, speaker
recognition).

## Goals

- When a Microsoft Teams call starts, recording begins automatically (or after one click,
  depending on a setting), with no other action needed.
- When the call ends, a timestamped transcript labelled **You / Others** is available within
  about a minute.
- A summary and action items are produced in the background afterwards, without noticeably
  slowing down or heating up the Mac.
- Action items become a to-do list that lives in Mynah and spans all meetings.
- Nothing leaves the Mac.

## Non-Goals (MVP)

- **Telling individual remote speakers apart** (Speaker 1/2/3) and **voice profiles** (named
  people recognized automatically in future calls). These are planned next. The MVP must not
  prevent them (see Data requirements), but does not build them.
- Auto-detecting apps other than Teams (Zoom, Google Meet, FaceTime, Slack). These are covered
  only by manual recording.
- Teams running in a web browser (auto-detection).
- A live transcript view during the call.
- Exporting or syncing to Markdown, Obsidian, Apple Reminders, Calendar or similar. Where notes
  go is undecided; the local store is the source of truth and exports come later.
- Calendar integration for meeting titles and attendees.
- Asking questions about meetings or chatting over transcripts.
- Editing transcript text.
- Languages other than those the configured ASR model already supports. No special
  multilingual handling.
- Telling other participants about the recording. This is a personal tool used only for calls the
  user is fine recording.

## Functional Requirements

### Enabling and setup

1. Meeting Capture ships in public releases but is **off by default**. Settings has a Meetings
   section with a master switch.
2. The first time it's enabled, a one-time setup:
   - requests the System Audio Recording permission (Core Audio process tap);
   - shows a short note that recording laws and consent rules vary and that the user is
     responsible for recording only calls they're allowed to record.
3. If the permission is denied, Settings shows that state and a button to open System Settings.
   Detection stays off.
4. On macOS versions that can't do per-process audio taps (earlier than 14.2), the Meetings
   section explains that the feature isn't available. Dictation is unaffected.

### Meeting detection (Teams)

1. A Teams meeting is considered **started** when the Teams desktop app (new Teams,
   `com.microsoft.teams2`, including its helper processes) starts using an audio input device.
2. A meeting is considered **ended** when Teams has not used audio input for a grace period
   (default 30 s), so brief device switches and reconnects don't split a meeting. It also ends
   when the Teams call window (read through Accessibility) has closed and the call has been
   silent for 20 s, since Teams can keep the mic open after you leave.
3. Setting **When a Teams call starts: Record automatically | Ask me**.
   - *Record automatically*: recording starts and a notification says so.
   - *Ask me*: a notification with Record / Ignore. Ignoring means that call isn't recorded.
4. Detection must not trigger on Mynah's own mic use (dictation).
5. The meeting title defaults to the Teams meeting window title, if it can be read through
   Accessibility. Otherwise it's "Teams call – <date time>". The title can be renamed later.

### Manual recording

1. The menu bar menu has **Record meeting…**. It lets you choose which app's audio to record from
   the apps currently playing audio (for example Zoom, FaceTime, a browser), and starts recording.
   The mic is recorded as the "You" track the same way.
2. A manual recording ends only when the user stops it.

### Capture

1. **The other participants' audio** is captured from the meeting app's audio output through a
   per-process system audio tap, **not** from the mic. It's labelled **Others**. It must be
   clean whether the user is on speakers or headphones.
2. **The user's voice** is captured from the mic as a separate track labelled **You**.
3. **Echo:** on speakers, the mic also picks up the other participants. Mic audio that is echo of
   the Others track must not appear as "You" speech in the transcript.
4. **Mute:**
   - A **Pause my mic** menu item and an optional shortcut stop the "You" track while "Others"
     keeps recording. This is always available.
   - In addition, Mynah reads Teams's mute state through Accessibility, as best it can, and drops
     mic audio while muted. This ships only if the proof of concept shows the mute button can be
     read reliably. If the state can't be read at runtime, Mynah records the mic and logs that
     mute tracking is unavailable.
5. **Dictation during a meeting:** mic audio captured while the dictation key is held is excluded
   from the meeting's "You" track. Dictation itself works normally during a meeting.
6. Audio is written to disk as it's captured, in a compressed voice format of roughly 15 MB per
   track per hour. It is never held in memory for the whole meeting. If the app or Mac crashes,
   at most the last few seconds are lost, and the partial meeting is recoverable on next launch.
7. If the audio device changes mid-call (headphones plugged or unplugged, AirPods connected),
   capture continues without needing user action.

### Recording indicator and controls

1. While recording, the menu bar icon shows a recording state (red) and the elapsed time.
2. The menu shows the current meeting and offers **Stop** and **Stop & Discard**. Discard
   deletes everything captured for that meeting.
3. Notifications: recording started (or Ask), and recording finished with the transcript ready.

### Transcription

1. During the call, audio is transcribed in chunks cut at natural pauses (~30 s), using the
   configured ASR model and the personal dictionary.
2. Each transcript segment has a start time, end time, speaker label (You / Others) and text.
3. The two tracks are combined in time order to make the readable transcript.
4. The transcript is complete within about 1 minute of the meeting ending (M2 Max reference).
5. Dictation always takes priority: a dictation request must never wait behind queued meeting
   transcription work.
6. If the engine is unavailable or crashes during a meeting, audio capture continues. Pending
   chunks are transcribed when the engine comes back.

### Summary and action items (deferred job)

1. After a meeting ends, a summary job is queued. It runs automatically only when all of these
   hold:
   - no meeting is being recorded,
   - the Mac's thermal state is nominal or fair,
   - no dictation is in progress.

   It waits otherwise, and pauses or stops (to resume later) if a meeting starts or the Mac heats
   up.
2. Each meeting has a **Summarize now** action that runs the job right away, still giving
   dictation priority.
3. Meetings with no detected speech are not summarized. All meetings are kept regardless of
   length.
4. The summary includes:
   - a short TL;DR,
   - key points or topics,
   - decisions,
   - open questions.
5. **Action items:** every commitment made in the meeting is extracted, not only the user's.
   Each item has:
   - text,
   - owner (**Me**, a person named in the conversation, or **Unassigned**),
   - optional due date if one was mentioned,
   - a link to the transcript time it came from.
6. Long meetings that don't fit the model in one pass are summarized in sections, then combined.
7. The summary model is the configured cleanup LLM by default (Gemma 4 E4B). A setting can
   choose a larger model that is loaded only for the job and unloaded afterwards.
8. A failed job is marked as such on the meeting, with a **Retry** action.

### Meetings window

1. A **Meetings** window opens from the menu bar menu. Its sidebar has **Meetings** and
   **To-dos**.
2. **Meetings list:** title, date and time, duration, app, and status (Recording / Transcribing /
   Waiting to summarize / Summarizing / Done / Failed). Newest first.
3. **Meeting detail:**
   - summary sections;
   - the meeting's action items (editable, as below);
   - the full transcript with timestamps and You/Others labels;
   - actions: rename, Summarize now / Retry, delete meeting, delete audio now.
4. **Search:** a search box matches words across all transcripts, summaries and action items. A
   result opens the meeting at the matching segment.

### To-dos

1. A **To-dos** view lists action items from all meetings. It defaults to the **Mine** filter, and
   can be switched to **All** and to **Open / Completed**.
2. Each item can be ticked off (and unticked), edited (text, owner, due date), and deleted. Each
   item links to its source meeting and transcript time.
3. Items can be added by hand, either with no meeting or attached to one.
4. Re-running a summary must not overwrite items the user has edited, completed or deleted.

### Retention

1. Setting **Keep meeting audio: Delete after transcript | 7 days | 30 days | Forever**. The
   default is **7 days**.
2. Transcripts, summaries and action items are kept until the user deletes them.
3. Deleting a meeting deletes its audio, transcript, summary and action items. Completed to-dos
   from it are deleted too.
4. Audio deletion runs automatically and doesn't need the app to be open at the exact moment it's
   due. Overdue audio is deleted on the next launch.

### Data (foundation for the assistant)

1. The source of truth is a local SQLite database in `~/Library/Application Support/Mynah/`. It
   holds meetings, transcript segments, summaries and action items, with full-text search.
2. Audio files live alongside it in a per-meeting folder, referenced from the database.
3. The schema must support adding these later without migrating existing data destructively:
   - individual speaker labels per segment,
   - people and voice profiles, with per-segment voice fingerprints that can be computed from
     audio before it's deleted,
   - links between action items and people,
   - non-meeting sources of tasks.

## Non-Functional Requirements

- **Performance and thermals (top priority):**
  - During a call, Mynah's added load must not noticeably slow down Teams (audio or video) or
    other apps.
  - No LLM work runs while a meeting is being recorded.
  - Transcription runs in short, low-priority bursts.
  - Background jobs check the thermal state and back off when it is serious or critical.
  - Only one heavy (LLM) job runs at a time.
  - These are verified by measuring CPU, GPU, memory and thermal state during a real 30+ minute
    call with video, on the M2 Max, before the MVP ships.
- **Memory:**
  - The MVP must not keep additional models loaded beyond the existing ASR and cleanup models.
  - Optional larger summary models are loaded only for the duration of a job.
  - Meeting audio is never held in memory for the whole meeting.
- **Disk:** about 30 MB per hour of meeting for both audio tracks, deleted per the retention
  setting. Text data is negligible.
- **Dictation latency:** no regression in dictation latency while idle. During a meeting, a
  dictation may wait at most one in-flight transcription chunk (well under 0.5 s).
- **Privacy:**
  - No network access for any part of this feature.
  - The engine stays on 127.0.0.1 with the per-launch token.
  - Meeting data stays in the user's Library and is never sent anywhere.
- **Reliability:**
  - A crash or force-quit during a meeting loses at most a few seconds of audio.
  - Incomplete meetings are recovered and processed on next launch.

## Constraints & Assumptions

- Apple Silicon. Requires macOS 14.2+ for per-process audio taps. The app's minimum stays 14.0,
  and the feature is unavailable below 14.2.
- The app is ad-hoc or self-signed and not notarized. The System Audio Recording permission must
  work under these signing conditions; this is to be confirmed in the proof of concept.
- The existing Python/MLX engine (`engine/`) runs every model call on one worker thread, first
  come first served (`Engine.run` in `server.py`). Meeting work needs a priority mechanism so
  dictation isn't queued behind it.
- The current `AudioRecorder` buffers everything in memory, which is fine for dictation. Meeting
  capture needs a streaming-to-disk recorder.
- Dictation history currently lives in `history.jsonl`. Moving it into the new database is not
  part of the MVP.
- Teams process names, audio ownership, the mute button and window titles are undocumented and
  may change with Teams updates. Detection and mute tracking must degrade gracefully, never
  crash or stop capture.
- Used on a personal Mac for personal and business calls the user is fine recording. Not
  designed for or tested against corporate or managed Macs.

## User Flows

### Flow 1: Automatic Teams call

1. The user joins a Teams call and Teams opens the mic.
2. Mynah starts recording, the menu bar icon turns red with a timer, and a notification says
   "Recording Teams call".
3. During the call, chunks are transcribed in the background. The user mutes at times (mic audio
   is dropped) and dictates once into chat (that's excluded).
4. The user leaves the call. After the 30 s grace period, recording stops and the transcript is
   finished.
5. Notification: "Transcript ready: <title>".
6. A few minutes later, once the Mac is idle and cool, the summary and action items are generated.
   The meeting status becomes Done.
7. The user opens Meetings › To-dos, sees new items under Mine, and ticks one off later.

### Flow 2: Ask mode

1. The setting is *Ask me*. A Teams call starts.
2. A notification appears with Record / Ignore. Record behaves as in Flow 1. Ignore means nothing
   is captured for this call.

### Flow 3: Manual recording of a FaceTime/Zoom call

1. Menu bar › Record meeting… › choose FaceTime.
2. Recording proceeds as in Flow 1 until the user clicks Stop.

### Flow 4: Discard

1. The recording started by mistake. Menu bar › Stop & Discard.
2. All captured audio and transcript for that session are deleted, and no meeting entry remains.

### Flow 5: Finding something later

1. Meetings › search "invoice".
2. Matching meetings are listed. Opening one jumps to the transcript segment and shows the
   related action items.

## Open Questions

- None blocking. Where to export notes and to-dos (Obsidian, Reminders, Markdown folder) is
  deliberately deferred.
- To be settled by the proof of concept rather than by decision:
  - which Teams process owns audio input and output;
  - whether the process tap permission works with ad-hoc and self-signed builds;
  - how well echo suppression works on speakers;
  - whether Teams's mute state can be read reliably through Accessibility;
  - measured thermal load during a real call.

## References

- Planning discussion: this thread (2026-10-16).
- Existing code:
  - `app/Sources/Mynah/AudioRecorder.swift` (in-memory 16 kHz capture);
  - `engine/src/mynah_engine/server.py` (single-worker engine, `/dictate` and `/command`);
  - `engine/src/mynah_engine/models.py` (ASR and LLM registry);
  - `app/Sources/Mynah/History.swift` (JSONL history);
  - `scripts/build_app.sh` (Info.plist, `LSMinimumSystemVersion` 14.0).
- Apple: Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`, macOS 14.2+).

**Beta: not the stable release.** This build adds **speaker recognition** to meeting capture: Mynah tells apart the other people on a call and learns their voices, so after you name someone once, later meetings label them automatically. Voices and names stay on your Mac.

### New in beta 8
- **The sidebar opens pages from the start.** Clicking Meetings shows the list, not the last meeting you opened. Pages open at the top.
- **The live transcript's Close button closes it** instead of popping right back open.
- **Mynah asks before** deleting a meeting's audio, forgetting a person, or quitting while a call is being recorded.
- **Due dates read naturally** ("Tomorrow", "Mon, Oct 20"), with overdue ones in coral.
- **Esc** cancels the meeting setup and Edit to-do. **The window reopens where you left it.**

### New in beta 7
- **Mynah's window keeps focus** when you close a popover or dialog (like New to-do), instead of dropping behind other apps.
- **Fewer freezes:** the meeting page no longer reloads the whole meeting every second during a call, Mynah gives up quickly on a busy app (Teams mid-call) when you dictate, and quitting can't hang on the engine.

### New in beta 6
- **Going straight from one meeting into the next starts a new recording** instead of carrying the first one on (needs a meeting with a name; ad hoc calls can't be told apart yet).

### New in beta 5
- **Sharing your screen no longer ends the recording.** Mynah took Teams hiding the call window while you present as you leaving the call.

### New in beta 4
- Leaving a Teams call no longer sends a false "can't see Teams' mute button" warning.
- Debug menu only: **Watch Teams participants** records how Teams' participant tiles change during a call, to explore naming speakers from who Teams shows as talking.

### New in beta 3
- **Teams mute detection works on a fresh Teams.** Mynah couldn't read Teams' call window unless something else had already made it readable, so being muted was never noticed and leaving the call didn't end the recording. Both work now.

### New in beta 2
- **Fewer "You" lines from other people on speakers.** Mynah is much stricter about what counts as you talking over the call, and it measures the speaker leak steadily across the whole meeting.
- **Short "yeah" / "okay" lines** your mic picked up from the call are now hidden too.
- **Teams mute detection** recognizes more versions of the mic button. If Mynah still can't see whether you're muted, it now sends a notification instead of quietly recording your mic.

### What to try
- Record a Teams call with two or more other people. When it's processed, the meeting page shows a **Speakers** card: anyone Mynah doesn't know yet is **Speaker 1**, **Speaker 2**, …
- Name them from the Speakers card, or click a name chip in the transcript. Pick someone you've named before, or **New person…**. **Clear name** undoes a wrong name.
- In the next call with the same people, they should be named automatically. The notes and to-dos use their names too ("Bob will send the deck").
- Renamed someone after the notes were written? Use **Write notes again** on the Speakers card.
- Older meetings whose audio is still saved: **⋯ › Find speakers**.
- **Settings › Meetings › Recognize speakers** turns it off. **People…** lets you rename or delete people, or forget all voices.

### Known limitations
- The first time, Mynah downloads a 21 MB voice model.
- Your own mic is still always **You**. Only the call audio is split by speaker.
- People who talk for less than about 5 seconds aren't remembered.
- Several people in one room on one mic, or someone who joins from a different mic or headset than usual, may come up as a new Speaker. Name them again and Mynah learns that voice too.
- Updating a beta resets macOS permissions, because builds are ad-hoc signed.

### Install
Download **Mynah-*.dmg** below, drag **Mynah** into **Applications**, open it, and use **System Settings › Privacy & Security › Open Anyway** the first time. Already on a beta? Mynah offers this update itself. On the stable channel, turn on **Settings › Updates › Beta versions** or install by hand. Requires Apple Silicon and macOS 14.2 or later for meeting capture.

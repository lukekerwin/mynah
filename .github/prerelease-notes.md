**Beta: not the stable release.** This build adds **speaker recognition** to meeting capture: Mynah tells apart the other people on a call and learns their voices, so after you name someone once, later meetings label them automatically. Everything else is the same as 0.2.1. Voices and names stay on your Mac.

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

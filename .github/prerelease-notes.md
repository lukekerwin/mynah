**Beta: not the stable release.** It adds **meeting capture**: Mynah notices when a Microsoft Teams call starts, records the call's audio and your mic as separate tracks, writes a timestamped transcript during the call, and afterwards writes a summary and a to-do list from the action items. Everything runs and stays on your Mac.

Meeting capture is **off by default**. Turn it on in **Settings › Meetings**. The setup asks for Notifications and **System Audio Recording** permission. Dictation works the same as in 0.1.x.

### What to try
- Join a Teams call. Recording starts automatically, or asks first if you choose "Ask me". The menu bar shows a red dot and a timer.
- **Pause My Mic** (menu or ⌃⌥M) and Teams mute both keep your words out of the transcript.
- Other apps: menu bar › **Record Meeting ›**, then pick the app or **All System Audio**.
- **Meetings & To-dos…** opens a window with search, summaries, transcripts and your action items.

### Known limitations
- Speakers are only told apart as **You** and **Others**.
- On speakers (no headphones), lines your mic picked up from the call are filtered out; this is still being tuned. Headphones give the cleanest transcript.
- Mute detection and meeting titles come from the Teams window, and only work with the English Teams interface.
- Updating a beta resets macOS permissions, because builds are ad-hoc signed.

### Install
Download **Mynah-*.dmg** below, drag **Mynah** into **Applications**, open it, and use **System Settings › Privacy & Security › Open Anyway** the first time. Requires Apple Silicon and macOS 14. Meeting capture needs macOS 14.2 or later.

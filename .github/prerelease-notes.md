**Beta: not the stable release.** This build makes dictation work in **remote desktops and VMs that block copy and paste**, and fixes a freeze.

### New in beta 3
- **Dictation no longer hangs on "processing" for up to a minute** during or right after a call. If cleaning up your words takes more than 5 seconds, Mynah inserts what you said with basic capitalization and punctuation instead of waiting.
- **Slow dictations are now logged** with timing and memory details in `engine.log` and `app.log`. If it happens to you, send those along.

### New in beta 2
- **Fixed freezes when you start dictating** with sound going to a monitor's speakers (or another output that's slow to start). Mynah waited for the start sound to play before it could open the microphone, which could take 10–20 seconds. Sounds now play in the background, and on an output that's slow to start, Mynah stops playing them until it's relaunched.

### New in beta 1
- **Type instead of paste.** In apps where the clipboard doesn't reach (Windows App, out of the box), Mynah types what you dictated key by key instead of pasting it. Add other remote desktop or VM apps in **Settings › Type instead of paste › Add app…**, or remove one by clicking its ✕.
- **Fixed a freeze** where Mynah stopped responding (often noticed only at the next dictation) while it re-registered for audio changes from every app on the Mac, over and over.
- **Mynah keeps its own log** at `~/Library/Logs/Mynah/app.log`, next to `engine.log`. If Mynah stops responding for more than 5 seconds, it notes it there and saves a `hang-*.txt` snapshot next to it. Send those along when reporting a freeze; no admin account needed.

### What to try
- Dictate right after a call ends, while its notes are being written.
- Dictate into a Windows session in Windows App, including punctuation like `?`, `!`, `:` and quotes.
- Switch to another app while a long dictation is being typed: typing stops.

### Known limitations
- Typing is slower than pasting: a long dictation takes a few seconds to appear.
- Emoji and characters that need Option or a dead key (é, ü, …) may not come through in a remote session.
- Command mode can't read the selected text inside a VM that blocks the clipboard.
- Updating a beta resets macOS permissions, because builds are ad-hoc signed.

### Install
Download **Mynah-*.dmg** below, drag **Mynah** into **Applications**, open it, and use **System Settings › Privacy & Security › Open Anyway** the first time. Already on a beta? Mynah offers this update itself. On the stable channel, turn on **Settings › Updates › Beta versions** or install by hand. Requires Apple Silicon and macOS 14.2 or later for meeting capture.

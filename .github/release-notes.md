Private, on-device dictation for Apple Silicon Macs. Hold **Fn**, talk, let go — clean text appears wherever you're typing.

### New in 0.2.2
**Faster dictation**
- **No more 2–3 second waits after Mynah sits idle.** The speech and cleanup models now stay ready in memory between dictations, and Mynah wakes them up as soon as you press the hotkey, while you're still talking. The first dictation after a short sleep dropped from about 3.2 s to 0.6 s in testing. (Macs with 24 GB or more keep the models in memory; smaller Macs rely on the wake-up alone.)

**Speaker recognition in meetings**
- Mynah tells apart the other people on a call and learns their voices. After a call, the meeting page shows a **Speakers** card: name **Speaker 1**, **Speaker 2**, … once, and later meetings label them automatically. The notes and to-dos use their names too ("Bob will send the deck").
- Name people from the Speakers card or by clicking a name chip in the transcript. **Write notes again** refreshes the notes after a rename, and **⋯ › Find speakers** works on older meetings whose audio is still saved.
- Turn it off in **Settings › Meetings › Recognize speakers**. **People…** lets you rename or delete people, or forget all voices. Voices and names stay on your Mac.

**Dictation**
- **Music and videos pause while you dictate** and resume when you stop (Spotify, Music, Podcasts, YouTube and other browser media, most video players). Turn it off in **Settings › Pause media while dictating**.
- **Sleep and screen lock are handled:** a dictation left running is cancelled quietly, and the hotkey no longer gets stuck after waking.

**Meetings**
- **Sharing your screen no longer ends the recording**, and going straight from one named meeting into the next starts a new recording.
- **Teams mute detection works on a fresh Teams** and recognizes more versions of the mic button. If Mynah can't tell whether you're muted, it notifies you instead of quietly recording.
- **Fewer "You" lines from other people on speakers,** including short "yeah" / "okay" lines your mic picked up from the call.
- **A recording ends when your Mac sleeps** instead of filling up with silence, and call detection restarts on wake. The meeting mic recovers if it fails to reopen.

**App**
- **Better battery life:** windows no longer redraw while you're not using them.
- **Fewer freezes**, a sidebar that opens pages from the start, windows that keep focus after dialogs and reopen where you left them (or back on screen if that display is gone), and confirmations before deleting audio, forgetting a person, or quitting mid-recording.
- Builds are ad-hoc signed, so macOS asks for Microphone and Accessibility again after each update.

### Install
1. Download **Mynah-*.dmg** below, open it, and drag **Mynah** into **Applications**.
2. Open Mynah. macOS will say it can't verify the developer (Mynah isn't notarized by Apple yet). Click **Done**, then go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Mynah. You only do this once.
3. Follow the setup window: allow Microphone and Accessibility, and let it download the models (~9 GB, one time).

**Requirements:** Apple Silicon (M1 or later), macOS 14+ (14.2+ for meeting capture), 16 GB RAM recommended (8 GB works with the smaller cleanup model), ~12 GB free disk.

See the [README](https://github.com/lukekerwin/mynah#readme) for details. Verify the download with the `.sha256` file if you like.

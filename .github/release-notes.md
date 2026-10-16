Private, on-device dictation for Apple Silicon Macs. Hold **Fn**, talk, let go — clean text appears wherever you're typing.

### New in 0.2.1
Meeting capture fixes:
- **No more "You" lines from other people on speakers.** Call audio your mic picks up through the speakers is removed before transcription, and echoed lines disappear from the live transcript as you go.
- **Muted in Teams is detected more reliably**, and the live transcript tells you when Mynah can't see Teams' mute button.
- **Recordings end when the call does.** Mynah now notices when you leave a Teams call instead of recording until you stop it.
- **Meeting titles describe the call** (e.g. "Q3 budget review with finance") instead of "Teams call" and the date, unless Teams gave the meeting a name or you renamed it.
- **Readable transcripts:** what the other people say is split into paragraphs at pauses instead of one long block.
- Builds are ad-hoc signed, so macOS asks for Microphone and Accessibility again after each update.

### Install
1. Download **Mynah-*.dmg** below, open it, and drag **Mynah** into **Applications**.
2. Open Mynah. macOS will say it can't verify the developer (Mynah isn't notarized by Apple yet). Click **Done**, then go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Mynah. You only do this once.
3. Follow the setup window: allow Microphone and Accessibility, and let it download the models (~9 GB, one time).

**Requirements:** Apple Silicon (M1 or later), macOS 14+, 16 GB RAM recommended (8 GB works with the smaller cleanup model), ~12 GB free disk.

See the [README](https://github.com/lukekerwin/mynah#readme) for details. Verify the download with the `.sha256` file if you like.

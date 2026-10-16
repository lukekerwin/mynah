Private, on-device dictation for Apple Silicon Macs. Hold **Fn**, talk, let go — clean text appears wherever you're typing.

### New in 0.2.0
- **In-app updates.** Mynah finds and installs new versions itself (Settings › Updates, or Mynah › Check for Updates…). Install 0.2.0 by hand once; after that you won't need to download the DMG again.
- **Redesigned app:** a sidebar window, a new menu bar panel and an animated recording overlay.
- **Meeting capture** (off by default, turn it on in Settings › Meetings): Mynah notices when a Microsoft Teams call starts, records the call and your mic as separate tracks, writes a live transcript, and afterwards a summary and to-do list. Other apps: menu bar › **Record a meeting**. Everything stays on your Mac. Needs macOS 14.2 or later.
- Builds are ad-hoc signed, so macOS asks for Microphone and Accessibility again after each update.

### Install
1. Download **Mynah-*.dmg** below, open it, and drag **Mynah** into **Applications**.
2. Open Mynah. macOS will say it can't verify the developer (Mynah isn't notarized by Apple yet). Click **Done**, then go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Mynah. You only do this once.
3. Follow the setup window: allow Microphone and Accessibility, and let it download the models (~9 GB, one time).

**Requirements:** Apple Silicon (M1 or later), macOS 14+, 16 GB RAM recommended (8 GB works with the smaller cleanup model), ~12 GB free disk.

See the [README](https://github.com/lukekerwin/mynah#readme) for details. Verify the download with the `.sha256` file if you like.

# Media Helper declarative app

Media Helper is a JSON-only client app for CC: App 0.14.0+. CC: App renders the interface as a native Minecraft screen, much like a browser renders a document.

## Install the app

Install CC: App 0.14.0 or newer, then run:

```bash
./.dev/sync-to-minecraft.sh
```

On Windows:

```powershell
.\.dev\sync-to-minecraft.ps1
```

Both scripts accept an explicit profile path (`--profile PATH` or `-Profile PATH`). Open a powered CC:Tweaked computer, attach a speaker and advanced monitor, press **F8**, and choose **Media**. CC: App renders its JSON as a native client interface.

YouTube search, thumbnails, `yt-dlp`, FFmpeg conversion, and caching happen on the real client computer. Only the generated CC:Tweaked player and converted media segments are uploaded. The CC computer does not contact YouTube. Install `yt-dlp` and FFmpeg locally and put them on `PATH`, or set absolute paths in `config/cc-media-helper.json` inside the Minecraft profile.

During video playback, touch the left third of the monitor to seek back, the middle to pause/resume, and the right third to seek forward.

## Hot reload

Edit `cc-appstore.json`, run the sync script, and keep the Media Helper interface open. CC: App detects the replacement and rebuilds the interface while preserving its current query, results, selection, and mode. No F8 press or mod restart is required.

The JSON uses reusable stateful views and native-style inputs, buttons, cards, large toggles, sliders, settings, status, and progress components. Enter submits the search input. A search preloads 12 results; scrolling reveals the extra row before incrementally fetching another page. Clicking a card immediately applies the selected Video/Audio and Play/Write-disks states. Settings persist locally for later playback. Controls bind to allowlisted handlers; projects cannot invoke arbitrary local commands.

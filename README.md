# VidGrab 2

Save the video you are watching, in apps that play video with iOS's own player.

**Package:** `com.adarsh.vidgrab` · **Built for:** iPhone 14 Pro Max, iOS 16.5, RootHide (ElleKit, PreferenceLoader)

A small download button sits in a corner of every playing video. A tap saves it to Photos at once (best quality); hold the button, or the video, for the menu:

- **Save to Photos** (also into an album named VidGrab)
- **Share…** (straight to WhatsApp, Telegram, Files, AirDrop, without going through Photos)
- **Save to GIF Stash** (made into a GIF and added to the GIF Stash library, so it shows up behind the keyboard's GIF button)
- **Choose Quality…** (for streams that come in several sizes)
- **Copy Link**

A bar at the top shows the progress and has a cancel button. Settings › VidGrab has the switches.

Pictures get the same button (since 2.2.0): **Save to Photos**, **Share…**, **Copy Picture**, **Copy Link**.
Where the picture's address leads to a larger original (Pinterest `i.pinimg.com/<size>/…` → `originals`,
X `name=orig`, Reddit `preview.redd.it` → `i.redd.it`), the original is fetched; otherwise the picture is saved
exactly as the app shows it. A hold on a picture stays the app's. The button's corner is Automatic by default:
top right, and bottom right in Pinterest, whose sound button sits at the top right of its videos.

## What changed from 1.1.0

`orig/VidGrab-1.1.0.m` is the source this started from. What was wrong or missing there, and what replaced it:

| 1.1.0 | 2.0.0 |
|---|---|
| Streams (HLS) were handed to `AVAssetExportSession` as a local `.m3u8`. AVFoundation does not open playlists from disk, so every stream ended in "Conversion failed". | Streams are joined by VidGrab itself and written with `AVAssetWriter`, sample for sample, no re-encoding (`VGJob.m`, `VGMux.m`). |
| The best *variant* playlist was downloaded on its own. Sound that lives in a separate rendition (X, Reddit, most new streams) was never fetched: silent videos. The code that looked for `EXT-X-MEDIA` ran on media playlists, where that tag never appears. | The master playlist is read properly: variant, its audio group, the group's rendition; both are downloaded and joined (`VGPlaylist.m`). |
| Transport-stream (`.ts`) segments cannot be opened by AVFoundation at all. | A small reader takes H.264 and AAC out of transport streams and packed-audio segments (`VGTS.m`). |
| Byte-range playlists downloaded the same file once per segment. | Each file once, and only the stretch that is used. |
| All segments were started at once, no retry: one hiccup failed the download. | Five at a time, three attempts each, cancel at any moment (`VGFetch.m`). |
| A hold anywhere in the app opened the menu whenever *any* video was playing somewhere; a third fallback could pick a video that was only preloaded. | Only a hold on a video counts, and the video is the one under the finger. Something solid of the app lying over the video is respected. |
| `UIWindow sendEvent:` was hooked (every touch event in the app went through VidGrab), plus four `AVPlayerItem` creators that the code did not need. Every video address was written to the system log. | No touch hook: recognizers are attached when a window appears. Three hooks in all, on AVFoundation. Nothing is logged unless the debug log is switched on. |
| The progress box faded out and in again on every update, sat in the middle of the screen, had no cancel. | A bar under the status bar that updates in place, with a cancel button. |
| A new `NSURLSession` per download, never released; a thread polling the task every 0.3 s. | One session per download, released with it; progress from one timer while a download runs. |
| Downloads sent `User-Agent: VidGrab/1.1`. | The app's own identity and cookies, and the request headers the app gave its player. |
| A web page sent instead of a video (expired link) was saved as `video.mp4` and failed in Photos. | The answer and the file are checked; errors are sentences. |
| No settings; `Pre-Depends: rootless-compat`; signed on the phone by the post-install script; arm64 only. | Settings page; built and signed by CI for RootHide; arm64 + arm64e; links only iOS's own libraries. |

New: the button on videos, Share, GIF Stash, the VidGrab album, quality limit, two-finger hold, stopping the app's own hold action, per-app switches, cancelling, downloads that survive leaving the app for a moment.

## Where it works

VidGrab sees videos that an app plays through `AVPlayer` in an `AVPlayerLayer`. Apps that decode and draw
video themselves (their own players on `AVSampleBufferDisplayLayer` or Metal) show no button and a hold
does nothing there; making those work would mean hooking each app's own classes, which is what this
design avoids. Protected (encrypted) streams and live streams are refused with a message.

## Files

| File | What it is |
|---|---|
| `VidGrab.h`, `VidGrabUI.h` | Declarations: engine / on-screen parts |
| `VGCore.m` | Settings, log, jailbreak root, runtime hook helper |
| `VGPlaylist.m` | HLS master and media playlists |
| `VGFetch.m` | Downloads: parallel, retries, byte ranges, cancel |
| `VGTS.m` | Transport stream and packed AAC reader |
| `VGMux.m` | Tracks out of files, MP4 writer |
| `VGJob.m` | One download from link to finished file |
| `VGCapture.m` | The three hooks, what a layer plays, the download button |
| `VGUI.m` | Recognizers, menu, progress bar, VidGrab's own window |
| `VGDeliver.m` | Photos + album, share sheet, GIF Stash, the queue |
| `VGPicture.m` | Pictures: which layers show one (`UIImageView`, Texture image nodes), their buttons, fetching the original |
| `VGDebug.m` | Test commands (off without a marker file) |
| `VidGrabSB.m` | SpringBoard part: moves a clip into GIF Stash's library |
| `VGS*.{h,m,c}` | GIF encoder, from GIF Stash |
| `tools/make_prefs.py` | Generates the Settings page and icon |
| `tools/engine_test.sh`, `tests/engine_test.m` | The engine against public test streams, on a Mac and in the simulator |
| `tools/sim_test.sh`, `tests/host/` | VidGrab inside a stand-in app in the simulator |
| `tools/phone.sh` | Install, logs and test commands over USB SSH |

## Building

GitHub Actions (`.github/workflows/build.yml`): a compile check on Linux, the engine tests, the simulator
run, and the `.deb` with RootHide's Theos on macOS. The package is the `vidgrab-roothide-deb-*` artifact.

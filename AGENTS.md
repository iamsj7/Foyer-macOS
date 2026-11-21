# AGENTS.md

Guidance for AI coding agents (and humans) working on Foyer.

## What this is

A native macOS SwiftUI app (Swift package, Apple silicon, macOS 14+) that browses and plays content
from Stremio-protocol add-ons. Design follows Apple's TV app; Liquid Glass on macOS 26+.

| Target | Role |
|---|---|
| `Sources/AddonKit` | Protocol client (`AddonClient`), models, `StreamQuality`, `HLSInspector`, `PlaybackProbe`, `HLSHeaderProxy`, `SourceCheck`, subtitles |
| `Sources/Foyer` | The app: `App.swift` (scenes, sidebar), Home/Search/Library/Genre views, `DetailView` + `DetailSections`, players (`PlayerScreen` + `AVControls` for AVFoundation, `MPVPlayer` for mpv), `PictureMode`, `Commands`, Settings, `About` (`AppInfo`) |
| `Sources/checks` | End-to-end checks executable, grouped (`--only`) |

## Commands

```bash
swift build -c release --arch arm64                       # build (always this config)
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
scripts/run.sh                                            # build and launch
scripts/check.sh "$STREAM_ADDON_URL" --only <groups>      # setup,catalog,streams,quality,playback,mpv,subtitles,persistence
scripts/package-app.sh                                    # dist/*.app + zip
```

- After a change, build incrementally and run **only the check groups the change touches**. Run the
  full `scripts/check.sh` only before a release or when asked (it takes minutes and hits live add-ons).
- To relaunch the app: `pkill -x Foyer`, then start `"$BIN/Foyer"`.

## Hard rules

- **Never print, log or commit add-on manifest URLs or stream URLs.** They carry private tokens. The
  user's add-on URL lives in the `STREAM_ADDON_URL` environment variable; check presence only
  (`[ -n "$STREAM_ADDON_URL" ]`). Don't open `~/Library/Application Support/Foyer/*.json` in
  output. When probing streams, print status codes and hosts only.
- **Legal only:** never add built-in stream sources, scrapers, torrent support, or suggestions of stream
  add-ons. Suggested add-ons must be catalogs, metadata, subtitles or trailers.
- **No AI attribution** in commits, PRs, tags or release notes (no `Co-Authored-By`, no "Generated
  with" footers). The human author is the only author.
- Commit or push only when asked.

## Platform rules

- Native first: SwiftUI/AppKit controls, Apple HIG, SF Symbols. Reduce Motion and VoiceOver supported.
- macOS 14 deployment target. Gate macOS 26 APIs (`glassEffect`, `GlassEffectContainer`,
  `.buttonStyle(.glass)`, `scrollEdgeEffectStyle`) with `if #available(macOS 26, *)`; helpers live in
  `NativeStyle.swift`. Check new SDK 27 APIs against Apple's docs before using them.
- `Package.swift` stamps the binary with SDK 27 (`-platform_version macos 14.0 27.0`); without it
  Liquid Glass doesn't engage. Keep it.
- Keep the main thread free: no synchronous network, disk-heavy or libmpv calls on it.

## Known platform quirks (don't "fix" these back)

- **libmpv:** every libmpv call goes through `MPVCore`'s serial queue; `shutdown()` is async. mpv's
  render thread can need the main thread (layer EDR toggles), so a main-thread mpv call can deadlock.
- **MPVKit MoltenVK context ignores resizes** (`moltenvk_control` returns `VO_NOTIMPL`). The drawable
  stays at the largest screen's pixel size, and `MPVHostView` places and scales the layer per picture
  mode (`PictureLayout.layerFrame`). Changing `drawableSize` after start shows the picture in a corner.
- **AVPlayer drops custom headers on segment requests and on cross-host redirects.** HLS needing
  headers goes through `HLSHeaderProxy` (loopback), which re-applies them, including on redirects.
- **AVKit's floating controls can't be hidden reliably** on macOS 26 (they stay up when the window
  isn't key; toggling `controlsStyle` leaves an empty glass panel). Apple's player therefore draws into
  an `AVPlayerLayer` with our own `AVControlsBar`, shared in look with mpv's bar.
- **HEVC tagged `hev1` in MP4** plays audio-only in AVFoundation; `PlayerModel.checkForVideo()` hands
  such streams to mpv.
- Stream add-ons key on IMDb ids; `Meta.streamID(for:)` maps `tmdb:` ids to IMDb ids.
- **App icon** is `Resources/Foyer.icon` (Icon Composer). `scripts/package-app.sh` compiles it with
  `actool`; actool's icon export fails ("exited with status 255") unless the `.icon` path is absolute.

## Style

- Comments explain *why* (constraints, workarounds), in present tense; no history or conversation.
- App identity (name, version, author, license) lives in `AppInfo` (`About.swift`).

# Building from Source

Requirements: Apple silicon Mac, Xcode 26 or later.

```bash
scripts/run.sh                 # build (release, arm64) and launch
open Package.swift             # or build and run from Xcode (Foyer scheme)
```

## Checks

`scripts/check.sh` builds the app and runs end-to-end checks against live add-ons. It needs a stream
add-on manifest URL of your own (never committed; only its host is printed):

```bash
scripts/check.sh "<manifest URL>"
scripts/check.sh "<manifest URL>" --only catalog,subtitles
```

Groups: `setup`, `catalog`, `streams`, `quality`, `playback`, `mpv`, `subtitles`, `persistence`.

## Layout

| Path | Contents |
|---|---|
| `Sources/AddonKit` | Protocol client, models, stream quality parsing, HLS inspection, playback probing, the HLS header proxy, source checking, subtitles |
| `Sources/Foyer` | SwiftUI app: browsing, title pages, players, settings |
| `Sources/checks` | Checks executable |

## Notes for contributors

- macOS 14 deployment target; macOS 26 APIs (Liquid Glass) behind `if #available(macOS 26, *)`.
- The linker stamps the binary with SDK 27 so Liquid Glass engages (see `Package.swift`).
- No synchronous libmpv calls on the main thread (mpv's render thread can need it).

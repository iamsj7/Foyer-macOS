# Contributing

Thanks for helping. A few ground rules keep the project healthy and legal.

## Scope

- Foyer is a **client** for the Stremio add-on protocol. It doesn't host, scrape or link to
  content, and it **never suggests or bundles stream sources.** Pull requests that add built-in
  stream providers, scrapers, torrent support or piracy-oriented defaults won't be accepted.
- Suggested add-ons must be legal: catalogs, metadata, subtitles, trailers.

## Development

```bash
scripts/run.sh                                    # build and launch
scripts/check.sh "<manifest URL>" --only catalog  # checks touching what you changed
```

- Swift 6 toolchain, macOS 14+ deployment target. Gate macOS 26 APIs (Liquid Glass) with
  `if #available(macOS 26, *)`.
- Follow Apple's Human Interface Guidelines; prefer native SwiftUI and AppKit controls.
- Keep the main thread free: no synchronous network or libmpv calls on it.
- Never log or print add-on manifest URLs or stream URLs; they can carry private tokens.
- Comments explain *why* (platform constraints, workarounds), in present tense.

## Branches

- `dev` is where work happens; open pull requests against `dev`. GitHub doesn't build `dev` or
  pull requests, so build and run the relevant checks locally before opening one.
- `main` holds released code. A version bump in `Sources/Foyer/About.swift` merged into `main`
  publishes a release automatically (see the wiki's Releasing page).

## Pull requests

1. One focused change per PR, with a short description and screenshots for UI changes.
2. Make sure `swift build -c release --arch arm64` succeeds with no new warnings.
3. Run the check groups your change touches.

By contributing, you agree that your contributions are licensed under GPL-3.0-or-later.

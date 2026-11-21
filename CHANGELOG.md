# Changelog

All notable changes are listed here. This project follows [Semantic Versioning](https://semver.org).

## [0.2.0] - 2026-11-21

### Added
- Quality-first Play: sources are checked from the highest quality down and the first that answers
  starts. Resume checks your last source first.
- Automatic fallbacks: a stream that fails or stalls for 30 s moves to the next best source at the
  same position; fallbacks are checked in the background while playing.
- Stream filters: quality, HDR, audio, AirPlay & Picture in Picture, and add-on.
- Quality chips (4K, Dolby Vision, Atmos, 5.1) in the player's control bar.
- What's New sheet after an update (Foyer ▸ What's New).
- Settings grouped into Add-ons, Playback, Subtitles, Library, Storage and About.

### Changed
- The stream list uses plain language; the Format column shows only with Settings ▸ Playback ▸ Show
  technical details.
- Source checks retry once, confirm the first bytes are media, and skip dead links for five minutes.
- Motion follows Apple's fluid-interface rules; toolbars have no background, as in Apple's apps.

### Fixed
- Quitting during playback saves the exact position.
- Player windows no longer reopen and start playing at launch (macOS 15 and later).
- Leaving a title page while sources are being checked no longer opens a player.
- Two overlapping players no longer clear each other's Now Playing info.

### Performance
- Watch progress updates only redraw the title they belong to, not every page.
- Title pages rank streams once per change instead of on every redraw, including window resizes.
- Artwork is decoded at its display size and cached, using far less memory.
- mpv time updates are throttled before they reach the main thread; control bars redraw only the
  clock and scrubber.
- The HLS proxy pauses downloads while the player isn't reading, so memory stays bounded.

## [0.1.0] - 2026-11-21

First public release.

### Added
- TV-app-style browsing: hero, Trending Now, catalog shelves, genres, Browse Categories, Continue
  Watching, Library.
- Title pages with cast, episodes, trailers and a stream table with measured quality and
  best-in-class markers.
- Smart Play (checks sources in quality order) and Resume on the same source.
- Apple's player for MP4/HLS and mpv for MKV and other formats, with one shared control bar,
  picture modes and cinema/IMAX aspect presets.
- Add-on subtitles with language preference and timing.
- Legal add-on suggestions; Cinemeta, TMDB and OpenSubtitles v3 installed on first launch.
- Settings: playback, subtitles, library, storage, about and acknowledgements.
- Update checks against GitHub Releases (Foyer ▸ Check for Updates…, automatic once a day).

### Security
- Only http(s) links from add-ons are accepted, so an add-on can't open local files, launch apps or
  use mpv's special protocols.

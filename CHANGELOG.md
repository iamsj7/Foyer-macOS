# Changelog

All notable changes are listed here. This project follows [Semantic Versioning](https://semver.org).

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

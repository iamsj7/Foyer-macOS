# FAQ

**Does Foyer provide movies or shows?**
No. It's a client. Catalogs, details, streams and subtitles all come from add-ons you install. The app
only suggests legal add-ons (catalogs, metadata, subtitles, trailers) and never suggests stream sources.

**Why won't a stream play in Apple's player?**
Apple's player doesn't open MKV, AVI or WebM, and some MP4s use codec tags it can't decode. Those play
in mpv automatically.

**Why are some streams missing?**
Torrent-only (`infoHash`) streams aren't supported; Foyer plays direct HTTP(S) streams.

**Why does the app say "Checking Sources…"?**
Play tests sources in quality order and starts the best one that responds, so you don't land on dead
links.

**Is my data sent anywhere?**
No accounts, analytics or telemetry. Requests go only to the add-ons you installed, the stream hosts
they return, and (once a day, can be turned off) GitHub Releases to check for updates.

**Which license?**
GPL-3.0-or-later. Bundled components keep their own licenses; see `THIRD_PARTY_NOTICES.md`.

# Add-ons

Foyer speaks the [Stremio add-on protocol](https://github.com/Stremio/stremio-addon-sdk):
`manifest`, `catalog`, `meta`, `stream` and `subtitles` resources.

## Installed on first launch

| Add-on | Provides |
|---|---|
| Cinemeta | Movie and TV catalogs, details, IMDb ratings |
| The Movie Database | Trending, genres, details, cast photos |
| OpenSubtitles v3 | Subtitles |

## Suggested (legal only)

Streaming Catalogs, Anime Kitsu, Streailer (trailers) and AIOMetadata. Foyer only suggests
add-ons that provide catalogs, metadata, subtitles or trailers. It **never suggests stream sources.**

## Adding any add-on

Paste a manifest URL (`https://…/manifest.json` or `stremio://…`) in **Settings ▸ Add-ons** and
click **Install**. Drag to reorder: order sets Home rows and stream priority.

## How the app uses them

- **IDs:** stream and subtitle add-ons key on IMDb ids. Titles from add-ons with their own ids
  (such as `tmdb:…`) are looked up by the IMDb id their metadata provides.
- **Link-only results** (`externalUrl`) from add-ons that only return links appear as **Open In**
  buttons. **YouTube trailers** (`ytId`) feed the Trailer button.
- **Headers:** stream `behaviorHints.proxyHeaders` are honoured by both players, including across
  redirects.

## Privacy

Manifest URLs may contain private tokens. Foyer stores them only in `addons.json`, never logs
them, and keeps stream lists out of the disk cache.

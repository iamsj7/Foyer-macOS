# Third-Party Notices

Foyer is licensed under GPL-3.0-or-later (see [LICENSE](LICENSE)). It includes the following
open-source components, each under its own license. Source code for every component is available from
the linked project.

## Bundled through MPVKit (LGPL build)

Foyer links [MPVKit](https://github.com/mpvkit/MPVKit)'s LGPL build (not the `-GPL` variant).
Because Foyer's complete source is published, you can rebuild it against modified versions of
these libraries, as the LGPL requires.

| Component | Purpose | License |
|---|---|---|
| [mpv / libmpv](https://mpv.io) | Fallback player | LGPL-2.1-or-later |
| [MPVKit](https://github.com/mpvkit/MPVKit) | libmpv packaging for Apple platforms | LGPL-3.0 |
| [FFmpeg](https://ffmpeg.org) | Demuxing and decoding | LGPL-2.1-or-later |
| [libplacebo](https://code.videolan.org/videolan/libplacebo) | GPU rendering, HDR tone mapping | LGPL-2.1-or-later |
| [libdovi](https://github.com/quietvoid/dovi_tool) | Dolby Vision metadata | MIT |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Vulkan on Metal | Apache-2.0 |
| [shaderc](https://github.com/google/shaderc) | Shader compilation | Apache-2.0 |
| [Little CMS](https://www.littlecms.com) | Colour management | MIT |
| [dav1d](https://code.videolan.org/videolan/dav1d) | AV1 decoding | BSD-2-Clause |
| [uavs3d](https://github.com/uavs3/uavs3d) | AVS3 decoding | BSD-3-Clause |
| [libass](https://github.com/libass/libass) | Subtitle rendering | ISC |
| [FreeType](https://freetype.org) | Font rendering | FreeType License |
| [HarfBuzz](https://harfbuzz.github.io) | Text shaping | MIT |
| [FriBidi](https://github.com/fribidi/fribidi) | Bidirectional text | LGPL-2.1-or-later |
| [libunibreak](https://github.com/adah1972/libunibreak) | Line breaking | zlib |
| [uchardet](https://www.freedesktop.org/wiki/Software/uchardet/) | Encoding detection | MPL-1.1 / GPL-2.0 / LGPL-2.1 |
| [libbluray](https://www.videolan.org/developers/libbluray.html) | Blu-ray structures | LGPL-2.1-or-later |
| [OpenSSL](https://www.openssl.org) | TLS | Apache-2.0 |
| [GnuTLS](https://www.gnutls.org), Nettle, GMP | TLS and cryptography | LGPL-2.1-or-later; Nettle/GMP: LGPL-3.0-or-later or GPL-2.0-or-later |
| [LuaJIT](https://luajit.org) | mpv scripting | MIT |

Verify each license against the component's own repository before redistributing modified builds.

## Data and services

Foyer shows data that add-ons provide. Names and marks belong to their owners; Foyer is
not affiliated with or endorsed by them.

- **Stremio add-on protocol:** <https://github.com/Stremio/stremio-addon-sdk>
- **Cinemeta:** default catalogs and title details (Stremio).
- **IMDb:** ratings and title identifiers shown through add-ons. Data © IMDb.com, Inc.
- **The Movie Database (TMDB):** catalogs, details and cast photos through the TMDB add-on.
  *This product uses the TMDB API but is not endorsed or certified by TMDB.*
- **OpenSubtitles:** subtitles through the OpenSubtitles add-on.
- **Apple:** SwiftUI, AVFoundation, AVKit and SF Symbols, under the Apple SDK license.

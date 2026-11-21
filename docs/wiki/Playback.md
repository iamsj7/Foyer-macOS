# Playback

## Two players

| Player | Used for | Highlights |
|---|---|---|
| Apple's player (AVFoundation) | MP4, MOV, HLS | HDR10, Dolby Vision, Atmos / Spatial Audio, AirPlay, Picture in Picture |
| mpv (MPVKit) | MKV, AVI, WebM, others | Most codecs and containers, HDR tone mapping, cinema/IMAX aspect presets |

The player is chosen from the container. If Apple's player can decode a file's audio but not its video
(for example HEVC tagged `hev1` inside MP4), Foyer switches to mpv at the same position.

Both players share one control bar: scrubber, skip ±10 s, play/pause, mute and volume, audio and
subtitle tracks, picture size, AirPlay and PiP (Apple's player), and full screen. Controls and the
cursor hide after 3 seconds without pointer movement.

## Play and Resume

- **Play** checks sources in quality order (Apple's player first, then mpv) and starts the first that
  responds. Slow add-on servers are given up to 20 s.
- **Resume** continues on the exact source you last used, at your position.
- Double-click a row in the stream table to play that specific stream.

## Picture size

Fit (original aspect), Zoom to Fill, Stretch, and in mpv Actual Size plus aspect presets:
16:9, 4:3, 1.85:1, 2.39:1, IMAX 1.90:1 and IMAX 1.43:1. Every video opens at Fit.

## Subtitles

Subtitles come from subtitle add-ons and the stream itself. Set a preferred language in **Settings**;
adjust timing in ±0.5 s steps from the player.

## Stream quality

The stream table parses labels and measures HLS playlists and media tracks for resolution, HDR,
codecs, channels and bitrate. Markers show **Best quality**, **Best video** and **Best audio**.

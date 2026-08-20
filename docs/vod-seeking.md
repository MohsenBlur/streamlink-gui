# VOD seeking: how it works, and the fallback if ads ever appear

## The problem this solved

Streaming a VOD gave the user no working timeline. `launchStreamlinkForVod` let
streamlink **pipe** the stream to the player's stdin, and a pipe has no
seekable timeline — MPC-HC even showed its seek bar (the app passes
`/viewpreset 2` specifically to keep it visible), but the bar was inert.
Downloaded VODs always seeked fine, because those are real files.

## What shipped: `--player-passthrough hls`

Streamlink resolves the stream and hands the player the HLS URL instead of
piping bytes. The player fetches the playlist itself, so its seek bar works
across the whole VOD.

Controlled by **Settings → Player → "Seekable VOD streaming"** (default on).
Turning it off restores piping exactly as before.

Consequences handled in code:

- `--hls-start-offset` does nothing under passthrough (streamlink processes
  nothing), so resume moves to player-side flags: VLC `--start-time=<s>`,
  MPV `--start=<s>`, MPC-HC `/start <ms>`. Both paths now share
  `buildPlayerArgs` in `lib/utils/player_args.dart`.
- Passthrough requires an explicit `--player`; streamlink aborts without one.
  A config that resolves to no player stays on piping.
- Lifecycle is unchanged: passthrough uses a blocking `subprocess.call`
  (`streamlink_cli/output/player.py`), so the streamlink process still lives
  for the whole session and `proc.exitCode` still drives teardown.
- Auth still works: the Twitch plugin embeds `nauthsig`/`nauth` in the usher
  URL, so the URL handed to the player is self-authorizing.

## The ad question — measured, not assumed

Streamlink filters VOD ad segments by looking for `"Amazon"` in the `EXTINF`
title (`plugins/twitch.py`, `_is_segment_ad`). Under passthrough that filtering
does not run, so the concern was that ads would reach the player.

Measured on 2026-08-20, resolving **anonymously** (no OAuth token — the worst
case for ads), across five large partnered channels:

| Channel | VOD | Segments | Ad-marked |
|---|---|---|---|
| shroud | 2827992810 | 2080 | 0 |
| xqc | 2850006339 | 3632 | 0 |
| pokimane | 2851008101 | 789 | 0 |
| summit1g | 2850844706 | 4874 | 0 |
| lirik | 2849711756 | 2610 | 0 |

~14,000 segments, **zero** ad-marked. The playlists carried no
`EXT-X-DATERANGE`, no `twitch-stitched-ad`, no `DISCONTINUITY`, and every
`EXTINF` title was empty. They end with `#EXT-X-ENDLIST`, i.e. complete
seekable VOD manifests.

Conclusion: in practice there is nothing for the filter to remove, so
passthrough was chosen. **This is an empirical result, not a guarantee** — if
Twitch starts stitching ads into VOD manifests, the fallback below becomes
necessary.

### How to re-check

```sh
bin/bin/streamlink.exe --stream-url "twitch.tv/videos/<id>" best   # -> playlist URL
curl -sS "<playlist url>" | grep -c Amazon                          # -> 0 means clean
```

## Fallback if ads do start appearing: serve a filtered playlist

Keep native seeking **and** guarantee filtering by serving the player a
playlist we control.

1. Resolve the media playlist: `streamlink --stream-url twitch.tv/videos/<id> <quality>`.
2. `GET` that playlist.
3. Drop ad segments — the `#EXTINF` line whose title contains `Amazon`, plus
   the URI line after it. Mirror `_is_segment_ad` for `twitch-stitched-ad`
   dateranges too if those ever show up.
4. Absolutise the segment URIs. Twitch VOD playlists use **relative** URIs
   (`0.ts`, `1.ts`), so prefix each with the playlist's base URL.
5. Serve the rewritten playlist over **localhost HTTP** and launch the player
   against `http://127.0.0.1:<port>/<name>.m3u8`.
6. Launch and resume exactly as local playback does — `buildPlayerArgs`
   already produces the right flags.

Only the small text playlist is served locally; video segments still stream
directly from Twitch's CDN, so the app never proxies video bytes.

### Verified feasibility (2026-08-20)

Prototyped end-to-end against a real 5.8-hour VOD using the bundled ffmpeg —
which is what MPC-HC's LAV Splitter uses internally, so it is a good proxy for
the target player:

| Approach | Reported duration | Seek to 3h |
|---|---|---|
| Passthrough (player opens Twitch URL) | 20988.717s ✅ correct | 0.84s |
| Filtered playlist over localhost HTTP | 20988.717s ✅ correct | 2.75s |
| Filtered playlist as a local **file** | ❌ fails | — |

Both working approaches landed at 10794.6s when asked for 10800s — one segment
boundary away, which is expected and fine.

### The trap: it must be HTTP, not a local file

Writing the filtered playlist to a temp `.m3u8` and opening it **does not
work**. ffmpeg applies a protocol whitelist of `file,crypto,data` when the
playlist itself is a local file, and refuses the `https` segment URIs:

```
Protocol 'https' not on whitelist 'file,crypto,data'!
```

The playlist is otherwise valid — passing
`-protocol_whitelist file,http,https,tcp,tls,crypto` makes the exact same file
work. But a media player gives no way to set that, so the local-file variant is
a dead end. Serving over localhost HTTP sidesteps it entirely: the playlist
arrives over `http`, and nested `https` segments are then ordinary HLS.

## Related fix that rode along

Streamlink parses `--player-args` with POSIX `shlex`, where a backslash escapes
the next character. MPV's Windows IPC path
`--input-ipc-server=\\.\pipe\mpv-socket-<id>` was arriving as
`--input-ipc-server=.pipempv-socket-<id>`, so MPV never created the pipe the
progress bridge connects to — **MPV watch-progress tracking never worked while
streaming** (local playback was fine; it bypasses shlex). Generated tokens now
go through `shlexQuote`, which single-quotes them; single quotes are the only
shlex construct that preserves backslashes literally.

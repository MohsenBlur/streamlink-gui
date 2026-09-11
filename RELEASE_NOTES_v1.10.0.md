# v1.10.0 — resuming a VOD actually resumes it

If you use MPC-HC, this release fixes a bug that has been there the whole time
and only became visible when v1.9.0 started relaunching streams for you.

## Resuming a stream never really worked

Pausing a streamed VOD for a few minutes and then unpausing could leave the
player restarting **from the very beginning**, losing your place.

MPC-HC accepts a "start playing at this position" instruction for files on your
disk and **silently ignores it for streams**. Measured on MPC-HC 2.7.4: asked
for 60 seconds in, it started at zero.

Resuming appeared to work anyway, because MPC-HC separately remembers where you
were in anything it has played before — but that memory is only saved when the
player closes normally. When the app restarted a dead stream for you it had to
force the player to quit, which skipped the save. So the restart had neither the
instruction (ignored) nor the memory (never written), and began at the start.

The app no longer takes the player's word for it. It checks where playback
actually started and moves it if it is in the wrong place. That also fixes
ordinary resuming, which had been quietly relying on the player's own memory and
would break whenever the quality or the stream address changed.

It also closes the player politely before forcing it, so the player's own memory
survives as a second line of defence.

## A second, bigger bug found on the way

With **Seekable VOD streaming turned off**, resuming a VOD would overwrite your
saved position within about four seconds — every single time, with no crash, no
pause and no restart involved.

In that mode the app skips ahead for the player rather than telling the player
where to start, and the player then counts from zero. A VOD resumed at 2h34m
reported "3 seconds", and that got saved over your real position and sent to
Twitch.

The project's own notes said this had been checked and was fine. The check was
real but measured the wrong thing — the timestamps inside the video rather than
the position the player displays. It has been re-measured against the player
itself and corrected.

## Your place is much harder to lose now

- The **furthest point you ever reached** in each VOD is remembered separately
  and never moves backwards on its own.
- If a VOD opens behind that point, the app tells you and offers to **jump
  there**.
- A position that arrives in the first seconds of playback and is far behind
  where you had got to is **refused**, because that is what a failed resume
  looks like. Deliberately restarting a VOD from the beginning still works.
- Watch positions now live in **their own file** instead of inside the main
  settings file, which is rewritten in full every time the window moves.

## Also fixed

- A restarted stream could be handed the port the previous player had not yet
  released, leaving it with no way to report progress for the rest of playback.
- If shutting down a player failed, nothing said so and a restart would silently
  never happen.
- Clearer diagnostics while a VOD plays: where playback started, whether the
  position was corrected, and when progress starts being saved.

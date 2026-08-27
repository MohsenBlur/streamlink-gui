import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/player_progress.dart';

void main() {
  group('parseVlcStatus', () {
    test('reads the position while playing', () {
      final s = parseVlcStatus('{"state":"playing","time":1234}')!;
      expect(s.activity, PlayerActivity.playing);
      expect(s.positionSeconds, 1234);
    });

    test('paused and stopped are distinct activities, position kept', () {
      // The old parser collapsed both to null, which made "the user paused"
      // indistinguishable from "the stream died" - the exact ambiguity the
      // pause-death bug hid in.
      final paused = parseVlcStatus('{"state":"paused","time":1234}')!;
      expect(paused.activity, PlayerActivity.paused);
      expect(paused.positionSeconds, 1234);

      final stopped = parseVlcStatus('{"state":"stopped","time":0}')!;
      expect(stopped.activity, PlayerActivity.stopped);
      expect(stopped.positionSeconds, 0);
    });

    test('opening and unknown states map to stopped', () {
      // For the verdict machine they are all "not playing back"; its startup
      // grace handles the interface being up before playback begins.
      expect(
        parseVlcStatus('{"state":"opening","time":0}')!.activity,
        PlayerActivity.stopped,
      );
      expect(
        parseVlcStatus('{"state":"weird","time":0}')!.activity,
        PlayerActivity.stopped,
      );
    });

    test("position zero is a position; belief is the gate's job", () {
      // The parser reports facts. The confirmation gate downstream is what
      // stops a lone 0 from erasing a resume point.
      final s = parseVlcStatus('{"state":"playing","time":0}')!;
      expect(s.positionSeconds, 0);
    });

    test('junk in, null out', () {
      expect(parseVlcStatus(''), isNull);
      expect(parseVlcStatus('<html>404</html>'), isNull);
      expect(parseVlcStatus('[1,2,3]'), isNull);
      expect(parseVlcStatus('{"time":1234}'), isNull);
    });

    test('a playing state with no usable time still reports the activity', () {
      final s = parseVlcStatus('{"state":"playing"}')!;
      expect(s.activity, PlayerActivity.playing);
      expect(s.positionSeconds, isNull);
      expect(
        parseVlcStatus('{"state":"playing","time":"1234"}')!.positionSeconds,
        isNull,
      );
    });
  });

  group('mpv command protocol', () {
    test('three commands, each carrying its request id', () {
      final cmds = mpvStatusCommands();
      expect(cmds, hasLength(3));
      expect(cmds[0], contains('"time-pos"'));
      expect(cmds[0], contains('"request_id":$mpvTimePosRequestId'));
      expect(cmds[1], contains('"pause"'));
      expect(cmds[1], contains('"request_id":$mpvPauseRequestId'));
      expect(cmds[2], contains('"eof-reached"'));
      expect(cmds[2], contains('"request_id":$mpvEofRequestId'));
      for (final c in cmds) {
        expect(c, endsWith('\n'), reason: 'mpv IPC is newline-delimited');
      }
    });

    test('mpvRepliesComplete requires all three ids', () {
      // The tracker used to destroy the socket on the FIRST newline, racing
      // the second reply. Three commands make waiting mandatory.
      expect(mpvRepliesComplete(''), isFalse);
      expect(mpvRepliesComplete('{"data":1.0,"request_id":1}\n'), isFalse);
      expect(
        mpvRepliesComplete(
          '{"data":1.0,"request_id":1}\n'
          '{"data":false,"request_id":2}\n',
        ),
        isFalse,
      );
      expect(
        mpvRepliesComplete(
          '{"data":1.0,"request_id":1}\n'
          '{"data":false,"request_id":2}\n'
          '{"data":false,"request_id":3}\n',
        ),
        isTrue,
      );
    });

    test('interleaved event lines do not satisfy completeness', () {
      expect(
        mpvRepliesComplete(
          '{"event":"playback-restart"}\n'
          '{"event":"seek"}\n'
          '{"event":"tick"}\n',
        ),
        isFalse,
      );
    });
  });

  group('parseMpvStatus', () {
    String replies(List<String> lines) => '${lines.join('\n')}\n';

    String timePos(double v) =>
        '{"data":$v,"error":"success","request_id":$mpvTimePosRequestId}';
    String pause(bool v) =>
        '{"data":$v,"error":"success","request_id":$mpvPauseRequestId}';
    String eofReached(bool v) =>
        '{"data":$v,"error":"success","request_id":$mpvEofRequestId}';

    test('reads time-pos and rounds to whole seconds', () {
      final s = parseMpvStatus(
        replies([timePos(42.7), pause(false), eofReached(false)]),
      )!;
      expect(s.activity, PlayerActivity.playing);
      expect(s.positionSeconds, 43);
      expect(s.eofReached, isFalse);
    });

    test('a paused player reports paused WITH its position', () {
      final s = parseMpvStatus(
        replies([timePos(42.7), pause(true), eofReached(false)]),
      )!;
      expect(s.activity, PlayerActivity.paused);
      expect(s.positionSeconds, 43);
    });

    test('eof-reached wins over pause for the activity', () {
      // With --keep-open=yes mpv idles PAUSED at end-of-file. The pause flag
      // is true, but "stopped at EOF" is the fact the verdict machine needs.
      final s = parseMpvStatus(
        replies([timePos(3600.0), pause(true), eofReached(true)]),
      )!;
      expect(s.activity, PlayerActivity.stopped);
      expect(s.eofReached, isTrue);
      expect(s.positionSeconds, 3600);
    });

    test('request ids beat type dispatch: eof cannot masquerade as pause', () {
      // Both are bools. Under the old type dispatch the eof reply would have
      // overwritten the pause flag - the reason the ids exist.
      final s = parseMpvStatus(
        replies([timePos(10.0), eofReached(false), pause(true)]),
      )!;
      expect(s.activity, PlayerActivity.paused);
    });

    test('replies may arrive in any order', () {
      final s = parseMpvStatus(
        replies([eofReached(false), pause(false), timePos(10.0)]),
      )!;
      expect(s.positionSeconds, 10);
      expect(s.activity, PlayerActivity.playing);
    });

    test('lines without request ids fall back to type dispatch', () {
      // Old mpv, or a reply whose id was lost: degrade to the historical
      // behaviour instead of losing the tick.
      final s = parseMpvStatus(
        replies([
          '{"data":7.2,"error":"success"}',
          '{"data":false,"error":"success"}',
        ]),
      )!;
      expect(s.positionSeconds, 7);
      expect(s.activity, PlayerActivity.playing);
    });

    test('unrelated event messages are ignored', () {
      final s = parseMpvStatus(
        replies(['{"event":"playback-restart"}', timePos(7.2), pause(false)]),
      )!;
      expect(s.positionSeconds, 7);
    });

    test('a failed reply is skipped per-property', () {
      // eof-reached unavailable during load simply reads as false; the
      // position from the same tick is still used.
      final s = parseMpvStatus(
        replies([
          timePos(5.0),
          pause(false),
          '{"data":null,"error":"property unavailable","request_id":$mpvEofRequestId}',
        ]),
      )!;
      expect(s.positionSeconds, 5);
      expect(s.eofReached, isFalse);
    });

    test('one malformed line does not discard the rest', () {
      final s = parseMpvStatus(
        replies(['not json at all', timePos(5.0), pause(false)]),
      )!;
      expect(s.positionSeconds, 5);
    });

    test('nothing usable at all is null', () {
      expect(parseMpvStatus(''), isNull);
      expect(
        parseMpvStatus(
          replies(['{"data":null,"error":"property unavailable"}']),
        ),
        isNull,
      );
      expect(parseMpvStatus(replies(['{"event":"seek"}'])), isNull);
    });

    test('pause alone still yields a status with no position', () {
      final s = parseMpvStatus(replies([pause(false)]))!;
      expect(s.activity, PlayerActivity.playing);
      expect(s.positionSeconds, isNull);
    });

    test('position zero is reported', () {
      final s = parseMpvStatus(
        replies([timePos(0.0), pause(false), eofReached(false)]),
      )!;
      expect(s.positionSeconds, 0);
      expect(s.activity, PlayerActivity.playing);
    });
  });

  group('parseMpcHcStatus', () {
    String page(String state, int posMs, {int? durMs}) =>
        '<html><p id="position">$posMs</p>'
        '${durMs == null ? '' : '<p id="duration">$durMs</p>'}'
        '<p id="statestring">$state</p></html>';

    test('converts milliseconds to seconds', () {
      final s = parseMpcHcStatus(page('Playing', 90600))!;
      expect(s.activity, PlayerActivity.playing);
      expect(s.positionSeconds, 91);
    });

    test('paused and stopped are distinct, position kept', () {
      final paused = parseMpcHcStatus(page('Paused', 90600))!;
      expect(paused.activity, PlayerActivity.paused);
      expect(paused.positionSeconds, 91);

      final stopped = parseMpcHcStatus(page('Stopped', 90600))!;
      expect(stopped.activity, PlayerActivity.stopped);
    });

    test('the state match is case-insensitive', () {
      expect(parseMpcHcStatus(page('playing', 5000))!.positionSeconds, 5);
    });

    test(
      'a page without a state is null; without a position, position-less',
      () {
        expect(parseMpcHcStatus('<html></html>'), isNull);
        expect(parseMpcHcStatus(''), isNull);
        final s = parseMpcHcStatus(
          '<html><p id="statestring">Playing</p></html>',
        )!;
        expect(s.positionSeconds, isNull);
      },
    );

    test('position zero is a position', () {
      expect(parseMpcHcStatus(page('Playing', 0))!.positionSeconds, 0);
    });

    test('paused at the duration is end-of-file, not a pause', () {
      // Measured against MPC-HC 2.7.4: at EOF it pauses on the last frame,
      // and when a stream DIES it jumps the position to the full duration
      // and pauses there - the dying gasp that used to mark a half-watched
      // VOD complete. A real user pause never moves the position, so
      // paused-at-end is unambiguous.
      final s = parseMpcHcStatus(page('Paused', 60000, durMs: 60000))!;
      expect(s.activity, PlayerActivity.stopped);
      expect(s.eofReached, isTrue);
    });

    test('a few hundred ms of overshoot past the duration still reads EOF',
        () {
      // Also measured: a 12000ms file paused at 12023ms after playing out.
      final s = parseMpcHcStatus(page('Paused', 12023, durMs: 12000))!;
      expect(s.eofReached, isTrue);
    });

    test('paused mid-file stays an ordinary pause', () {
      final s = parseMpcHcStatus(page('Paused', 30000, durMs: 60000))!;
      expect(s.activity, PlayerActivity.paused);
      expect(s.eofReached, isFalse);
    });

    test('without a duration the EOF signal cannot fire', () {
      final s = parseMpcHcStatus(page('Paused', 60000))!;
      expect(s.activity, PlayerActivity.paused);
      expect(s.eofReached, isFalse);
    });

    test('playing at the duration is not EOF - the jump comes with a pause',
        () {
      final s = parseMpcHcStatus(page('Playing', 60000, durMs: 60000))!;
      expect(s.activity, PlayerActivity.playing);
      expect(s.eofReached, isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/player_progress.dart';

void main() {
  group('parseVlcPosition', () {
    test('reads the position while playing', () {
      expect(parseVlcPosition('{"state":"playing","time":1234}'), 1234);
    });

    test('a paused or stopped player reports nothing', () {
      expect(parseVlcPosition('{"state":"paused","time":1234}'), isNull);
      expect(parseVlcPosition('{"state":"stopped","time":0}'), isNull);
    });

    test('position zero is not a position', () {
      // The player is at the very start, or has not loaded yet; writing 0
      // would erase a resume point the user has not actually watched past.
      expect(parseVlcPosition('{"state":"playing","time":0}'), isNull);
    });

    test('junk in, null out', () {
      // Each of these used to be swallowed by a bare catch inside the timer,
      // where "unparseable" and "paused" were indistinguishable.
      expect(parseVlcPosition(''), isNull);
      expect(parseVlcPosition('<html>404</html>'), isNull);
      expect(parseVlcPosition('[1,2,3]'), isNull);
      expect(parseVlcPosition('{"state":"playing"}'), isNull);
      expect(parseVlcPosition('{"state":"playing","time":"1234"}'), isNull);
    });
  });

  group('parseMpvPosition', () {
    String replies(List<String> lines) => '${lines.join('\n')}\n';

    test('reads time-pos and rounds to whole seconds', () {
      expect(
          parseMpvPosition(replies([
            '{"data":42.7,"error":"success"}',
            '{"data":false,"error":"success"}',
          ])),
          43);
    });

    test('a paused player reports nothing, whatever its position', () {
      expect(
          parseMpvPosition(replies([
            '{"data":42.7,"error":"success"}',
            '{"data":true,"error":"success"}',
          ])),
          isNull);
    });

    test('the two replies may arrive in either order', () {
      // They are separate commands on one socket; nothing guarantees order.
      expect(
          parseMpvPosition(replies([
            '{"data":false,"error":"success"}',
            '{"data":10.0,"error":"success"}',
          ])),
          10);
    });

    test('unrelated event messages are ignored', () {
      expect(
          parseMpvPosition(replies([
            '{"event":"playback-restart"}',
            '{"data":7.2,"error":"success"}',
          ])),
          7);
    });

    test('a failed reply carries no usable position', () {
      expect(
          parseMpvPosition(
              replies(['{"data":null,"error":"property unavailable"}'])),
          isNull);
    });

    test('one malformed line does not discard the rest', () {
      expect(
          parseMpvPosition(replies([
            'not json at all',
            '{"data":5.0,"error":"success"}',
          ])),
          5);
    });

    test('no position reply at all reports nothing', () {
      expect(parseMpvPosition(''), isNull);
      expect(parseMpvPosition(replies(['{"data":false,"error":"success"}'])),
          isNull);
    });

    test('position zero is reported, unlike the other two players', () {
      // MPV's pause flag is authoritative, so a genuine 0.0 while playing
      // means the user seeked back to the start - which should be recorded.
      expect(
          parseMpvPosition(replies([
            '{"data":0.0,"error":"success"}',
            '{"data":false,"error":"success"}',
          ])),
          0);
    });
  });

  group('parseMpcHcPosition', () {
    String page(String state, int posMs) =>
        '<html><p id="position">$posMs</p><p id="statestring">$state</p></html>';

    test('converts milliseconds to seconds', () {
      expect(parseMpcHcPosition(page('Playing', 90_600)), 91);
    });

    test('only a playing state counts', () {
      expect(parseMpcHcPosition(page('Paused', 90_600)), isNull);
      expect(parseMpcHcPosition(page('Stopped', 90_600)), isNull);
    });

    test('the state match is case-insensitive', () {
      expect(parseMpcHcPosition(page('playing', 5000)), 5);
    });

    test('a page without the fields reports nothing', () {
      expect(parseMpcHcPosition('<html></html>'), isNull);
      expect(parseMpcHcPosition(''), isNull);
      expect(parseMpcHcPosition(page('Playing', 0)), isNull);
    });
  });
}

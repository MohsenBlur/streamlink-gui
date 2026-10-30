import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/mpc_slave.dart';
import 'package:streamlink_gui/utils/mpc_slave_protocol.dart';
import 'package:streamlink_gui/utils/player_progress.dart';

import 'support/fake_mpc_slave.dart';

/// MPC-HC's /slave API: what its messages mean, a session over it, and the
/// channel to the runner that carries them.
void main() {
  group('the protocol', () {
    test("command ids are MPC-HC's own (MpcApi.h, 2.8.4)", () {
      // A wrong id is silently ignored by the player, or silently dropped
      // by the runner: nothing would fail but tracking.
      expect(MpcCommand.connect, 0x50000000);
      expect(MpcCommand.state, 0x50000001);
      expect(MpcCommand.playMode, 0x50000002);
      expect(MpcCommand.nowPlaying, 0x50000003);
      expect(MpcCommand.currentPosition, 0x50000007);
      expect(MpcCommand.notifySeek, 0x50000008);
      expect(MpcCommand.notifyEndOfStream, 0x50000009);
      expect(MpcCommand.version, 0x5000000A);
      expect(MpcCommand.disconnect, 0x5000000B);
      expect(MpcCommand.setPosition, 0xA0002000);
      expect(MpcCommand.getNowPlaying, 0xA0003002);
      expect(MpcCommand.getCurrentPosition, 0xA0003004);
      expect(MpcCommand.closeApp, 0xA0004006);
      expect(MpcLoadState.loaded, 2);
      expect([MpcPlayState.play, MpcPlayState.pause, MpcPlayState.stop],
          [0, 1, 2]);
    });

    test('seconds parse as MPC-HC and MPC-BE format them', () {
      expect(parseMpcSeconds('12.345'), 12.345);
      expect(parseMpcSeconds('600'), 600);
      expect(parseMpcSeconds(' 7.000 '), 7);
      expect(parseMpcSeconds(''), isNull);
      expect(parseMpcSeconds('abc'), isNull);
      expect(parseMpcSeconds('-1.000'), isNull);
      expect(parseMpcSeconds('nan'), isNull);
    });

    test("now-playing's duration is its last field, whatever precedes it", () {
      expect(
          parseMpcNowPlayingDuration(
              'Title|Author|Desc|https://x/index.m3u8|10800.500'),
          10800.5);
      // MPC-BE: whole seconds.
      expect(parseMpcNowPlayingDuration('t|a|d|C:\\v.mp4|60'), 60);
      // An escaped bar in a field, and a path ending in a backslash, which
      // makes the next separator look escaped.
      expect(
          parseMpcNowPlayingDuration(r'A \| B|||C:\folder\|12.000'), 12);
      expect(parseMpcNowPlayingDuration('no bars'), isNull);
      expect(parseMpcNowPlayingDuration('t|a|d|f|'), isNull);
      expect(parseMpcNowPlayingDuration('t|a|d|f|0.000'), isNull);
    });

    test('a seek is an absolute number of seconds', () {
      expect(mpcSetPositionPayload(9292), '9292');
      expect(mpcSetPositionPayload(-3), '0');
    });
  });

  group('MpcSlaveState', () {
    MpcSlaveState loaded({int playMode = MpcPlayState.play}) => MpcSlaveState()
      ..apply(MpcCommand.connect, '1')
      ..apply(MpcCommand.state, '${MpcLoadState.loaded}')
      ..apply(MpcCommand.nowPlaying, 't|a|d|f|60.000')
      ..apply(MpcCommand.playMode, '$playMode');

    test('nothing is playing until a file is loaded', () {
      final state = MpcSlaveState()..apply(MpcCommand.connect, '1');
      expect(state.status(null).activity, PlayerActivity.stopped);
      state.apply(MpcCommand.state, '${MpcLoadState.loading}');
      expect(state.status(5).activity, PlayerActivity.stopped);
      expect(state.status(5).eofReached, isFalse);
    });

    test('play, pause and stop, with the position rounded', () {
      expect(loaded().status(12.6).activity, PlayerActivity.playing);
      expect(loaded().status(12.6).positionSeconds, 13);
      expect(loaded(playMode: MpcPlayState.pause).status(30).activity,
          PlayerActivity.paused);
      expect(loaded(playMode: MpcPlayState.stop).status(30).activity,
          PlayerActivity.stopped);
      expect(loaded().status(0).positionSeconds, 0,
          reason: 'zero is a position');
      expect(loaded().status(null).positionSeconds, isNull);
    });

    test('the end of the stream, as MPC-HC reports it', () {
      // At EOF MPC-HC pauses on the last frame and says so.
      final state = loaded()
        ..apply(MpcCommand.playMode, '${MpcPlayState.pause}')
        ..apply(MpcCommand.notifyEndOfStream, '');
      final status = state.status(31);
      expect(status.eofReached, isTrue);
      expect(status.activity, PlayerActivity.stopped);
      expect(status.positionSeconds, 31,
          reason: 'mid-VOD: a premature end, which the monitor heals');
    });

    test('paused at its own duration is the end even unannounced', () {
      // Measured on 2.7.4: a dying stream drains, jumps the position to the
      // full duration and pauses there. A real pause never moves it.
      final state = loaded(playMode: MpcPlayState.pause);
      expect(state.status(60).eofReached, isTrue);
      expect(state.status(59.4).eofReached, isTrue);
      expect(state.status(60.023).eofReached, isTrue, reason: 'overshoot');
      expect(state.status(30).eofReached, isFalse);
      expect(state.status(30).activity, PlayerActivity.paused);
      expect(loaded().status(60).eofReached, isFalse,
          reason: 'playing at the duration is not the end: the jump comes '
              'with a pause');
      final noDuration = MpcSlaveState()
        ..apply(MpcCommand.connect, '1')
        ..apply(MpcCommand.state, '${MpcLoadState.loaded}')
        ..apply(MpcCommand.playMode, '${MpcPlayState.pause}');
      expect(noDuration.status(60).eofReached, isFalse);
    });

    test('a seek, playing again or another file moves it off the end', () {
      MpcSlaveState atEnd() => loaded()
        ..apply(MpcCommand.playMode, '${MpcPlayState.pause}')
        ..apply(MpcCommand.notifyEndOfStream, '');
      expect(
          (atEnd()..apply(MpcCommand.notifySeek, '20.000')).status(20).eofReached,
          isFalse);
      expect(
          (atEnd()..apply(MpcCommand.playMode, '${MpcPlayState.play}'))
              .status(20)
              .eofReached,
          isFalse);
      expect(
          (atEnd()
                ..apply(MpcCommand.state, '${MpcLoadState.closing}')
                ..apply(MpcCommand.state, '${MpcLoadState.loaded}'))
              .status(20)
              .eofReached,
          isFalse);
      // A notice that arrives while playing (MPC-HC repeats it with each
      // play-state change while at the end) does not make playback the end.
      final playing = loaded()..apply(MpcCommand.notifyEndOfStream, '');
      expect(playing.status(20).eofReached, isFalse);
      expect(playing.status(20).activity, PlayerActivity.playing);
    });

    test('closing reads as stopped, and garbage changes nothing', () {
      final state = loaded()
        ..apply(MpcCommand.playMode, 'x')
        ..apply(MpcCommand.state, '')
        ..apply(MpcCommand.currentPosition, 'nope');
      expect(state.status(5).activity, PlayerActivity.playing);
      state.apply(MpcCommand.disconnect, '');
      expect(state.disconnected, isTrue);
      expect(state.status(5).activity, PlayerActivity.stopped);
    });
  });

  group('MpcSlaveSession', () {
    late FakeMpcSlave slave;
    late MpcSlaveSession session;
    late FakeMpcPlayer player;

    setUp(() async {
      slave = FakeMpcSlave();
      session = await MpcSlaveSession.open(slave);
      player = slave.players[session.id]!;
    });

    test('is the window the runner opened', () {
      expect(session.window, FakeMpcSlave.windowOf(session.id));
      expect(slave.opened, [session.id]);
    });

    test('asks nothing before the player connects', () async {
      expect(session.connected, isFalse);
      expect(await session.poll(), isNull);
      expect(slave.sent, isEmpty);
    });

    test('a poll asks where the player is and reads the answer', () async {
      player.connect(startAt: 600);
      expect(session.connected, isTrue);
      final status = await session.poll();
      expect(status!.activity, PlayerActivity.playing);
      expect(status.positionSeconds, 600);
      expect(slave.commandsTo(session.id), [MpcCommand.getCurrentPosition]);
      expect((await session.poll())!.positionSeconds, 601);
    });

    test('an answer that comes after the send reports still counts', () async {
      player
        ..answerLate = true
        ..connect(startAt: 42);
      expect((await session.poll())!.positionSeconds, 42);
    });

    test('no answer is no position, not a stale one', () async {
      player.connect(startAt: 42);
      await session.poll();
      player.answerPolls = false;
      final status =
          await session.poll(timeout: const Duration(milliseconds: 20));
      expect(status!.positionSeconds, isNull);
    });

    test('a player with nothing loaded is not asked', () async {
      player.connect();
      slave.emit(session.id, MpcCommand.state, '${MpcLoadState.closing}');
      final status = await session.poll();
      expect(status!.activity, PlayerActivity.stopped);
      expect(slave.sent, isEmpty);
    });

    test('a refused question is no facts at all', () async {
      player.connect();
      slave.closed.add(session.id); // the runner no longer has the session
      expect(await session.poll(), isNull);
    });

    test('a closing player is not asked', () async {
      player.connect();
      player.disconnect();
      expect(session.connected, isFalse);
      expect(await session.poll(), isNull);
    });

    test('a seek counts once the player reports it', () async {
      player.connect();
      expect(await session.seek(600), isTrue);
      expect(slave.sent.last, (session.id, MpcCommand.setPosition, '600'));
      expect(player.position, 600);
    });

    test('a seek the player takes but never makes is not a seek', () async {
      // MPC-HC takes CMD_SETPOSITION whatever its state, and ignores it
      // with nothing loaded.
      player
        ..acknowledgeSeeks = false
        ..connect();
      expect(
          await session.seek(600, timeout: const Duration(milliseconds: 20)),
          isFalse);
    });

    test('no seek before the player connects', () async {
      expect(await session.seek(600), isFalse);
      expect(slave.sent, isEmpty);
    });

    test("only its own session's messages", () async {
      final other = await MpcSlaveSession.open(slave);
      slave.players[other.id]!.connect(startAt: 5);
      expect(other.connected, isTrue);
      expect(session.connected, isFalse);
      final rejected = <MpcSlaveRejection>[];
      session.onRejected = rejected.add;
      slave.reject(other.id, 1234, MpcCommand.connect);
      slave.reject(session.id, 4321, MpcCommand.connect);
      expect(rejected.single.pid, 4321);
    });

    test('closing ends the session at the runner and stops listening',
        () async {
      player.connect();
      final events = <int>[];
      session.onEvent = (event) => events.add(event.command);
      await session.close();
      expect(slave.closed, {session.id});
      expect(session.connected, isFalse);
      slave.emit(session.id, MpcCommand.playMode, '0');
      expect(events, isEmpty);
      expect(await session.poll(), isNull);
      await session.close(); // twice is harmless
    });

    test('binds the process it was launched with', () async {
      expect(await session.bind(4242), isTrue);
      expect(slave.bound, {session.id: 4242});
    });
  });

  group('MethodChannelMpcSlave', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('streamlink_gui/mpc_slave');
    final calls = <MethodCall>[];
    late MethodChannelMpcSlave slave;

    setUp(() {
      calls.clear();
      slave = MethodChannelMpcSlave();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'open':
            return {'session': 3, 'window': '197380'};
          case 'bind':
          case 'send':
            return true;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> fromRunner(String method, Map<String, Object?> args) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
                channel.name,
                const StandardMethodCodec()
                    .encodeMethodCall(MethodCall(method, args)),
                (_) {});

    test('speaks the runner channel', () async {
      final window = await slave.open();
      expect(window.session, 3);
      expect(window.window, '197380');
      expect(await slave.bind(3, 4242), isTrue);
      expect(await slave.send(3, MpcCommand.getCurrentPosition, ''), isTrue);
      await slave.close(3);
      expect([for (final c in calls) c.method],
          ['open', 'bind', 'send', 'close']);
      expect(calls[1].arguments, {'session': 3, 'pid': 4242});
      // 0xA0003004 does not fit 32 bits; it must reach the runner whole.
      expect(calls[2].arguments,
          {'session': 3, 'command': 0xA0003004, 'payload': ''});
      expect(calls[3].arguments, {'session': 3});
    });

    test("passes on the runner's events and refusals", () async {
      await slave.open(); // installs the handler
      final events = <MpcSlaveEvent>[];
      final rejections = <MpcSlaveRejection>[];
      slave.events.listen(events.add);
      slave.rejections.listen(rejections.add);
      await fromRunner('event', {
        'session': 3,
        'command': MpcCommand.currentPosition,
        'payload': '12.500',
      });
      await fromRunner('rejected',
          {'session': 3, 'pid': 777, 'command': MpcCommand.connect});
      await fromRunner('event', {'session': 'x', 'command': 1});
      expect(events.single.payload, '12.500');
      expect(events.single.command, MpcCommand.currentPosition);
      expect(rejections.single.pid, 777);
    });

    test('a runner without the channel reads as no control window', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await expectLater(slave.open(), throwsA(isA<MissingPluginException>()));
      expect(await slave.send(3, MpcCommand.getCurrentPosition, ''), isFalse);
      await slave.close(3);
    });

    test('a runner with no window to give is an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      await expectLater(slave.open(), throwsStateError);
    });
  });
}

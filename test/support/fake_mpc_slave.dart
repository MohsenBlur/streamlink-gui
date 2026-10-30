import 'dart:async';

import 'package:streamlink_gui/services/mpc_slave.dart';
import 'package:streamlink_gui/utils/mpc_slave_protocol.dart';

/// The runner's /slave channel with MPC-HC on the other end of it, as the
/// app sees the pair: windows to hand out, sessions to bind, and a player per
/// session that answers the way MPC-HC does - a position on request, a seek
/// notification after a seek.
class FakeMpcSlave implements MpcSlaveChannel {
  final StreamController<MpcSlaveEvent> _events =
      StreamController<MpcSlaveEvent>.broadcast(sync: true);
  final StreamController<MpcSlaveRejection> _rejections =
      StreamController<MpcSlaveRejection>.broadcast(sync: true);

  /// Sessions opened, in order.
  final List<int> opened = [];

  /// session -> the pid it was bound to.
  final Map<int, int> bound = {};
  final Set<int> closed = {};

  /// Every send: (session, command, payload).
  final List<(int, int, String)> sent = [];

  final Map<int, FakeMpcPlayer> players = {};

  /// Why open throws, when set.
  Object? openFailure;
  bool bindResult = true;
  var _next = 1;

  @override
  Stream<MpcSlaveEvent> get events => _events.stream;

  @override
  Stream<MpcSlaveRejection> get rejections => _rejections.stream;

  /// The window string session [session] is launched with.
  static String windowOf(int session) => '${70000 + session}';

  @override
  Future<MpcSlaveWindow> open() async {
    final failure = openFailure;
    if (failure != null) throw failure;
    final session = _next++;
    opened.add(session);
    players[session] = FakeMpcPlayer(this, session);
    return MpcSlaveWindow(session, windowOf(session));
  }

  @override
  Future<bool> bind(int session, int pid) async {
    bound[session] = pid;
    return bindResult;
  }

  @override
  Future<bool> send(int session, int command, String payload) async {
    sent.add((session, command, payload));
    final player = players[session];
    if (player == null || !player.connected || closed.contains(session)) {
      return false;
    }
    return player.handle(command, payload);
  }

  @override
  Future<void> close(int session) async {
    closed.add(session);
  }

  /// A message from session [session]'s player, passed on by the runner.
  void emit(int session, int command, [String payload = '']) =>
      _events.add(MpcSlaveEvent(session, command, payload));

  /// A message the runner refused for [session].
  void reject(int session, int pid, int command) =>
      _rejections.add(MpcSlaveRejection(session, pid, command));

  /// The commands sent to [session], in order.
  List<int> commandsTo(int session) =>
      [for (final (s, command, _) in sent) if (s == session) command];
}

/// MPC-HC behind one session.
class FakeMpcPlayer {
  FakeMpcPlayer(this.slave, this.session);

  final FakeMpcSlave slave;
  final int session;

  bool connected = false;
  int playMode = MpcPlayState.play;
  double position = 0;

  /// Seconds the position advances per answered poll while playing, as the
  /// tracker's fake VLC does: the tests poll in milliseconds.
  double advancePerPoll = 1;

  /// Whether a seek is followed by the notification MPC-HC sends once it has
  /// moved.
  bool acknowledgeSeeks = true;

  /// Whether a position request is answered at all.
  bool answerPolls = true;

  /// Answers after the send's result rather than during the send, which the
  /// runner's ordering does not rule out.
  bool answerLate = false;

  /// What MPC-HC sends as it starts: the connect, then the file loading and
  /// playing. [duration] in seconds for now-playing.
  void connect({double startAt = 0, double duration = 10800}) {
    connected = true;
    position = startAt;
    slave.emit(session, MpcCommand.connect, FakeMpcSlave.windowOf(session));
    slave.emit(session, MpcCommand.state, '${MpcLoadState.loading}');
    slave.emit(session, MpcCommand.state, '${MpcLoadState.loaded}');
    slave.emit(session, MpcCommand.nowPlaying,
        'Title|||https://example/index.m3u8|${duration.toStringAsFixed(3)}');
    slave.emit(session, MpcCommand.playMode, '$playMode');
  }

  /// The end of the stream, as MPC-HC reports it: pause, then the notice.
  void endOfStream() {
    playMode = MpcPlayState.pause;
    slave.emit(session, MpcCommand.playMode, '${MpcPlayState.pause}');
    slave.emit(session, MpcCommand.notifyEndOfStream);
  }

  /// MPC-HC closing.
  void disconnect() {
    slave.emit(session, MpcCommand.disconnect);
    connected = false;
  }

  bool handle(int command, String payload) {
    switch (command) {
      case MpcCommand.getCurrentPosition:
        if (!answerPolls) return true;
        final reported = position;
        if (playMode == MpcPlayState.play) position += advancePerPoll;
        void answer() => slave.emit(
            session, MpcCommand.currentPosition, reported.toStringAsFixed(3));
        if (answerLate) {
          Timer(const Duration(milliseconds: 5), answer);
        } else {
          answer();
        }
      case MpcCommand.setPosition:
        final target = double.tryParse(payload);
        if (target == null) return true;
        position = target;
        if (acknowledgeSeeks) {
          slave.emit(
              session, MpcCommand.notifySeek, position.toStringAsFixed(3));
        }
    }
    return true;
  }
}

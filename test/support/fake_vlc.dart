import 'dart:convert';
import 'dart:io';

import 'package:streamlink_gui/services/player_service.dart';

/// VLC's HTTP status interface, as the progress tracker polls it: each
/// `GET /requests/status.json` reports [state] at [time], and while playing,
/// time advances one second per poll.
class FakeVlc {
  FakeVlc._(this._server);

  final HttpServer _server;

  String state = 'playing';
  int time = 0;
  int polls = 0;

  /// The Authorization header of each poll, in order.
  final List<String?> authorizations = <String?>[];

  /// Listens on [port], where the service told the player to put its
  /// interface; 0 for any free one (see [OwnPortsPlayerService]).
  static Future<FakeVlc> serve(int port, {int startAt = 100}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final vlc = FakeVlc._(server)..time = startAt;
    server.listen((request) {
      vlc.polls++;
      vlc.authorizations.add(request.headers.value('authorization'));
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'state': vlc.state, 'time': vlc.time}));
      if (vlc.state == 'playing') vlc.time++;
      request.response.close();
    });
    return vlc;
  }

  /// Where it listens.
  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

/// A player service whose players get ports no other test file can hold.
///
/// Ports from 8089 up are shared by every test file running at the same
/// time. The service probed one, found it free, and the fake VLC bound it a
/// moment later - by which time another file's fake, or player_ports_test's
/// deliberate squatter on 8089, could be there first, and the test failed
/// with "Only one usage of each socket address". [serveVlc] binds first and
/// hands its port to the next player; any other player gets an ephemeral
/// port of its own.
class OwnPortsPlayerService extends PlayerService {
  OwnPortsPlayerService({
    super.startProcess,
    super.runProcess,
    super.progressPollInterval,
    super.apiService,
  });

  final List<int> _next = <int>[];

  /// A fake VLC on a port of its own, which the next player started is told
  /// to put its interface on.
  Future<FakeVlc> serveVlc({int startAt = 100}) async {
    final vlc = await FakeVlc.serve(0, startAt: startAt);
    _next.add(vlc.port);
    return vlc;
  }

  @override
  Future<int> getNextAvailablePlayerPort() async {
    if (_next.isNotEmpty) return _next.removeAt(0);
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }
}

/// Polls [condition] until it holds, failing after [timeout].
Future<void> waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10),
    String reason = 'condition'}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

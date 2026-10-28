import 'dart:convert';
import 'dart:io';

/// VLC's HTTP status interface, as the progress tracker polls it: each
/// `GET /requests/status.json` reports [state] at [time], and while playing,
/// time advances one second per poll.
class FakeVlc {
  FakeVlc._(this._server);

  final HttpServer _server;

  String state = 'playing';
  int time = 0;
  int polls = 0;

  /// Listens on [port], where the service told the player to put its
  /// interface.
  static Future<FakeVlc> serve(int port, {int startAt = 100}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final vlc = FakeVlc._(server)..time = startAt;
    server.listen((request) {
      vlc.polls++;
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'state': vlc.state, 'time': vlc.time}));
      if (vlc.state == 'playing') vlc.time++;
      request.response.close();
    });
    return vlc;
  }

  Future<void> close() => _server.close(force: true);
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

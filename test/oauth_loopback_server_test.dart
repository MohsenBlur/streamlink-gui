import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/oauth_loopback_server.dart';

/// Drives the sign-in listener over real loopback HTTP, the way the browser
/// page and a hostile page would.
void main() {
  late HttpClient client;
  final servers = <OAuthLoopbackServer>[];

  setUp(() => client = HttpClient());
  tearDown(() async {
    client.close(force: true);
    for (final s in servers) {
      await s.close();
    }
    servers.clear();
  });

  Future<OAuthLoopbackServer> started({
    String clientId = 'myclient',
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final server = OAuthLoopbackServer(
        port: 0, clientId: clientId, timeout: timeout, state: 'abc123state');
    servers.add(server);
    await server.start();
    return server;
  }

  Future<({int status, String body})> get(
      OAuthLoopbackServer server, String pathAndQuery,
      {String method = 'GET'}) async {
    final request = await client.openUrl(
        method, Uri.parse('http://127.0.0.1:${server.boundPort}$pathAndQuery'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, body: body);
  }

  Future<bool> accepts(int port) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(seconds: 1));
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  test('the authorize URL carries the state, the client and the bound port',
      () async {
    final server = await started();
    final url = Uri.parse(server.authorizeUrl);
    expect(url.host, 'id.twitch.tv');
    expect(url.queryParameters['client_id'], 'myclient');
    expect(url.queryParameters['redirect_uri'],
        'http://localhost:${server.boundPort}');
    expect(url.queryParameters['response_type'], 'token');
    expect(url.queryParameters['scope'], 'user:read:follows');
    expect(url.queryParameters['state'], 'abc123state');
  });

  test('a blank Client ID signs in with, and records, the public client',
      () async {
    final server = await started(clientId: '   ');
    expect(server.clientId, OAuthLoopbackServer.publicClientId);
    expect(Uri.parse(server.authorizeUrl).queryParameters['client_id'],
        OAuthLoopbackServer.publicClientId);
  });

  test('generated states are long, hex and different every time', () {
    final a = OAuthLoopbackServer.generateState();
    final b = OAuthLoopbackServer.generateState();
    expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(a, isNot(b));
    expect(OAuthLoopbackServer(port: 0, clientId: 'x').state,
        isNot(OAuthLoopbackServer(port: 0, clientId: 'x').state));
  });

  test('the redirect page is served and does not contain the state',
      () async {
    final server = await started();
    final page = await get(server, '/');
    expect(page.status, 200);
    expect(page.body, contains("fetch('/token?access_token="));
    expect(page.body, contains("fragment.get('state')"));
    expect(page.body, isNot(contains('abc123state')),
        reason: 'the page reads the state from the fragment; a page that '
            'could load this one must not be able to learn it');
  });

  test('a token with this sign-in\'s state is accepted once, then the port '
      'closes', () async {
    final server = await started();
    final port = server.boundPort;
    final reply = await get(server, '/token?access_token=tok123&state=abc123state');
    expect(reply.status, 200);
    expect(reply.body, 'OK');

    final result = await server.result;
    expect(result.outcome, OAuthLoopbackOutcome.token);
    expect(result.accessToken, 'tok123');

    // The result is published only once the port is released.
    expect(server.isListening, isFalse);
    expect(await accepts(port), isFalse);
  });

  test('a token without the state, or with another one, is refused and the '
      'sign-in stays open', () async {
    final server = await started();
    final missing = await get(server, '/token?access_token=attacker');
    final wrong =
        await get(server, '/token?access_token=attacker&state=guess');
    expect(missing.status, 403);
    expect(wrong.status, 403);

    var settled = false;
    unawaited(server.result.then((_) => settled = true));
    await pumpEventQueue();
    expect(settled, isFalse);
    expect(server.isListening, isTrue);

    // The real redirect still gets through afterwards.
    final real = await get(server, '/token?access_token=mine&state=abc123state');
    expect(real.status, 200);
    expect((await server.result).accessToken, 'mine');
  });

  test('a second /token racing the first neither crashes nor wins', () async {
    final server = await started();
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final replies = await Future.wait([
        for (final token in ['first', 'second', 'third'])
          get(server, '/token?access_token=$token&state=abc123state')
              .then<int?>((r) => r.status)
              .catchError((Object _) => null),
      ]);
      expect(replies.where((s) => s == 200), hasLength(1),
          reason: 'exactly one request may be accepted');
      expect(replies.where((s) => s != 200 && s != null),
          everyElement(HttpStatus.gone));
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
    final result = await server.result;
    expect(result.outcome, OAuthLoopbackOutcome.token);
    expect(['first', 'second', 'third'], contains(result.accessToken));
  });

  test('a token that could not be a token is refused', () async {
    final server = await started();
    final spaced = await get(server,
        '/token?access_token=${Uri.encodeQueryComponent('a b')}&state=abc123state');
    final crlf = await get(server,
        '/token?access_token=${Uri.encodeQueryComponent('a\r\nX-Evil: 1')}&state=abc123state');
    final empty = await get(server, '/token?access_token=&state=abc123state');
    expect([spaced.status, crlf.status, empty.status], everyElement(400));
    expect(server.isListening, isTrue);
  });

  test('Twitch\'s refusal for this sign-in ends it as denied', () async {
    final server = await started();
    final page = await get(server,
        '/?error=access_denied&error_description=The+user+denied+you+access&state=abc123state');
    expect(page.status, 200, reason: 'the page still explains it to the user');
    final result = await server.result;
    expect(result.outcome, OAuthLoopbackOutcome.denied);
    expect(result.error, 'The user denied you access');
    expect(server.isListening, isFalse);
  });

  test('a forged refusal is only a page view', () async {
    final server = await started();
    await get(server, '/?error=access_denied&state=guess');
    await get(server, '/?error=access_denied');
    expect(server.isListening, isTrue);
    expect((await get(server, '/token?access_token=t&state=abc123state')).status,
        200);
    expect((await server.result).outcome, OAuthLoopbackOutcome.token);
  });

  test('an abandoned sign-in times out and releases the port', () async {
    final server =
        await started(timeout: const Duration(milliseconds: 100));
    final port = server.boundPort;
    final result = await server.result.timeout(const Duration(seconds: 5));
    expect(result.outcome, OAuthLoopbackOutcome.timedOut);
    expect(server.isListening, isFalse);
    expect(await accepts(port), isFalse);
  });

  test('close() cancels the sign-in and the port can be bound again',
      () async {
    final server = await started();
    final port = server.boundPort;
    await server.close();
    expect((await server.result).outcome, OAuthLoopbackOutcome.cancelled);
    expect(server.boundPort, port, reason: 'still says which port it had');

    final again = OAuthLoopbackServer(port: port, clientId: 'x');
    servers.add(again);
    await again.start();
    expect(again.boundPort, port);
  });

  test('a result can be awaited and the same port bound at once, as a '
      'second Connect does', () async {
    for (var i = 0; i < 20; i++) {
      final server = await started(timeout: const Duration(milliseconds: 1));
      final port = server.boundPort;
      expect((await server.result).outcome, OAuthLoopbackOutcome.timedOut);
      final next = OAuthLoopbackServer(port: port, clientId: 'x');
      servers.add(next);
      await next.start();
      await next.close();
    }
  });

  test('closing after a result keeps the result', () async {
    final server = await started();
    await get(server, '/token?access_token=kept&state=abc123state');
    await server.close();
    final result = await server.result;
    expect(result.outcome, OAuthLoopbackOutcome.token);
    expect(result.accessToken, 'kept');
  });

  test('a port another program holds makes start() throw', () async {
    final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(holder.close);
    final server = OAuthLoopbackServer(port: holder.port, clientId: 'x');
    await expectLater(server.start(), throwsA(isA<SocketException>()));
    expect(server.isListening, isFalse);
  });

  test('only GET is answered, and unknown paths are 404', () async {
    final server = await started();
    expect(
        (await get(server, '/token?access_token=t&state=abc123state',
                method: 'POST'))
            .status,
        405);
    expect((await get(server, '/favicon.ico')).status, 404);
    expect(server.isListening, isTrue);
  });
}

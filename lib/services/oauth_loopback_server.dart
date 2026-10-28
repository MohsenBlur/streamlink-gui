import 'dart:async';
import 'dart:io';
import 'dart:math';

/// How a sign-in through [OAuthLoopbackServer] ended.
enum OAuthLoopbackOutcome {
  /// Twitch redirected back with a token, and it carried this sign-in's
  /// state.
  token,

  /// Twitch redirected back with an error instead, usually because the user
  /// pressed Cancel on its consent page.
  denied,

  /// Nothing came back within [OAuthLoopbackServer.timeout].
  timedOut,

  /// [OAuthLoopbackServer.close] ended it first: a newer sign-in replaced
  /// it, or the app is closing.
  cancelled,
}

class OAuthLoopbackResult {
  const OAuthLoopbackResult(this.outcome, {this.accessToken, this.error});

  final OAuthLoopbackOutcome outcome;

  /// The bare token (no `oauth:` prefix), for [OAuthLoopbackOutcome.token].
  final String? accessToken;

  /// Twitch's description of why, for [OAuthLoopbackOutcome.denied].
  final String? error;
}

/// The local listener Twitch's implicit-grant sign-in redirects back to.
///
/// Twitch sends the browser to `http://localhost:<port>/#access_token=...`.
/// The token is in the fragment, which never reaches a server, so `/` serves
/// a small page whose script forwards it to `/token`.
///
/// This used to live inline in the main screen, and had four faults:
///
/// * No `state`. `/token` stored any token from any page, so once a sign-in
///   had been started and abandoned, any website visited later could fire
///   `fetch('http://localhost:<port>/token?access_token=<theirs>')` and
///   quietly switch the app to an account of its choosing (login CSRF). Now
///   every sign-in carries a fresh random [state], Twitch hands it back in the
///   fragment next to the token, and `/token` refuses a request without it.
///   The page itself never contains it: it reads it from the fragment.
/// * No end. The server closed only after a token arrived, so an abandoned
///   sign-in left the port listening for the rest of the session. It now
///   closes after [timeout] too, and on [close].
/// * A second `/token` request (a reload, a duplicate fetch) that was already
///   in flight when the first one finished crashed on a null server. The
///   result is single-shot, and every later request gets a plain refusal.
/// * The minted Client ID was recorded as the raw field, which is blank when
///   the user cleared it, although the sign-in itself used the public
///   fallback. [clientId] is the one the authorize URL actually carries.
class OAuthLoopbackServer {
  OAuthLoopbackServer({
    required this.port,
    required String clientId,
    this.scopes = const ['user:read:follows'],
    this.timeout = defaultTimeout,
    String? state,
  })  : clientId = effectiveClientId(clientId),
        state = state ?? generateState();

  /// Long enough to sign in, two-factor prompt included; short enough that an
  /// abandoned attempt does not leave a listener open all session.
  static const Duration defaultTimeout = Duration(minutes: 5);

  /// Twitch's own web client, which signs in when no Client ID is configured.
  static const String publicClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  /// The Client ID a sign-in is actually made with: [configured], or
  /// [publicClientId] when that is blank.
  static String effectiveClientId(String configured) {
    final trimmed = configured.trim();
    return trimmed.isNotEmpty ? trimmed : publicClientId;
  }

  /// 128 random bits, hex: unguessable, and URL-safe with no encoding.
  static String generateState() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// The port asked for. 0 binds any free one (tests); [boundPort] says which.
  final int port;

  /// The Client ID the authorize URL carries, and so the one that mints the
  /// token. Never blank.
  final String clientId;

  final List<String> scopes;
  final Duration timeout;

  /// This sign-in's anti-forgery value, which `/token` must echo.
  final String state;

  HttpServer? _server;
  Timer? _timer;
  final Completer<OAuthLoopbackResult> _result =
      Completer<OAuthLoopbackResult>();

  /// Completes once, with how the sign-in ended. Never with an error.
  Future<OAuthLoopbackResult> get result => _result.future;

  /// Whether the listener is accepting connections.
  bool get isListening => _server != null;

  int get boundPort => _server?.port ?? port;

  /// Where to send the browser.
  ///
  /// Built by hand, unencoded, exactly as it always was: it reaches the
  /// browser through explorer.exe (see _openExternalLink in main.dart), and
  /// the values are already URL-safe - the state is hex, and `:` and `/` are
  /// legal in a query.
  String get authorizeUrl => 'https://id.twitch.tv/oauth2/authorize'
      '?client_id=${Uri.encodeQueryComponent(clientId)}'
      '&redirect_uri=http://localhost:$boundPort'
      '&response_type=token'
      '&scope=${scopes.join('+')}'
      '&state=$state';

  /// Binds the listener and starts the [timeout]. Throws when the port cannot
  /// be bound (another program holds it).
  Future<void> start() async {
    if (_server != null || _result.isCompleted) {
      throw StateError('This sign-in has already been started.');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _timer = Timer(timeout,
        () => _end(const OAuthLoopbackResult(OAuthLoopbackOutcome.timedOut)));
    server.listen(_handle, onError: (Object _) {});
  }

  /// Abandons the sign-in: [result] completes as cancelled (unless it already
  /// completed) and the port is released.
  Future<void> close() =>
      _end(const OAuthLoopbackResult(OAuthLoopbackOutcome.cancelled));

  /// Records [outcome] if nothing has been recorded yet. Synchronous, so a
  /// second request racing the first can never also be accepted.
  bool _settle(OAuthLoopbackResult outcome) {
    if (_result.isCompleted) return false;
    _timer?.cancel();
    _timer = null;
    _result.complete(outcome);
    return true;
  }

  Future<void> _end(OAuthLoopbackResult outcome) async {
    _settle(outcome);
    await _shutDown();
  }

  Future<void> _shutDown() async {
    final server = _server;
    _server = null;
    _timer?.cancel();
    _timer = null;
    if (server == null) return;
    try {
      await server.close(force: true);
    } catch (_) {}
  }

  bool _stateMatches(String? echoed) => echoed != null && echoed == state;

  /// Printable ASCII with no spaces: what a Twitch token is made of, and
  /// nothing that could break the `Authorization` header or the streamlink
  /// argument it ends up in.
  static final RegExp _plausibleToken = RegExp(r'^[\x21-\x7E]{1,512}$');

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var settled = false;
    try {
      if (request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.write('Method not allowed');
      } else if (request.uri.path == '/') {
        // Twitch reports a refusal in the query, not the fragment. Only a
        // refusal for THIS sign-in ends it; a forged one is just a page view.
        final query = request.uri.queryParameters;
        final error = query['error'];
        if (error != null && _stateMatches(query['state'])) {
          final description = query['error_description']?.trim();
          settled = _settle(OAuthLoopbackResult(OAuthLoopbackOutcome.denied,
              error: description == null || description.isEmpty
                  ? error
                  : description));
        }
        response.headers.contentType = ContentType.html;
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write(_page);
      } else if (request.uri.path == '/token') {
        final query = request.uri.queryParameters;
        final token = query['access_token']?.trim();
        if (_result.isCompleted) {
          response.statusCode = HttpStatus.gone;
          response.write('This sign-in has already finished.');
        } else if (!_stateMatches(query['state'])) {
          // Not this sign-in's redirect: a forged request, or a tab left from
          // an earlier attempt. Refused, and the real one stays open.
          response.statusCode = HttpStatus.forbidden;
          response.write('This sign-in was not started by the app.');
        } else if (token == null || !_plausibleToken.hasMatch(token)) {
          response.statusCode = HttpStatus.badRequest;
          response.write('No usable access token.');
        } else {
          settled = _settle(OAuthLoopbackResult(OAuthLoopbackOutcome.token,
              accessToken: token));
          response.write('OK');
        }
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write('Not found');
      }
      await response.close();
    } catch (_) {
      // A browser that hangs up mid-response must not take the listener, or
      // the app, down with it.
    }
    // Closed only once the answer is out: a forced close any earlier could
    // drop the "OK" the page is waiting for, and it would report a failure
    // for a sign-in that worked.
    if (settled) await _shutDown();
  }

  /// The redirect target. Reads the token and the state from the fragment
  /// and forwards both; the state is never written into the page, so a page
  /// that can load this one still cannot learn it. The fragment is cleared
  /// from the address bar so the token does not stay in the tab's history.
  static const String _page = r'''
<!DOCTYPE html>
<html>
<head>
  <title>Twitch Streamlink GUI Login</title>
  <style>
    body {
      background-color: #0c0f17;
      color: #ffffff;
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100vh;
      margin: 0;
    }
    .card {
      background-color: #161b26;
      border: 1px solid #1e2433;
      border-radius: 12px;
      padding: 30px;
      box-shadow: 0 8px 30px rgba(0,0,0,0.3);
      text-align: center;
      max-width: 400px;
    }
    h2 { color: #9146ff; margin-top: 0; }
    .spinner {
      border: 4px solid rgba(255,255,255,0.1);
      width: 36px;
      height: 36px;
      border-radius: 50%;
      border-left-color: #9146ff;
      animation: spin 1s linear infinite;
      margin: 20px auto;
    }
    @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div class="card">
    <h2>Twitch Authorization</h2>
    <div id="status">Connecting with Streamlink Twitch GUI...</div>
    <div id="loader" class="spinner"></div>
  </div>
  <script>
    const fragment = new URLSearchParams(window.location.hash.substring(1));
    const query = new URLSearchParams(window.location.search);
    function finish(text) {
      document.getElementById('status').innerText = text;
      document.getElementById('loader').style.display = 'none';
    }
    if (window.location.hash) {
      history.replaceState(null, '', window.location.pathname);
    }
    const token = fragment.get('access_token');
    if (token) {
      fetch('/token?access_token=' + encodeURIComponent(token) +
            '&state=' + encodeURIComponent(fragment.get('state') || ''))
        .then((response) => finish(response.ok
          ? 'Authentication successful! You can close this tab now.'
          : 'This sign-in has expired or was not started by the app. Click Connect Account in the app to try again.'))
        .catch(() => finish('Error saving token to application.'));
    } else if (query.get('error')) {
      finish('Twitch did not connect the account: ' +
             (query.get('error_description') || query.get('error')) +
             '. You can close this tab.');
    } else {
      finish('No access token found in URL fragment.');
    }
  </script>
</body>
</html>
''';
}

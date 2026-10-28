import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/session_end.dart';

/// The Dart half of the session-end handshake. The runner sends `queryEnd`
/// without waiting, then `end`, whose reply it waits a few seconds for before
/// letting Windows end the process; or `cancelled`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();

  /// Sends [method] as the runner would; completes with the decoded reply.
  Future<Object?> send(String method) {
    final reply = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      SessionEnd.channel.name,
      codec.encodeMethodCall(MethodCall(method)),
      (data) => reply.complete(data == null ? null : codec.decodeEnvelope(data)),
    );
    return reply.future;
  }

  late int saves;
  late int cancels;
  late Completer<void> saving;

  setUp(() {
    saves = 0;
    cancels = 0;
    saving = Completer<void>();
    SessionEnd.listen(
      onEnding: () {
        saves++;
        return saving.future;
      },
      onCancelled: () => cancels++,
    );
  });
  tearDown(SessionEnd.stopListening);

  test('end answers only once the save has finished', () async {
    var answered = false;
    final reply = send('end').then((value) {
      answered = true;
      return value;
    });
    await pumpEventQueue();
    expect(saves, 1);
    expect(answered, isFalse,
        reason: 'answering lets Windows end the process');

    saving.complete();
    expect(await reply, isTrue);
  });

  test('the save starts at the query, and end waits for that same one',
      () async {
    expect(await send('queryEnd'), isNull,
        reason: 'the runner is not waiting on the query');
    expect(saves, 1);

    final reply = send('end');
    saving.complete();
    expect(await reply, isTrue);
    expect(saves, 1, reason: 'one save per ending session');
  });

  test('a cancelled end lets the next one save again', () async {
    await send('queryEnd');
    await send('cancelled');
    expect(cancels, 1);

    await send('queryEnd');
    expect(saves, 2);
  });

  test('a save that fails still answers', () async {
    final reply = send('end');
    await pumpEventQueue();
    saving.completeError(StateError('disk'));
    expect(await reply, isTrue);
  });
}

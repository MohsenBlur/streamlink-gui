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

  group('a session end this process outlives', () {
    // The Restart Manager closing apps for an installer sends a real
    // WM_ENDSESSION(TRUE), but only asks: the app goes on running. Its hold
    // on the download queue stayed for the rest of the run, and a later real
    // shutdown was handed the finished save instead of a fresh one.
    late int survived;

    setUp(() {
      survived = 0;
      SessionEnd.listen(
        onEnding: () {
          saves++;
          return saving.future;
        },
        onCancelled: () => cancels++,
        onSurvived: () => survived++,
        survivalGrace: const Duration(milliseconds: 40),
      );
    });

    test('goes back to normal once the grace has passed', () async {
      saving.complete();
      expect(await send('end'), isTrue);
      expect(survived, 0, reason: 'Windows may still end the process');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(survived, 1);
      expect(cancels, 0);
    });

    test('a later session end saves afresh', () async {
      saving.complete();
      await send('end');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await send('queryEnd');
      expect(saves, 2, reason: 'not the save the first end finished');
    });

    test('so does one that arrives inside the grace, which keeps the hold',
        () async {
      saving.complete();
      await send('end');
      await send('queryEnd');
      expect(saves, 2);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(survived, 0,
          reason: 'the second session end is still under way');
    });

    test('without its own callback, it is treated as called off', () async {
      SessionEnd.listen(
        onEnding: () async => saves++,
        onCancelled: () => cancels++,
        survivalGrace: const Duration(milliseconds: 40),
      );
      await send('end');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cancels, 1);
    });
  });
}

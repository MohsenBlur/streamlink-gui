import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// `DATA_BLOB` from wincrypt.h.
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptDataNative = Int32 Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Void> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _CryptData = int Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Void> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> dataOut,
);
typedef _LocalAllocNative = Pointer<Void> Function(Uint32 flags, IntPtr bytes);
typedef _LocalAlloc = Pointer<Void> Function(int flags, int bytes);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFree = Pointer<Void> Function(Pointer<Void> memory);

class _Bindings {
  _Bindings(DynamicLibrary crypt32, DynamicLibrary kernel32)
      : protect = crypt32
            .lookupFunction<_CryptDataNative, _CryptData>('CryptProtectData'),
        unprotect = crypt32
            .lookupFunction<_CryptDataNative, _CryptData>('CryptUnprotectData'),
        localAlloc =
            kernel32.lookupFunction<_LocalAllocNative, _LocalAlloc>('LocalAlloc'),
        localFree =
            kernel32.lookupFunction<_LocalFreeNative, _LocalFree>('LocalFree');

  final _CryptData protect;
  final _CryptData unprotect;
  final _LocalAlloc localAlloc;
  final _LocalFree localFree;
}

/// Windows DPAPI (`CryptProtectData` / `CryptUnprotectData`), current-user
/// scope, through bare `dart:ffi`.
///
/// What it buys: the sealed bytes open only for this Windows account on this
/// machine, so a config that leaves it - a synced or backed-up AppData, a
/// file attached to a support request, another account on the same PC -
/// carries nothing usable. It does not stop code already running as this
/// user, which can ask DPAPI just as this app does.
///
/// Bare `dart:ffi` rather than `package:ffi` or `package:win32`: both are
/// only transitive here, and four calls do not justify a direct dependency.
/// Memory comes from `LocalAlloc`, which is also what DPAPI's own output
/// must be released with.
class Dpapi {
  Dpapi._();

  /// Never show a prompt; fail instead. This runs inside autosaves.
  static const int _uiForbidden = 0x1;

  /// `LMEM_FIXED | LMEM_ZEROINIT`.
  static const int _lptr = 0x40;

  /// Null off Windows, or if the libraries cannot be bound.
  static final _Bindings? _bindings = _bind();

  static _Bindings? _bind() {
    if (!Platform.isWindows) return null;
    try {
      return _Bindings(
        DynamicLibrary.open('crypt32.dll'),
        DynamicLibrary.open('kernel32.dll'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether DPAPI can be called at all on this machine.
  static bool get isAvailable => _bindings != null;

  /// Seals [data] for the current user, or returns null if DPAPI refuses.
  ///
  /// [entropy] must be passed again, byte for byte, to [unprotect].
  static Uint8List? protect(Uint8List data, {Uint8List? entropy}) =>
      _call(data, entropy, seal: true);

  /// Opens bytes sealed by [protect], or returns null when they are not
  /// openable here: another account or machine sealed them, the entropy
  /// differs, or they were damaged.
  static Uint8List? unprotect(Uint8List data, {Uint8List? entropy}) =>
      _call(data, entropy, seal: false);

  static Uint8List? _call(Uint8List data, Uint8List? entropy,
      {required bool seal}) {
    final api = _bindings;
    if (api == null) return null;

    final allocations = <({Pointer<Uint8> pointer, int length})>[];
    Pointer<Uint8> allocate(int length) {
      // A zero-byte LocalAlloc is not guaranteed a usable pointer.
      final pointer = api.localAlloc(_lptr, length < 1 ? 1 : length);
      if (pointer.address == 0) throw StateError('LocalAlloc failed');
      final bytes = pointer.cast<Uint8>();
      allocations.add((pointer: bytes, length: length));
      return bytes;
    }

    Pointer<_DataBlob> blobOf(Uint8List bytes) {
      final blob = allocate(sizeOf<_DataBlob>()).cast<_DataBlob>();
      final buffer = allocate(bytes.length);
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      blob.ref
        ..cbData = bytes.length
        ..pbData = buffer;
      return blob;
    }

    try {
      final input = blobOf(data);
      final Pointer<_DataBlob> extra =
          entropy == null ? nullptr : blobOf(entropy);
      final output = allocate(sizeOf<_DataBlob>()).cast<_DataBlob>();

      final call = seal ? api.protect : api.unprotect;
      final ok = call(input, nullptr, extra, nullptr, nullptr, _uiForbidden,
          output);
      if (ok == 0) return null;

      final result = output.ref.pbData;
      final length = output.ref.cbData;
      if (result.address == 0) return Uint8List(0);
      try {
        final view = result.asTypedList(length);
        final copy = Uint8List.fromList(view);
        // Opened bytes are the secret itself: do not hand them back to the
        // heap intact.
        if (!seal) view.fillRange(0, length, 0);
        return copy;
      } finally {
        api.localFree(result.cast());
      }
    } catch (_) {
      return null;
    } finally {
      for (final allocation in allocations) {
        // The input buffer holds the plaintext when sealing.
        allocation.pointer.asTypedList(allocation.length).fillRange(
            0, allocation.length, 0);
        api.localFree(allocation.pointer.cast());
      }
    }
  }
}

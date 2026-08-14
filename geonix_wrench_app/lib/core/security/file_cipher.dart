import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypts downloaded files (e.g. job-card PDFs) **before** they are written
/// to device storage, so cleartext copies never sit on disk.
///
/// Scheme: AES-256-GCM (authenticated encryption). A single random 256-bit key
/// is generated once and persisted in the OS-backed secure store
/// (`flutter_secure_storage` → Android Keystore / iOS Keychain), never in
/// SharedPreferences or app files.
///
/// On-disk layout of an encrypted file:
///   [12-byte GCM IV][ciphertext + 16-byte GCM auth tag]
class FileCipher {
  const FileCipher._();

  static const String _keyStorageKey = 'geonix.file_encryption_key';
  static const int _ivLength = 12;

  static final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    // On Android this uses the Android Keystore; on iOS the Keychain.
    // No `encryptedSharedPreferences` (needs API 23+) so we stay compatible
    // with the project's minSdk.
  );

  static enc.Key? _cachedKey;

  static Future<enc.Key> _getKey() async {
    if (_cachedKey != null) return _cachedKey!;
    final existing = await _secureStorage.read(key: _keyStorageKey);
    if (existing != null) {
      _cachedKey = enc.Key(base64.decode(existing));
      return _cachedKey!;
    }
    final key = enc.Key.fromSecureRandom(32); // AES-256
    await _secureStorage.write(
      key: _keyStorageKey,
      value: base64.encode(key.bytes),
    );
    _cachedKey = key;
    return key;
  }

  /// Encrypts [plaintext] (e.g. raw PDF bytes) and returns the protected blob.
  static Future<Uint8List> encryptBytes(Uint8List plaintext) async {
    final key = await _getKey();
    final iv = enc.IV.fromSecureRandom(_ivLength);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(plaintext, iv: iv);

    final out = BytesBuilder()
      ..add(iv.bytes)
      ..add(encrypted.bytes); // ciphertext + GCM tag
    return out.toBytes();
  }

  /// Reverses [encryptBytes], returning the original plaintext bytes.
  static Future<Uint8List> decryptBytes(Uint8List data) async {
    if (data.length <= _ivLength) {
      throw const FileCipherException('Encrypted payload is too short.');
    }
    final key = await _getKey();
    final iv = enc.IV(data.sublist(0, _ivLength));
    final cipherBytes = data.sublist(_ivLength);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    return Uint8List.fromList(
      encrypter.decryptBytes(enc.Encrypted(cipherBytes), iv: iv),
    );
  }
}

class FileCipherException implements Exception {
  const FileCipherException(this.message);
  final String message;

  @override
  String toString() => 'FileCipherException: $message';
}

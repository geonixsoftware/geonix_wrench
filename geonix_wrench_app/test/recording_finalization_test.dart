import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geonix_wrench_app/core/services/recording_controller.dart';

/// Builds a top-level MP4 box: a 4-byte big-endian size, a 4-byte type, and
/// [payloadLength] bytes of body.
Uint8List _box(String type, {int payloadLength = 0}) {
  final bytes = BytesBuilder();
  final header = ByteData(8)..setUint32(0, 8 + payloadLength);
  bytes.add(header.buffer.asUint8List()..setRange(4, 8, type.codeUnits));
  bytes.add(Uint8List(payloadLength));
  return bytes.toBytes();
}

/// Builds a box using the 64-bit extended size form (size field == 1).
Uint8List _largeBox(String type, {int payloadLength = 0}) {
  final bytes = BytesBuilder();
  final header = ByteData(16)
    ..setUint32(0, 1)
    ..setUint64(8, 16 + payloadLength);
  bytes.add(header.buffer.asUint8List()..setRange(4, 8, type.codeUnits));
  bytes.add(Uint8List(payloadLength));
  return bytes.toBytes();
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('finalization_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<File> write(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  test('finds moov in a finalized recording', () async {
    final file = await write('done.m4a', [
      ..._box('ftyp', payloadLength: 16),
      ..._box('mdat', payloadLength: 512),
      ..._box('moov', payloadLength: 128),
    ]);
    expect(await mp4HasMoovAtom(file), isTrue);
  });

  test('rejects a recording that is still being written', () async {
    // What macOS hands back before finalisation completes: the audio payload
    // is on disk but the moov box describing it has not been appended yet.
    final file = await write('partial.m4a', [
      ..._box('ftyp', payloadLength: 16),
      ..._box('mdat', payloadLength: 512),
    ]);
    expect(await mp4HasMoovAtom(file), isFalse);
  });

  test('walks past a box using the 64-bit extended size form', () async {
    final file = await write('large.m4a', [
      ..._box('ftyp', payloadLength: 16),
      ..._largeBox('mdat', payloadLength: 256),
      ..._box('moov', payloadLength: 64),
    ]);
    expect(await mp4HasMoovAtom(file), isTrue);
  });

  test('does not mistake payload bytes for the moov box', () async {
    // "moov" appearing inside the audio data must not count — only a real
    // top-level box does.
    final mdat = _box('mdat', payloadLength: 64);
    mdat.setRange(20, 24, 'moov'.codeUnits);
    final file = await write('decoy.m4a', [..._box('ftyp', payloadLength: 8), ...mdat]);
    expect(await mp4HasMoovAtom(file), isFalse);
  });

  test('returns false rather than looping on a zero-length box', () async {
    final degenerate = ByteData(8)..setUint32(0, 0);
    final file = await write(
      'zero.m4a',
      degenerate.buffer.asUint8List()..setRange(4, 8, 'mdat'.codeUnits),
    );
    expect(await mp4HasMoovAtom(file), isFalse);
  });

  test('returns false for an empty or non-MP4 file', () async {
    expect(await mp4HasMoovAtom(await write('empty.m4a', [])), isFalse);
    expect(
      await mp4HasMoovAtom(await write('noise.wav', List<int>.filled(96, 0x41))),
      isFalse,
    );
  });

  test('returns false for a missing file instead of throwing', () async {
    expect(await mp4HasMoovAtom(File('${tempDir.path}/nope.m4a')), isFalse);
  });
}

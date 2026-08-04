import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/src/rust/frb_generated.dart';
import 'package:textutilz/src/rust/api/hex_session.dart';

/// Exercises the HexSession bindings from Dart exactly as HexEditorView does:
/// windowed reads, overwrite/insert/delete, undo/redo, save, and binary sniff.
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  File tempWith(List<int> bytes) {
    final f = File(
        '${Directory.systemTemp.path}/textutilz_hex_dart_${DateTime.now().microsecondsSinceEpoch}.bin');
    f.writeAsBytesSync(bytes);
    return f;
  }

  test('reads windows and reflects overwrite/insert/delete', () {
    final f = tempWith('hello world'.codeUnits);
    final s = HexSession.open(path: f.path);

    expect(s.len().toInt(), 11);
    expect(
        s.readWindow(offset: BigInt.zero, len: BigInt.from(11)),
        Uint8List.fromList('hello world'.codeUnits));

    // Overwrite 'h' -> 'H' (what the hex/char panels do on a keystroke).
    s.overwriteBytes(offset: BigInt.zero, bytes: [0x48]);
    // Insert '!' at end.
    s.insertBytes(offset: BigInt.from(s.len().toInt()), bytes: [0x21]);
    // Delete a byte.
    s.delete(offset: BigInt.from(1), len: BigInt.one);

    final out =
        s.readWindow(offset: BigInt.zero, len: BigInt.from(s.len().toInt()));
    expect(String.fromCharCodes(out), 'Hllo world!');

    f.deleteSync();
  });

  test('undo/redo round-trips through the bridge', () {
    final f = tempWith('abc'.codeUnits);
    final s = HexSession.open(path: f.path);

    s.overwriteBytes(offset: BigInt.zero, bytes: [0x58]); // 'X'
    expect(s.canUndo(), true);
    final caret = s.undo();
    expect(caret, isNotNull);
    expect(
        String.fromCharCodes(
            s.readWindow(offset: BigInt.zero, len: BigInt.from(3))),
        'abc');
    s.redo();
    expect(
        String.fromCharCodes(
            s.readWindow(offset: BigInt.zero, len: BigInt.from(3))),
        'Xbc');

    f.deleteSync();
  });

  test('save persists edited bytes', () {
    final f = tempWith('data'.codeUnits);
    final s = HexSession.open(path: f.path);
    s.overwriteBytes(offset: BigInt.zero, bytes: [0x44]); // 'D'
    expect(s.isDirty(), true);
    s.save();
    expect(s.isDirty(), false);
    expect(f.readAsBytesSync(), Uint8List.fromList('Data'.codeUnits));
    f.deleteSync();
  });

  test('binary sniff distinguishes text from binary', () {
    final text = tempWith('plain ascii text\n'.codeUnits);
    final bin = tempWith([0x00, 0x01, 0x02, 0x03, 0x04]);
    expect(isBinaryFile(path: text.path), false);
    expect(isBinaryFile(path: bin.path), true);
    text.deleteSync();
    bin.deleteSync();
  });
}

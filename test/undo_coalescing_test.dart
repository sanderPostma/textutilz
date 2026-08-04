import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/src/rust/frb_generated.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';

/// The shared undo-coalescing switch must change EditSession (main editor)
/// undo granularity: per-keystroke when off, word-at-a-time when on.
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  EditSession scratch() {
    final path =
        '${Directory.systemTemp.path}/textutilz_undo_${DateTime.now().microsecondsSinceEpoch}.txt';
    return EditSession.createScratch(path: path, content: '');
  }

  void typeAbc(EditSession s) {
    var r = BigInt.zero, c = BigInt.zero;
    for (final ch in ['a', 'b', 'c']) {
      final caret = s.insert(row: r, col: c, text: ch);
      r = caret.row;
      c = caret.col;
    }
  }

  test('coalescing OFF -> each keystroke is its own undo step', () {
    final s = scratch();
    s.setCoalesceUndo(on_: false);
    typeAbc(s);
    expect(s.line(vrow: BigInt.zero), 'abc');
    s.undo();
    expect(s.line(vrow: BigInt.zero), 'ab');
    s.undo();
    expect(s.line(vrow: BigInt.zero), 'a');
  });

  test('coalescing ON -> whole run undoes in one step', () {
    final s = scratch();
    s.setCoalesceUndo(on_: true);
    typeAbc(s);
    expect(s.line(vrow: BigInt.zero), 'abc');
    s.undo();
    expect(s.line(vrow: BigInt.zero), '');
  });
}

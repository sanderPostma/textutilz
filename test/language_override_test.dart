import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/document_state.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/store.dart';
import 'package:textutilz/src/rust/api/structured.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

/// The per-document format pin.
///
/// The precedence rule itself — a pin beats every detection signal — is tested
/// in Rust, where the decision is made. What is checked here is the Dart half:
/// that [TabRuntime] hands the pin to Rust rather than second-guessing it, and
/// that the pin survives the trip through [DocRecord] to the session store and
/// back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  final temps = <String>[];

  tearDownAll(() {
    for (final path in temps) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  });

  /// A tab over a real file. The extension is a detection signal, so it is the
  /// caller's choice — several tests below turn on the extension lying about
  /// the content.
  TabRuntime tabFor(String content, {required String extension}) {
    final path =
        '${Directory.systemTemp.path}/textutilz_lang_${temps.length}.$extension';
    File(path).writeAsStringSync(content);
    temps.add(path);
    return TabRuntime(
      meta: DocumentMeta(
        id: DocumentMeta.newId(),
        displayName: 'doc.$extension',
        path: path,
        extension: extension,
      ),
      session: EditSession.open(path: path),
    );
  }

  group('pinning a format', () {
    test('a new document starts unpinned and is detected', () {
      final tab = tabFor('{"a": 1}', extension: 'json');
      expect(tab.meta.languageOverride, isNull);
      expect(tab.markupLanguage, StructuredLanguage.json);
    });

    test('a pin overrides what the extension says', () {
      // The case the pin exists for: a file whose extension lies about its
      // content, which detection cannot get right on its own.
      final tab = tabFor('name: textutilz\nversion: 1', extension: 'txt');
      expect(tab.markupLanguage, StructuredLanguage.yaml);

      expect(tab.setLanguageOverride(StructuredLanguage.xml), isTrue);
      expect(tab.markupLanguage, StructuredLanguage.xml);
    });

    test('clearing the pin returns the document to detection', () {
      final tab = tabFor('{"a": 1}', extension: 'json');
      tab.setLanguageOverride(StructuredLanguage.yaml);
      expect(tab.markupLanguage, StructuredLanguage.yaml);

      expect(tab.setLanguageOverride(null), isTrue);
      expect(tab.markupLanguage, StructuredLanguage.json);
      expect(tab.meta.languageOverride, isNull);
    });

    test('pinning to the format already detected reports no change', () {
      // The host only repaints when this returns true, so a redundant pin must
      // not claim the format moved.
      final tab = tabFor('{"a": 1}', extension: 'json');
      expect(tab.setLanguageOverride(StructuredLanguage.json), isFalse);
      expect(tab.meta.languageOverride, StructuredLanguage.json);
    });

    test('pinning plain text suppresses colouring of a structured file', () {
      final tab = tabFor('{"a": 1}', extension: 'json');
      expect(tab.setLanguageOverride(StructuredLanguage.plainText), isTrue);
      expect(tab.markupLanguage, StructuredLanguage.plainText);
    });

    test('a pin holds when the document is edited', () {
      // Detection re-runs on every keystroke; the pin must not be re-derived
      // away by content that says something else.
      final tab = tabFor('', extension: 'txt');
      tab.setLanguageOverride(StructuredLanguage.xml);
      tab.session.replaceAll(text: 'a: 1\nb: 2');
      expect(tab.refreshMarkupLanguage(), isFalse);
      expect(tab.markupLanguage, StructuredLanguage.xml);
    });
  });

  group('JSON5 as a pin rather than an app-wide switch', () {
    test('two documents can hold different dialects at once', () {
      // The whole point of moving JSON5 off a single app-wide flag: it used to
      // follow whichever document the JSON bar happened to point at.
      final strict = tabFor('{"a": 1}', extension: 'json');
      final loose = tabFor('{"a": 1}', extension: 'json');

      loose.setLanguageOverride(StructuredLanguage.json5);

      expect(strict.markupLanguage, StructuredLanguage.json);
      expect(loose.markupLanguage, StructuredLanguage.json5);
    });
  });

  group('persistence', () {
    /// A record round-tripped through the shape the store reads and writes.
    DocumentMeta roundTrip(DocumentMeta meta) {
      final tab = TabRuntime(meta: meta, session: EditSession.open(path: meta.path));
      final record = tab.toRecord(order: 0, active: true);
      return DocumentMeta.fromRecord(record);
    }

    test('a pin survives the trip through DocRecord', () {
      final tab = tabFor('{"a": 1}', extension: 'json');
      tab.setLanguageOverride(StructuredLanguage.json5);
      expect(
        roundTrip(tab.meta).languageOverride,
        StructuredLanguage.json5,
      );
    });

    test('no pin round-trips as null', () {
      final tab = tabFor('{"a": 1}', extension: 'json');
      expect(roundTrip(tab.meta).languageOverride, isNull);
    });

    test('a restored pin is applied when the tab is rebuilt', () {
      // Restoring the field is not enough — the tab has to resolve its format
      // through it on construction, before anything paints.
      final tab = tabFor('{"a": 1}', extension: 'json');
      tab.setLanguageOverride(StructuredLanguage.plainText);
      final restored = TabRuntime(
        meta: roundTrip(tab.meta),
        session: EditSession.open(path: tab.meta.path),
      );
      expect(restored.markupLanguage, StructuredLanguage.plainText);
    });
  });
}

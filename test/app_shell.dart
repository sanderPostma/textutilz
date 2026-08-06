import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/document_state.dart';
import 'package:textutilz/main.dart' as app;
import 'package:textutilz/src/rust/api/store.dart';

/// A harness that pumps the real application shell.
///
/// Several behaviours can only be tested from here, because they live on the
/// private `_TextEditorState` and have no other entry point: that a keypress
/// reaches a fold command, that the status-bar picker pins a format, that
/// opening a tool bar retargets on a view-mode change. Testing them by calling
/// the underlying method directly proves nothing about the wiring, which is
/// exactly where the bugs are.
///
/// Two things make this work, both learned the hard way:
///
/// * **Size the surface to at least the app's real minimum width.** The GTK
///   runner enforces 980px (`linux/runner/my_application.cc`), and the status
///   bar genuinely does not fit in the 800px default test surface — it
///   overflows by 27px and fails the test with a layout exception that has
///   nothing to do with what is being tested.
/// * **Never let a test touch the real session store.** [AppStore.openAt] takes
///   an explicit path so the shell restores from a temp database instead of
///   reading, and then overwriting, the tabs of whoever ran the suite.
///
/// The shell restores its tabs through its normal `_restoreSession` path, so
/// the setup here exercises production code rather than reaching around it.
class AppShellHarness {
  AppShellHarness._(this.storePath, this._dir, this._files);

  final String storePath;
  final String _dir;
  final List<String> _files;

  /// The window size the shell is pumped at. Above the runner's 980px floor,
  /// so every status-bar segment is shown and none of them overflow.
  static const Size windowSize = Size(1000, 700);

  static int _counter = 0;

  /// Seed a session of [documents] (name → content) and pump the app shell
  /// with it restored. The first document is the active tab.
  ///
  /// Each document is written to a real temp file, because the shell opens
  /// non-transient documents through `EditSession.open` and skips any whose
  /// path is missing.
  static Future<AppShellHarness> pump(
    WidgetTester tester, {
    required Map<String, String> documents,
    String viewMode = ViewMode.edit,
  }) async {
    final id = _counter++;
    // A fresh directory per harness, not a counter-named file in the shared
    // temp dir. `flutter test` runs each test FILE in its own isolate, so the
    // counter restarts at zero in every one of them and two files racing on
    // `textutilz_shell_0.db` produced "database is locked" and "attempt to
    // write a readonly database" — intermittently, in whichever test happened
    // to lose.
    final dir = Directory.systemTemp.createTempSync('textutilz_shell_').path;
    final storePath = '$dir/session_$id.db';
    final files = <String>[];

    final store = AppStore.openAt(path: storePath);
    final records = <DocRecord>[];
    int order = 0;
    for (final entry in documents.entries) {
      final path = '$dir/${entry.key}';
      File(path).writeAsStringSync(entry.value);
      files.add(path);
      records.add(
        DocRecord(
          id: 'shell-$id-$order',
          displayName: entry.key,
          path: path,
          isTransient: false,
          contentType: 'Plain Text',
          extension_: entry.key.split('.').last,
          autoDelete: 'off',
          viewMode: viewMode,
          fontRead: 14,
          fontTail: 14,
          fontEdit: 14,
          scratchContent: null,
          createdDay: 0,
          tabOrder: order,
          isActive: order == 0,
          collapsedFolds: Uint32List(0),
          languageOverride: null,
        ),
      );
      order++;
    }
    store.saveSession(docs: records);
    app.appStore = store;

    tester.view.physicalSize = windowSize;
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(const app.MyApp());
    await tester.pump();

    final harness = AppShellHarness._(storePath, dir, files);
    addTearDown(() {
      tester.view.reset();
      app.appStore = null;
      harness._cleanUp();
    });
    return harness;
  }

  /// Read the session back as the shell persisted it. Used to assert that a
  /// change reached the store, not just the widget tree.
  List<DocRecord> persistedSession() =>
      AppStore.openAt(path: storePath).loadSession(todayEpochDay: 0);

  void _cleanUp() {
    for (final path in [..._files, storePath]) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
    try {
      Directory(_dir).deleteSync(recursive: true);
    } catch (_) {}
  }
}

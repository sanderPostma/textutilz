import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:io';
import 'package:textutilz/src/rust/api/file_manager.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/hex_session.dart' show isBinaryFile;
import 'package:textutilz/src/rust/api/store.dart';
import 'package:textutilz/src/rust/api/paths.dart' as rust_paths;
import 'package:textutilz/src/rust/frb_generated.dart';
import 'editor.dart';
import 'find_results_panel.dart';
import 'menu_ribbon.dart';
import 'mime_tools_panel.dart';
import 'markup_styling.dart';
import 'validation_results_panel.dart';
import 'src/rust/api/structured.dart';
import 'structured_tools_panel.dart';
import 'edit_tools_panel.dart';
import 'external_change_button.dart';
import 'document_state.dart';
import 'jwt_tools_panel.dart';
import 'hex_editor_view.dart';
import 'hex_find_panel.dart';
import 'hex_find_state.dart';
import 'editor_settings.dart';
import 'package:textutilz/src/rust/api/edit_ops.dart' as rust_edit_ops;
import 'find_panel.dart';
import 'find_state.dart';
import 'tool_bar.dart';
import 'package:textutilz/src/rust/api/search.dart' show MatchSpan;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(1000, 600),
    // The ribbon's menu columns stop fitting below ~980px, so the window
    // refuses to go narrower rather than degrading. Height is left free.
    //
    // This alone does NOT hold: window_manager's Linux backend applies the
    // minimum through gdk_window_set_geometry_hints, and GDK geometry hints
    // are ignored under Wayland. The binding minimum is the size request in
    // linux/runner/my_application.cc; keep the two in sync.
    minimumSize: Size(980, 400),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await RustLib.init();

  // Open the session store and apply the persisted theme *before* runApp, so
  // setting themeNotifier can't notify a listener mid-build (it has none yet).
  try {
    final store = AppStore.open();
    appStore = store;
    final theme = store.getSetting(key: 'theme_mode');
    themeNotifier.value = theme == 'light' ? ThemeMode.light : ThemeMode.dark;
    // Shared editor preference: undo coalescing (per-keystroke by default).
    undoCoalescingNotifier.value =
        store.getSetting(key: kUndoCoalescingSetting) == 'true';
  } catch (e) {
    debugPrint('store open failed: $e');
  }

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

/// Rust-owned session store (SQLite), opened once in [main].
AppStore? appStore;
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.dark);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, child) {
        return MaterialApp(
          title: 'TextUtilz',
          theme: ThemeData.light(
            useMaterial3: true,
          ).copyWith(scaffoldBackgroundColor: Colors.white),
          darkTheme: ThemeData.dark(
            useMaterial3: true,
          ).copyWith(scaffoldBackgroundColor: const Color(0xFF1E1E1E)),
          themeMode: currentMode,
          home: const TextEditor(),
        );
      },
    );
  }
}

class TextEditor extends StatefulWidget {
  const TextEditor({super.key});

  @override
  State<TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<TextEditor> with WindowListener {
  final List<TabRuntime> _tabs = [];
  int _activeTabIndex = -1;
  TabRuntime? get _activeTab =>
      _activeTabIndex >= 0 && _activeTabIndex < _tabs.length
      ? _tabs[_activeTabIndex]
      : null;

  final FocusNode _focusNode = FocusNode();
  bool _isRibbonVisible = false;

  final FindController _findController = FindController();
  final GlobalKey<FindPanelState> _findPanelKey = GlobalKey<FindPanelState>();
  final HexFindController _hexFindController = HexFindController();
  final GlobalKey<HexFindPanelState> _hexFindPanelKey =
      GlobalKey<HexFindPanelState>();
  bool _isFindVisible = false;

  /// The docked tool bar's panel id, or null when none is open. Mutually
  /// exclusive with the find bar — see _openFind / _openToolBar.
  String? _activeToolPanelId;

  // ---- Validation results panel --------------------------------------------
  bool _isValidationVisible = false;

  /// Whether the document is revalidated as the user stops typing. Held here
  /// rather than in the panel so the setting survives closing and reopening the
  /// bar, and so the debounce that drives auto-validation lives next to the
  /// edit notifications that reset it.
  ///
  /// The JSON5 dialect used to live here too, as one app-wide flag. It is now
  /// per document, on `DocumentMeta.languageOverride`.
  bool _structuredAutoValidate = false;
  Timer? _autoValidateDebounce;

  /// How long the document must be idle before auto-validation runs.
  static const Duration _autoValidateDelay = Duration(milliseconds: 2000);
  StructuredLanguage _validationLanguage = StructuredLanguage.plainText;
  List<StructuredDiagnostic> _validationDiagnostics = const [];
  List<String> _validationContext = const [];
  bool _validationTruncated = false;

  int _newDocCounter = 1;
  bool _ctrlHeld =
      false; // while held, wheel zooms Read/Tail instead of scrolling
  bool _isMaximized = false;
  bool _pendingNewPanel =
      false; // Ctrl+N asked the ribbon to open its New panel
  Timer? _midnightTimer;
  Timer? _filePollTimer;

  /// Rust-owned session store (SQLite). Null only if it failed to open.
  AppStore? _store;

  // Editor view preferences, persisted app-wide in the settings table. Line
  // numbers render a gutter; word wrap is currently state-only (rendering is a
  // later pass).
  bool _showLineNumbers = false;
  bool _wordWrap = false;

  @override
  void initState() {
    super.initState();
    windowManager.setPreventClose(true);
    windowManager.addListener(this);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // Reuse the store opened in main(); rebuild the tab session from it. Theme
    // was already applied in main() (before the tree built).
    _store = appStore;
    if (_store != null) {
      try {
        _showLineNumbers =
            _store!.getSetting(key: 'show_line_numbers') == 'true';
        _wordWrap = _store!.getSetting(key: 'word_wrap') == 'true';
        final counterSetting = _store!.getSetting(key: 'new_doc_counter');
        if (counterSetting != null) {
          _newDocCounter = int.tryParse(counterSetting) ?? 1;
        }
        _restoreSession(_store!);
      } catch (e) {
        debugPrint('session restore failed: $e');
      }
    }
    _scheduleMidnightCleanup();
    _filePollTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) => _pollExternalFileChanges(),
    );
    // Shared editor settings: when toggled (e.g. by a future config panel),
    // apply to every open editor and persist. Works for all editors alike.
    undoCoalescingNotifier.addListener(_onUndoCoalescingChanged);
    // The editor's match highlighting is read from the controller at build
    // time (see the CustomEditor `matches`/`currentMatch` args below), so a
    // rebuild here is what actually propagates a new/updated match set to
    // the painter — the panel's own setState only repaints itself.
    _findController.addListener(_onFindChanged);
    _hexFindController.addListener(_onHexFindChanged);
  }

  void _onFindChanged() {
    if (mounted) setState(() {});
    // The query/options changing invalidates the viewport highlight scan
    // too — e.g. Match case toggled, or new text typed (via scheduleRefresh
    // -> refresh() -> notifyListeners()).
    _scheduleViewportScan();
  }

  void _onHexFindChanged() {
    if (mounted) setState(() {});
  }

  /// Propagate the undo-coalescing preference to all open sessions and persist.
  void _onUndoCoalescingChanged() {
    for (final t in _tabs) {
      applyUndoSettingToText(t.session);
      final h = t.hexSessionOrNull;
      if (h != null) applyUndoSettingToHex(h);
    }
    _store?.setSetting(
      key: kUndoCoalescingSetting,
      value: undoCoalescingNotifier.value ? 'true' : 'false',
    );
  }

  void _restoreSession(AppStore store) {
    final records = store.loadSession(todayEpochDay: currentEpochDay());
    String? activeId;
    for (final r in records) {
      if (r.isActive) activeId = r.id;
      try {
        final EditSession session;
        if (r.isTransient) {
          // Rehydrate the scratch file from its persisted content.
          session = EditSession.createScratch(
            path: r.path,
            content: r.scratchContent ?? '',
          );
        } else {
          if (!File(r.path).existsSync()) continue; // real file gone — skip
          session = EditSession.open(path: r.path);
        }
        applyUndoSettingToText(session);
        DocumentMeta.reserveId(r.id);
        _tabs.add(
          TabRuntime(meta: DocumentMeta.fromRecord(r), session: session),
        );
      } catch (e) {
        debugPrint('restore failed for ${r.path}: $e');
      }
    }
    if (_tabs.isNotEmpty) {
      final idx = _tabs.indexWhere((t) => t.meta.id == activeId);
      _activeTabIndex = idx >= 0 ? idx : 0;
    }
  }

  /// Persist the current tab set (order + active + scratch content) to the store.
  /// Called after structural changes and on close.
  void _persistSession() {
    final store = _store;
    if (store == null) return;
    try {
      // onAppClose docs are ephemeral: never persisted, so they don't restore
      // on the next launch (their scratch files are removed at app close).
      final records = <DocRecord>[
        for (int i = 0; i < _tabs.length; i++)
          if (_tabs[i].meta.autoDelete != AutoDelete.onAppClose)
            _tabs[i].toRecord(order: i, active: i == _activeTabIndex),
      ];
      store.saveSession(docs: records);
    } catch (e) {
      debugPrint('persist failed: $e');
    }
  }

  void _toggleTheme() {
    final next = themeNotifier.value == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    themeNotifier.value = next;
    try {
      _store?.setSetting(
        key: 'theme_mode',
        value: next == ThemeMode.dark ? 'dark' : 'light',
      );
    } catch (e) {
      debugPrint('theme persist failed: $e');
    }
  }

  void _toggleLineNumbers() {
    setState(() => _showLineNumbers = !_showLineNumbers);
    try {
      _store?.setSetting(
        key: 'show_line_numbers',
        value: _showLineNumbers ? 'true' : 'false',
      );
    } catch (e) {
      debugPrint('line-numbers persist failed: $e');
    }
  }

  void _toggleWordWrap() {
    setState(() => _wordWrap = !_wordWrap);
    try {
      _store?.setSetting(key: 'word_wrap', value: _wordWrap ? 'true' : 'false');
    } catch (e) {
      debugPrint('word-wrap persist failed: $e');
    }
  }

  /// Apply a MIME transform to the active editor — the selection if there is
  /// one, otherwise the whole document — as one undoable step, then close the
  /// ribbon. The transform runs before any mutation, so decode failures leave
  /// the document untouched and surface as a SnackBar.
  void _runMimeOp(MimeOp op) {
    final editor = _activeEditor;
    if (editor == null) return;
    try {
      editor.transformSelectionOrAll(op.apply);
    } catch (e) {
      setState(() => _isRibbonVisible = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${op.label} failed: input is not valid.')),
      );
      return;
    }
    setState(() => _isRibbonVisible = false);
    _persistSession();
  }

  void _runEditOp(EditOp op) {
    final editor = _activeEditor;
    if (editor == null) return;
    try {
      final ext = _activeTab?.meta.extension ?? '';
      final language =
          _activeTab?.markupLanguage ?? StructuredLanguage.plainText;
      editor.transformSelectionOrAll((input) {
        return rust_edit_ops.applyEditOp(
          input: input,
          opId: op.opId,
          extension_: ext,
          language: language,
          tabWidth: BigInt.from(4),
        );
      });
    } catch (e) {
      setState(() => _isRibbonVisible = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${op.label} failed: $e')));
      return;
    }
    setState(() => _isRibbonVisible = false);
    _persistSession();
  }

  /// Run a structured-format tool.
  ///
  /// Transforms go through [transformSelectionOrAll] as one undoable edit, and
  /// Rust validates before it produces any output — so an invalid document
  /// leaves the text untouched and reports where the problem is. Validate is
  /// the exception: it changes nothing and opens the results panel instead.
  void _runStructuredOp(StructuredTextOp op) {
    final editor = _activeEditor;
    if (editor == null) return;
    if (op.action == StructuredTextAction.validate) {
      _runValidation(op.language);
      return;
    }
    try {
      editor.transformSelectionOrAll(op.apply);
    } on StructuredToolException catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${op.label} failed: ${error.message}')),
      );
      return;
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${op.label} failed: $error')));
      return;
    }
    setState(() => _isRibbonVisible = false);
    _persistSession();
  }

  /// Validate the whole document and show the results panel.
  ///
  /// Always the whole document, never the selection: a fragment of valid JSON
  /// is not valid JSON, so validating a selection would report errors that are
  /// not really there.
  void _runValidation(StructuredLanguage language, {bool focusPanel = true}) {
    final tab = _activeTab;
    if (tab == null) return;
    if (!MarkupStyling.isStructured(language)) return;
    final analysis = tab.session.markupAnalysis(language: language);
    // A row of context per problem, read here rather than inside the panel so
    // the panel stays a pure view over the data it is handed.
    final lineCount = tab.lineCount;
    final context = [
      for (final d in analysis.diagnostics)
        if (d.row < lineCount)
          tab.session.line(vrow: BigInt.from(d.row))
        else
          '',
    ];
    setState(() {
      if (focusPanel) _isRibbonVisible = false;
      _validationLanguage = language;
      _validationDiagnostics = analysis.diagnostics;
      _validationContext = context;
      _validationTruncated = analysis.truncated;
      _isValidationVisible = true;
    });
  }

  /// The format validation should run against.
  ///
  /// Just the document's effective format now that the JSON5 dialect is a pin
  /// on the document rather than an app-wide switch layered on top — Rust has
  /// already applied it.
  StructuredLanguage _validationTargetLanguage() =>
      _activeTab?.markupLanguage ?? StructuredLanguage.plainText;

  /// Pin the active document to [language], or hand it back to autodetection
  /// with null.
  ///
  /// The format drives colouring, folding, comment syntax, the Tools menu and
  /// validation. The editor picks the change up on its own — `markupLanguage`
  /// is a widget property, and its `didUpdateWidget` rescans folds when it
  /// changes — but an open result list has to be reconsidered here, because
  /// those diagnostics were produced by a grammar that no longer applies.
  void _setLanguageOverride(StructuredLanguage? language) {
    final tab = _activeTab;
    if (tab == null) return;
    tab.setLanguageOverride(language);
    setState(() {});
    if (_isValidationVisible || _structuredAutoValidate) {
      _scheduleAutoValidation();
    }
    _persistSession();
  }

  /// Restart the idle timer that triggers auto-validation.
  ///
  /// Validation is O(document), so it must not run per keystroke. Waiting for a
  /// pause means a burst of typing costs one pass, not one per character.
  void _scheduleAutoValidation() {
    _autoValidateDebounce?.cancel();
    if (!_structuredAutoValidate) return;
    final language = _validationTargetLanguage();
    if (!MarkupStyling.isStructured(language)) return;
    _autoValidateDebounce = Timer(_autoValidateDelay, () {
      if (!mounted) return;
      _runValidation(language, focusPanel: false);
    });
  }

  /// The document type shown in the status bar.
  ///
  /// The detected format wins over the stored content type, because detection
  /// is what actually drives colouring, comment syntax and the tools — so this
  /// is the honest answer to "what does the app think this file is".
  String get _documentTypeLabel {
    final tab = _activeTab;
    if (tab == null) return 'Normal text file';
    final detected = tab.markupLanguage;
    if (MarkupStyling.isStructured(detected)) {
      return MarkupStyling.label(detected);
    }
    return tab.meta.contentType;
  }

  String get _documentTypeTooltip {
    final tab = _activeTab;
    if (tab == null) return 'No document open';
    final language = tab.markupLanguage;
    final pinned = tab.meta.languageOverride != null;
    if (!MarkupStyling.isStructured(language)) {
      return pinned
          ? 'Pinned to plain text. Click to pick a format or return to '
                'autodetection.'
          : 'No structured format detected. Click to pick one; otherwise set '
                'the type when creating the document, or save it with a known '
                'extension.';
    }
    final label = MarkupStyling.label(language);
    final how = pinned ? 'Pinned to' : 'Detected as';
    return '$how $label — colouring, comment syntax and the $label tools '
        'follow this. Stored type: ${tab.meta.contentType}. Click to change.';
  }

  /// The "no pin, detect instead" entry in the format picker. Not a language
  /// id, so `structuredLanguageFromId` returns null for it — see
  /// [_buildLanguagePicker].
  static const String _autoDetectId = 'auto';

  /// The status-bar format control: shows the effective format, and opens the
  /// list of formats the document can be pinned to.
  ///
  /// A pin is the escape hatch for the cases detection cannot win: a `.txt`
  /// file that is really YAML, a `.json` file the user wants read as JSON5, or
  /// an empty scratch buffer that has nothing to detect from yet.
  ///
  /// The menu is keyed on the language *ids* rather than on
  /// `StructuredLanguage?` values, because `PopupMenuButton` reads a null
  /// selection as "the menu was dismissed" and routes it to `onCanceled` — so
  /// an Auto-detect entry valued null could set a pin but never clear one.
  /// `_autoDetectId` is deliberately not a language id, which is exactly what
  /// makes `structuredLanguageFromId` map it back to null.
  Widget _buildLanguagePicker() {
    final tab = _activeTab;
    final pinnedId = tab?.meta.languageOverride == null
        ? _autoDetectId
        : structuredLanguageId(language: tab!.meta.languageOverride!);
    return Tooltip(
      message: _documentTypeTooltip,
      child: PopupMenuButton<String>(
        key: const ValueKey('status-document-type'),
        enabled: tab != null,
        position: PopupMenuPosition.over,
        tooltip: '',
        onSelected: (id) =>
            _setLanguageOverride(structuredLanguageFromId(id: id)),
        itemBuilder: (context) => [
          CheckedPopupMenuItem<String>(
            value: _autoDetectId,
            checked: pinnedId == _autoDetectId,
            child: const Text('Auto-detect'),
          ),
          const PopupMenuDivider(),
          for (final language in structuredLanguages())
            CheckedPopupMenuItem<String>(
              value: structuredLanguageId(language: language),
              checked: pinnedId == structuredLanguageId(language: language),
              child: Text(MarkupStyling.label(language)),
            ),
        ],
        child: Text(
          _documentTypeLabel,
          key: const ValueKey('status-document-type-label'),
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  void _closeValidation() {
    setState(() {
      _isValidationVisible = false;
      _validationDiagnostics = const [];
      _validationContext = const [];
    });
  }

  @override
  void dispose() {
    _filePollTimer?.cancel();
    _autoValidateDebounce?.cancel();
    _midnightTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    windowManager.removeListener(this);
    undoCoalescingNotifier.removeListener(_onUndoCoalescingChanged);
    _focusNode.dispose();
    _findController.removeListener(_onFindChanged);
    _findController.dispose();
    _hexFindController.removeListener(_onHexFindChanged);
    _hexFindController.dispose();
    _viewportDebounce?.cancel();
    _findRefreshDebounce?.cancel();
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    final bool held = HardwareKeyboard.instance.isControlPressed;
    if (held != _ctrlHeld && mounted) setState(() => _ctrlHeld = held);
    return false;
  }

  // ---- Auto-delete enforcement -------------------------------------------

  // OS-correct scratch directory, owned by Rust (dirs crate).
  String get _scratchDir => rust_paths.scratchDir();

  void _deleteScratchFile(TabRuntime tab) {
    if (!tab.meta.isTransient) return;
    try {
      final f = File(tab.meta.path);
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      debugPrint('auto-delete failed for ${tab.meta.path}: $e');
    }
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  void onWindowClose() async {
    // Persist first (captures scratch content from the live session), then clear
    // the on-disk scratch files for onAppClose docs — their content stays in the
    // DB and is rehydrated on the next launch.
    _persistSession();
    for (final tab in _tabs) {
      if (tab.meta.autoDelete == AutoDelete.onAppClose) _deleteScratchFile(tab);
    }
    await windowManager.destroy();
  }

  void _scheduleMidnightCleanup() {
    final now = DateTime.now();
    final nextMidnight = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    _midnightTimer = Timer(nextMidnight.difference(now), () {
      _runMidnightCleanup();
      _scheduleMidnightCleanup();
    });
  }

  void _runMidnightCleanup() {
    final toClose = _tabs
        .where((t) => t.meta.autoDelete == AutoDelete.atMidnight)
        .toList();
    if (toClose.isEmpty) return;
    for (final t in toClose) {
      _deleteScratchFile(t);
    }
    setState(() {
      _tabs.removeWhere(toClose.contains);
      if (_activeTabIndex >= _tabs.length) _activeTabIndex = _tabs.length - 1;
    });
    _retargetFind();
    _persistSession();
  }

  void _pollExternalFileChanges() {
    bool needsSetState = false;
    for (final tab in _tabs) {
      if (tab.meta.isTransient) continue;
      try {
        final changed = tab.session.hasExternalChanges();
        if (changed && tab.mode == ViewMode.tail && !tab.session.isDirty()) {
          // Tail explicitly means follow the file. Read/Edit never refresh
          // behind the user's back, and a dirty Tail session is protected too.
          try {
            tab.session.refresh();
            tab.hasExternalChanges = false;
            // Opening, saving or saving-as can change the extension the format is
            // detected from, so the cached language is no longer trustworthy.
            tab.refreshMarkupLanguage();
            needsSetState = true;

            if (_activeTab == tab && tab.tailAutoScroll) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (tab.scrollController.hasClients) {
                  tab.scrollController.jumpTo(
                    tab.scrollController.position.maxScrollExtent,
                  );
                }
              });
            }
          } catch (e) {
            if (!tab.hasExternalChanges) {
              tab.hasExternalChanges = true;
              needsSetState = true;
            }
            debugPrint('Error refreshing tail file: $e');
          }
        } else if (tab.hasExternalChanges != changed) {
          tab.hasExternalChanges = changed;
          needsSetState = true;
        }
      } catch (e) {
        debugPrint('Error polling file changes: $e');
      }
    }
    if (needsSetState && mounted) {
      setState(() {});
    }
  }

  Future<void> _reloadExternalChange(TabRuntime tab) async {
    if (!tab.hasExternalChanges) return;
    if (tab.session.isDirty()) {
      final reload = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Reload "${tab.name}"?'),
          content: const Text(
            'The file changed on disk. Reloading will discard your unsaved changes.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reload and discard'),
            ),
          ],
        ),
      );
      if (reload != true || !mounted) return;
    }

    try {
      tab.session.refresh();
      tab.hasExternalChanges = false;
      // Opening, saving or saving-as can change the extension the format is
      // detected from, so the cached language is no longer trustworthy.
      tab.refreshMarkupLanguage();
      if (_activeTab == tab) {
        _retargetFind();
        tab.editorKey.currentState?.handleExternalReload();
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not reload ${tab.name}: $e')),
      );
    }
  }

  // ---- Tab / document lifecycle ------------------------------------------

  Future<void> _openFile() async {
    setState(() {
      _isRibbonVisible = false;
    });
    final path = await pickFile();
    if (path != null) {
      int existingIndex = _tabs.indexWhere((t) => t.meta.path == path);
      if (existingIndex >= 0) {
        setState(() {
          _activeTabIndex = existingIndex;
        });
        _retargetFind();
        return;
      }
      try {
        final session = EditSession.open(path: path);
        applyUndoSettingToText(session);
        String name = path.split('/').last;
        // Binary files open straight into the hex editor; text files start in
        // Read mode. Either can be toggled per tab afterwards.
        bool binary = false;
        try {
          binary = isBinaryFile(path: path);
        } catch (_) {}
        // The filename's extension is the strongest format signal there is, and
        // it was being dropped here — every opened file inherited the default
        // `txt`, so a `.xml` document could only be recognised by sniffing its
        // content, and stopped being XML the moment an edit made the sample
        // unrecognisable.
        final dot = name.lastIndexOf('.');
        final extension = dot > 0 ? name.substring(dot + 1) : 'txt';
        setState(() {
          _tabs.add(
            TabRuntime(
              meta: DocumentMeta(
                id: DocumentMeta.newId(),
                displayName: name,
                path: path,
                extension: extension,
                viewMode: binary ? ViewMode.hex : ViewMode.read,
              ),
              session: session,
            ),
          );
          _activeTabIndex = _tabs.length - 1;
        });
        _retargetFind();
        _focusNode.requestFocus();
        _persistSession();
      } catch (e) {
        debugPrint("Error opening file: $e");
      }
    }
  }

  void _createNewDocument(NewDocumentRequest req) {
    try {
      final ext = req.extension.trim().isEmpty ? 'txt' : req.extension.trim();
      final path = '$_scratchDir/${req.name}.$ext';
      // Fresh empty scratch file (Rust owns the file IO).
      final session = EditSession.createScratch(path: path, content: '');
      applyUndoSettingToText(session);
      setState(() {
        _tabs.add(
          TabRuntime(
            meta: DocumentMeta(
              id: DocumentMeta.newId(),
              displayName: req.name,
              path: path,
              isTransient: true,
              contentType: req.contentType,
              extension: ext,
              autoDelete: req.autoDelete,
              viewMode: ViewMode.edit,
            ),
            session: session,
          ),
        );
        _activeTabIndex = _tabs.length - 1;
        _isRibbonVisible = false;
        _newDocCounter++;
        _store?.setSetting(
          key: 'new_doc_counter',
          value: _newDocCounter.toString(),
        );
      });
      _retargetFind();
      _focusNode.requestFocus();
      _persistSession();
    } catch (e) {
      debugPrint('Error creating new document: $e');
    }
  }

  void _closeActiveTab() => _closeTabAt(_activeTabIndex);

  /// Save the active tab under a newly chosen path (always prompts). Rebinds the
  /// tab to the new path and clears its transient flag.
  Future<void> _saveFileAs() async {
    final tab = _activeTab;
    if (tab == null) return;
    final suggested = tab.meta.path.split('/').last;
    final newPath = await pickSaveFile(defaultName: suggested);
    if (newPath == null) return; // cancelled
    final oldPath = tab.meta.path;
    final wasTransient = tab.meta.isTransient;
    if (tab.mode == ViewMode.hex) {
      tab.hexSession.saveAs(newPath: newPath);
    } else {
      tab.session.saveAs(newPath: newPath);
      tab.hasExternalChanges = false;
    }
    final base = newPath.split('/').last;
    final dot = base.lastIndexOf('.');
    if (!mounted) return;
    setState(() {
      tab.meta.path = newPath;
      tab.meta.displayName = base;
      tab.meta.isTransient = false;
      if (dot > 0) tab.meta.extension = base.substring(dot + 1);
      // After the extension, never before: detection reads it, so refreshing
      // first would cache the format of the *old* filename.
      tab.refreshMarkupLanguage();
      _isRibbonVisible = false;
    });
    // A transient scratch file left behind under the old path is now orphaned.
    if (wasTransient && oldPath != newPath) {
      try {
        final f = File(oldPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _persistSession();
  }

  /// Close every tab except the active one.
  Future<void> _closeOtherTabs() async {
    final keep = _activeTab;
    if (keep == null) return;
    for (final t in _tabs.where((t) => t != keep).toList()) {
      final idx = _tabs.indexOf(t);
      if (idx >= 0) await _closeTabAt(idx);
    }
    if (!mounted) return;
    setState(() {
      _activeTabIndex = _tabs.indexOf(keep).clamp(0, _tabs.length - 1);
      _isRibbonVisible = false;
    });
    _persistSession();
  }

  /// Close all tabs positioned to the right of the active one.
  Future<void> _closeTabsToRight() async {
    final keep = _activeTab;
    if (keep == null) return;
    final keepIdx = _tabs.indexOf(keep);
    if (keepIdx < 0) return;
    for (final t in _tabs.sublist(keepIdx + 1).toList()) {
      final idx = _tabs.indexOf(t);
      if (idx >= 0) await _closeTabAt(idx);
    }
    if (!mounted) return;
    setState(() {
      _activeTabIndex = _tabs.indexOf(keep).clamp(0, _tabs.length - 1);
      _isRibbonVisible = false;
    });
    _persistSession();
  }

  /// Copy the active tab's file name (basename) to the clipboard (Rust-side).
  void _copyFileName() {
    final tab = _activeTab;
    if (tab == null) return;
    copyTextToClipboard(text: baseName(path: tab.meta.path));
    setState(() => _isRibbonVisible = false);
  }

  /// Copy the active tab's full file path to the clipboard (Rust-side).
  void _copyFilePath() {
    final tab = _activeTab;
    if (tab == null) return;
    copyTextToClipboard(text: tab.meta.path);
    setState(() => _isRibbonVisible = false);
  }

  /// Set the active tab's auto-delete policy (from the Auto-delete panel).
  void _setAutoDelete(AutoDelete policy) {
    final tab = _activeTab;
    if (tab == null) return;
    setState(() => tab.meta.autoDelete = policy);
    _persistSession();
  }

  /// Close the tab at [index], confirming first if it has unsaved editor
  /// changes. Auto-delete tabs cannot save, so their dialog offers only
  /// Discard/Cancel; savable tabs offer Save/Discard/Cancel.
  Future<void> _closeTabAt(int index) async {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    if (tab.isDirty) {
      final choice = await _showCloseDialog(tab);
      if (choice == null || choice == 'cancel') return;
      if (choice == 'save') {
        final saved = await _saveTab(tab);
        if (!saved) return; // Save dialog cancelled — keep the tab open.
      }
      // 'discard' falls through.
    }
    // A discarded/closed scratch doc should not come back: drop its file.
    _deleteScratchFile(tab);
    if (!mounted) return;
    setState(() {
      final removeIdx = _tabs.indexOf(tab);
      if (removeIdx >= 0) _tabs.removeAt(removeIdx);
      if (_activeTabIndex >= _tabs.length) _activeTabIndex = _tabs.length - 1;
      _isRibbonVisible = false;
    });
    _retargetFind();
    _persistSession();
  }

  /// Returns 'save' | 'discard' | 'cancel' | null (dismissed).
  Future<String?> _showCloseDialog(TabRuntime tab) {
    final savable = tab.meta.autoDelete == AutoDelete.off;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close "${tab.name}"?'),
        content: Text(
          savable
              ? 'This document has unsaved changes.'
              : 'This is an auto-delete document (${tab.meta.autoDelete.label}). '
                    'Its changes will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Discard'),
          ),
          if (savable)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Save'),
            ),
        ],
      ),
    );
  }

  /// Save [tab] (only meaningful for savable, i.e. auto-delete==off, tabs).
  /// Transient docs route through the Save-As dialog. Returns false if the user
  /// cancels the Save-As dialog.
  Future<bool> _saveTab(TabRuntime tab) async {
    // Hex mode saves the byte session; refresh the text session so a later
    // toggle back to a text view reflects the bytes now on disk.
    if (tab.meta.viewMode == ViewMode.hex) {
      final hs = tab.hexSession;
      if (!hs.isDirty()) return true;
      hs.save();
      tab.session.refresh();
      tab.hasExternalChanges = false;
      // Opening, saving or saving-as can change the extension the format is
      // detected from, so the cached language is no longer trustworthy.
      tab.refreshMarkupLanguage();
      if (mounted) setState(() {});
      _persistSession();
      return true;
    }
    if (!tab.session.isDirty()) return true;
    if (tab.meta.isTransient) {
      final suggested = '${tab.meta.displayName}.${tab.meta.extension}';
      final newPath = await pickSaveFile(defaultName: suggested);
      if (newPath == null) return false; // cancelled
      final oldPath = tab.meta.path;
      tab.session.saveAs(newPath: newPath);
      final base = newPath.split('/').last;
      final dot = base.lastIndexOf('.');
      if (mounted) {
        setState(() {
          tab.meta.path = newPath;
          tab.meta.displayName = base;
          tab.meta.isTransient = false;
          if (dot > 0) tab.meta.extension = base.substring(dot + 1);
          // Saving a scratch buffer as `notes.xml` makes it an XML document.
          tab.refreshMarkupLanguage();
        });
      }
      try {
        final f = File(oldPath);
        if (oldPath != newPath && f.existsSync()) f.deleteSync();
      } catch (_) {}
    } else {
      tab.session.save();
      tab.hasExternalChanges = false;
      // Opening, saving or saving-as can change the extension the format is
      // detected from, so the cached language is no longer trustworthy.
      tab.refreshMarkupLanguage();
      if (mounted) setState(() {});
    }
    _persistSession();
    return true;
  }

  // ---- Font size ----------------------------------------------------------

  double _rowHeightForMode(String mode) =>
      (_activeTab?.meta.fontSizeFor(mode) ?? 14.0) * (20.0 / 14.0);

  void _setActiveFontSize(String mode, double size) {
    final tab = _activeTab;
    if (tab == null) return;
    setState(() => tab.meta.setFontSize(mode, size));
  }

  void _zoomActive(double scrollDeltaY) {
    final tab = _activeTab;
    if (tab == null) return;
    final mode = tab.mode;
    final current = tab.meta.fontSizeFor(mode);
    final next = (current + (scrollDeltaY < 0 ? 1.0 : -1.0)).clamp(8.0, 40.0);
    if (next != current) _setActiveFontSize(mode, next);
  }

  // ---- Read/Tail scroll navigation ---------------------------------------

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (_activeTab == null) return KeyEventResult.ignored;
    if (_activeTab!.mode == ViewMode.edit) return KeyEventResult.ignored;

    final double rowHeight = _rowHeightForMode(_activeTab!.mode);
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      double currentOffset = _activeTab!.scrollController.offset;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _activeTab!.scrollController.jumpTo(currentOffset + rowHeight);
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _activeTab!.scrollController.jumpTo(currentOffset - rowHeight);
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
        _activeTab!.scrollController.jumpTo(
          currentOffset +
              _activeTab!.scrollController.position.viewportDimension,
        );
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
        _activeTab!.scrollController.jumpTo(
          currentOffset -
              _activeTab!.scrollController.position.viewportDimension,
        );
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.home) {
        if (HardwareKeyboard.instance.isControlPressed) {
          _activeTab!.scrollController.jumpTo(0.0);
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.end) {
        if (HardwareKeyboard.instance.isControlPressed) {
          _activeTab!.scrollController.jumpTo(
            _activeTab!.scrollController.position.maxScrollExtent,
          );
          return KeyEventResult.handled;
        }
      } else if (_activeTab!.mode == ViewMode.tail &&
          (event.logicalKey == LogicalKeyboardKey.keyT ||
              event.logicalKey == LogicalKeyboardKey.scrollLock)) {
        if (event is KeyDownEvent &&
            !HardwareKeyboard.instance.isControlPressed) {
          setState(() {
            _activeTab!.tailAutoScroll = !_activeTab!.tailAutoScroll;
            if (_activeTab!.tailAutoScroll) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_activeTab!.scrollController.hasClients) {
                  _activeTab!.scrollController.jumpTo(
                    _activeTab!.scrollController.position.maxScrollExtent,
                  );
                }
              });
            }
          });
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ---- Global keyboard shortcuts -----------------------------------------
  // These reach us by bubbling up from the focused editor/viewer, which return
  // KeyEventResult.ignored for these Ctrl combos so the ancestor Focus sees them.
  KeyEventResult _handleGlobalShortcut(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_activeToolPanelId != null) {
        _closeToolBar();
        return KeyEventResult.handled;
      }
      if (_isFindVisible) {
        _closeFind();
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.f3 && _isFindVisible) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        if (_activeTab?.mode == ViewMode.hex) {
          _hexFindController.stepBackward();
        } else {
          _findController.stepBackward();
        }
      } else {
        if (_activeTab?.mode == ViewMode.hex) {
          _hexFindController.stepForward();
        } else {
          _findController.stepForward();
        }
      }
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyX) {
      setState(() {
        _isRibbonVisible = !_isRibbonVisible;
      });
      return KeyEventResult.handled;
    }
    final fold = _handleFoldShortcut(event);
    if (fold == KeyEventResult.handled) return fold;
    if (!HardwareKeyboard.instance.isControlPressed)
      return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyO:
        _openFile();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyW:
        if (_activeTab != null) _closeActiveTab();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyN:
        setState(() {
          _isRibbonVisible = true;
          _pendingNewPanel = true;
        });
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS:
        if (_activeTab?.isDirty == true) _saveFile();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        if (HardwareKeyboard.instance.isShiftPressed) {
          if (_activeTab?.mode == ViewMode.edit) {
            _openFind(FindPanelMode.find);
            _findController.findAll();
          }
        } else {
          _openFind(FindPanelMode.find);
        }
        return KeyEventResult.handled;
      // Ctrl+R is the documented binding (shown in the Search menu); Ctrl+H is
      // kept as an unlisted alias for Notepad++ / VS Code muscle memory.
      case LogicalKeyboardKey.keyR:
      case LogicalKeyboardKey.keyH:
        _openFind(FindPanelMode.replace);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyG:
        _openToolBar('search.goto');
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        _openFind(FindPanelMode.mark);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Alt+<digit>, in Notepad++'s order: 0 is the whole document, 1..8 are
  /// nesting levels.
  static const List<LogicalKeyboardKey> _foldLevelKeys = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
  ];

  /// The folding bindings, Notepad++'s: Alt+0 / Alt+Shift+0 fold and unfold
  /// everything, Alt+1..8 and Alt+Shift+1..8 fold and unfold a nesting level,
  /// and Ctrl+Alt+F / Ctrl+Alt+Shift+F close and open the region around the
  /// caret.
  ///
  /// A matched binding is reported handled whether or not there is an editor
  /// to run it on, so Ctrl+Alt+F cannot fall through to Ctrl+F and open the
  /// find panel instead.
  KeyEventResult _handleFoldShortcut(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    if (!keys.isAltPressed) return KeyEventResult.ignored;
    final editor = _activeEditor;
    final shift = keys.isShiftPressed;

    if (keys.isControlPressed) {
      if (event.logicalKey != LogicalKeyboardKey.keyF) {
        return KeyEventResult.ignored;
      }
      if (shift) {
        editor?.expandAtCursor();
      } else {
        editor?.collapseAtCursor();
      }
      return KeyEventResult.handled;
    }

    final level = _foldLevelKeys.indexOf(event.logicalKey);
    if (level < 0) return KeyEventResult.ignored;
    if (level == 0) {
      shift ? editor?.unfoldAll() : editor?.foldAll();
    } else {
      shift ? editor?.unfoldLevel(level) : editor?.foldToLevel(level);
    }
    return KeyEventResult.handled;
  }

  /// The live editor state for the active tab, or null when the active tab
  /// isn't in Edit mode (or isn't mounted yet).
  CustomEditorState? get _activeEditor => (_activeTab?.mode == ViewMode.edit)
      ? _activeTab!.editorKey.currentState
      : null;

  /// Whether the docked find/tool bars are allowed to render for the active
  /// tab. Mirrors the editor-area if/else-if chain below (JwtToolView /
  /// HexEditorView / CustomEditor): the bars only make sense while a plain
  /// [CustomEditor] is the visible widget, i.e. edit mode and no jwt.* tool
  /// view is showing. Kept as a single getter so the next branch added to
  /// that chain only needs updating here, not on every bar guard.
  bool get _barsMayShow =>
      _activeTab?.mode == ViewMode.edit &&
      _activeTab?.activeTool?.startsWith('jwt') != true;

  /// Whether the transform tools have a document to work on.
  ///
  /// Deliberately *not* `_activeEditor != null`. `_activeEditor` resolves a
  /// `GlobalKey`'s `currentState`, and that key's `State` is created by the very
  /// build that mounts the editor — so on the first frame after opening a file
  /// or switching tabs it is still null, and every tool button rendered in that
  /// same frame came up disabled until some later rebuild (typing a character)
  /// happened to fix it. The honest condition is the one the bars already use
  /// to decide whether to render at all.
  bool get _editToolsAvailable => _barsMayShow;

  /// Show the find panel in [mode], pointed at the active tab's document.
  void _openFind(FindPanelMode mode) {
    final tab = _activeTab;
    if (tab == null) return;
    if (tab.mode == ViewMode.hex) {
      if (mode == FindPanelMode.mark) return;
      _openHexFind(
        mode == FindPanelMode.replace ? HexFindMode.replace : HexFindMode.find,
      );
      return;
    }
    if (tab.mode != ViewMode.edit) return;
    // Ctrl+F with the panel already open on this same document must not throw
    // the user's place away: `attach` resets the match list and the current
    // index, so re-running it here would jump them back to match 1 (or, with
    // no refresh, to "No results"). Just re-read the selection scope, switch
    // face, and hand focus back to the query field.
    final alreadyOnThisDoc =
        _isFindVisible && identical(_findController.session, tab.session);
    _findController.scope = _activeEditor?.selectionScope;
    if (!alreadyOnThisDoc) {
      _findController.attach(tab.session, tab.session.lineCount().toInt());
      // The query text deliberately persists across closes and across tabs,
      // so a reopen has to re-run it — `attach` alone leaves the panel
      // reporting "No results" with the old query still sitting in the field.
      if (_findController.query.text.isNotEmpty) {
        _findController.refresh();
      }
    }
    _findController.setMode(mode);
    _activeToolPanelId = null;
    setState(() {
      _isFindVisible = true;
      // The ribbon is Positioned(top: 0) in the same Stack and the bars are
      // the Column's first children, so leaving it open would park the query
      // field underneath it. _openToolBar closes it for the same reason.
      _isRibbonVisible = false;
    });
    _scheduleViewportScan();
    // Re-focus the query field even when the panel is already open (its
    // State isn't recreated, so `initState`'s one-shot focus won't re-run),
    // so a repeated Ctrl+F always returns focus to it, matching
    // Notepad++/VS Code.
    _findPanelKey.currentState?.requestQueryFocus();
  }

  void _openHexFind(HexFindMode mode) {
    final tab = _activeTab;
    if (tab == null || tab.mode != ViewMode.hex) return;
    _hexFindController.attach(tab.hexSession);
    _hexFindController.setMode(mode);
    _activeToolPanelId = null;
    setState(() {
      _isFindVisible = true;
      _isRibbonVisible = false;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _hexFindPanelKey.currentState?.requestQueryFocus(),
    );
  }

  void _closeFind() {
    _viewportDebounce?.cancel();
    _findRefreshDebounce?.cancel();
    _viewportScanGen++; // invalidate any in-flight scan
    setState(() {
      _isFindVisible = false;
      _viewportMatches = const [];
    });
    if (_activeTab?.mode == ViewMode.hex) {
      _activeTab?.hexEditorKey.currentState?.focusEditor();
    } else {
      _activeEditor?.focusEditor();
    }
  }

  /// Dock a tool bar, closing the find bar. Only one bar shows at a time.
  ///
  /// Refuses when the bars cannot render for the active tab. Storing an id
  /// that `_barsMayShow` then suppresses made the click a silent no-op AND
  /// left the id behind, so switching that tab to Edit later made the bar
  /// appear unbidden. The ribbon entries are disabled on this path too (see
  /// `_entryEnabled` in menu_ribbon.dart); this is the backstop.
  void _openToolBar(String panelId) {
    if (!_barsMayShow) return;
    setState(() {
      _isRibbonVisible = false;
      _isFindVisible = false;
      _activeToolPanelId = panelId;
    });
  }

  /// Last known "the active editor has a linear selection" value.
  ///
  /// The docked MIME bar's marker ("Transforms the selection." vs
  /// "⚠️ Transforms the whole document.") is read from the editor during
  /// build, but selecting text only wrote the status-bar ValueNotifier — the
  /// host never rebuilt, so the marker stayed stale in both directions.
  ///
  /// This field exists ONLY to detect the change: the build sites still read
  /// the editor live, so what they render is always current. Keeping the
  /// comparison here means the caret moving (which fires constantly) rebuilds
  /// nothing unless the boolean actually flipped.
  bool _hasLinearSelection = false;

  void _syncSelectionMarker() {
    final has = _activeEditor?.hasLinearSelection ?? false;
    if (has != _hasLinearSelection) {
      setState(() => _hasLinearSelection = has);
    }
  }

  void _closeToolBar() {
    setState(() => _activeToolPanelId = null);
    _activeEditor?.focusEditor();
  }

  // ---- Viewport-scoped highlighting --------------------------------------
  //
  // `_findController.loaded` only holds matches from windows already paged
  // in by stepping (scanning is forward-only from row 0), so it cannot be
  // used directly to highlight whatever happens to be on screen — a match
  // 500k rows down, reached only by scrolling, would never be loaded. So the
  // highlight set is its own independent, viewport-scoped scan straight to
  // Rust (`findInRows` over just the visible rows), decoupled from the
  // stepping cursor. Cost is therefore proportional to what's on screen, not
  // to document size or how far stepping has paged in.
  List<MatchSpan> _viewportMatches = const [];
  int _viewportScanGen = 0;
  Timer? _viewportDebounce;

  void _scheduleViewportScan() {
    _viewportDebounce?.cancel();
    _viewportDebounce = Timer(kMatchDebounce, _runViewportScan);
  }

  Timer? _findRefreshDebounce;

  /// The document changed under the find panel. Every loaded match span past
  /// the edit is now at the wrong coordinates: the painted highlights sit at
  /// pre-edit positions, and clicking Replace on a stale span makes Rust
  /// reject it ("match text no longer matches the pattern"). So re-scan.
  ///
  /// Debounced, because this fires on every keystroke. The refresh is
  /// anchored on the caret so the current match stays where the user is
  /// typing instead of snapping back to the first match in the document.
  void _onDocumentEdited() {
    // Format autodetection has to keep up with the content: an unsaved scratch
    // buffer becomes recognisably JSON or XML only once enough of it is typed.
    // Detection reads only the opening rows, so this is cheap per keystroke.
    _activeTab?.refreshMarkupLanguage();
    _scheduleAutoValidation();
    if (!_isFindVisible && !_findController.isSearchResultsVisible) return;
    final tab = _activeTab;
    if (tab == null || tab.mode != ViewMode.edit) return;
    _findController.setLineCount(tab.session.lineCount().toInt());
    // A result span is a coordinate snapshot. Once the document changes it
    // must not remain clickable at an obsolete position.
    if (_findController.isSearchResultsVisible) {
      _findController.closeSearchResults();
    }
    if (!_isFindVisible) return;
    _scheduleViewportScan();
    _findRefreshDebounce?.cancel();
    _findRefreshDebounce = Timer(kMatchDebounce, () {
      if (!mounted || !_isFindVisible) return;
      if (_findController.query.text.isEmpty) return;
      final (row, col) = _activeEditor?.caretPosition ?? (0, 0);
      _findController.refresh(anchorRow: row, anchorCol: col);
    });
  }

  Future<void> _runViewportScan() async {
    final gen = ++_viewportScanGen;
    if (!_isFindVisible) return;
    final tab = _activeTab;
    final editor = _activeEditor;
    final query = _findController.query.text;
    if (tab == null ||
        tab.mode != ViewMode.edit ||
        editor == null ||
        query.isEmpty ||
        _findController.regexError != null) {
      if (mounted && gen == _viewportScanGen)
        setState(() => _viewportMatches = const []);
      return;
    }
    final (first, last) = editor.visibleRowRange;
    if (first >= last) {
      if (mounted && gen == _viewportScanGen)
        setState(() => _viewportMatches = const []);
      return;
    }
    List<MatchSpan> found;
    try {
      // Through the controller, so this shares the active "In selection"
      // scope with the counter, stepping and Replace All. Painting the raw
      // `findInRows` result here would highlight matches the counter doesn't
      // count and Replace All won't touch.
      found = await _findController.scanViewport(first, last);
    } catch (_) {
      // A transient scan failure (e.g. an in-progress invalid regex edit)
      // leaves the previous highlight set rather than flashing it empty.
      return;
    }
    // Discard a result for a superseded scan (query/options/viewport changed
    // again, or the panel closed, while this scan was in flight).
    if (gen != _viewportScanGen || !mounted) return;
    setState(() => _viewportMatches = found);
  }

  /// Re-point the panel at the newly active tab. Loaded matches are dropped
  /// and rescanned; the query text and option toggles persist across tabs,
  /// matching Notepad++.
  void _retargetFind() {
    final tab = _activeTab;
    // The change-detector below is per-host, not per-tab, so a tab switch has
    // to re-read it or the first selection in the new tab can match the stale
    // value and skip the rebuild. The new editor's State doesn't exist yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSelectionMarker();
    });
    if (_activeToolPanelId != null &&
        (tab == null || tab.mode != ViewMode.edit)) {
      setState(() => _activeToolPanelId = null);
    }
    if (!_isFindVisible) {
      if (_findController.isSearchResultsVisible) {
        _findController.closeSearchResults();
      }
      return;
    }
    if (tab != null && tab.mode == ViewMode.hex) {
      _findController.attach(null, 0);
      _hexFindController.attach(tab.hexSession);
      _viewportScanGen++;
      setState(() => _viewportMatches = const []);
      return;
    }
    _hexFindController.attach(null);
    if (tab == null || tab.mode != ViewMode.edit) {
      _findController.attach(null, 0);
      _viewportScanGen++;
      setState(() => _viewportMatches = const []);
      return;
    }
    _findController.attach(tab.session, tab.session.lineCount().toInt());
    // The new tab's editor State doesn't exist yet at this point in a tab
    // switch, so `_activeEditor` is still null and reading its selection here
    // would leave the scope null — disabling "In selection" until the next
    // time the panel is opened. Read it once the new editor has been built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isFindVisible) return;
      _findController.scope = _activeEditor?.selectionScope;
      _findController.refresh();
      _scheduleViewportScan();
    });
  }

  /// Run a ribbon Edit-menu action against the active editor, then close the
  /// ribbon (focus returns to the editor inside the action itself).
  void _runEditAction(void Function(CustomEditorState) action) {
    final editor = _activeEditor;
    if (editor == null) return;
    action(editor);
    setState(() => _isRibbonVisible = false);
  }

  Future<void> _saveFile() async {
    final tab = _activeTab;
    if (tab == null || (tab.mode != ViewMode.edit && tab.mode != ViewMode.hex))
      return;
    // Auto-delete documents are ephemeral by design and must not save.
    if (tab.meta.autoDelete != AutoDelete.off) return;
    await _saveTab(tab);
    if (mounted) setState(() => _isRibbonVisible = false);
  }

  String _getNextUniqueNewDocName() {
    String name = 'new $_newDocCounter';
    while (_tabs.any((t) => t.name == name)) {
      _newDocCounter++;
      _store?.setSetting(
        key: 'new_doc_counter',
        value: _newDocCounter.toString(),
      );
      name = 'new $_newDocCounter';
    }
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    // Two chrome bars with distinct hue identities so they read as clearly
    // different surfaces, re-toned per theme:
    //   • Title bar → violet/indigo gradient
    //   • Tab bar   → teal
    // Both are saturated enough to be obvious while keeping the dark theme
    // controls / dark light-theme text legible on top.
    // Title bar: dark blue (dark) / sky blue (light).
    final Gradient titleGradient = dark
        ? const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFF0059B3), Color(0xFF004A94)],
          )
        : const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFFBAE0FA), Color(0xFF93CEF6)],
          );
    // Tab bar: indigo/blue-violet (dark) — the analogous (~250°) partner to the
    // #0059B3 title, tuned up in saturation so the two bars share vibrancy;
    // a soft sky that matches the title (light).
    final Color tabBarColor = dark
        ? const Color(0xFF3B2E86)
        : const Color(0xFFCBE7FA);
    // Active tab lifts out of the strip.
    final Color activeTabColor = dark ? const Color(0xFF5B49B8) : Colors.white;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) => _handleGlobalShortcut(event),
      child: Scaffold(
        body: Column(
          children: [
            // The drag area deliberately does NOT wrap this row.
            //
            // `DragToMoveArea` is a `GestureDetector` with an `onDoubleTap`
            // (double-click to maximise), and a `DoubleTapGestureRecognizer`
            // holds the gesture arena open for `kDoubleTapTimeout` — 300ms —
            // after the first tap. While it is held the arena cannot be swept,
            // so a button underneath it cannot be declared the winner and its
            // `onPressed` does not run. Every control in this bar was paying
            // that 300ms, which is why the menu button felt sluggish next to
            // Alt-X (which fires on key *down*). Only the empty filler below is
            // draggable now.
            Container(
              height: 48,
              decoration: BoxDecoration(gradient: titleGradient),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.menu, size: 20),
                    onPressed: () {
                      setState(() {
                        _isRibbonVisible = !_isRibbonVisible;
                      });
                    },
                    tooltip: 'Menu (Alt-X)',
                  ),
                  const SizedBox(width: 8),
                  if (_activeTab?.activeTool?.startsWith('jwt') == true)
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'exit',
                          label: Text('<- Exit Tool'),
                        ),
                        ButtonSegment(
                          value: 'jwt.decode',
                          label: Text('Decoder'),
                        ),
                        ButtonSegment(
                          value: 'jwt.encode',
                          label: Text('Encoder'),
                        ),
                      ],
                      selected: {_activeTab!.activeTool!},
                      onSelectionChanged: (Set<String> newSelection) {
                        final val = newSelection.first;
                        setState(() {
                          if (val == 'exit') {
                            _activeTab!.activeTool = null;
                          } else {
                            _activeTab!.activeTool = val;
                          }
                        });
                        _persistSession();
                      },
                      style: ButtonStyle(
                        foregroundColor: WidgetStateProperty.resolveWith((
                          states,
                        ) {
                          if (states.contains(WidgetState.selected)) {
                            return Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer;
                          }
                          return Colors.white; // Unselected text color
                        }),
                      ),
                    )
                  else if (_activeTab?.activeTool != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          icon: const Icon(
                            Icons.arrow_back,
                            size: 16,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'Exit Tool',
                            style: TextStyle(color: Colors.white),
                          ),
                          onPressed: () {
                            setState(() {
                              _activeTab!.activeTool = null;
                            });
                            _persistSession();
                          },
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Tool',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    )
                  else if (_activeTab?.mode == ViewMode.hex)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          icon: const Icon(
                            Icons.arrow_back,
                            size: 16,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'Exit Hex',
                            style: TextStyle(color: Colors.white),
                          ),
                          onPressed: () {
                            setState(() {
                              _activeTab!.mode = ViewMode.read;
                            });
                            _retargetFind();
                            _persistSession();
                          },
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Hex Editor',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    )
                  else
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: ViewMode.read,
                          label: Text('Read'),
                        ),
                        ButtonSegment(
                          value: ViewMode.tail,
                          label: Text('Tail'),
                        ),
                        ButtonSegment(
                          value: ViewMode.edit,
                          label: Text('Edit'),
                        ),
                      ],
                      selected: {_activeTab?.mode ?? ViewMode.read},
                      onSelectionChanged: (Set<String> newSelection) {
                        if (_activeTab != null) {
                          setState(() {
                            _activeTab!.mode = newSelection.first;
                            if (_activeTab!.mode == ViewMode.tail) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (_activeTab!.scrollController.hasClients) {
                                  _activeTab!.scrollController.jumpTo(
                                    _activeTab!
                                        .scrollController
                                        .position
                                        .maxScrollExtent,
                                  );
                                }
                              });
                            }
                          });
                          // Leaving Edit mode must drop any docked bar, the
                          // same as switching tabs does — otherwise the id
                          // lingers and the bar reappears on the way back.
                          _retargetFind();
                          _persistSession();
                        }
                      },
                    ),
                  if (_activeTab?.activeTool == null &&
                      _activeTab?.mode != ViewMode.hex &&
                      _activeTab?.hasExternalChanges == true) ...[
                    const SizedBox(width: 8),
                    ExternalChangeButton(
                      hasUnsavedChanges: _activeTab!.session.isDirty(),
                      onReload: () => _reloadExternalChange(_activeTab!),
                    ),
                  ],
                  if (_activeTab?.mode == ViewMode.tail) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        _activeTab!.tailAutoScroll
                            ? Icons.pause
                            : Icons.vertical_align_bottom,
                        size: 20,
                      ),
                      tooltip: _activeTab!.tailAutoScroll
                          ? 'Pause auto-scroll'
                          : 'Resume auto-scroll',
                      onPressed: () {
                        setState(() {
                          _activeTab!.tailAutoScroll =
                              !_activeTab!.tailAutoScroll;
                          if (_activeTab!.tailAutoScroll) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (_activeTab!.scrollController.hasClients) {
                                _activeTab!.scrollController.jumpTo(
                                  _activeTab!
                                      .scrollController
                                      .position
                                      .maxScrollExtent,
                                );
                              }
                            });
                          }
                        });
                      },
                    ),
                  ],
                  // The window's drag handle: the empty stretch of title bar
                  // between the controls and the window buttons. Dragging and
                  // double-click-to-maximise live here and nowhere else, so no
                  // control competes with them. Window controls sit flush
                  // right, with the theme toggle immediately to the left of
                  // the minimize button.
                  const Expanded(
                    child: DragToMoveArea(child: SizedBox.expand()),
                  ),
                  ValueListenableBuilder<ThemeMode>(
                    valueListenable: themeNotifier,
                    builder: (context, mode, child) {
                      final brightness = mode == ThemeMode.dark
                          ? Brightness.dark
                          : Brightness.light;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              mode == ThemeMode.dark
                                  ? Icons.light_mode
                                  : Icons.dark_mode,
                              size: 18,
                            ),
                            tooltip: 'Toggle theme',
                            onPressed: _toggleTheme,
                          ),
                          WindowCaptionButton.minimize(
                            brightness: brightness,
                            onPressed: () => windowManager.minimize(),
                          ),
                          if (_isMaximized)
                            WindowCaptionButton.unmaximize(
                              brightness: brightness,
                              onPressed: () => windowManager.unmaximize(),
                            )
                          else
                            WindowCaptionButton.maximize(
                              brightness: brightness,
                              onPressed: () => windowManager.maximize(),
                            ),
                          WindowCaptionButton.close(
                            brightness: brightness,
                            onPressed: () => windowManager.close(),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Column(
                    children: [
                      if (_tabs.isNotEmpty)
                        Container(
                          height: 28,
                          color: tabBarColor,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: _tabs.length,
                            itemBuilder: (context, index) {
                              final tab = _tabs[index];
                              final isActive = index == _activeTabIndex;
                              return GestureDetector(
                                onTap: () {
                                  setState(() => _activeTabIndex = index);
                                  _retargetFind();
                                  _persistSession();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? activeTabColor
                                        : Colors.transparent,
                                    border: isActive
                                        ? Border(
                                            bottom: BorderSide(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              width: 2,
                                            ),
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Auto-delete (scratch) tabs carry a trash-can
                                      // glyph so their ephemeral nature is obvious.
                                      if (tab.meta.autoDelete !=
                                          AutoDelete.off) ...[
                                        Tooltip(
                                          message:
                                              'Auto-delete: ${tab.meta.autoDelete.label}',
                                          child: Icon(
                                            Icons.delete_outline,
                                            size: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error
                                                .withOpacity(0.8),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      Text(
                                        tab.name,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: isActive
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      if (tab.isDirty) ...[
                                        const SizedBox(width: 4),
                                        const Icon(
                                          Icons.circle,
                                          size: 7,
                                          color: Colors.blueAccent,
                                        ),
                                      ],
                                      const SizedBox(width: 6),
                                      InkWell(
                                        onTap: () => _closeTabAt(index),
                                        child: const Icon(
                                          Icons.close,
                                          size: 14,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      // The bars sit below the document tabs so the tab bar stays
                      // adjacent to the window chrome; the title tab therefore
                      // hangs from the file tabs rather than from the chrome.
                      if (_isFindVisible && _barsMayShow)
                        FindPanel(
                          key: _findPanelKey,
                          controller: _findController,
                          onClose: _closeFind,
                          onReveal: (span) => _activeEditor?.revealSpan(span),
                        ),
                      if (_isFindVisible && _activeTab?.mode == ViewMode.hex)
                        HexFindPanel(
                          key: _hexFindPanelKey,
                          controller: _hexFindController,
                          onClose: _closeFind,
                          onReveal: (match) => _activeTab
                              ?.hexEditorKey
                              .currentState
                              ?.revealMatch(match),
                          onContentChanged: () {
                            setState(() {});
                            _persistSession();
                          },
                        ),
                      if (_activeToolPanelId != null && _barsMayShow)
                        ToolBar(
                          panelId: _activeToolPanelId!,
                          editToolsEnabled: _editToolsAvailable,
                          mimeToolsEnabled: _editToolsAvailable,
                          mimeHasSelection:
                              _activeEditor?.hasLinearSelection ?? false,
                          onRunEditOp: _runEditOp,
                          onRunMimeOp: _runMimeOp,
                          onRunStructuredOp: _runStructuredOp,
                          structuredUseJson5:
                              _activeTab?.markupLanguage ==
                              StructuredLanguage.json5,
                          onStructuredUseJson5Changed: (on) =>
                              _setLanguageOverride(
                                on
                                    ? StructuredLanguage.json5
                                    : StructuredLanguage.json,
                              ),
                          structuredAutoValidate: _structuredAutoValidate,
                          onStructuredAutoValidateChanged: (on) {
                            setState(() => _structuredAutoValidate = on);
                            if (on) {
                              // Show the current state straight away rather
                              // than waiting for the next keystroke.
                              _runValidation(_validationTargetLanguage());
                            } else {
                              _autoValidateDebounce?.cancel();
                            }
                          },
                          onClose: _closeToolBar,
                          lineCount: _activeTab?.lineCount ?? 1,
                          currentLine: _activeTab?.stats.value.row ?? 1,
                          onGotoLine: (line) => _activeEditor?.gotoLine(line),
                        ),
                      if (_activeTab != null &&
                          _activeTab!.activeTool?.startsWith('jwt') == true)
                        Expanded(
                          child: JwtToolView(
                            key: ValueKey('jwt-${_activeTab!.meta.id}'),
                            initialEncoded: _activeTab!.session.contentString(),
                            mode: _activeTab!.activeTool == 'jwt.encode'
                                ? JwtMode.encode
                                : JwtMode.decode,
                          ),
                        )
                      else if (_activeTab != null &&
                          _activeTab!.mode == ViewMode.hex)
                        Expanded(
                          child: HexEditorView(
                            key: _activeTab!.hexEditorKey,
                            session: _activeTab!.hexSession,
                            matches: _isFindVisible
                                ? _hexFindController.matches
                                : const [],
                            currentMatch: _isFindVisible
                                ? _hexFindController.currentMatch
                                : null,
                            settings: HexViewSettings(
                              fontSize: _activeTab!.meta.fontSizeFor(
                                ViewMode.hex,
                              ),
                            ),
                            onFontSizeChanged: (size) =>
                                _setActiveFontSize(ViewMode.hex, size),
                            onContentChanged: () {
                              if (_isFindVisible) {
                                _hexFindController.scheduleRefresh();
                              }
                              setState(() {});
                            },
                            onCursorChanged: (offset, totalLen) {
                              // Reuse EditorStats to carry byte offset / length;
                              // the status bar formats them for hex mode.
                              _activeTab!.stats.value = EditorStats(
                                row: offset,
                                col: totalLen,
                              );
                            },
                          ),
                        )
                      else if (_activeTab != null &&
                          _activeTab!.mode == ViewMode.edit)
                        Expanded(
                          child: CustomEditor(
                            key: _activeTab!.editorKey,
                            session: _activeTab!.session,
                            showLineNumbers: _showLineNumbers,
                            fontSize: _activeTab!.meta.fontSizeFor(
                              ViewMode.edit,
                            ),
                            markupLanguage: _activeTab!.markupLanguage,
                            diagnostics: _validationDiagnostics,
                            initialCollapsedFolds:
                                _activeTab!.meta.collapsedFolds,
                            // Stored on the document, not persisted on the
                            // spot: like font size, it rides along with the
                            // next session write.
                            onCollapsedFoldsChanged: (rows) =>
                                _activeTab!.meta.collapsedFolds = rows,
                            onFontSizeChanged: (size) =>
                                _setActiveFontSize(ViewMode.edit, size),
                            onCursorChanged: (row, col, selChars, selLines) {
                              _activeTab!.stats.value = EditorStats(
                                row: row + 1,
                                col: col + 1,
                                selChars: selChars,
                                selLines: selLines,
                              );
                              // Gated on the boolean actually flipping; this
                              // fires on every caret move.
                              _syncSelectionMarker();
                            },
                            // Dirtiness lives in the session; repaint the tab dot.
                            // Editing also moves every match after the caret, so
                            // the find panel's state has to be invalidated too.
                            onContentChanged: () {
                              setState(() {});
                              _onDocumentEdited();
                            },
                            matches: _isFindVisible
                                ? _viewportMatches
                                : const [],
                            currentMatch: _isFindVisible
                                ? _findController.currentMatch
                                : null,
                            markedSpans: _findController.markedSpans,
                            markedLines: _findController.markedLines,
                            onViewportChanged: _isFindVisible
                                ? _scheduleViewportScan
                                : null,
                          ),
                        )
                      else
                        Expanded(
                          child: Focus(
                            focusNode: _focusNode,
                            autofocus: true,
                            onKeyEvent: (node, event) => _handleKeyEvent(event),
                            child: _activeTab == null
                                ? const Center(child: Text("No file loaded."))
                                : Listener(
                                    onPointerSignal: (signal) {
                                      if (signal is PointerScrollEvent &&
                                          HardwareKeyboard
                                              .instance
                                              .isControlPressed) {
                                        _zoomActive(signal.scrollDelta.dy);
                                      }
                                    },
                                    child: SelectionArea(
                                      child: Scrollbar(
                                        controller:
                                            _activeTab!.scrollController,
                                        thumbVisibility: true,
                                        trackVisibility: true,
                                        child: ListView.builder(
                                          controller:
                                              _activeTab!.scrollController,
                                          itemCount: _activeTab!.lineCount,
                                          itemExtent: _rowHeightForMode(
                                            _activeTab!.mode,
                                          ),
                                          physics: _ctrlHeld
                                              ? const NeverScrollableScrollPhysics()
                                              : null,
                                          itemBuilder: (context, index) {
                                            try {
                                              final line = _activeTab!.session
                                                  .line(
                                                    vrow: BigInt.from(index),
                                                  );
                                              final textStyle = TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: _activeTab!.meta
                                                    .fontSizeFor(
                                                      _activeTab!.mode,
                                                    ),
                                                fontWeight: FontWeight.w500,
                                                color:
                                                    Theme.of(
                                                          context,
                                                        ).brightness ==
                                                        Brightness.light
                                                    ? Colors.black
                                                    : Colors.white,
                                              );
                                              // One lexer call per visible
                                              // row. It resumes from the
                                              // session's cached checkpoint,
                                              // so this stays cheap even deep
                                              // into a large document.
                                              final tokens =
                                                  MarkupStyling.isStructured(
                                                    _activeTab!.markupLanguage,
                                                  )
                                                  ? _activeTab!.session
                                                        .markupTokens(
                                                          language: _activeTab!
                                                              .markupLanguage,
                                                          fromRow: BigInt.from(
                                                            index,
                                                          ),
                                                          toRow: BigInt.from(
                                                            index + 1,
                                                          ),
                                                        )
                                                  : const <
                                                      StructuredRowTokens
                                                    >[];
                                              final lineSpan = tokens.isEmpty
                                                  ? TextSpan(
                                                      text: line,
                                                      style: textStyle,
                                                    )
                                                  : MarkupStyling.styledLine(
                                                      line: line,
                                                      tokens:
                                                          tokens.first.tokens,
                                                      baseStyle: textStyle,
                                                      brightness: Theme.of(
                                                        context,
                                                      ).brightness,
                                                    );

                                              if (!_showLineNumbers) {
                                                return Text.rich(
                                                  lineSpan,
                                                  maxLines: 1,
                                                  softWrap: false,
                                                );
                                              }

                                              return Row(
                                                children: [
                                                  Container(
                                                    width: 60,
                                                    padding:
                                                        const EdgeInsets.only(
                                                          right: 16,
                                                        ),
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: Text(
                                                      '${index + 1}',
                                                      style: textStyle.copyWith(
                                                        color: Colors.grey,
                                                      ),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: Text.rich(
                                                      lineSpan,
                                                      maxLines: 1,
                                                      softWrap: false,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            } catch (e) {
                                              return const Text(
                                                "Error reading line",
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      if (_findController.isSearchResultsVisible &&
                          _barsMayShow)
                        FindResultsPanel(
                          query: _findController.searchResultsQuery,
                          results: _findController.searchResults,
                          isLoading: _findController.isSearchResultsLoading,
                          error: _findController.searchResultsError,
                          currentMatch: _findController.currentMatch,
                          onClose: _findController.closeSearchResults,
                          onSelectResult: (span) {
                            _findController.selectSearchResult(span);
                            _activeEditor?.revealSpan(span);
                            _activeEditor?.focusEditor();
                          },
                        ),
                      if (_isValidationVisible && _barsMayShow)
                        ValidationResultsPanel(
                          language: _validationLanguage,
                          diagnostics: _validationDiagnostics,
                          contextLines: _validationContext,
                          truncated: _validationTruncated,
                          onClose: _closeValidation,
                          onSelect: (diagnostic) {
                            // Select the offending span, so the problem is
                            // visible rather than merely scrolled to.
                            _activeEditor?.revealSpan(
                              MatchSpan(
                                startRow: BigInt.from(diagnostic.row),
                                startCol: BigInt.from(diagnostic.col),
                                endRow: BigInt.from(diagnostic.endRow),
                                endCol: BigInt.from(diagnostic.endCol),
                              ),
                            );
                            _activeEditor?.focusEditor();
                          },
                        ),
                    ],
                  ),
                  // Tap-barrier: while the ribbon is open, a click anywhere in the
                  // content area below it closes it. Present only when the ribbon
                  // is visible, so it never intercepts normal interaction.
                  if (_isRibbonVisible)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _isRibbonVisible = false),
                      ),
                    ),
                  if (_isRibbonVisible)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: MenuRibbon(
                        markupLanguage:
                            _activeTab?.markupLanguage ??
                            StructuredLanguage.plainText,
                        onOpen: _openFile,
                        onNew: () => _pendingNewPanel = false,
                        autoOpenNew: _pendingNewPanel,
                        newDocDefaultName: _getNextUniqueNewDocName(),
                        onCreateDocument: _createNewDocument,
                        onSave:
                            (_activeTab != null &&
                                _activeTab!.isDirty &&
                                _activeTab!.meta.autoDelete == AutoDelete.off)
                            ? _saveFile
                            : null,
                        onUndo: (_activeEditor?.canUndo ?? false)
                            ? () => _runEditAction((e) => e.menuUndo())
                            : null,
                        onRedo: (_activeEditor?.canRedo ?? false)
                            ? () => _runEditAction((e) => e.menuRedo())
                            : null,
                        onCut: (_activeEditor?.hasSelection ?? false)
                            ? () => _runEditAction((e) => e.menuCut())
                            : null,
                        onCopy: (_activeEditor?.hasSelection ?? false)
                            ? () => _runEditAction((e) => e.menuCopy())
                            : null,
                        onPaste: _activeEditor != null
                            ? () => _runEditAction((e) => e.menuPaste())
                            : null,
                        showLineNumbers: _showLineNumbers,
                        wordWrap: _wordWrap,
                        onToggleLineNumbers: _toggleLineNumbers,
                        onToggleWordWrap: _toggleWordWrap,
                        onFoldAll: _activeEditor?.hasFolds == true
                            ? () => _activeEditor?.foldAll()
                            : null,
                        onUnfoldAll: _activeEditor?.hasFolds == true
                            ? () => _activeEditor?.unfoldAll()
                            : null,
                        mimeToolsEnabled: _editToolsAvailable,
                        mimeHasSelection:
                            _activeEditor?.hasLinearSelection ?? false,
                        onRunMimeOp: _runMimeOp,
                        editToolsEnabled: _editToolsAvailable,
                        onRunEditOp: _runEditOp,
                        onEnterToolMode: (toolId) {
                          if (_activeTab != null) {
                            setState(() {
                              _activeTab!.activeTool = toolId;
                              _isRibbonVisible = false;
                              _isFindVisible = false;
                              _activeToolPanelId = null;
                            });
                            _persistSession();
                          }
                        },
                        onEnterHex: () {
                          if (_activeTab != null) {
                            setState(() {
                              _activeTab!.mode = ViewMode.hex;
                              _isRibbonVisible = false;
                            });
                            // Leaving Edit mode has to drop the docked bars, or
                            // they reappear when the tab returns to Edit.
                            _retargetFind();
                            _persistSession();
                          }
                        },
                        onSaveAs: _activeTab != null ? _saveFileAs : null,
                        onCloseOtherTabs: _tabs.length > 1
                            ? _closeOtherTabs
                            : null,
                        onCloseTabsToRight:
                            (_activeTab != null &&
                                _activeTabIndex < _tabs.length - 1)
                            ? _closeTabsToRight
                            : null,
                        onCopyFileName: _activeTab != null
                            ? _copyFileName
                            : null,
                        onCopyFilePath: _activeTab != null
                            ? _copyFilePath
                            : null,
                        onFind:
                            (_activeTab?.mode == ViewMode.edit ||
                                _activeTab?.mode == ViewMode.hex)
                            ? () {
                                setState(() => _isRibbonVisible = false);
                                _openFind(FindPanelMode.find);
                              }
                            : null,
                        onReplace:
                            (_activeTab?.mode == ViewMode.edit ||
                                _activeTab?.mode == ViewMode.hex)
                            ? () {
                                setState(() => _isRibbonVisible = false);
                                _openFind(FindPanelMode.replace);
                              }
                            : null,
                        onMark: _activeTab?.mode == ViewMode.edit
                            ? () {
                                setState(() => _isRibbonVisible = false);
                                _openFind(FindPanelMode.mark);
                              }
                            : null,
                        onFindAll: _barsMayShow
                            ? () {
                                setState(() => _isRibbonVisible = false);
                                _openFind(FindPanelMode.find);
                                _findController.findAll();
                              }
                            : null,
                        currentAutoDelete: _activeTab?.meta.autoDelete,
                        onSetAutoDelete: _activeTab != null
                            ? _setAutoDelete
                            : null,
                        onCloseTab: _activeTab != null ? _closeActiveTab : null,
                        onOpenToolBar: _openToolBar,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 2.0,
              ),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        double w = constraints.maxWidth;
                        Widget sep = Container(
                          width: 1,
                          height: 14,
                          color: Colors.grey.withOpacity(0.5),
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                        );

                        // Scrollable, because the width thresholds below only
                        // drop whole segments at hand-picked breakpoints and
                        // cannot know how wide the remaining ones actually
                        // render. Selecting text adds "Sel: n | n" to the
                        // stats segment and overflowed the row by 97px at the
                        // app's own 1000px default width — a red-and-yellow
                        // stripe across the status bar, in the real app, on
                        // nothing rarer than selecting a few lines. Reversed
                        // so the row stays pinned to the right edge, which is
                        // where it sat before, and so what scrolls out of
                        // reach under pressure is the left-most segment.
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (w > 700) ...[_buildLanguagePicker(), sep],
                              if (w > 600) ...[
                                Text(
                                  'length: ?  lines: ${_activeTab?.lineCount ?? 0}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                sep,
                              ],
                              if (w > 200 && _activeTab != null) ...[
                                ValueListenableBuilder<EditorStats>(
                                  valueListenable: _activeTab!.stats,
                                  builder: (context, stats, child) {
                                    if (_activeTab?.mode == ViewMode.hex) {
                                      final off = stats.row;
                                      return Text(
                                        'Offset: 0x${off.toRadixString(16).toUpperCase()} ($off)  Bytes: ${stats.col}',
                                        style: const TextStyle(fontSize: 12),
                                      );
                                    }
                                    String sel = stats.selChars > 0
                                        ? "  Sel: ${stats.selChars} | ${stats.selLines}"
                                        : "";
                                    return Text(
                                      'Ln: ${stats.row}  Col: ${stats.col}$sel',
                                      style: const TextStyle(fontSize: 12),
                                    );
                                  },
                                ),
                                sep,
                              ],
                              if (w > 400) ...[
                                const Text(
                                  'Windows (CR LF)',
                                  style: TextStyle(fontSize: 12),
                                ),
                                sep,
                                const Text(
                                  'UTF-8',
                                  style: TextStyle(fontSize: 12),
                                ),
                                sep,
                                const Text(
                                  'INS',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

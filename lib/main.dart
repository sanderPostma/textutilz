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
import 'menu_ribbon.dart';
import 'mime_tools_panel.dart';
import 'edit_tools_panel.dart';
import 'document_state.dart';
import 'jwt_tools_panel.dart';
import 'hex_editor_view.dart';
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
    size: Size(800, 600),
    // The find/replace panel's controls stop fitting below ~800px, so the
    // window refuses to go narrower rather than degrading into a scrolling
    // toggle cluster. Height is left free.
    minimumSize: Size(800, 400),
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
          theme: ThemeData.light(useMaterial3: true).copyWith(
            scaffoldBackgroundColor: Colors.white,
          ),
          darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
            scaffoldBackgroundColor: const Color(0xFF1E1E1E),
          ),
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
      _activeTabIndex >= 0 && _activeTabIndex < _tabs.length ? _tabs[_activeTabIndex] : null;

  final FocusNode _focusNode = FocusNode();
  bool _isRibbonVisible = false;

  final FindController _findController = FindController();
  final GlobalKey<FindPanelState> _findPanelKey = GlobalKey<FindPanelState>();
  bool _isFindVisible = false;

  /// The docked tool bar's panel id, or null when none is open. Mutually
  /// exclusive with the find bar — see _openFind / _openToolBar.
  String? _activeToolPanelId;

  int _newDocCounter = 1;
  bool _ctrlHeld = false; // while held, wheel zooms Read/Tail instead of scrolling
  bool _isMaximized = false;
  bool _pendingNewPanel = false; // Ctrl+N asked the ribbon to open its New panel
  Timer? _midnightTimer;
  Timer? _tailTimer;

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
        _showLineNumbers = _store!.getSetting(key: 'show_line_numbers') == 'true';
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
    _tailTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _pollTailFiles());
    // Shared editor settings: when toggled (e.g. by a future config panel),
    // apply to every open editor and persist. Works for all editors alike.
    undoCoalescingNotifier.addListener(_onUndoCoalescingChanged);
    // The editor's match highlighting is read from the controller at build
    // time (see the CustomEditor `matches`/`currentMatch` args below), so a
    // rebuild here is what actually propagates a new/updated match set to
    // the painter — the panel's own setState only repaints itself.
    _findController.addListener(_onFindChanged);
  }

  void _onFindChanged() {
    if (mounted) setState(() {});
    // The query/options changing invalidates the viewport highlight scan
    // too — e.g. Match case toggled, or new text typed (via scheduleRefresh
    // -> refresh() -> notifyListeners()).
    _scheduleViewportScan();
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
        value: undoCoalescingNotifier.value ? 'true' : 'false');
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
          session = EditSession.createScratch(path: r.path, content: r.scratchContent ?? '');
        } else {
          if (!File(r.path).existsSync()) continue; // real file gone — skip
          session = EditSession.open(path: r.path);
        }
        applyUndoSettingToText(session);
        DocumentMeta.reserveId(r.id);
        _tabs.add(TabRuntime(meta: DocumentMeta.fromRecord(r), session: session));
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
    final next = themeNotifier.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    themeNotifier.value = next;
    try {
      _store?.setSetting(key: 'theme_mode', value: next == ThemeMode.dark ? 'dark' : 'light');
    } catch (e) {
      debugPrint('theme persist failed: $e');
    }
  }

  void _toggleLineNumbers() {
    setState(() => _showLineNumbers = !_showLineNumbers);
    try {
      _store?.setSetting(key: 'show_line_numbers', value: _showLineNumbers ? 'true' : 'false');
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
      editor.transformSelectionOrAll((input) {
        return rust_edit_ops.applyEditOp(
          input: input,
          opId: op.opId,
          extension_: ext,
          tabWidth: BigInt.from(4),
        );
      });
    } catch (e) {
      setState(() => _isRibbonVisible = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${op.label} failed: $e')),
      );
      return;
    }
    setState(() => _isRibbonVisible = false);
    _persistSession();
  }


  @override
  void dispose() {
    _tailTimer?.cancel();
    _midnightTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    windowManager.removeListener(this);
    undoCoalescingNotifier.removeListener(_onUndoCoalescingChanged);
    _focusNode.dispose();
    _findController.removeListener(_onFindChanged);
    _findController.dispose();
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
    final nextMidnight =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
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

  void _pollTailFiles() {
    bool needsSetState = false;
    for (final tab in _tabs) {
      if (tab.mode == ViewMode.tail && !tab.meta.isTransient) {
        try {
          final f = File(tab.path);
          if (f.existsSync()) {
            final mtime = f.lastModifiedSync();
            if (tab.lastModified == null || mtime.isAfter(tab.lastModified!)) {
              tab.lastModified = mtime;
              tab.session.refresh();
              needsSetState = true;
              
              if (_activeTab == tab && tab.tailAutoScroll) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (tab.scrollController.hasClients) {
                    tab.scrollController.jumpTo(tab.scrollController.position.maxScrollExtent);
                  }
                });
              }
            }
          }
        } catch (e) {
          debugPrint('Error polling tail file: $e');
        }
      }
    }
    if (needsSetState && mounted) {
      setState(() {});
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
        setState(() {
          _tabs.add(TabRuntime(
            meta: DocumentMeta(
              id: DocumentMeta.newId(),
              displayName: name,
              path: path,
              viewMode: binary ? ViewMode.hex : ViewMode.read,
            ),
            session: session,
          ));
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
        _tabs.add(TabRuntime(
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
        ));
        _activeTabIndex = _tabs.length - 1;
        _isRibbonVisible = false;
        _newDocCounter++;
        _store?.setSetting(key: 'new_doc_counter', value: _newDocCounter.toString());
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
    }
    final base = newPath.split('/').last;
    final dot = base.lastIndexOf('.');
    if (!mounted) return;
    setState(() {
      tab.meta.path = newPath;
      tab.meta.displayName = base;
      tab.meta.isTransient = false;
      if (dot > 0) tab.meta.extension = base.substring(dot + 1);
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
        content: Text(savable
            ? 'This document has unsaved changes.'
            : 'This is an auto-delete document (${tab.meta.autoDelete.label}). '
                'Its changes will be lost.'),
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
        });
      }
      try {
        final f = File(oldPath);
        if (oldPath != newPath && f.existsSync()) f.deleteSync();
      } catch (_) {}
    } else {
      tab.session.save();
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
        _activeTab!.scrollController.jumpTo(currentOffset + _activeTab!.scrollController.position.viewportDimension);
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
        _activeTab!.scrollController.jumpTo(currentOffset - _activeTab!.scrollController.position.viewportDimension);
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.home) {
        if (HardwareKeyboard.instance.isControlPressed) {
          _activeTab!.scrollController.jumpTo(0.0);
          return KeyEventResult.handled;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.end) {
        if (HardwareKeyboard.instance.isControlPressed) {
          _activeTab!.scrollController.jumpTo(_activeTab!.scrollController.position.maxScrollExtent);
          return KeyEventResult.handled;
        }
      } else if (_activeTab!.mode == ViewMode.tail &&
          (event.logicalKey == LogicalKeyboardKey.keyT ||
           event.logicalKey == LogicalKeyboardKey.scrollLock)) {
        if (event is KeyDownEvent && !HardwareKeyboard.instance.isControlPressed) {
          setState(() {
            _activeTab!.tailAutoScroll = !_activeTab!.tailAutoScroll;
            if (_activeTab!.tailAutoScroll) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_activeTab!.scrollController.hasClients) {
                  _activeTab!.scrollController.jumpTo(_activeTab!.scrollController.position.maxScrollExtent);
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
        _findController.stepBackward();
      } else {
        _findController.stepForward();
      }
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isAltPressed && event.logicalKey == LogicalKeyboardKey.keyX) {
      setState(() {
        _isRibbonVisible = !_isRibbonVisible;
      });
      return KeyEventResult.handled;
    }
    if (!HardwareKeyboard.instance.isControlPressed) return KeyEventResult.ignored;
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
        _openFind(FindPanelMode.find);
        return KeyEventResult.handled;
      // Ctrl+R is the documented binding (shown in the Search menu); Ctrl+H is
      // kept as an unlisted alias for Notepad++ / VS Code muscle memory.
      case LogicalKeyboardKey.keyR:
      case LogicalKeyboardKey.keyH:
        _openFind(FindPanelMode.replace);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The live editor state for the active tab, or null when the active tab
  /// isn't in Edit mode (or isn't mounted yet).
  CustomEditorState? get _activeEditor =>
      (_activeTab?.mode == ViewMode.edit) ? _activeTab!.editorKey.currentState : null;

  /// Whether the docked find/tool bars are allowed to render for the active
  /// tab. Mirrors the editor-area if/else-if chain below (JwtToolView /
  /// HexEditorView / CustomEditor): the bars only make sense while a plain
  /// [CustomEditor] is the visible widget, i.e. edit mode and no jwt.* tool
  /// view is showing. Kept as a single getter so the next branch added to
  /// that chain only needs updating here, not on every bar guard.
  bool get _barsMayShow =>
      _activeTab?.mode == ViewMode.edit &&
      _activeTab?.activeTool?.startsWith('jwt') != true;

  /// Show the find panel in [mode], pointed at the active tab's document.
  void _openFind(FindPanelMode mode) {
    final tab = _activeTab;
    if (tab == null || tab.mode != ViewMode.edit) return;
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

  void _closeFind() {
    _viewportDebounce?.cancel();
    _findRefreshDebounce?.cancel();
    _viewportScanGen++; // invalidate any in-flight scan
    setState(() {
      _isFindVisible = false;
      _viewportMatches = const [];
    });
    _activeEditor?.focusEditor();
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
    if (!_isFindVisible) return;
    final tab = _activeTab;
    if (tab == null || tab.mode != ViewMode.edit) return;
    _findController.setLineCount(tab.session.lineCount().toInt());
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
      if (mounted && gen == _viewportScanGen) setState(() => _viewportMatches = const []);
      return;
    }
    final (first, last) = editor.visibleRowRange;
    if (first >= last) {
      if (mounted && gen == _viewportScanGen) setState(() => _viewportMatches = const []);
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
    if (!_isFindVisible) return;
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
    if (tab == null || (tab.mode != ViewMode.edit && tab.mode != ViewMode.hex)) return;
    // Auto-delete documents are ephemeral by design and must not save.
    if (tab.meta.autoDelete != AutoDelete.off) return;
    await _saveTab(tab);
    if (mounted) setState(() => _isRibbonVisible = false);
  }

  String _getNextUniqueNewDocName() {
    String name = 'new $_newDocCounter';
    while (_tabs.any((t) => t.name == name)) {
      _newDocCounter++;
      _store?.setSetting(key: 'new_doc_counter', value: _newDocCounter.toString());
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
    final Color tabBarColor = dark ? const Color(0xFF3B2E86) : const Color(0xFFCBE7FA);
    // Active tab lifts out of the strip.
    final Color activeTabColor = dark ? const Color(0xFF5B49B8) : Colors.white;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) => _handleGlobalShortcut(event),
      child: Scaffold(
      body: Column(
        children: [
          DragToMoveArea(
            child: Container(
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
                        ButtonSegment(value: 'exit', label: Text('<- Exit Tool')),
                        ButtonSegment(value: 'jwt.decode', label: Text('Decoder')),
                        ButtonSegment(value: 'jwt.encode', label: Text('Encoder')),
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
                        foregroundColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) {
                            return Theme.of(context).colorScheme.onSecondaryContainer;
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
                          icon: const Icon(Icons.arrow_back, size: 16, color: Colors.white),
                          label: const Text('Exit Tool', style: TextStyle(color: Colors.white)),
                          onPressed: () {
                            setState(() {
                              _activeTab!.activeTool = null;
                            });
                            _persistSession();
                          },
                        ),
                        const SizedBox(width: 12),
                        const Text('Tool', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      ],
                    )
                  else if (_activeTab?.mode == ViewMode.hex)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.arrow_back, size: 16, color: Colors.white),
                          label: const Text('Exit Hex', style: TextStyle(color: Colors.white)),
                          onPressed: () {
                            setState(() {
                              _activeTab!.mode = ViewMode.read;
                            });
                            _persistSession();
                          },
                        ),
                        const SizedBox(width: 12),
                        const Text('Hex Editor', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      ],
                    )
                  else
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: ViewMode.read, label: Text('Read')),
                        ButtonSegment(value: ViewMode.tail, label: Text('Tail')),
                        ButtonSegment(value: ViewMode.edit, label: Text('Edit')),
                      ],
                      selected: {_activeTab?.mode ?? ViewMode.read},
                      onSelectionChanged: (Set<String> newSelection) {
                        if (_activeTab != null) {
                          setState(() {
                            _activeTab!.mode = newSelection.first;
                            if (_activeTab!.mode == ViewMode.tail) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                 if (_activeTab!.scrollController.hasClients) {
                                   _activeTab!.scrollController.jumpTo(_activeTab!.scrollController.position.maxScrollExtent);
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
                  if (_activeTab?.mode == ViewMode.tail) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        _activeTab!.tailAutoScroll ? Icons.pause : Icons.vertical_align_bottom,
                        size: 20,
                      ),
                      tooltip: _activeTab!.tailAutoScroll ? 'Pause auto-scroll' : 'Resume auto-scroll',
                      onPressed: () {
                        setState(() {
                          _activeTab!.tailAutoScroll = !_activeTab!.tailAutoScroll;
                          if (_activeTab!.tailAutoScroll) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (_activeTab!.scrollController.hasClients) {
                                _activeTab!.scrollController.jumpTo(_activeTab!.scrollController.position.maxScrollExtent);
                              }
                            });
                          }
                        });
                      },
                    ),
                  ],
                  // Draggable filler; the outer DragToMoveArea makes it move
                  // the window. Window controls sit flush right, with the theme
                  // toggle immediately to the left of the minimize button.
                  const Spacer(),
                  ValueListenableBuilder<ThemeMode>(
                    valueListenable: themeNotifier,
                    builder: (context, mode, child) {
                      final brightness = mode == ThemeMode.dark ? Brightness.dark : Brightness.light;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(mode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode, size: 18),
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
                    }
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Column(
                  children: [
                    if (_isFindVisible && _barsMayShow)
                      FindPanel(
                        key: _findPanelKey,
                        controller: _findController,
                        onClose: _closeFind,
                        onReveal: (span) => _activeEditor?.revealSpan(span),
                      ),
                    if (_activeToolPanelId != null && _barsMayShow)
                      ToolBar(
                        panelId: _activeToolPanelId!,
                        editToolsEnabled: _activeEditor != null,
                        mimeToolsEnabled: _activeEditor != null,
                        mimeHasSelection:
                            _activeEditor?.hasLinearSelection ?? false,
                        onRunEditOp: _runEditOp,
                        onRunMimeOp: _runMimeOp,
                        onClose: _closeToolBar,
                      ),
                    if (_tabs.isNotEmpty)
                      Container(
                        height: 36,
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
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                decoration: BoxDecoration(
                                  color: isActive ? activeTabColor : Colors.transparent,
                                  border: isActive ? Border(bottom: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)) : null,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Auto-delete (scratch) tabs carry a trash-can
                                    // glyph so their ephemeral nature is obvious.
                                    if (tab.meta.autoDelete != AutoDelete.off) ...[
                                      Tooltip(
                                        message: 'Auto-delete: ${tab.meta.autoDelete.label}',
                                        child: Icon(Icons.delete_outline,
                                            size: 14,
                                            color: Theme.of(context).colorScheme.error.withOpacity(0.8)),
                                      ),
                                      const SizedBox(width: 4),
                                    ],
                                    Text(tab.name, style: TextStyle(fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                                    if (tab.isDirty) ...[
                                      const SizedBox(width: 4),
                                      const Icon(Icons.circle, size: 8, color: Colors.blueAccent),
                                    ],
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: () => _closeTabAt(index),
                                      child: const Icon(Icons.close, size: 16),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (_activeTab != null && _activeTab!.activeTool?.startsWith('jwt') == true)
                      Expanded(
                        child: JwtToolView(
                          key: ValueKey('jwt-${_activeTab!.meta.id}'),
                          initialEncoded: _activeTab!.session.contentString(),
                          mode: _activeTab!.activeTool == 'jwt.encode' ? JwtMode.encode : JwtMode.decode,
                        ),
                      )
                    else if (_activeTab != null && _activeTab!.mode == ViewMode.hex)
                      Expanded(
                        child: HexEditorView(
                          key: ValueKey('hex-${_activeTab!.meta.id}'),
                          session: _activeTab!.hexSession,
                          settings: HexViewSettings(
                            fontSize: _activeTab!.meta.fontSizeFor(ViewMode.hex),
                          ),
                          onFontSizeChanged: (size) =>
                              _setActiveFontSize(ViewMode.hex, size),
                          onContentChanged: () => setState(() {}),
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
                    else if (_activeTab != null && _activeTab!.mode == ViewMode.edit) ...[
                      Expanded(
                        child: CustomEditor(
                          key: _activeTab!.editorKey,
                          session: _activeTab!.session,
                          showLineNumbers: _showLineNumbers,
                          fontSize: _activeTab!.meta.fontSizeFor(ViewMode.edit),
                          onFontSizeChanged: (size) => _setActiveFontSize(ViewMode.edit, size),
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
                          matches: _isFindVisible ? _viewportMatches : const [],
                          currentMatch:
                              _isFindVisible ? _findController.currentMatch : null,
                          onViewportChanged:
                              _isFindVisible ? _scheduleViewportScan : null,
                        ),
                      ),
                    ]
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
                                      HardwareKeyboard.instance.isControlPressed) {
                                    _zoomActive(signal.scrollDelta.dy);
                                  }
                                },
                                child: SelectionArea(
                                  child: Scrollbar(
                                    controller: _activeTab!.scrollController,
                                    thumbVisibility: true,
                                    trackVisibility: true,
                                    child: ListView.builder(
                                      controller: _activeTab!.scrollController,
                                      itemCount: _activeTab!.lineCount,
                                      itemExtent: _rowHeightForMode(_activeTab!.mode),
                                      physics: _ctrlHeld
                                          ? const NeverScrollableScrollPhysics()
                                          : null,
                                      itemBuilder: (context, index) {
                                      try {
                                        final line = _activeTab!.session.line(vrow: BigInt.from(index));
                                        final textStyle = TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: _activeTab!.meta.fontSizeFor(_activeTab!.mode),
                                          fontWeight: FontWeight.w500,
                                          color: Theme.of(context).brightness == Brightness.light ? Colors.black : Colors.white,
                                        );
                                        
                                        if (!_showLineNumbers) {
                                          return Text(
                                            line,
                                            style: textStyle,
                                            maxLines: 1,
                                            softWrap: false,
                                          );
                                        }

                                        return Row(
                                          children: [
                                            Container(
                                              width: 60,
                                              padding: const EdgeInsets.only(right: 16),
                                              alignment: Alignment.centerRight,
                                              child: Text(
                                                '${index + 1}',
                                                style: textStyle.copyWith(color: Colors.grey),
                                              ),
                                            ),
                                            Expanded(
                                              child: Text(
                                                line,
                                                style: textStyle,
                                                maxLines: 1,
                                                softWrap: false,
                                              ),
                                            ),
                                          ],
                                        );
                                      } catch (e) {
                                        return const Text("Error reading line");
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                      ),
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
                      onOpen: _openFile,
                      onNew: () => _pendingNewPanel = false,
                      autoOpenNew: _pendingNewPanel,
                      newDocDefaultName: _getNextUniqueNewDocName(),
                      onCreateDocument: _createNewDocument,
                      onSave: (_activeTab != null &&
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
                      mimeToolsEnabled: _activeEditor != null,
                      mimeHasSelection: _activeEditor?.hasLinearSelection ?? false,
                      onRunMimeOp: _runMimeOp,
                      editToolsEnabled: _activeEditor != null,
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
                          _persistSession();
                        }
                      },
                      onSaveAs: _activeTab != null ? _saveFileAs : null,
                      onCloseOtherTabs: _tabs.length > 1 ? _closeOtherTabs : null,
                      onCloseTabsToRight:
                          (_activeTab != null && _activeTabIndex < _tabs.length - 1)
                              ? _closeTabsToRight
                              : null,
                      onCopyFileName: _activeTab != null ? _copyFileName : null,
                      onCopyFilePath: _activeTab != null ? _copyFilePath : null,
                      onFind: _activeTab?.mode == ViewMode.edit
                          ? () {
                              setState(() => _isRibbonVisible = false);
                              _openFind(FindPanelMode.find);
                            }
                          : null,
                      onReplace: _activeTab?.mode == ViewMode.edit
                          ? () {
                              setState(() => _isRibbonVisible = false);
                              _openFind(FindPanelMode.replace);
                            }
                          : null,
                      currentAutoDelete: _activeTab?.meta.autoDelete,
                      onSetAutoDelete: _activeTab != null ? _setAutoDelete : null,
                      onCloseTab: _activeTab != null ? _closeActiveTab : null,
                      onOpenToolBar: _openToolBar,
                    ),
                  ),
              ],
            ),
          ),
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
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
                        margin: const EdgeInsets.symmetric(horizontal: 12)
                      );

                      return Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (w > 700) ...[
                             Text(_activeTab?.meta.contentType ?? 'Normal text file', style: const TextStyle(fontSize: 12)),
                             sep,
                          ],
                          if (w > 600) ...[
                             Text('length: ?  lines: ${_activeTab?.lineCount ?? 0}', style: const TextStyle(fontSize: 12)),
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
                                String sel = stats.selChars > 0 ? "  Sel: ${stats.selChars} | ${stats.selLines}" : "";
                                return Text('Ln: ${stats.row}  Col: ${stats.col}$sel', style: const TextStyle(fontSize: 12));
                              }
                            ),
                            sep,
                          ],
                          if (w > 400) ...[
                            const Text('Windows (CR LF)', style: TextStyle(fontSize: 12)),
                            sep,
                            const Text('UTF-8', style: TextStyle(fontSize: 12)),
                            sep,
                            const Text('INS', style: TextStyle(fontSize: 12)),
                          ]
                        ]
                      );
                    }
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:io';
import 'package:textutilz/src/rust/api/file_manager.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/store.dart';
import 'package:textutilz/src/rust/api/paths.dart' as rust_paths;
import 'package:textutilz/src/rust/frb_generated.dart';
import 'editor.dart';
import 'menu_ribbon.dart';
import 'mime_tools_panel.dart';
import 'document_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
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
        _restoreSession(_store!);
      } catch (e) {
        debugPrint('session restore failed: $e');
      }
    }
    _scheduleMidnightCleanup();
    _tailTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) => _pollTailFiles());
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

  @override
  void dispose() {
    _tailTimer?.cancel();
    _midnightTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    windowManager.removeListener(this);
    _focusNode.dispose();
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
        return;
      }
      try {
        final session = EditSession.open(path: path);
        String name = path.split('/').last;
        setState(() {
          _tabs.add(TabRuntime(
            meta: DocumentMeta(
              id: DocumentMeta.newId(),
              displayName: name,
              path: path,
              viewMode: ViewMode.read,
            ),
            session: session,
          ));
          _activeTabIndex = _tabs.length - 1;
        });
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
      });
      _focusNode.requestFocus();
      _persistSession();
    } catch (e) {
      debugPrint('Error creating new document: $e');
    }
  }

  void _closeActiveTab() => _closeTabAt(_activeTabIndex);

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
    }
    return KeyEventResult.ignored;
  }

  /// The live editor state for the active tab, or null when the active tab
  /// isn't in Edit mode (or isn't mounted yet).
  CustomEditorState? get _activeEditor =>
      (_activeTab?.mode == ViewMode.edit) ? _activeTab!.editorKey.currentState : null;

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
    if (tab == null || tab.mode != ViewMode.edit) return;
    // Auto-delete documents are ephemeral by design and must not save.
    if (tab.meta.autoDelete != AutoDelete.off) return;
    await _saveTab(tab);
    if (mounted) setState(() => _isRibbonVisible = false);
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
                    tooltip: 'Menu',
                  ),
                  const SizedBox(width: 8),
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
                    if (_activeTab != null && _activeTab!.mode == ViewMode.edit)
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
                          },
                          // Dirtiness lives in the session; repaint the tab dot.
                          onContentChanged: () => setState(() {}),
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
                      newDocDefaultName: 'new $_newDocCounter',
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
                      onCloseTab: _activeTab != null ? _closeActiveTab : null,
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

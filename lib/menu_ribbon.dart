import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:textutilz/src/rust/api/commands.dart';
import 'document_state.dart';
import 'mime_tools_panel.dart';
import 'edit_tools_panel.dart';
import 'tool_bar.dart';
class MenuEntry {
  final String label;
  final IconData icon;

  /// When null, the entry renders as a disabled placeholder.
  final VoidCallback? onPressed;

  /// A command descriptor that this entry might correspond to.
  final CommandDescriptor? command;

  /// Optional keyboard shortcut hint (e.g. "Ctrl+O"), shown right-aligned.
  final String? shortcut;

  /// When non-null, the entry is a toggle: it renders a trailing switch
  /// reflecting this value, and [onPressed] flips it. Mutually exclusive with
  /// [shortcut] in the trailing slot.
  final bool? toggled;

  /// When true, this entry is a non-interactive sub-header dividing groups of
  /// items within a single column (e.g. "Current tab" under File).
  final bool isHeader;

  const MenuEntry({
    required this.label,
    required this.icon,
    this.onPressed,
    this.command,
    this.shortcut,
    this.toggled,
    this.isHeader = false,
  });

  /// A sub-header row grouping the items that follow it within a column.
  const MenuEntry.header(this.label)
      : icon = Icons.remove,
        onPressed = null,
        command = null,
        shortcut = null,
        toggled = null,
        isHeader = true;
}

/// A menu column: an accent-colored header above a vertical stack of entries.
class MenuColumn {
  final String title;
  final Color accent;
  final List<MenuEntry> entries;

  const MenuColumn({
    required this.title,
    required this.accent,
    required this.entries,
  });
}

/// The ribbon overlay: a search field on top, and below it either the
/// menu table (columns of stacked items) or, once the search field has
/// text, a stub search-results panel.
class MenuRibbon extends StatefulWidget {
  final VoidCallback? onOpen;
  final VoidCallback? onSave;
  final VoidCallback? onCloseTab;

  /// Edit actions. Null disables (dims) the corresponding menu entry — e.g.
  /// Undo is null when there is nothing to undo, Copy/Cut when there is no
  /// selection, and all of them when the active tab isn't in Edit mode.
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onCut;
  final VoidCallback? onCopy;
  final VoidCallback? onPaste;

  /// View toggles (line numbers / word wrap) and their current state. The
  /// callback flips the state on the host; the bool drives the switch.
  final bool showLineNumbers;
  final bool wordWrap;
  final VoidCallback? onToggleLineNumbers;
  final VoidCallback? onToggleWordWrap;

  /// MIME tools: whether an editor is available to transform, whether it
  /// currently has a (linear) selection to scope to, and the runner invoked
  /// with the chosen operation when the user presses GO.
  final bool mimeToolsEnabled;
  final bool mimeHasSelection;
  final ValueChanged<MimeOp>? onRunMimeOp;

  /// NPP Edit tools properties.
  final bool editToolsEnabled;
  final ValueChanged<EditOp>? onRunEditOp;

  /// Optional hook fired when the New panel is opened.
  final VoidCallback? onNew;

  /// When true, the ribbon opens directly into its New-document panel
  /// (used by the Ctrl+N shortcut).
  final bool autoOpenNew;

  /// Prefilled name for a new document (e.g. "new 3").
  final String newDocDefaultName;

  /// Called when the user confirms creation of a new document.
  final ValueChanged<NewDocumentRequest>? onCreateDocument;

  /// Notifies the host of the current search query (empty string when cleared).
  final ValueChanged<String>? onSearchChanged;

  /// Invoked when a tool mode should be activated for the current tab.
  final ValueChanged<String>? onEnterToolMode;

  /// Invoked when the current tab should switch to the hex editor view.
  final VoidCallback? onEnterHex;

  // Current-tab actions (null disables the entry).
  final VoidCallback? onSaveAs;
  final VoidCallback? onCloseOtherTabs;
  final VoidCallback? onCloseTabsToRight;
  final VoidCallback? onCopyFileName;
  final VoidCallback? onCopyFilePath;

  /// Open the find/replace panel in Find or Replace mode.
  final VoidCallback? onFind;
  final VoidCallback? onReplace;

  /// The active tab's current auto-delete policy (for the Auto-delete panel's
  /// selected radio), and the setter invoked when the user picks one.
  final AutoDelete? currentAutoDelete;
  final ValueChanged<AutoDelete>? onSetAutoDelete;

  /// Opens a tool panel as a docked bar instead of an in-ribbon panel.
  /// Only called for ids `ToolBar.handles` claims.
  final ValueChanged<String>? onOpenToolBar;

  const MenuRibbon({
    super.key,
    this.onOpen,
    this.onSave,
    this.onCloseTab,
    this.onUndo,
    this.onRedo,
    this.onCut,
    this.onCopy,
    this.onPaste,
    this.showLineNumbers = false,
    this.wordWrap = false,
    this.onToggleLineNumbers,
    this.onToggleWordWrap,
    this.mimeToolsEnabled = false,
    this.mimeHasSelection = false,
    this.onRunMimeOp,
    this.editToolsEnabled = false,
    this.onRunEditOp,
    this.onNew,
    this.autoOpenNew = false,
    this.newDocDefaultName = 'new 1',
    this.onCreateDocument,
    this.onSearchChanged,
    this.onEnterToolMode,
    this.onEnterHex,
    this.onSaveAs,
    this.onCloseOtherTabs,
    this.onCloseTabsToRight,
    this.onCopyFileName,
    this.onCopyFilePath,
    this.onFind,
    this.onReplace,
    this.currentAutoDelete,
    this.onSetAutoDelete,
    this.onOpenToolBar,
  });

  @override
  State<MenuRibbon> createState() => _MenuRibbonState();
}

class _MenuRibbonState extends State<MenuRibbon> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';
  int? _hoveredColumn;
  late final CommandRegistry _registry;

  @override
  void initState() {
    super.initState();
    _registry = getCommandRegistry();
    // Esc clears the search field when it has text.
    _searchFocus.onKeyEvent = _handleSearchKey;
    if (widget.autoOpenNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cmd = _registry.commands.cast<CommandDescriptor?>().firstWhere((c) => c?.id == 'file.new', orElse: () => null);
        if (cmd != null) _openCommandPanel(cmd);
      });
    } else {
      // Focus the search field as soon as the ribbon appears.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _activeCommand == null) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(MenuRibbon oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ribbon already visible and Ctrl+N pressed: jump to the New panel.
    if (!oldWidget.autoOpenNew && widget.autoOpenNew && _activeCommand == null) {
      final cmd = _registry.commands.cast<CommandDescriptor?>().firstWhere((c) => c?.id == 'file.new', orElse: () => null);
      if (cmd != null) _openCommandPanel(cmd);
    }
  }

  /// When non-null, the ribbon shows a full-width panel (with a back button)
  /// instead of the search field + menu table.
  CommandDescriptor? _activeCommand;

  void _openCommandPanel(CommandDescriptor cmd) {
    final id = cmd.panelId;
    if (id != null && ToolBar.handles(id)) {
      // These panels no longer have an in-ribbon build path, so falling
      // through without a host callback would render an empty panel with no
      // way back. Better to do nothing.
      widget.onOpenToolBar?.call(id);
      return;
    }
    setState(() => _activeCommand = cmd);
    if (cmd.id == 'file.new') widget.onNew?.call();
  }

  void _closePanel() => setState(() => _activeCommand = null);

  // Accent colors, tuned to read well in both light and dark themes.
  static const Color _fileAccent = Color(0xFF4F8FF7); // blue
  static const Color _editAccent = Color(0xFF19C6A6); // teal
  static const Color _searchAccent = Color(0xFF9B6DFF); // violet
  static const Color _viewAccent = Color(0xFFF2A83B); // amber
  static const Color _toolsAccent = Color(0xFF5FB861); // green

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    widget.onSearchChanged?.call(value);
  }

  /// Clears the search field on Esc (only while it has text, so an empty-field
  /// Esc still bubbles up to whatever wants to close the ribbon).
  KeyEventResult _handleSearchKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _query.isNotEmpty) {
      _searchController.clear();
      _onQueryChanged('');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  IconData _parseIcon(String? iconName) {
    switch (iconName) {
      case 'note_add': return Icons.note_add;
      case 'folder_open': return Icons.folder_open;
      case 'save': return Icons.save;
      case 'tab_unselected': return Icons.tab_unselected;
      case 'undo': return Icons.undo;
      case 'redo': return Icons.redo;
      case 'content_cut': return Icons.content_cut;
      case 'content_copy': return Icons.content_copy;
      case 'content_paste': return Icons.content_paste;
      case 'search': return Icons.search;
      case 'find_replace': return Icons.find_replace;
      case 'my_location': return Icons.my_location;
      case 'format_list_numbered': return Icons.format_list_numbered;
      case 'wrap_text': return Icons.wrap_text;
      case 'transform': return Icons.transform;
      case 'format_size': return Icons.format_size;
      case 'keyboard_return': return Icons.keyboard_return;
      case 'space_bar': return Icons.space_bar;
      case 'comment': return Icons.comment;
      case 'memory': return Icons.memory;
      case 'save_as': return Icons.save_as;
      case 'clear_all': return Icons.clear_all;
      case 'keyboard_tab': return Icons.keyboard_tab;
      case 'drive_file_rename_outline': return Icons.drive_file_rename_outline;
      case 'folder_copy': return Icons.folder_copy;
      case 'auto_delete': return Icons.auto_delete;
      default: return Icons.extension;
    }
  }

  VoidCallback? _getAction(String? actionId) {
    switch (actionId) {
      case 'file.open': return widget.onOpen;
      case 'file.save': return widget.onSave;
      case 'file.close': return widget.onCloseTab;
      case 'edit.undo': return widget.onUndo;
      case 'edit.redo': return widget.onRedo;
      case 'edit.cut': return widget.onCut;
      case 'edit.copy': return widget.onCopy;
      case 'edit.paste': return widget.onPaste;
      case 'view.linenumbers': return widget.onToggleLineNumbers;
      case 'view.wordwrap': return widget.onToggleWordWrap;
      case 'tools.jwt': return widget.onEnterToolMode != null ? () => widget.onEnterToolMode!('jwt.decode') : null;
      case 'tools.hex': return widget.onEnterHex;
      case 'file.saveas': return widget.onSaveAs;
      case 'tab.closeothers': return widget.onCloseOtherTabs;
      case 'tab.closeright': return widget.onCloseTabsToRight;
      case 'tab.copyname': return widget.onCopyFileName;
      case 'tab.copypath': return widget.onCopyFilePath;
      case 'search.find': return widget.onFind;
      case 'search.replace': return widget.onReplace;
      default: return null;
    }
  }

  /// Whether a ribbon entry may be clicked right now.
  ///
  /// Entries that open a docked BAR must be disabled when that bar cannot
  /// render (not Edit mode, or a jwt/hex view is showing): the click would
  /// otherwise close the ribbon and do nothing visible, and the explanation
  /// the bar carries ("Open a document in Edit mode to run MIME tools.") would
  /// never be reachable on exactly the path that needs it.
  ///
  /// Keyed on [ToolBar.handles] rather than a hand-written id prefix list —
  /// the prefix check this replaces covered `edit.*` and silently omitted
  /// every `mime.*` entry. Panels that stay INSIDE the ribbon ('mime', 'new',
  /// 'autodelete') render their own disabled explanation and stay clickable.
  bool _entryEnabled(CommandDescriptor cmd) {
    final panel = cmd.panelId;
    if (panel == null || !ToolBar.handles(panel)) return true;
    return panel.startsWith('mime.')
        ? widget.mimeToolsEnabled
        : widget.editToolsEnabled;
  }

  /// The tap handler for a command, or null when it is disabled.
  VoidCallback? _entryAction(CommandDescriptor cmd) {
    if (!_entryEnabled(cmd)) return null;
    return cmd.panelId != null
        ? () => _openCommandPanel(cmd)
        : _getAction(cmd.actionId);
  }

  List<MenuColumn> get _columns {
    MenuEntry entry(String id) {
      final cmd = _registry.commands.firstWhere((c) => c.id == id);
      return MenuEntry(
        label: cmd.title,
        icon: _parseIcon(cmd.icon),
        shortcut: cmd.shortcut,
        toggled: cmd.id == 'view.linenumbers' ? widget.showLineNumbers :
                 cmd.id == 'view.wordwrap' ? widget.wordWrap : cmd.toggled,
        command: cmd,
        onPressed: _entryAction(cmd),
      );
    }
    return [
        MenuColumn(
          title: 'File',
          accent: _fileAccent,
          entries: [
            entry('file.new'),
            entry('file.open'),
            const MenuEntry.header('Current tab'),
            entry('file.save'),
            entry('file.saveas'),
            entry('file.close'),
            entry('tab.closeothers'),
            entry('tab.closeright'),
            entry('tab.copyname'),
            entry('tab.copypath'),
            entry('tab.autodelete'),
          ],
        ),
        MenuColumn(
          title: 'Edit',
          accent: _editAccent,
          entries: [
            entry('edit.undo'),
            entry('edit.redo'),
            entry('edit.cut'),
            entry('edit.copy'),
            entry('edit.paste'),
            entry('edit.case'),
            entry('edit.eol'),
            entry('edit.blank'),
            entry('edit.comment'),
          ],
        ),
        MenuColumn(
          title: 'Search',
          accent: _searchAccent,
          entries: [
            entry('search.find'),
            entry('search.replace'),
            entry('search.goto'),
          ],
        ),
        MenuColumn(
          title: 'View',
          accent: _viewAccent,
          entries: [
            entry('view.linenumbers'),
            entry('view.wordwrap'),
          ],
        ),
        MenuColumn(
          title: 'Tools',
          accent: _toolsAccent,
          entries: [
            entry('tools.mime'),
            entry('tools.jwt'),
            entry('tools.hex'),
          ],
        ),
      ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      child: Container(
        width: double.infinity,
        color: scheme.surfaceContainer,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: _activeCommand != null && _activeCommand!.panelId != null
              ? _buildPanelContent(_activeCommand!, scheme)
              : Column(
                  key: const ValueKey('normal'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSearchField(scheme),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      // Pin swapped children to the left instead of the
                      // AnimatedSwitcher's default centered Stack, so the menu
                      // blocks stay left-aligned.
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      ),
                      child: _query.isEmpty
                          ? SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: _buildMenuTable(scheme),
                            )
                          : _buildResultsPanel(scheme),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget? _buildPanelContent(CommandDescriptor cmd, ColorScheme scheme) {
    switch (cmd.panelId) {
      case 'new':
        return RibbonPanelScaffold(
          key: const ValueKey('panel-new'),
          title: 'New document',
          onBack: _closePanel,
          scheme: scheme,
          child: NewDocumentForm(
            defaultName: widget.newDocDefaultName,
            onCancel: _closePanel,
            onCreate: (req) => widget.onCreateDocument?.call(req),
          ),
        );
      case 'mime':
        return RibbonPanelScaffold(
          key: const ValueKey('panel-mime'),
          title: 'MIME tools',
          onBack: _closePanel,
          scheme: scheme,
          child: MimeToolsPanel(
            enabled: widget.mimeToolsEnabled,
            hasSelection: widget.mimeHasSelection,
            onRun: (op) => widget.onRunMimeOp?.call(op),
          ),
        );
      // The 11 mime.*/edit.* panel ids do NOT appear here: _openCommandPanel
      // hands every id ToolBar.handles() to onOpenToolBar and returns, so
      // _activeCommand is never set for them. Their titles now live in exactly
      // one place, ToolBar._editSpecs/_mimeSpecs.
      case 'autodelete':
        return RibbonPanelScaffold(
          key: const ValueKey('panel-autodelete'),
          title: 'Auto-delete',
          onBack: _closePanel,
          scheme: scheme,
          child: AutoDeletePanel(
            current: widget.currentAutoDelete,
            onChanged: widget.onSetAutoDelete,
          ),
        );
      default:
        return null;
    }
  }

  Widget _buildSearchField(ColorScheme scheme) {
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        autofocus: true,
        onChanged: _onQueryChanged,
        textAlignVertical: TextAlignVertical.center,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search…',
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  splashRadius: 16,
                  onPressed: () {
                    _searchController.clear();
                    _onQueryChanged('');
                  },
                ),
          filled: true,
          fillColor: scheme.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuTable(ColorScheme scheme) {
    final columns = _columns;
    // Columns size their width to their own content (see _MenuColumnCard).
    // IntrinsicHeight + stretch makes every card as tall as the tallest one
    // (menu items stay top-aligned inside). The Row packs them to the left.
    return IntrinsicHeight(
      key: const ValueKey('menu-table'),
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < columns.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          MouseRegion(
            onEnter: (_) => setState(() => _hoveredColumn = i),
            onExit: (_) => setState(() => _hoveredColumn = null),
            child: _MenuColumnCard(
              column: columns[i],
              // Resting when nothing hovered; full when this one is
              // hovered; dimmed when a sibling is hovered.
              emphasis: _hoveredColumn == null
                  ? 0.72
                  : (_hoveredColumn == i ? 1.0 : 0.32),
              scheme: scheme,
            ),
          ),
        ],
      ],
      ),
    );
  }

  Color _getCategoryAccent(String category) {
    switch (category) {
      case 'File': return _fileAccent;
      case 'Edit': return _editAccent;
      case 'Search': return _searchAccent;
      case 'View': return _viewAccent;
      case 'Tools':
      case 'MIME Tools': return _toolsAccent;
      default: return _toolsAccent;
    }
  }

  Widget _buildResultsPanel(ColorScheme scheme) {
    final results = _registry.search(query: _query);

    return Container(
      key: const ValueKey('results-panel'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120, maxHeight: 300),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Results for "$_query"',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (results.isEmpty)
            Row(
              children: [
                Icon(Icons.search_off, size: 16, color: scheme.outline),
                const SizedBox(width: 8),
                Text(
                  'No commands found.',
                  style: TextStyle(fontSize: 13, color: scheme.outline),
                ),
              ],
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final cmd = results[index];
                  final accent = _getCategoryAccent(cmd.category);
                  return _MenuEntryTile(
                    entry: MenuEntry(
                      label: cmd.title,
                      icon: _parseIcon(cmd.icon),
                      shortcut: cmd.shortcut,
                      toggled: cmd.id == 'view.linenumbers' ? widget.showLineNumbers :
                               cmd.id == 'view.wordwrap' ? widget.wordWrap : cmd.toggled,
                      command: cmd,
                      // Same enablement gate as the menu table: without it the
                      // search box was a back door to tool bars that cannot
                      // render.
                      onPressed: _entryAction(cmd),
                    ),
                    accent: accent,
                    scheme: scheme,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// A single column rendered as a soft card: accent header + stacked entries.
/// [emphasis] (0..1) drives the hover dim/highlight animation.
class _MenuColumnCard extends StatelessWidget {
  static const double _minColumnWidth = 92;
  static const double _maxColumnWidth = 240;

  final MenuColumn column;
  final double emphasis;
  final ColorScheme scheme;

  const _MenuColumnCard({
    required this.column,
    required this.emphasis,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: 0.4 + 0.6 * emphasis,
      // Width hugs the widest item, clamped between _minColumnWidth and
      // _maxColumnWidth. IntrinsicWidth sizes the card to its content; the
      // clamp caps it so an over-long item ellipsizes instead of stretching.
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: _minColumnWidth,
          maxWidth: _maxColumnWidth,
        ),
        child: IntrinsicWidth(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                column.accent.withOpacity(0.05 + 0.09 * emphasis),
                scheme.surface,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: column.accent.withOpacity(0.25 + 0.5 * emphasis),
                width: 1,
              ),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(
                    column.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: column.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                for (final entry in column.entries)
                  if (entry.isHeader)
                    _MenuSubHeader(
                        label: entry.label, accent: column.accent, scheme: scheme)
                  else
                    _MenuEntryTile(
                        entry: entry, accent: column.accent, scheme: scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One menu row: leading icon + label. Disabled (dimmed) when [entry.onPressed]
/// is null.
class _MenuEntryTile extends StatelessWidget {
  final MenuEntry entry;
  final Color accent;
  final ColorScheme scheme;

  const _MenuEntryTile({
    required this.entry,
    required this.accent,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = entry.onPressed != null;
    final Color fg = enabled ? scheme.onSurface : scheme.onSurface.withOpacity(0.38);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: entry.onPressed,
          hoverColor: accent.withOpacity(0.12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                Icon(entry.icon, size: 16, color: enabled ? accent : fg),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: fg),
                  ),
                ),
                if (entry.toggled != null) ...[
                  const SizedBox(width: 10),
                  // Display-only: the row's InkWell handles the toggle so a tap
                  // anywhere on the entry flips it.
                  IgnorePointer(
                    child: Transform.scale(
                      scale: 0.7,
                      child: Switch(
                        value: entry.toggled!,
                        activeThumbColor: accent,
                        onChanged: (_) {},
                      ),
                    ),
                  ),
                ] else if (entry.shortcut != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    entry.shortcut!,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(enabled ? 0.5 : 0.3),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sub-header dividing groups of items within a single column. A thin rule
/// plus a dimmed accent label (e.g. "Current tab" under the File column).
class _MenuSubHeader extends StatelessWidget {
  final String label;
  final Color accent;
  final ColorScheme scheme;

  const _MenuSubHeader({
    required this.label,
    required this.accent,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, thickness: 1, color: accent.withOpacity(0.2)),
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 6, bottom: 2),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: accent.withOpacity(0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Generic full-width ribbon panel: a back button + title header above an
/// arbitrary child. Reused by every menu item that swaps out the ribbon.
class RibbonPanelScaffold extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final Widget child;
  final ColorScheme scheme;

  const RibbonPanelScaffold({
    super.key,
    required this.title,
    required this.onBack,
    required this.child,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: 'Back',
              onPressed: onBack,
            ),
            const SizedBox(width: 4),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

/// Auto-delete policy picker for the active tab, shown inside a
/// [RibbonPanelScaffold]. Applies immediately on selection (like the edit
/// tool panels). Disabled when there is no active tab ([onChanged] is null).
class AutoDeletePanel extends StatelessWidget {
  final AutoDelete? current;
  final ValueChanged<AutoDelete>? onChanged;

  const AutoDeletePanel({super.key, required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete this document automatically:',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            for (final option in AutoDelete.values)
              RadioListTile<AutoDelete>(
                value: option,
                groupValue: current ?? AutoDelete.off,
                onChanged: enabled ? (v) => onChanged!(v ?? AutoDelete.off) : null,
                title: Text(option.label, style: const TextStyle(fontSize: 13)),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
        ),
      ),
    );
  }
}

/// The "New document" form shown inside a [RibbonPanelScaffold].
class NewDocumentForm extends StatefulWidget {
  final String defaultName;
  final VoidCallback onCancel;
  final ValueChanged<NewDocumentRequest> onCreate;

  const NewDocumentForm({
    super.key,
    required this.defaultName,
    required this.onCancel,
    required this.onCreate,
  });

  @override
  State<NewDocumentForm> createState() => _NewDocumentFormState();
}

class _NewDocumentFormState extends State<NewDocumentForm> {
  late final TextEditingController _nameController;
  final TextEditingController _typeController =
      TextEditingController(text: 'Plain Text');
  final FocusNode _typeFocus = FocusNode();
  final TextEditingController _extController = TextEditingController(text: 'txt');
  AutoDelete _autoDelete = AutoDelete.off;

  /// Common content types offered as autocomplete suggestions.
  static const List<String> _contentTypes = [
    'Plain Text',
    'Markdown',
    'JSON',
    'YAML',
    'XML',
    'HTML',
    'CSS',
    'JavaScript',
    'TypeScript',
    'Dart',
    'Rust',
    'Python',
    'Java',
    'C',
    'C++',
    'Go',
    'Shell',
    'SQL',
    'CSV',
    'Log',
    'INI',
    'TOML',
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.defaultName);
  }

  @override
  void didUpdateWidget(NewDocumentForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.defaultName != widget.defaultName) {
      _nameController.text = widget.defaultName;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _typeController.dispose();
    _typeFocus.dispose();
    _extController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    widget.onCreate(NewDocumentRequest(
      name: name,
      contentType: _typeController.text.trim().isEmpty
          ? 'Plain Text'
          : _typeController.text.trim(),
      extension: _extController.text.trim().isEmpty
          ? 'txt'
          : _extController.text.trim(),
      autoDelete: _autoDelete,
    ));
  }

  InputDecoration _dec(ColorScheme scheme, String label) => InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  /// Content-type field with autocomplete over [_contentTypes]. Uses
  /// RawAutocomplete so [_typeController] stays the single source of truth.
  Widget _buildContentTypeField(ColorScheme scheme) {
    return RawAutocomplete<String>(
      textEditingController: _typeController,
      focusNode: _typeFocus,
      optionsBuilder: (TextEditingValue value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return _contentTypes;
        return _contentTypes.where((t) => t.toLowerCase().contains(q));
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: _dec(scheme, 'Content type'),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final list = options.toList();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final option = list[i];
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Text(option, style: const TextStyle(fontSize: 13)),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameController,
          decoration: _dec(scheme, 'Document name'),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: _buildContentTypeField(scheme),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _extController,
                decoration: _dec(scheme, 'Ext'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Auto-delete',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant)),
        for (final option in AutoDelete.values)
          RadioListTile<AutoDelete>(
            value: option,
            groupValue: _autoDelete,
            onChanged: (v) => setState(() => _autoDelete = v ?? AutoDelete.off),
            title: Text(option.label, style: const TextStyle(fontSize: 13)),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Create'),
            ),
          ],
        ),
      ],
      ),
      ),
    );
  }
}

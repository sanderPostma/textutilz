import 'package:flutter/material.dart';

import 'docked_bar.dart';
import 'edit_tools_panel.dart';
import 'goto_line_panel.dart';
import 'markup_styling.dart';
import 'src/rust/api/structured.dart';
import 'mime_tools_panel.dart';
import 'structured_tools_panel.dart';

/// One row of tool controls, docked above the editor.
///
/// Maps a ribbon `panelId` to its title and content. Only the MIME, edit,
/// and go-to-line panels become bars — `new` and `autodelete` are forms and
/// stay inside the ribbon, which is what [handles] distinguishes.
class ToolBar extends StatefulWidget {
  final String panelId;
  final bool editToolsEnabled;
  final bool mimeToolsEnabled;
  final bool mimeHasSelection;
  final ValueChanged<EditOp> onRunEditOp;
  final ValueChanged<MimeOp> onRunMimeOp;
  final ValueChanged<StructuredTextOp> onRunStructuredOp;
  final VoidCallback onClose;
  final int lineCount;
  final int currentLine;
  final ValueChanged<int>? onGotoLine;

  const ToolBar({
    super.key,
    required this.panelId,
    required this.editToolsEnabled,
    required this.mimeToolsEnabled,
    required this.mimeHasSelection,
    required this.onRunEditOp,
    required this.onRunMimeOp,
    required this.onRunStructuredOp,
    required this.onClose,
    this.lineCount = 1,
    this.currentLine = 1,
    this.onGotoLine,
    this.structuredUseJson5 = false,
    this.onStructuredUseJson5Changed,
    this.structuredAutoValidate = false,
    this.onStructuredAutoValidateChanged,
  });

  /// JSON bar: whether the JSON5 dialect switch is on.
  final bool structuredUseJson5;
  final ValueChanged<bool>? onStructuredUseJson5Changed;

  /// Structured bars: whether the document is revalidated after typing stops.
  final bool structuredAutoValidate;
  final ValueChanged<bool>? onStructuredAutoValidateChanged;

  @override
  State<ToolBar> createState() => _ToolBarState();

  /// The aggregate MIME tools bar: all four categories as tabs in one bar.
  /// This is the menu's MIME entry; the per-operation ids below are reachable
  /// from ribbon search when the user knows exactly which one they want.
  static const String mimeAllId = 'mime';

  /// Go to line bar id.
  static const String gotoId = 'search.goto';

  /// Panel ids that dock as a bar. Everything else stays in the ribbon.
  static bool handles(String panelId) =>
      panelId == gotoId ||
      panelId == mimeAllId ||
      _editSpecs.containsKey(panelId) ||
      _structuredSpecs.containsKey(panelId) ||
      _mimeSpecs.containsKey(panelId);

  static const Map<String, StructuredLanguage> _structuredSpecs = {
    'structured.json': StructuredLanguage.json,
    'structured.yaml': StructuredLanguage.yaml,
    'structured.xml': StructuredLanguage.xml,
  };

  static const Map<String, (EditCategory, String)> _editSpecs = {
    'edit.case': (EditCategory.caseConv, 'Convert Case'),
    'edit.eol': (EditCategory.eolConv, 'EOL Conversion'),
    'edit.blank': (EditCategory.blankOps, 'Blank Operations'),
    'edit.comment': (EditCategory.commentOps, 'Comment/Uncomment'),
  };

  static const Map<String, (MimeCategory, bool, String)> _mimeSpecs = {
    'mime.base64.encode': (MimeCategory.base64, false, 'Base64 Encode'),
    'mime.base64.decode': (MimeCategory.base64, true, 'Base64 Decode'),
    'mime.qp.encode': (
      MimeCategory.quotedPrintable,
      false,
      'Quoted-printable Encode',
    ),
    'mime.qp.decode': (
      MimeCategory.quotedPrintable,
      true,
      'Quoted-printable Decode',
    ),
    'mime.url.encode': (MimeCategory.url, false, 'URL Encode'),
    'mime.url.decode': (MimeCategory.url, true, 'URL Decode'),
    'mime.saml.decode': (MimeCategory.saml, true, 'SAML Decode'),
  };
}

class _ToolBarState extends State<ToolBar> {
  /// Which face a single-operation MIME bar is showing.
  ///
  /// Lives here rather than in [SingleMimeToolPanel] because the docked bar's
  /// title has to track it: the panel used to own the flag, so tapping Decode
  /// changed the Apply label while the tab above still read "Base64 Encode".
  /// Null until the user touches the selector, so the bar opens on whichever
  /// face its menu entry named.
  bool? _decode;

  /// The bar's current decode state: the user's choice if they made one,
  /// otherwise the face the panel id asked for.
  bool _decodeFor(bool fromId) => _decode ?? fromId;

  @override
  void didUpdateWidget(ToolBar old) {
    super.didUpdateWidget(old);
    // A different tool is now docked, so a choice made in the previous one
    // must not carry over — mime.url.encode should open on Encode even if the
    // user last left the Base64 bar on Decode.
    if (old.panelId != widget.panelId) _decode = null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.panelId == ToolBar.gotoId) {
      return DockedBar(
        title: 'Go to Line',
        onClose: widget.onClose,
        child: GotoLinePanel(
          lineCount: widget.lineCount,
          currentLine: widget.currentLine,
          onGotoLine: widget.onGotoLine ?? (_) {},
          onClose: widget.onClose,
        ),
      );
    }
    final edit = ToolBar._editSpecs[widget.panelId];
    if (edit != null) {
      return DockedBar(
        title: edit.$2,
        onClose: widget.onClose,
        child: EditToolsPanel(
          enabled: widget.editToolsEnabled,
          category: edit.$1,
          onRun: widget.onRunEditOp,
        ),
      );
    }
    if (widget.panelId == ToolBar.mimeAllId) {
      return DockedBar(
        title: 'MIME tools',
        onClose: widget.onClose,
        child: MimeToolsPanel(
          enabled: widget.mimeToolsEnabled,
          hasSelection: widget.mimeHasSelection,
          onRun: widget.onRunMimeOp,
        ),
      );
    }
    final structured = ToolBar._structuredSpecs[widget.panelId];
    if (structured != null) {
      return DockedBar(
        title:
            '${MarkupStyling.label(structured == StructuredLanguage.json && widget.structuredUseJson5 ? StructuredLanguage.json5 : structured)} tools',
        onClose: widget.onClose,
        child: StructuredToolsPanel(
          language: structured,
          enabled: widget.editToolsEnabled,
          hasSelection: widget.mimeHasSelection,
          useJson5: widget.structuredUseJson5,
          onUseJson5Changed: widget.onStructuredUseJson5Changed,
          autoValidate: widget.structuredAutoValidate,
          onAutoValidateChanged: widget.onStructuredAutoValidateChanged,
          onRun: widget.onRunStructuredOp,
        ),
      );
    }
    final mime = ToolBar._mimeSpecs[widget.panelId]!;
    final decode = _decodeFor(mime.$2);
    return DockedBar(
      // Titled from the live decode flag, not from the panel id, so the tab
      // and the Apply button always name the same operation.
      title: MimeOp(category: mime.$1, decode: decode).label,
      onClose: widget.onClose,
      child: SingleMimeToolPanel(
        enabled: widget.mimeToolsEnabled,
        hasSelection: widget.mimeHasSelection,
        category: mime.$1,
        decode: decode,
        onDecodeChanged: (v) => setState(() => _decode = v),
        onRun: widget.onRunMimeOp,
      ),
    );
  }
}

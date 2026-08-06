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
class ToolBar extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    if (panelId == gotoId) {
      return DockedBar(
        title: 'Go to Line',
        onClose: onClose,
        child: GotoLinePanel(
          lineCount: lineCount,
          currentLine: currentLine,
          onGotoLine: onGotoLine ?? (_) {},
          onClose: onClose,
        ),
      );
    }
    final edit = _editSpecs[panelId];
    if (edit != null) {
      return DockedBar(
        title: edit.$2,
        onClose: onClose,
        child: EditToolsPanel(
          enabled: editToolsEnabled,
          category: edit.$1,
          onRun: onRunEditOp,
        ),
      );
    }
    if (panelId == mimeAllId) {
      return DockedBar(
        title: 'MIME tools',
        onClose: onClose,
        child: MimeToolsPanel(
          enabled: mimeToolsEnabled,
          hasSelection: mimeHasSelection,
          onRun: onRunMimeOp,
        ),
      );
    }
    final structured = _structuredSpecs[panelId];
    if (structured != null) {
      return DockedBar(
        title:
            '${MarkupStyling.label(structured == StructuredLanguage.json && structuredUseJson5 ? StructuredLanguage.json5 : structured)} tools',
        onClose: onClose,
        child: StructuredToolsPanel(
          language: structured,
          enabled: editToolsEnabled,
          hasSelection: mimeHasSelection,
          useJson5: structuredUseJson5,
          onUseJson5Changed: onStructuredUseJson5Changed,
          autoValidate: structuredAutoValidate,
          onAutoValidateChanged: onStructuredAutoValidateChanged,
          onRun: onRunStructuredOp,
        ),
      );
    }
    final mime = _mimeSpecs[panelId]!;
    return DockedBar(
      title: mime.$3,
      onClose: onClose,
      child: SingleMimeToolPanel(
        enabled: mimeToolsEnabled,
        hasSelection: mimeHasSelection,
        category: mime.$1,
        initialDecode: mime.$2,
        onRun: onRunMimeOp,
      ),
    );
  }
}

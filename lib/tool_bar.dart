import 'package:flutter/material.dart';

import 'docked_bar.dart';
import 'edit_tools_panel.dart';
import 'mime_tools_panel.dart';

/// One row of tool controls, docked above the editor.
///
/// Maps a ribbon `panelId` to its title and content. Only the MIME and edit
/// panels become bars — `new` and `autodelete` are forms and stay inside the
/// ribbon, which is what [handles] distinguishes.
class ToolBar extends StatelessWidget {
  final String panelId;
  final bool editToolsEnabled;
  final bool mimeToolsEnabled;
  final bool mimeHasSelection;
  final ValueChanged<EditOp> onRunEditOp;
  final ValueChanged<MimeOp> onRunMimeOp;
  final VoidCallback onClose;

  const ToolBar({
    super.key,
    required this.panelId,
    required this.editToolsEnabled,
    required this.mimeToolsEnabled,
    required this.mimeHasSelection,
    required this.onRunEditOp,
    required this.onRunMimeOp,
    required this.onClose,
  });

  /// The aggregate MIME tools bar: all four categories as tabs in one bar.
  /// This is the menu's MIME entry; the per-operation ids below are reachable
  /// from ribbon search when the user knows exactly which one they want.
  static const String mimeAllId = 'mime';

  /// Panel ids that dock as a bar. Everything else stays in the ribbon.
  static bool handles(String panelId) =>
      panelId == mimeAllId ||
      _editSpecs.containsKey(panelId) ||
      _mimeSpecs.containsKey(panelId);

  static const Map<String, (EditCategory, String)> _editSpecs = {
    'edit.case': (EditCategory.caseConv, 'Convert Case'),
    'edit.eol': (EditCategory.eolConv, 'EOL Conversion'),
    'edit.blank': (EditCategory.blankOps, 'Blank Operations'),
    'edit.comment': (EditCategory.commentOps, 'Comment/Uncomment'),
  };

  static const Map<String, (MimeCategory, bool, String)> _mimeSpecs = {
    'mime.base64.encode': (MimeCategory.base64, false, 'Base64 Encode'),
    'mime.base64.decode': (MimeCategory.base64, true, 'Base64 Decode'),
    'mime.qp.encode': (MimeCategory.quotedPrintable, false, 'Quoted-printable Encode'),
    'mime.qp.decode': (MimeCategory.quotedPrintable, true, 'Quoted-printable Decode'),
    'mime.url.encode': (MimeCategory.url, false, 'URL Encode'),
    'mime.url.decode': (MimeCategory.url, true, 'URL Decode'),
    'mime.saml.decode': (MimeCategory.saml, true, 'SAML Decode'),
  };

  @override
  Widget build(BuildContext context) {
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

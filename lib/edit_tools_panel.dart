import 'package:flutter/material.dart';

enum EditCategory { caseConv, eolConv, blankOps, commentOps }

extension EditCategoryLabel on EditCategory {
  String get label => switch (this) {
        EditCategory.caseConv => 'Convert Case',
        EditCategory.eolConv => 'EOL Conversion',
        EditCategory.blankOps => 'Blank Operations',
        EditCategory.commentOps => 'Comment/Uncomment',
      };
}

class EditOp {
  final String opId;
  final String label;

  const EditOp({required this.opId, required this.label});
}

class EditToolsPanel extends StatefulWidget {
  final bool enabled;
  final ValueChanged<EditOp> onRun;
  final EditCategory category;

  const EditToolsPanel({
    super.key,
    required this.enabled,
    required this.onRun,
    required this.category,
  });

  @override
  State<EditToolsPanel> createState() => _EditToolsPanelState();
}

class _EditToolsPanelState extends State<EditToolsPanel> {
  // Option states
  String _selectedCaseOp = 'edit.case.uppercase';
  String _selectedEolOp = 'edit.eol.windows';
  String _selectedBlankOp = 'edit.blank.trim_trailing';
  String _selectedCommentOp = 'edit.comment.toggle_single_line';

  EditOp get _currentOp {
    switch (widget.category) {
      case EditCategory.caseConv:
        return EditOp(
          opId: _selectedCaseOp,
          label: _caseOps.firstWhere((o) => o.$1 == _selectedCaseOp).$2,
        );
      case EditCategory.eolConv:
        return EditOp(
          opId: _selectedEolOp,
          label: _eolOps.firstWhere((o) => o.$1 == _selectedEolOp).$2,
        );
      case EditCategory.blankOps:
        return EditOp(
          opId: _selectedBlankOp,
          label: _blankOps.firstWhere((o) => o.$1 == _selectedBlankOp).$2,
        );
      case EditCategory.commentOps:
        return EditOp(
          opId: _selectedCommentOp,
          label: _commentOps.firstWhere((o) => o.$1 == _selectedCommentOp).$2,
        );
    }
  }

  static const _caseOps = [
    ('edit.case.uppercase', 'UPPERCASE'),
    ('edit.case.lowercase', 'lowercase'),
    ('edit.case.proper', 'Proper Case'),
    ('edit.case.proper_blend', 'Proper Case (blend)'),
    ('edit.case.sentence', 'Sentence case'),
    ('edit.case.sentence_blend', 'Sentence case (blend)'),
    ('edit.case.invert', 'iNVERT cASE'),
    ('edit.case.random', 'ranDOm CasE'),
  ];

  static const _eolOps = [
    ('edit.eol.windows', 'Windows (CR LF)'),
    ('edit.eol.unix', 'Unix (LF)'),
    ('edit.eol.mac', 'Macintosh (CR)'),
  ];

  static const _blankOps = [
    ('edit.blank.trim_trailing', 'Trim Trailing Space'),
    ('edit.blank.trim_leading', 'Trim Leading Space'),
    ('edit.blank.trim_both', 'Trim Leading and Trailing Space'),
    ('edit.blank.eol_to_space', 'EOL to Space'),
    ('edit.blank.trim_both_and_eol_to_space', 'Trim both and EOL to Space'),
    ('edit.blank.tab_to_space', 'TAB to Space'),
    ('edit.blank.space_to_tab_all', 'Space to TAB (All)'),
    ('edit.blank.space_to_tab_leading', 'Space to TAB (Leading)'),
  ];

  static const _commentOps = [
    ('edit.comment.toggle_single_line', 'Toggle Single Line Comment'),
    ('edit.comment.block_comment', 'Block Comment'),
    ('edit.comment.block_uncomment', 'Block Uncomment'),
    ('edit.comment.single_line_comment', 'Single Line Comment'),
    ('edit.comment.single_line_uncomment', 'Single Line Uncomment'),
  ];

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            switch (widget.category) {
              EditCategory.caseConv => _buildChoiceList(_caseOps, _selectedCaseOp, (val) => setState(() => _selectedCaseOp = val!)),
              EditCategory.eolConv => _buildChoiceList(_eolOps, _selectedEolOp, (val) => setState(() => _selectedEolOp = val!)),
              EditCategory.blankOps => _buildChoiceList(_blankOps, _selectedBlankOp, (val) => setState(() => _selectedBlankOp = val!)),
              EditCategory.commentOps => _buildChoiceList(_commentOps, _selectedCommentOp, (val) => setState(() => _selectedCommentOp = val!)),
            },
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 16),
              label: Text('Apply ${_currentOp.label}'),
              onPressed: widget.enabled ? () => widget.onRun(_currentOp) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChoiceList(List<(String, String)> ops, String groupVal, ValueChanged<String?> onChanged) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: ops.map((op) {
        final selected = groupVal == op.$1;
        return ChoiceChip(
          label: Text(op.$2),
          selected: selected,
          onSelected: (sel) {
            if (sel) onChanged(op.$1);
          },
        );
      }).toList(),
    );
  }
}

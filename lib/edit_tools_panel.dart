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

class EditToolsPanel extends StatelessWidget {
  final bool enabled;
  final ValueChanged<EditOp> onRun;
  final EditCategory category;

  const EditToolsPanel({
    super.key,
    required this.enabled,
    required this.onRun,
    required this.category,
  });

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
    final ops = switch (category) {
      EditCategory.caseConv => _caseOps,
      EditCategory.eolConv => _eolOps,
      EditCategory.blankOps => _blankOps,
      EditCategory.commentOps => _commentOps,
    };
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: ops
          .map((op) => ActionChip(
                label: Text(op.$2),
                onPressed: enabled ? () => onRun(EditOp(opId: op.$1, label: op.$2)) : null,
              ))
          .toList(),
    );
  }
}

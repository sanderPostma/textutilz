import 'package:flutter/material.dart';

/// Content widget for the docked "Go to Line" tool bar.
class GotoLinePanel extends StatefulWidget {
  final int lineCount;
  final int currentLine;
  final ValueChanged<int> onGotoLine;
  final VoidCallback onClose;

  const GotoLinePanel({
    super.key,
    required this.lineCount,
    required this.currentLine,
    required this.onGotoLine,
    required this.onClose,
  });

  @override
  State<GotoLinePanel> createState() => _GotoLinePanelState();
}

class _GotoLinePanelState extends State<GotoLinePanel> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentLine.toString());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    final parsed = int.tryParse(text);
    if (parsed != null && parsed > 0) {
      widget.onGotoLine(parsed);
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Line number (1 – ${widget.lineCount}):',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 120,
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          child: const Text('Go', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

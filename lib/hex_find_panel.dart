import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'docked_bar.dart';
import 'hex_find_state.dart';

class HexFindPanel extends StatefulWidget {
  final HexFindController controller;
  final VoidCallback onClose;
  final ValueChanged<HexMatch> onReveal;
  final VoidCallback onContentChanged;

  const HexFindPanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onReveal,
    required this.onContentChanged,
  });

  @override
  State<HexFindPanel> createState() => HexFindPanelState();
}

class HexFindPanelState extends State<HexFindPanel> {
  final FocusNode _queryFocus = FocusNode();
  int _revealTick = 0;

  HexFindController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _revealTick = c.revealTick;
    c.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => requestQueryFocus());
  }

  @override
  void didUpdateWidget(HexFindPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, c)) {
      oldWidget.controller.removeListener(_changed);
      c.addListener(_changed);
      _revealTick = c.revealTick;
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _queryFocus.dispose();
    super.dispose();
  }

  void requestQueryFocus() => _queryFocus.requestFocus();

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_revealTick == c.revealTick) return;
    _revealTick = c.revealTick;
    final match = c.currentMatch;
    if (match != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReveal(match);
      });
    }
  }

  Future<void> _replaceCurrent() async {
    try {
      final replaced = await c.replaceCurrent();
      if (!mounted) return;
      if (replaced) widget.onContentChanged();
    } catch (e) {
      if (!mounted) return;
      _showError('Replace failed: $e');
    }
  }

  Future<void> _replaceAll() async {
    try {
      final count = await c.replaceAll();
      if (!mounted) return;
      if (count > 0) widget.onContentChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$count byte ${count == 1 ? 'match' : 'matches'} replaced',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showError('Replace all failed: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  KeyEventResult _queryKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        c.stepBackward();
      } else {
        c.stepForward();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final current = c.currentIndex < 0 ? 0 : c.currentIndex + 1;
    final total = '${c.matches.length}${c.complete ? '' : '+'}';
    return DockedBar(
      onClose: widget.onClose,
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            icon: Icon(
              c.mode == HexFindMode.find
                  ? Icons.keyboard_arrow_right
                  : Icons.keyboard_arrow_down,
              size: 18,
            ),
            tooltip: c.mode == HexFindMode.find
                ? 'Switch to Replace'
                : 'Switch to Find',
            onPressed: () => c.setMode(
              c.mode == HexFindMode.find
                  ? HexFindMode.replace
                  : HexFindMode.find,
            ),
            visualDensity: VisualDensity.compact,
          ),
          SizedBox(
            width: 250,
            child: Focus(
              onKeyEvent: _queryKey,
              child: TextField(
                key: const Key('hex-find-query'),
                controller: c.query,
                focusNode: _queryFocus,
                onChanged: (_) => c.scheduleRefresh(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: c.format == HexQueryFormat.hex
                      ? 'Bytes: DE AD BE EF'
                      : 'Text (UTF-8)',
                  errorText: c.error,
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
              ),
            ),
          ),
          SegmentedButton<HexQueryFormat>(
            segments: const [
              ButtonSegment(value: HexQueryFormat.hex, label: Text('Hex')),
              ButtonSegment(value: HexQueryFormat.text, label: Text('Text')),
            ],
            selected: {c.format},
            onSelectionChanged: (value) => c.setFormat(value.first),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          IconButton(
            key: const Key('hex-find-previous'),
            icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            tooltip: 'Previous match (Shift+F3)',
            onPressed: c.matches.isEmpty ? null : c.stepBackward,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const Key('hex-find-next'),
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            tooltip: 'Next match (F3)',
            onPressed: c.matches.isEmpty ? null : c.stepForward,
            visualDensity: VisualDensity.compact,
          ),
          if (c.isLoading)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text('$current / $total', key: const Key('hex-find-count')),
          if (c.mode == HexFindMode.replace) ...[
            SizedBox(
              width: 220,
              child: TextField(
                key: const Key('hex-replace-query'),
                controller: c.replacement,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: c.format == HexQueryFormat.hex
                      ? 'Replace bytes'
                      : 'Replace text (UTF-8)',
                  prefixIcon: const Icon(Icons.find_replace, size: 18),
                ),
                onSubmitted: (_) => _replaceCurrent(),
              ),
            ),
            OutlinedButton(
              key: const Key('hex-replace-current'),
              onPressed: c.currentMatch == null ? null : _replaceCurrent,
              child: const Text('Replace'),
            ),
            FilledButton.tonal(
              key: const Key('hex-replace-all'),
              onPressed: c.matches.isEmpty ? null : _replaceAll,
              child: const Text('Replace All'),
            ),
          ],
        ],
      ),
    );
  }
}

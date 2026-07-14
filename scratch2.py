import re

# 1. Update EditorPainter in editor.dart
with open("lib/editor.dart", "r") as f:
    content = f.read()

painter_def = """class EditorPainter extends CustomPainter {
  final int visualLineCount;
  final double scrollY;
  final double scrollX;
  final int cursorRow;
  final int cursorCol;
  final int? selStartRow;
  final int? selStartCol;
  final bool isBlockSelection;
  final String Function(int) getLineText;
  final bool isFocused;
  final Color textColor;

  EditorPainter({
    required this.visualLineCount,
    required this.scrollY,
    required this.scrollX,
    required this.cursorRow,
    required this.cursorCol,
    required this.selStartRow,
    required this.selStartCol,
    required this.isBlockSelection,
    required this.getLineText,
    required this.isFocused,
    required this.textColor,
  });"""
content = re.sub(r"class EditorPainter extends CustomPainter \{.*?\}\);", painter_def, content, flags=re.DOTALL)

content = content.replace("color: Colors.white,", "color: textColor,")

# 2. Update CustomEditor widget to pass textColor
paint_call = """          child: CustomPaint(
            size: Size(width, height),
            painter: EditorPainter(
              visualLineCount: _visualLineCount,
              scrollY: _vScroll.hasClients ? _vScroll.offset : 0.0,
              scrollX: _hScroll.hasClients ? _hScroll.offset : 0.0,
              cursorRow: _cursorRow,
              cursorCol: _cursorCol,
              selStartRow: _selStartRow,
              selStartCol: _selStartCol,
              isBlockSelection: _isBlockSelection,
              getLineText: _getLineText,
              isFocused: _focusNode.hasFocus,
              textColor: Theme.of(context).colorScheme.onSurface,
            ),
          ),"""
content = re.sub(r"          child: CustomPaint\(.*?isFocused: _focusNode\.hasFocus,\n            \),\n          \),", paint_call, content, flags=re.DOTALL)

# 3. Fix Alt/Ctrl movement in _handleKey
arrow_left_right = """        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          if (ctrl || alt) {
            String line = _getLineText(_cursorRow);
            if (_cursorCol == 0 && _cursorRow > 0) {
              _cursorRow--;
              _cursorCol = _getLineText(_cursorRow).length;
            } else {
              _cursorCol = alt ? _prevCamelBoundary(line, _cursorCol) : _prevWordBoundary(line, _cursorCol);
            }
          } else {
            _cursorCol = (_cursorCol - 1).clamp(0, _getLineLength(_cursorRow));
          }
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (ctrl || alt) {
            String line = _getLineText(_cursorRow);
            if (_cursorCol >= line.length && _cursorRow < _visualLineCount - 1) {
              _cursorRow++;
              _cursorCol = 0;
            } else {
              _cursorCol = alt ? _nextCamelBoundary(line, _cursorCol) : _nextWordBoundary(line, _cursorCol);
            }
          } else {
            _cursorCol = (_cursorCol + 1).clamp(0, _getLineLength(_cursorRow));
          }"""

content = re.sub(r"        \} else if \(event.logicalKey == LogicalKeyboardKey.arrowLeft\) \{.*?_cursorCol = \(_cursorCol \+ 1\)\.clamp\(0, _getLineLength\(_cursorRow\)\);\n          \}", arrow_left_right, content, flags=re.DOTALL)

with open("lib/editor.dart", "w") as f:
    f.write(content)


# 4. Update main.dart to prevent duplicate files
with open("lib/main.dart", "r") as f:
    main_content = f.read()

open_file_logic = """  Future<void> _openFile() async {
    setState(() {
      _isRibbonVisible = false;
    });
    final path = await pickFile();
    if (path != null) {
      int existingIndex = _tabs.indexWhere((t) => t.path == path);
      if (existingIndex >= 0) {
        setState(() {
          _activeTabIndex = existingIndex;
        });
        return;
      }
      try {
        final buffer = FileBuffer.open(path: path);"""
main_content = main_content.replace("""  Future<void> _openFile() async {
    setState(() {
      _isRibbonVisible = false;
    });
    final path = await pickFile();
    if (path != null) {
      try {
        final buffer = FileBuffer.open(path: path);""", open_file_logic)

with open("lib/main.dart", "w") as f:
    f.write(main_content)

print("done")

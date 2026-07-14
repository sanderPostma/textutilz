import re

with open("lib/editor.dart", "r") as f:
    content = f.read()

# First add the EditorSettings class and the boundary methods
settings_code = """class EditorSettings {
  static int tabSize = 4;
}

class CustomEditor extends StatefulWidget {"""

content = content.replace("class CustomEditor extends StatefulWidget {", settings_code)

boundary_methods = """  int get _visualLineCount => widget.initialLineCount + _totalAddedLines;

  int _nextWordBoundary(String line, int col) {
    if (col >= line.length) return line.length;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
    int startChar = line.codeUnitAt(col);
    bool startIsAlpha = isAlphaNumeric(startChar);
    bool startIsSpace = startChar == 32;
    for (int i = col + 1; i < line.length; i++) {
      int c = line.codeUnitAt(i);
      bool isAlpha = isAlphaNumeric(c);
      bool isSpace = c == 32;
      if (startIsSpace) { if (!isSpace) return i; }
      else if (startIsAlpha) { if (!isAlpha) return i; }
      else { if (isAlpha || isSpace) return i; }
    }
    return line.length;
  }

  int _prevWordBoundary(String line, int col) {
    if (col <= 0) return 0;
    if (col > line.length) return line.length;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
    int startChar = line.codeUnitAt(col - 1);
    bool startIsAlpha = isAlphaNumeric(startChar);
    bool startIsSpace = startChar == 32;
    for (int i = col - 2; i >= 0; i--) {
      int c = line.codeUnitAt(i);
      bool isAlpha = isAlphaNumeric(c);
      bool isSpace = c == 32;
      if (startIsSpace) { if (!isSpace) return i + 1; }
      else if (startIsAlpha) { if (!isAlpha) return i + 1; }
      else { if (isAlpha || isSpace) return i + 1; }
    }
    return 0;
  }

  int _nextCamelBoundary(String line, int col) {
    if (col >= line.length) return line.length;
    bool isUpper(int c) => c >= 65 && c <= 90;
    bool isLower(int c) => c >= 97 && c <= 122;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || isUpper(c) || isLower(c) || c == 95;
    for (int i = col + 1; i < line.length; i++) {
      int prev = line.codeUnitAt(i - 1);
      int curr = line.codeUnitAt(i);
      if (!isAlphaNumeric(prev) && isAlphaNumeric(curr)) return i;
      if (isAlphaNumeric(prev) && !isAlphaNumeric(curr)) return i;
      if (isLower(prev) && isUpper(curr)) return i;
      if (isUpper(prev) && isUpper(curr) && i + 1 < line.length && isLower(line.codeUnitAt(i + 1))) return i;
      if (prev == 95 && curr != 95) return i;
    }
    return line.length;
  }

  int _prevCamelBoundary(String line, int col) {
    if (col <= 0) return 0;
    if (col > line.length) return line.length;
    bool isUpper(int c) => c >= 65 && c <= 90;
    bool isLower(int c) => c >= 97 && c <= 122;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || isUpper(c) || isLower(c) || c == 95;
    for (int i = col - 1; i > 0; i--) {
      int prev = line.codeUnitAt(i - 1);
      int curr = line.codeUnitAt(i);
      if (!isAlphaNumeric(prev) && isAlphaNumeric(curr)) return i;
      if (isAlphaNumeric(prev) && !isAlphaNumeric(curr)) return i;
      if (isLower(prev) && isUpper(curr)) return i;
      if (isUpper(prev) && isUpper(curr) && i + 1 < line.length && isLower(line.codeUnitAt(i + 1))) return i;
      if (prev == 95 && curr != 95) return i;
    }
    return 0;
  }"""

content = content.replace("  int get _visualLineCount => widget.initialLineCount + _totalAddedLines;", boundary_methods)

# Now replace the handleKey block. We find from '  void _handleKey(KeyEvent event) {' down to '  void _copySelection() {'

new_handle_key = """  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

    setState(() {
      bool ctrl = HardwareKeyboard.instance.isControlPressed;
      bool shift = HardwareKeyboard.instance.isShiftPressed;
      bool alt = HardwareKeyboard.instance.isAltPressed;
      bool meta = HardwareKeyboard.instance.isMetaPressed;
      
      bool isModifier = event.logicalKey == LogicalKeyboardKey.controlLeft ||
                        event.logicalKey == LogicalKeyboardKey.controlRight ||
                        event.logicalKey == LogicalKeyboardKey.shiftLeft ||
                        event.logicalKey == LogicalKeyboardKey.shiftRight ||
                        event.logicalKey == LogicalKeyboardKey.altLeft ||
                        event.logicalKey == LogicalKeyboardKey.altRight ||
                        event.logicalKey == LogicalKeyboardKey.metaLeft ||
                        event.logicalKey == LogicalKeyboardKey.metaRight;

      if (isModifier) return;

      bool isMovementKey = (event.logicalKey == LogicalKeyboardKey.arrowUp ||
           event.logicalKey == LogicalKeyboardKey.arrowDown ||
           event.logicalKey == LogicalKeyboardKey.arrowLeft ||
           event.logicalKey == LogicalKeyboardKey.arrowRight ||
           event.logicalKey == LogicalKeyboardKey.pageUp ||
           event.logicalKey == LogicalKeyboardKey.pageDown ||
           event.logicalKey == LogicalKeyboardKey.home ||
           event.logicalKey == LogicalKeyboardKey.end);

      if (isMovementKey) {
        bool isLineMove = ctrl && shift && !alt && (event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.arrowDown);
        bool isScroll = ctrl && !shift && !alt && (event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.arrowDown);
        
        if (isScroll) {
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _vScroll.jumpTo(math.max(0, _vScroll.offset - _rowHeight));
          } else {
            _vScroll.jumpTo(math.min(_vScroll.position.maxScrollExtent, _vScroll.offset + _rowHeight));
          }
          return;
        }
        
        if (isLineMove) {
          _selStartRow = null;
          _selStartCol = null;
          if (event.logicalKey == LogicalKeyboardKey.arrowUp && _cursorRow > 0) {
            _prepareEdit(_cursorRow);
            _prepareEdit(_cursorRow - 1);
            List<int> lr1 = _getLogicalRow(_cursorRow);
            List<int> lr2 = _getLogicalRow(_cursorRow - 1);
            String line1 = _editBuffer[lr1[0]]![lr1[1]];
            String line2 = _editBuffer[lr2[0]]![lr2[1]];
            _editBuffer[lr1[0]]![lr1[1]] = line2;
            _editBuffer[lr2[0]]![lr2[1]] = line1;
            _cursorRow--;
            _scrollToCursor();
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown && _cursorRow < _visualLineCount - 1) {
            _prepareEdit(_cursorRow);
            _prepareEdit(_cursorRow + 1);
            List<int> lr1 = _getLogicalRow(_cursorRow);
            List<int> lr2 = _getLogicalRow(_cursorRow + 1);
            String line1 = _editBuffer[lr1[0]]![lr1[1]];
            String line2 = _editBuffer[lr2[0]]![lr2[1]];
            _editBuffer[lr1[0]]![lr1[1]] = line2;
            _editBuffer[lr2[0]]![lr2[1]] = line1;
            _cursorRow++;
            _scrollToCursor();
          }
          return;
        }
        
        if (!shift) {
          _selStartRow = null;
          _selStartCol = null;
        } else {
          _selStartRow ??= _cursorRow;
          _selStartCol ??= _cursorCol;
        }

        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _cursorRow = (_cursorRow - 1).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _cursorRow = (_cursorRow + 1).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
          _cursorRow = (_cursorRow - (_vScroll.position.viewportDimension ~/ _rowHeight)).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
          _cursorRow = (_cursorRow + (_vScroll.position.viewportDimension ~/ _rowHeight)).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          if (ctrl) {
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
          if (ctrl) {
            String line = _getLineText(_cursorRow);
            if (_cursorCol >= line.length && _cursorRow < _visualLineCount - 1) {
              _cursorRow++;
              _cursorCol = 0;
            } else {
              _cursorCol = alt ? _nextCamelBoundary(line, _cursorCol) : _nextWordBoundary(line, _cursorCol);
            }
          } else {
            _cursorCol = (_cursorCol + 1).clamp(0, _getLineLength(_cursorRow));
          }
        } else if (event.logicalKey == LogicalKeyboardKey.home) {
          _cursorCol = 0;
        } else if (event.logicalKey == LogicalKeyboardKey.end) {
          _cursorCol = _getLineLength(_cursorRow);
        }
        _scrollToCursor();
        return;
      }
      
      if (ctrl && !alt) {
        if (event.logicalKey.keyLabel == 'C' || event.logicalKey.keyLabel == 'c') {
          _copySelection();
          return;
        } else if (event.logicalKey.keyLabel == 'X' || event.logicalKey.keyLabel == 'x') {
          if (_selStartRow != null && _selStartCol != null) {
            _copySelection();
            _deleteSelection(keepBlankLines: false);
          }
          return;
        } else if (event.logicalKey.keyLabel == 'V' || event.logicalKey.keyLabel == 'v') {
          _pasteText();
          return;
        } else if (event.logicalKey.keyLabel == 'D' || event.logicalKey.keyLabel == 'd') {
          _prepareEdit(_cursorRow);
          List<int> lr = _getLogicalRow(_cursorRow);
          String line = _editBuffer[lr[0]]![lr[1]];
          _editBuffer[lr[0]]!.insert(lr[1] + 1, line);
          _totalAddedLines++;
          _cursorRow++;
          _scrollToCursor();
          return;
        }
      }

      if (event.logicalKey == LogicalKeyboardKey.backspace || event.logicalKey == LogicalKeyboardKey.delete) {
        if (_selStartRow != null && _selStartCol != null) {
          _deleteSelection(keepBlankLines: ctrl && event.logicalKey == LogicalKeyboardKey.delete);
        } else {
          if (event.logicalKey == LogicalKeyboardKey.backspace) {
            if (_cursorCol > 0) {
              _prepareEdit(_cursorRow);
              List<int> lr = _getLogicalRow(_cursorRow);
              String line = _editBuffer[lr[0]]![lr[1]];
              if (_cursorCol <= line.length) {
                _editBuffer[lr[0]]![lr[1]] = line.substring(0, _cursorCol - 1) + line.substring(_cursorCol);
              }
              _cursorCol--;
              _scrollToCursor();
            } else if (_cursorCol == 0 && _cursorRow > 0) {
              _prepareEdit(_cursorRow);
              _prepareEdit(_cursorRow - 1);
              List<int> lr1 = _getLogicalRow(_cursorRow - 1);
              List<int> lr2 = _getLogicalRow(_cursorRow);
              String line1 = _editBuffer[lr1[0]]![lr1[1]];
              String line2 = _editBuffer[lr2[0]]![lr2[1]];
              int newCol = line1.length;
              _editBuffer[lr1[0]]![lr1[1]] = line1 + line2;
              _editBuffer[lr2[0]]!.removeAt(lr2[1]);
              _totalAddedLines--;
              _cursorRow--;
              _cursorCol = newCol;
              _scrollToCursor();
            }
          } else if (event.logicalKey == LogicalKeyboardKey.delete) {
            _prepareEdit(_cursorRow);
            List<int> lr = _getLogicalRow(_cursorRow);
            String line = _editBuffer[lr[0]]![lr[1]];
            if (_cursorCol < line.length) {
              _editBuffer[lr[0]]![lr[1]] = line.substring(0, _cursorCol) + line.substring(_cursorCol + 1);
              _scrollToCursor();
            } else if (_cursorRow < _visualLineCount - 1) {
              _prepareEdit(_cursorRow + 1);
              lr = _getLogicalRow(_cursorRow);
              List<int> lr2 = _getLogicalRow(_cursorRow + 1);
              String line2 = _editBuffer[lr2[0]]![lr2[1]];
              _editBuffer[lr[0]]![lr[1]] = line + line2;
              _editBuffer[lr2[0]]!.removeAt(lr2[1]);
              _totalAddedLines--;
              _scrollToCursor();
            }
          }
        }
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (_selStartRow != null && _selStartCol != null) {
          _deleteSelection(keepBlankLines: false);
        }
        _prepareEdit(_cursorRow);
        List<int> lr = _getLogicalRow(_cursorRow);
        String line = _editBuffer[lr[0]]![lr[1]];
        if (_cursorCol > line.length) {
          line = line.padRight(_cursorCol, ' ');
        }
        String part1 = line.substring(0, _cursorCol);
        String part2 = line.substring(_cursorCol);
        _editBuffer[lr[0]]![lr[1]] = part1;
        _editBuffer[lr[0]]!.insert(lr[1] + 1, part2);
        _totalAddedLines++;
        _cursorRow++;
        _cursorCol = 0;
        _scrollToCursor();
      } else if (event.logicalKey == LogicalKeyboardKey.tab) {
        if (!shift) {
          if (_selStartRow != null && _selStartCol != null && _selStartRow != _cursorRow) {
            int minR = math.min(_selStartRow!, _cursorRow);
            int maxR = math.max(_selStartRow!, _cursorRow);
            for (int i = minR; i <= maxR; i++) {
              _prepareEdit(i);
              List<int> lr = _getLogicalRow(i);
              _editBuffer[lr[0]]![lr[1]] = (' ' * EditorSettings.tabSize) + _editBuffer[lr[0]]![lr[1]];
            }
            if (_selStartRow == minR) _selStartCol = _selStartCol! + EditorSettings.tabSize;
            else _cursorCol += EditorSettings.tabSize;
            
            if (_cursorRow == maxR) _cursorCol += EditorSettings.tabSize;
            else _selStartCol = _selStartCol! + EditorSettings.tabSize;
            _scrollToCursor();
          } else {
            int spacesToInsert = EditorSettings.tabSize - (_cursorCol % EditorSettings.tabSize);
            _prepareEdit(_cursorRow);
            List<int> lr = _getLogicalRow(_cursorRow);
            String line = _editBuffer[lr[0]]![lr[1]];
            if (_cursorCol <= line.length) {
              _editBuffer[lr[0]]![lr[1]] = line.substring(0, _cursorCol) + (' ' * spacesToInsert) + line.substring(_cursorCol);
            } else {
              _editBuffer[lr[0]]![lr[1]] = line.padRight(_cursorCol, ' ') + (' ' * spacesToInsert);
            }
            _cursorCol += spacesToInsert;
            _scrollToCursor();
          }
        } else {
          int minR = _cursorRow;
          int maxR = _cursorRow;
          if (_selStartRow != null && _selStartCol != null) {
            minR = math.min(_selStartRow!, _cursorRow);
            maxR = math.max(_selStartRow!, _cursorRow);
          }
          
          for (int i = minR; i <= maxR; i++) {
            _prepareEdit(i);
            List<int> lr = _getLogicalRow(i);
            String line = _editBuffer[lr[0]]![lr[1]];
            int spacesRemoved = 0;
            while (spacesRemoved < EditorSettings.tabSize && line.startsWith(' ')) {
              line = line.substring(1);
              spacesRemoved++;
            }
            _editBuffer[lr[0]]![lr[1]] = line;
            
            if (i == _cursorRow) _cursorCol = math.max(0, _cursorCol - spacesRemoved);
            if (i == _selStartRow) _selStartCol = math.max(0, _selStartCol! - spacesRemoved);
          }
          _scrollToCursor();
        }
        return;
      } else {
        if (!ctrl && !alt && !meta) {
          if (event.character != null && event.character!.isNotEmpty) {
            String char = event.character!;
            if (char.codeUnitAt(0) >= 32 && char.codeUnitAt(0) != 127) {
              if (_selStartRow != null && _selStartCol != null) {
                _deleteSelection(keepBlankLines: false);
              }
              _prepareEdit(_cursorRow);
              List<int> lr = _getLogicalRow(_cursorRow);
              String line = _editBuffer[lr[0]]![lr[1]];
              if (_cursorCol <= line.length) {
                _editBuffer[lr[0]]![lr[1]] = line.substring(0, _cursorCol) + char + line.substring(_cursorCol);
              } else {
                _editBuffer[lr[0]]![lr[1]] = line.padRight(_cursorCol, ' ') + char;
              }
              _cursorCol += char.length;
              _scrollToCursor();
            }
          }
        }
      }
      _notifyCursor();
    });
  }"""

pattern = re.compile(r"  void _handleKey\(KeyEvent event\) \{.*?(?=^  void _copySelection\(\) \{)", re.MULTILINE | re.DOTALL)
content = pattern.sub(new_handle_key + "\n", content)

with open("lib/editor.dart", "w") as f:
    f.write(content)

print("done")

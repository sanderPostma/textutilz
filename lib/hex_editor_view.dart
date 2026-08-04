import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:textutilz/src/rust/api/hex_session.dart';

/// Radix used to render the offset gutter and the byte cells.
enum HexRadix { hex, dec }

/// How the right-hand character panel decodes bytes.
enum HexCharEncoding { latin1, utf8, utf16 }

extension HexCharEncodingLabel on HexCharEncoding {
  String get label => switch (this) {
        HexCharEncoding.latin1 => 'Latin-1',
        HexCharEncoding.utf8 => 'UTF-8',
        HexCharEncoding.utf16 => 'UTF-16',
      };
}

/// Immutable view settings for a [HexEditorView]. Kept as a plain value object
/// (no runtime handles) so it can be persisted or shared between side-by-side
/// views later.
class HexViewSettings {
  /// Bytes per row, or 0 for automatic (largest multiple of 8 that fits).
  final int bytesPerRow;
  final HexRadix offsetRadix;
  final HexRadix byteRadix;
  final HexCharEncoding charEncoding;
  final bool insertMode;
  final double fontSize;

  const HexViewSettings({
    this.bytesPerRow = 0,
    this.offsetRadix = HexRadix.hex,
    this.byteRadix = HexRadix.hex,
    this.charEncoding = HexCharEncoding.latin1,
    this.insertMode = false,
    this.fontSize = 14.0,
  });

  HexViewSettings copyWith({
    int? bytesPerRow,
    HexRadix? offsetRadix,
    HexRadix? byteRadix,
    HexCharEncoding? charEncoding,
    bool? insertMode,
    double? fontSize,
  }) =>
      HexViewSettings(
        bytesPerRow: bytesPerRow ?? this.bytesPerRow,
        offsetRadix: offsetRadix ?? this.offsetRadix,
        byteRadix: byteRadix ?? this.byteRadix,
        charEncoding: charEncoding ?? this.charEncoding,
        insertMode: insertMode ?? this.insertMode,
        fontSize: fontSize ?? this.fontSize,
      );
}

/// A self-contained, reusable hex editor over a Rust [HexSession]. Holds only
/// view/caret state; all byte mutations and undo/redo go through the session.
///
/// Because both panels render from the same [HexSession.readWindow], editing in
/// either the hex matrix or the character panel updates the other automatically.
///
/// The widget makes no assumptions about being the only view on screen (no
/// global state), so several can be placed side-by-side for a future compare
/// mode.
class HexEditorView extends StatefulWidget {
  final HexSession session;
  final HexViewSettings settings;

  /// Called when the user changes a toggle (radix / encoding / insert mode /
  /// bytes-per-row) so the host can persist it.
  final ValueChanged<HexViewSettings>? onSettingsChanged;

  /// Reports the caret byte offset and the current total length for the status bar.
  final void Function(int offset, int totalLen)? onCursorChanged;

  /// Fired after any edit so the host can repaint dirty indicators.
  final VoidCallback? onContentChanged;

  /// Ctrl+wheel font zoom.
  final ValueChanged<double>? onFontSizeChanged;

  const HexEditorView({
    super.key,
    required this.session,
    this.settings = const HexViewSettings(),
    this.onSettingsChanged,
    this.onCursorChanged,
    this.onContentChanged,
    this.onFontSizeChanged,
  });

  @override
  State<HexEditorView> createState() => _HexEditorViewState();
}

class _HexEditorViewState extends State<HexEditorView> {
  // App-level shortcuts the editor lets bubble up instead of handling.
  static final Set<LogicalKeyboardKey> _bubbleShortcutKeys = {
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyO,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyN,
  };

  final ScrollController _vScroll = ScrollController();
  final FocusNode _focusNode = FocusNode();

  late HexViewSettings _settings;

  // Caret state.
  int _caret = 0; // byte offset in [0, len]
  bool _regionHex = true; // hex matrix vs character panel
  int _nibble = 0; // 0 = high, 1 = low (hex region only)
  bool _byteGroupOpen = false; // an undo group spanning a two-nibble byte edit

  // Geometry / layout snapshots updated each build (needed by navigation).
  int _bpr = 16;
  double _viewportHeight = 0;

  HexSession get _s => widget.session;
  int get _len => _s.len().toInt();

  double get _fontSize => _settings.fontSize;
  double get _charW => _fontSize * (8.4 / 14.0);
  double get _rowH => _fontSize * (20.0 / 14.0);

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _vScroll.addListener(() => setState(() {}));
    _focusNode.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(HexEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings != oldWidget.settings &&
        widget.settings != _settings) {
      _settings = widget.settings;
    }
  }

  @override
  void dispose() {
    _endByteGroup();
    _vScroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _updateSettings(HexViewSettings s) {
    setState(() => _settings = s);
    widget.onSettingsChanged?.call(s);
  }

  // ---- byte-edit undo grouping (one undo step per typed byte) --------------

  void _beginByteGroup() {
    if (!_byteGroupOpen) {
      _s.beginGroup();
      _byteGroupOpen = true;
    }
  }

  void _endByteGroup() {
    if (_byteGroupOpen) {
      _s.endGroup();
      _byteGroupOpen = false;
    }
  }

  int? _byteAt(int offset) {
    if (offset < 0 || offset >= _len) return null;
    final w = _s.readWindow(offset: BigInt.from(offset), len: BigInt.one);
    return w.isEmpty ? null : w[0];
  }

  // ---- geometry helpers ----------------------------------------------------

  int get _cellDigits => _settings.byteRadix == HexRadix.hex ? 2 : 3;
  double get _cellW => (_cellDigits + 1) * _charW; // digits + trailing space
  double get _groupGap => _charW;
  double get _sepW => 2 * _charW;

  int get _addressDigits {
    final maxOff = math.max(_len, 1);
    final s = _settings.offsetRadix == HexRadix.hex
        ? maxOff.toRadixString(16)
        : maxOff.toString();
    return math.max(_settings.offsetRadix == HexRadix.hex ? 6 : 8, s.length);
  }

  double get _gutterW => (_addressDigits + 2) * _charW;

  double _hexCellX(int k) =>
      _gutterW + k * _cellW + (k ~/ 8) * _groupGap;

  double get _charStartX => _hexCellX(_bpr - 1) + _cellW + _sepW;

  double get _totalWidth => _charStartX + _bpr * _charW + _charW;

  /// Largest multiple of 8 whose row fits [available] px wide; min 8. Honors a
  /// pinned [HexViewSettings.bytesPerRow] when non-zero.
  int _computeBpr(double available) {
    if (_settings.bytesPerRow > 0) return _settings.bytesPerRow;
    if (available <= 0) return 16;
    for (final cand in const [64, 56, 48, 40, 32, 24, 16, 8]) {
      final saved = _bpr;
      _bpr = cand;
      final w = _totalWidth;
      _bpr = saved;
      if (w <= available) return cand;
    }
    return 8;
  }

  int get _rowCount => _len == 0 ? 1 : (_len + _bpr - 1) ~/ _bpr;

  // ---- caret movement & scroll --------------------------------------------

  void _notifyCursor() {
    widget.onCursorChanged?.call(_caret, _len);
  }

  void _scrollToCaret() {
    if (!_vScroll.hasClients) return;
    final caretRow = _caret ~/ _bpr;
    final y = caretRow * _rowH;
    final vp = _vScroll.position.viewportDimension;
    final maxV = _vScroll.position.maxScrollExtent;
    if (y < _vScroll.offset) {
      _vScroll.jumpTo(y.clamp(0.0, maxV));
    } else if (y + _rowH > _vScroll.offset + vp) {
      _vScroll.jumpTo((y + _rowH - vp).clamp(0.0, maxV));
    }
  }

  void _moveCaret(int offset, {bool resetNibble = true}) {
    _endByteGroup();
    setState(() {
      _caret = offset.clamp(0, _len);
      if (resetNibble) _nibble = 0;
    });
    _scrollToCaret();
    _notifyCursor();
  }

  // ---- editing -------------------------------------------------------------

  int? _hexDigit(String s) {
    if (s.length != 1) return null;
    final c = s.toLowerCase().codeUnitAt(0);
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // a-f
    return null;
  }

  void _typeHexDigit(int d) {
    setState(() {
      if (_settings.insertMode) {
        if (_nibble == 0) {
          _beginByteGroup();
          _s.insertBytes(offset: BigInt.from(_caret), bytes: [d << 4]);
          _nibble = 1; // low nibble of the byte just inserted
        } else {
          final b = _byteAt(_caret) ?? 0;
          _s.overwriteBytes(offset: BigInt.from(_caret), bytes: [(b & 0xF0) | d]);
          _caret += 1;
          _nibble = 0;
          _endByteGroup();
        }
      } else {
        final b = _byteAt(_caret) ?? 0;
        if (_nibble == 0) {
          _beginByteGroup();
          _s.overwriteBytes(
              offset: BigInt.from(_caret), bytes: [(d << 4) | (b & 0x0F)]);
          _nibble = 1;
        } else {
          _s.overwriteBytes(
              offset: BigInt.from(_caret), bytes: [(b & 0xF0) | d]);
          _caret += 1;
          _nibble = 0;
          _endByteGroup();
        }
      }
    });
    widget.onContentChanged?.call();
    _scrollToCaret();
    _notifyCursor();
  }

  List<int> _encodeChar(String s, HexCharEncoding enc) {
    switch (enc) {
      case HexCharEncoding.utf8:
        return utf8.encode(s);
      case HexCharEncoding.utf16:
        final out = <int>[];
        for (final cu in s.codeUnits) {
          out.add(cu & 0xFF);
          out.add((cu >> 8) & 0xFF);
        }
        return out;
      case HexCharEncoding.latin1:
        final out = <int>[];
        for (final r in s.runes) {
          if (r < 256) {
            out.add(r);
          } else {
            out.addAll(utf8.encode(String.fromCharCode(r)));
          }
        }
        return out;
    }
  }

  void _typeChar(String s) {
    _endByteGroup();
    final bytes = _encodeChar(s, _settings.charEncoding);
    if (bytes.isEmpty) return;
    setState(() {
      if (_settings.insertMode) {
        _s.insertBytes(offset: BigInt.from(_caret), bytes: bytes);
      } else {
        _s.overwriteBytes(offset: BigInt.from(_caret), bytes: bytes);
      }
      _caret += bytes.length;
      _nibble = 0;
    });
    widget.onContentChanged?.call();
    _scrollToCaret();
    _notifyCursor();
  }

  void _backspace() {
    // Deleting shifts bytes, so it only applies in insert mode; a fixed-length
    // overwrite buffer has nothing to remove.
    if (!_settings.insertMode) return;
    _endByteGroup();
    if (_caret <= 0) return;
    setState(() {
      _s.delete(offset: BigInt.from(_caret - 1), len: BigInt.one);
      _caret -= 1;
      _nibble = 0;
    });
    widget.onContentChanged?.call();
    _scrollToCaret();
    _notifyCursor();
  }

  void _deleteForward() {
    // Only in insert mode; see _backspace.
    if (!_settings.insertMode) return;
    _endByteGroup();
    if (_caret >= _len) return;
    setState(() {
      _s.delete(offset: BigInt.from(_caret), len: BigInt.one);
      _nibble = 0;
    });
    widget.onContentChanged?.call();
    _notifyCursor();
  }

  void _undo() {
    _endByteGroup();
    final c = _s.undo();
    if (c != null) {
      setState(() {
        _caret = c.toInt().clamp(0, _len);
        _nibble = 0;
      });
      widget.onContentChanged?.call();
      _scrollToCaret();
      _notifyCursor();
    }
  }

  void _redo() {
    _endByteGroup();
    final c = _s.redo();
    if (c != null) {
      setState(() {
        _caret = c.toInt().clamp(0, _len);
        _nibble = 0;
      });
      widget.onContentChanged?.call();
      _scrollToCaret();
      _notifyCursor();
    }
  }

  // ---- key handling --------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;

    // Bubble Alt+X (menu) and app shortcuts.
    if (HardwareKeyboard.instance.isAltPressed && key == LogicalKeyboardKey.keyX) {
      return KeyEventResult.ignored;
    }
    if (ctrl && _bubbleShortcutKeys.contains(key)) {
      return KeyEventResult.ignored;
    }

    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _undo();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyY) {
      _redo();
      return KeyEventResult.handled;
    }

    switch (key) {
      case LogicalKeyboardKey.arrowRight:
        _moveCaret(_caret + 1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _moveCaret(_caret - 1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveCaret(_caret - _bpr);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _moveCaret(_caret + _bpr);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        _moveCaret((_caret ~/ _bpr) * _bpr);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        final rowStart = (_caret ~/ _bpr) * _bpr;
        _moveCaret(math.min(rowStart + _bpr - 1, _len));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        final rows = math.max(1, (_viewportHeight / _rowH).floor());
        _moveCaret(_caret - rows * _bpr);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        final rows = math.max(1, (_viewportHeight / _rowH).floor());
        _moveCaret(_caret + rows * _bpr);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
        _endByteGroup();
        setState(() {
          _regionHex = !_regionHex;
          _nibble = 0;
        });
        return KeyEventResult.handled;
      case LogicalKeyboardKey.insert:
        _updateSettings(_settings.copyWith(insertMode: !_settings.insertMode));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
        _backspace();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.delete:
        _deleteForward();
        return KeyEventResult.handled;
    }

    // Character input.
    final ch = event.character;
    if (!ctrl && ch != null && ch.isNotEmpty) {
      if (_regionHex) {
        final d = _hexDigit(ch);
        if (d != null) {
          _typeHexDigit(d);
          return KeyEventResult.handled;
        }
      } else {
        // Ignore control characters produced by non-text keys.
        if (ch.codeUnitAt(0) >= 0x20 || ch == '\t') {
          _typeChar(ch);
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  // ---- mouse ---------------------------------------------------------------

  void _handleTapDown(TapDownDetails d) {
    _focusNode.requestFocus();
    _endByteGroup();
    final y = d.localPosition.dy + (_vScroll.hasClients ? _vScroll.offset : 0);
    final x = d.localPosition.dx;
    final row = (y / _rowH).floor().clamp(0, _rowCount - 1);
    final rowStart = row * _bpr;

    // Character panel?
    if (x >= _charStartX - _sepW / 2) {
      final k = ((x - _charStartX) / _charW).floor().clamp(0, _bpr - 1);
      setState(() {
        _regionHex = false;
        _caret = math.min(rowStart + k, _len);
        _nibble = 0;
      });
    } else {
      // Hex matrix: find nearest cell.
      int k = 0;
      double best = double.infinity;
      for (int i = 0; i < _bpr; i++) {
        final cx = _hexCellX(i);
        final dist = (x - cx).abs();
        if (dist < best) {
          best = dist;
          k = i;
        }
      }
      final within = x - _hexCellX(k);
      setState(() {
        _regionHex = true;
        _caret = math.min(rowStart + k, _len);
        _nibble = within > _charW * 1.0 ? 1 : 0;
      });
    }
    _notifyCursor();
  }

  // ---- char-panel glyph decoding (per visible window) ----------------------

  static bool _isPrintableRune(int r) =>
      r >= 0x20 && r != 0x7F && !(r >= 0x80 && r <= 0x9F);

  /// One glyph per byte in [bytes]; continuation bytes of a multi-byte unit get
  /// a dim middle dot. Unprintable bytes become '.'.
  List<String> _decodeChars(Uint8List bytes) {
    final n = bytes.length;
    final out = List<String>.filled(n, '.');
    switch (_settings.charEncoding) {
      case HexCharEncoding.latin1:
        for (int i = 0; i < n; i++) {
          final b = bytes[i];
          out[i] = _isPrintableRune(b) ? String.fromCharCode(b) : '.';
        }
        break;
      case HexCharEncoding.utf8:
        int i = 0;
        while (i < n) {
          final lead = bytes[i];
          int seq;
          if (lead < 0x80) {
            seq = 1;
          } else if (lead >= 0xC0 && lead < 0xE0) {
            seq = 2;
          } else if (lead >= 0xE0 && lead < 0xF0) {
            seq = 3;
          } else if (lead >= 0xF0 && lead < 0xF8) {
            seq = 4;
          } else {
            out[i] = '.';
            i += 1;
            continue;
          }
          if (i + seq > n) {
            out[i] = '.';
            i += 1;
            continue;
          }
          try {
            final decoded = utf8.decode(bytes.sublist(i, i + seq));
            final r = decoded.runes.first;
            out[i] = _isPrintableRune(r) ? decoded : '.';
            for (int j = 1; j < seq; j++) {
              out[i + j] = '·';
            }
            i += seq;
          } catch (_) {
            out[i] = '.';
            i += 1;
          }
        }
        break;
      case HexCharEncoding.utf16:
        int i = 0;
        while (i + 1 < n) {
          final cu = bytes[i] | (bytes[i + 1] << 8);
          out[i] = _isPrintableRune(cu) ? String.fromCharCode(cu) : '.';
          out[i + 1] = '·';
          i += 2;
        }
        break;
    }
    return out;
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _notifyCursor();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _buildToolbar(context, scheme),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _bpr = _computeBpr(constraints.maxWidth);
              _viewportHeight = constraints.maxHeight;
              final totalHeight = _rowCount * _rowH;

              // Visible row window.
              final scrollY = _vScroll.hasClients ? _vScroll.offset : 0.0;
              final firstRow =
                  (scrollY / _rowH).floor().clamp(0, _rowCount);
              final visRows = (constraints.maxHeight / _rowH).ceil() + 1;
              final lastRow = (firstRow + visRows).clamp(0, _rowCount);

              // Fetch just the visible bytes in one call.
              final winStart = firstRow * _bpr;
              final winLen = math.max(0, (lastRow - firstRow) * _bpr);
              final bytes = winLen == 0
                  ? Uint8List(0)
                  : _s.readWindow(
                      offset: BigInt.from(winStart),
                      len: BigInt.from(winLen));
              final glyphs = _decodeChars(bytes);
              final modified = winLen == 0
                  ? const <ByteRange>[]
                  : _s.modifiedRanges(
                      offset: BigInt.from(winStart),
                      len: BigInt.from(winLen));

              return Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent &&
                      HardwareKeyboard.instance.isControlPressed &&
                      widget.onFontSizeChanged != null) {
                    final delta = event.scrollDelta.dy > 0 ? -1.0 : 1.0;
                    widget.onFontSizeChanged!(
                        (_fontSize + delta).clamp(8.0, 40.0));
                  }
                },
                child: Focus(
                  focusNode: _focusNode,
                  autofocus: true,
                  onKeyEvent: _onKey,
                  child: GestureDetector(
                    onTapDown: _handleTapDown,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _HexPainter(
                              bytes: bytes,
                              glyphs: glyphs,
                              modified: modified,
                              winStart: winStart,
                              firstRow: firstRow,
                              lastRow: lastRow,
                              totalLen: _len,
                              bpr: _bpr,
                              scrollY: scrollY,
                              caret: _caret,
                              regionHex: _regionHex,
                              nibble: _nibble,
                              hasFocus: _focusNode.hasFocus,
                              fontSize: _fontSize,
                              charW: _charW,
                              rowH: _rowH,
                              gutterW: _gutterW,
                              cellW: _cellW,
                              cellDigits: _cellDigits,
                              groupGap: _groupGap,
                              charStartX: _charStartX,
                              addressDigits: _addressDigits,
                              offsetRadix: _settings.offsetRadix,
                              byteRadix: _settings.byteRadix,
                              textColor: Theme.of(context).brightness ==
                                      Brightness.light
                                  ? Colors.black
                                  : Colors.white,
                              gutterBg: scheme.surfaceContainerHighest,
                              gutterFg: scheme.onSurface.withOpacity(0.55),
                              caretColor: scheme.primary,
                              modifiedBg: scheme.tertiary.withOpacity(0.28),
                              dimColor: scheme.onSurface.withOpacity(0.3),
                            ),
                          ),
                        ),
                        // Invisible scrollbar drives native vertical scrolling.
                        Scrollbar(
                          controller: _vScroll,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _vScroll,
                            physics: const ClampingScrollPhysics(),
                            child: SizedBox(
                              height: totalHeight,
                              width: double.infinity,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, ColorScheme scheme) {
    Widget radixToggle(String label, HexRadix value, ValueChanged<HexRadix> on) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label ', style: const TextStyle(fontSize: 12)),
          ToggleButtons(
            constraints: const BoxConstraints(minHeight: 26, minWidth: 34),
            isSelected: [value == HexRadix.hex, value == HexRadix.dec],
            onPressed: (i) => on(i == 0 ? HexRadix.hex : HexRadix.dec),
            children: const [Text('Hex'), Text('Dec')],
          ),
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            // Insert / overwrite.
            OutlinedButton(
              onPressed: () => _updateSettings(
                  _settings.copyWith(insertMode: !_settings.insertMode)),
              child: Text(_settings.insertMode ? 'INS' : 'OVR'),
            ),
            const SizedBox(width: 16),
            radixToggle('Offset', _settings.offsetRadix,
                (v) => _updateSettings(_settings.copyWith(offsetRadix: v))),
            const SizedBox(width: 16),
            radixToggle('Bytes', _settings.byteRadix,
                (v) => _updateSettings(_settings.copyWith(byteRadix: v))),
            const SizedBox(width: 16),
            const Text('Chars ', style: TextStyle(fontSize: 12)),
            DropdownButton<HexCharEncoding>(
              value: _settings.charEncoding,
              isDense: true,
              onChanged: (v) => v == null
                  ? null
                  : _updateSettings(_settings.copyWith(charEncoding: v)),
              items: HexCharEncoding.values
                  .map((e) =>
                      DropdownMenuItem(value: e, child: Text(e.label)))
                  .toList(),
            ),
            const SizedBox(width: 16),
            const Text('Width ', style: TextStyle(fontSize: 12)),
            DropdownButton<int>(
              value: _settings.bytesPerRow,
              isDense: true,
              onChanged: (v) => v == null
                  ? null
                  : _updateSettings(_settings.copyWith(bytesPerRow: v)),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Auto')),
                DropdownMenuItem(value: 8, child: Text('8')),
                DropdownMenuItem(value: 16, child: Text('16')),
                DropdownMenuItem(value: 24, child: Text('24')),
                DropdownMenuItem(value: 32, child: Text('32')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HexPainter extends CustomPainter {
  final Uint8List bytes;
  final List<String> glyphs;
  final List<ByteRange> modified;
  final int winStart;
  final int firstRow;
  final int lastRow;
  final int totalLen;
  final int bpr;
  final double scrollY;
  final int caret;
  final bool regionHex;
  final int nibble;
  final bool hasFocus;

  final double fontSize;
  final double charW;
  final double rowH;
  final double gutterW;
  final double cellW;
  final int cellDigits;
  final double groupGap;
  final double charStartX;
  final int addressDigits;
  final HexRadix offsetRadix;
  final HexRadix byteRadix;

  final Color textColor;
  final Color gutterBg;
  final Color gutterFg;
  final Color caretColor;
  final Color modifiedBg;
  final Color dimColor;

  _HexPainter({
    required this.bytes,
    required this.glyphs,
    required this.modified,
    required this.winStart,
    required this.firstRow,
    required this.lastRow,
    required this.totalLen,
    required this.bpr,
    required this.scrollY,
    required this.caret,
    required this.regionHex,
    required this.nibble,
    required this.hasFocus,
    required this.fontSize,
    required this.charW,
    required this.rowH,
    required this.gutterW,
    required this.cellW,
    required this.cellDigits,
    required this.groupGap,
    required this.charStartX,
    required this.addressDigits,
    required this.offsetRadix,
    required this.byteRadix,
    required this.textColor,
    required this.gutterBg,
    required this.gutterFg,
    required this.caretColor,
    required this.modifiedBg,
    required this.dimColor,
  });

  double _hexCellX(int k) => gutterW + k * cellW + (k ~/ 8) * groupGap;

  bool _isModified(int offset) {
    for (final r in modified) {
      final start = r.start.toInt();
      final len = r.len.toInt();
      if (offset >= start && offset < start + len) return true;
    }
    return false;
  }

  void _text(Canvas canvas, String s, double x, double y, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset(x, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Gutter background band.
    final gutterPaint = Paint()..color = gutterBg;
    canvas.drawRect(Rect.fromLTWH(0, 0, gutterW, size.height), gutterPaint);

    final caretRow = caret ~/ bpr;
    final caretCol = caret % bpr;

    for (int row = firstRow; row < lastRow; row++) {
      final rowOffset = row * bpr;
      if (rowOffset > totalLen) break;
      final y = row * rowH - scrollY;
      if (y > size.height || y + rowH < 0) continue;

      // Offset address.
      final addr = offsetRadix == HexRadix.hex
          ? rowOffset.toRadixString(16).toUpperCase().padLeft(addressDigits, '0')
          : rowOffset.toString().padLeft(addressDigits, '0');
      _text(canvas, addr, charW, y, gutterFg);

      for (int k = 0; k < bpr; k++) {
        final off = rowOffset + k;
        if (off >= totalLen) {
          // Allow the caret to sit at the append position (== totalLen).
          if (off == totalLen && off == caret) {
            _paintCaret(canvas, k, y, isHexRegion: true, empty: true);
          }
          break;
        }
        final b = bytes[off - winStart];
        final cellX = _hexCellX(k);
        final modifiedHere = _isModified(off);

        if (modifiedHere) {
          canvas.drawRect(
              Rect.fromLTWH(cellX, y, cellDigits * charW, rowH), Paint()..color = modifiedBg);
        }

        final cell = byteRadix == HexRadix.hex
            ? b.toRadixString(16).toUpperCase().padLeft(2, '0')
            : b.toString().padLeft(cellDigits, ' ');
        _text(canvas, cell, cellX, y, textColor);

        // Character panel glyph.
        final gx = charStartX + k * charW;
        if (modifiedHere) {
          canvas.drawRect(
              Rect.fromLTWH(gx, y, charW, rowH), Paint()..color = modifiedBg);
        }
        final g = glyphs[off - winStart];
        _text(canvas, g, gx, y, g == '·' ? dimColor : textColor);

        // Caret highlight (both panels).
        if (off == caret) {
          _paintCaret(canvas, k, y, isHexRegion: regionHex);
        }
      }
    }
    // Keep unused fields referenced for future selection work.
    // (caretRow/caretCol computed for potential row highlighting.)
    if (caretRow < 0 || caretCol < 0) {}
  }

  void _paintCaret(Canvas canvas, int k, double y,
      {required bool isHexRegion, bool empty = false}) {
    final active = Paint()
      ..color = caretColor.withOpacity(hasFocus ? 0.9 : 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final cellX = _hexCellX(k);
    final gx = charStartX + k * charW;

    // Box the inactive-region counterpart faintly, the active one solid.
    final hexRect = Rect.fromLTWH(cellX - 1, y, cellDigits * charW + 2, rowH);
    final charRect = Rect.fromLTWH(gx - 1, y, charW + 2, rowH);

    if (isHexRegion) {
      canvas.drawRect(hexRect, active);
      canvas.drawRect(
          charRect,
          Paint()
            ..color = caretColor.withOpacity(0.25)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0);
      if (!empty && hasFocus) {
        // Nibble caret bar.
        final nx = cellX + nibble * charW;
        canvas.drawRect(Rect.fromLTWH(nx, y + rowH - 2, charW, 2),
            Paint()..color = caretColor);
      }
    } else {
      canvas.drawRect(charRect, active);
      canvas.drawRect(
          hexRect,
          Paint()
            ..color = caretColor.withOpacity(0.25)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0);
    }
  }

  @override
  bool shouldRepaint(covariant _HexPainter old) => true;
}

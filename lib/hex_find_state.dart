import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'src/rust/api/hex_session.dart';

enum HexFindMode { find, replace }

enum HexQueryFormat { hex, text }

class HexMatch {
  final int offset;
  final int length;

  const HexMatch(this.offset, this.length);
}

/// Byte-oriented search state for the hex editor. Unlike text search it has no
/// regex, whole-word, direction or extended-mode options: the query resolves
/// to one exact byte sequence.
class HexFindController extends ChangeNotifier {
  static const int resultLimit = 100000;
  static const Duration debounce = Duration(milliseconds: 150);

  final TextEditingController query = TextEditingController();
  final TextEditingController replacement = TextEditingController();

  HexSession? _session;
  HexSession? get session => _session;

  HexFindMode mode = HexFindMode.find;
  HexQueryFormat format = HexQueryFormat.hex;
  List<HexMatch> matches = const [];
  int currentIndex = -1;
  bool complete = true;
  bool isLoading = false;
  String? error;
  int revealTick = 0;
  Timer? _debounce;
  bool _disposed = false;
  int _generation = 0;

  HexMatch? get currentMatch =>
      currentIndex >= 0 && currentIndex < matches.length
      ? matches[currentIndex]
      : null;

  void attach(HexSession? value) {
    if (identical(_session, value)) return;
    _session = value;
    unawaited(refresh());
  }

  void setMode(HexFindMode value) {
    if (mode == value) return;
    mode = value;
    notifyListeners();
  }

  void setFormat(HexQueryFormat value) {
    if (format == value) return;
    format = value;
    scheduleRefresh();
  }

  void scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(refresh()));
    notifyListeners();
  }

  List<int>? _parse(String source, {required bool allowEmpty}) {
    final value = source.trim();
    if (value.isEmpty) {
      if (allowEmpty) return const [];
      error = null;
      return null;
    }
    if (format == HexQueryFormat.text) return utf8.encode(source);

    try {
      final tokens = value.split(RegExp(r'[\s,;:_-]+'));
      final out = <int>[];
      if (tokens.length > 1) {
        for (var token in tokens.where((e) => e.isNotEmpty)) {
          if (token.toLowerCase().startsWith('0x')) token = token.substring(2);
          if (token.isEmpty || token.length > 2) throw const FormatException();
          out.add(int.parse(token, radix: 16));
        }
      } else {
        var compact = tokens.single;
        if (compact.toLowerCase().startsWith('0x')) {
          compact = compact.substring(2);
        }
        if (compact.isEmpty || compact.length.isOdd) {
          throw const FormatException();
        }
        for (var i = 0; i < compact.length; i += 2) {
          out.add(int.parse(compact.substring(i, i + 2), radix: 16));
        }
      }
      return out;
    } on FormatException {
      error = 'Enter bytes as pairs, for example DE AD BE EF';
      return null;
    }
  }

  Future<void> refresh({int? anchorOffset}) async {
    _debounce?.cancel();
    final generation = ++_generation;
    final pattern = _parse(query.text, allowEmpty: false);
    final s = _session;
    if (s == null || pattern == null || pattern.isEmpty) {
      matches = const [];
      currentIndex = -1;
      complete = true;
      isLoading = false;
      if (!_disposed) notifyListeners();
      return;
    }
    error = null;
    isLoading = true;
    if (!_disposed) notifyListeners();
    try {
      final found = await s.findBytes(
        pattern: pattern,
        fromOffset: BigInt.zero,
        maxResults: BigInt.from(resultLimit),
      );
      if (_disposed || generation != _generation) return;
      matches = found.offsets
          .map((offset) => HexMatch(offset.toInt(), pattern.length))
          .toList(growable: false);
      complete = found.complete;
      if (matches.isEmpty) {
        currentIndex = -1;
      } else if (anchorOffset != null) {
        final i = matches.indexWhere((m) => m.offset >= anchorOffset);
        currentIndex = i < 0 ? 0 : i;
      } else {
        currentIndex = currentIndex.clamp(0, matches.length - 1);
      }
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e.toString();
      matches = const [];
      currentIndex = -1;
    }
    isLoading = false;
    if (!_disposed) notifyListeners();
  }

  void stepForward() {
    if (matches.isEmpty) return;
    currentIndex = (currentIndex + 1) % matches.length;
    revealTick++;
    notifyListeners();
  }

  void stepBackward() {
    if (matches.isEmpty) return;
    currentIndex = (currentIndex - 1 + matches.length) % matches.length;
    revealTick++;
    notifyListeners();
  }

  Future<bool> replaceCurrent() async {
    final s = _session;
    final match = currentMatch;
    final pattern = _parse(query.text, allowEmpty: false);
    final bytes = _parse(replacement.text, allowEmpty: true);
    if (s == null || match == null || pattern == null || bytes == null) {
      notifyListeners();
      return false;
    }
    final anchor = s
        .replaceBytes(
          offset: BigInt.from(match.offset),
          expected: pattern,
          replacement: bytes,
        )
        .toInt();
    currentIndex = -1;
    revealTick++;
    await refresh(anchorOffset: anchor);
    return true;
  }

  Future<int> replaceAll() async {
    final s = _session;
    final pattern = _parse(query.text, allowEmpty: false);
    final bytes = _parse(replacement.text, allowEmpty: true);
    if (s == null || pattern == null || bytes == null) {
      notifyListeners();
      return 0;
    }
    final count = (await s.replaceAllBytes(
      pattern: pattern,
      replacement: bytes,
    )).toInt();
    currentIndex = -1;
    await refresh();
    return count;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    query.dispose();
    replacement.dispose();
    super.dispose();
  }
}

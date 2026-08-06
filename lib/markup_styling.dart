import 'package:flutter/material.dart';

import 'src/rust/api/structured.dart';

/// Presentation for structured formats.
///
/// Detection, lexing, folding and validation all live in Rust
/// (`rust/src/markup/`). What is left here is the part that is genuinely UI:
/// which colour a token kind is painted in, and how a row's tokens become a
/// [TextSpan]. Adding a format means adding a lexer in Rust; the only change
/// here would be a colour for any new token kind.
class MarkupStyling {
  const MarkupStyling._();

  /// The display name of a language, for panel titles and menu labels.
  static String label(StructuredLanguage language) => switch (language) {
    StructuredLanguage.plainText => 'Plain Text',
    StructuredLanguage.json => 'JSON',
    StructuredLanguage.json5 => 'JSON5',
    StructuredLanguage.yaml => 'YAML',
    StructuredLanguage.xml => 'XML',
  };

  /// True for the formats that have a lexer, so the caller can skip the
  /// token round trip entirely for plain text.
  static bool isStructured(StructuredLanguage language) =>
      language != StructuredLanguage.plainText;

  /// Build a styled span for one row from the tokens Rust produced for it.
  ///
  /// Token columns are UTF-16 code units, which is what Dart's `String` indices
  /// already are, so they are used directly. Tokens are assumed sorted and
  /// non-overlapping — the Rust sink guarantees both — but the offsets are still
  /// clamped, because a row can change between the token call and the paint.
  static TextSpan styledLine({
    required String line,
    required List<StructuredToken> tokens,
    required TextStyle baseStyle,
    required Brightness brightness,
  }) {
    if (tokens.isEmpty) {
      return TextSpan(text: line, style: baseStyle);
    }
    final children = <InlineSpan>[];
    var offset = 0;
    for (final token in tokens) {
      final start = token.start.clamp(offset, line.length);
      final end = token.end.clamp(start, line.length);
      if (start > offset) {
        children.add(TextSpan(text: line.substring(offset, start)));
      }
      if (end > start) {
        children.add(
          TextSpan(
            text: line.substring(start, end),
            style: styleFor(token.kind, brightness),
          ),
        );
      }
      offset = end;
    }
    if (offset < line.length) {
      children.add(TextSpan(text: line.substring(offset)));
    }
    return TextSpan(style: baseStyle, children: children);
  }

  /// The style for a token kind. Most kinds differ only in colour; the ones
  /// that carry structure — tag and element names — also take a weight, which
  /// is what makes nesting readable at a glance in a dense XML document.
  static TextStyle styleFor(StructuredTokenKind kind, Brightness brightness) {
    return TextStyle(
      color: colorFor(kind, brightness),
      fontWeight: switch (kind) {
        StructuredTokenKind.tagName || StructuredTokenKind.key =>
          FontWeight.w600,
        _ => null,
      },
      fontStyle: kind == StructuredTokenKind.comment ? FontStyle.italic : null,
    );
  }

  /// The colour for a token kind.
  ///
  /// Two palettes, chosen by theme brightness. Both follow the convention the
  /// reference editors use — warm for literal data, cool for names and
  /// structure, green for comments, red for anything invalid — so a document
  /// reads the same way in either theme.
  static Color colorFor(StructuredTokenKind kind, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (kind) {
      // Names: keys, attributes, aliases.
      StructuredTokenKind.key ||
      StructuredTokenKind.attributeName => dark
          ? const Color(0xFF9CDCFE)
          : const Color(0xFF0451A5),
      // Element names get their own colour so open/close tags stand out from
      // the attributes sitting next to them.
      StructuredTokenKind.tagName => dark
          ? const Color(0xFF4EC9B0)
          : const Color(0xFF800000),
      StructuredTokenKind.str => dark
          ? const Color(0xFFCE9178)
          : const Color(0xFFA31515),
      StructuredTokenKind.number => dark
          ? const Color(0xFFB5CEA8)
          : const Color(0xFF098658),
      StructuredTokenKind.keyword => dark
          ? const Color(0xFF569CD6)
          : const Color(0xFF0000FF),
      StructuredTokenKind.punctuation => dark
          ? const Color(0xFFD4D4D4)
          : const Color(0xFF505050),
      StructuredTokenKind.comment => dark
          ? const Color(0xFF6A9955)
          : const Color(0xFF008000),
      // Element content: the document's actual text, so it stays the plainest
      // thing on screen.
      StructuredTokenKind.text => dark
          ? const Color(0xFFD4D4D4)
          : const Color(0xFF1E1E1E),
      StructuredTokenKind.cData => dark
          ? const Color(0xFFD7BA7D)
          : const Color(0xFF7A5B00),
      StructuredTokenKind.doctype ||
      StructuredTokenKind.processingInstruction ||
      StructuredTokenKind.directive => dark
          ? const Color(0xFFC586C0)
          : const Color(0xFF7B2E8E),
      StructuredTokenKind.entity ||
      StructuredTokenKind.alias => dark
          ? const Color(0xFFDCDCAA)
          : const Color(0xFF795E26),
      StructuredTokenKind.invalid => dark
          ? const Color(0xFFF48771)
          : const Color(0xFFCC0000),
    };
  }

  /// Background wash for a matched delimiter pair.
  ///
  /// A wash rather than a colour change: the delimiters keep their syntax
  /// colour, so highlighting the pair adds information instead of replacing it.
  static Color matchHighlight(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0x66B47EDE)
      : const Color(0x66C8A2E8);

  /// Colour for the fold gutter's boxes and guide lines.
  static Color foldGuide(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF7A7A7A)
      : const Color(0xFF9A9A9A);

  /// The rule drawn across a collapsed row, marking hidden content.
  static Color collapsedRule(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFFB0B0B0)
      : const Color(0xFF303030);

  /// Squiggle colour for a row carrying a diagnostic.
  static Color diagnosticUnderline(
    StructuredSeverity severity,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    return switch (severity) {
      StructuredSeverity.error => dark
          ? const Color(0xFFF14C4C)
          : const Color(0xFFCC0000),
      StructuredSeverity.warning => dark
          ? const Color(0xFFCCA700)
          : const Color(0xFF9A6700),
    };
  }
}

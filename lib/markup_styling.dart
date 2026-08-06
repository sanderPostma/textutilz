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
    required ColorScheme scheme,
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
            style: styleFor(token.kind, scheme),
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
  static TextStyle styleFor(StructuredTokenKind kind, ColorScheme scheme) {
    return TextStyle(
      color: colorFor(kind, scheme),
      fontWeight: switch (kind) {
        StructuredTokenKind.tagName ||
        StructuredTokenKind.key => FontWeight.w600,
        _ => null,
      },
      fontStyle: kind == StructuredTokenKind.comment ? FontStyle.italic : null,
    );
  }

  /// The colour for a token kind under the theme actually in use.
  ///
  /// The palette is *derived* rather than fixed, because a fixed one answers
  /// only to the two themes it was picked against and ignores the scheme the
  /// app is actually running.
  ///
  /// What is derived and what is not matters here. Syntax colouring is a
  /// convention before it is a decoration — green means comment, red means
  /// broken — so deriving *hues* from the scheme would trade that away and
  /// give a pink-seeded theme pink comments. The hue therefore comes from
  /// [_canonical] and stays. What the scheme supplies is a slight tint toward
  /// its primary ([_tint]), enough that the palette belongs to the theme
  /// rather than sitting on top of it.
  ///
  /// Three kinds are taken from the scheme outright, because they are roles
  /// rather than syntax: `invalid` is [ColorScheme.error], so a bad token
  /// matches every other error the app shows, and punctuation and element text
  /// are the scheme's own on-surface colours.
  ///
  /// **Legibility is asserted, not enforced.** An earlier draft solved each
  /// colour's lightness against the surface until it cleared 4.5:1. Probing it
  /// across nine seeds in both brightnesses, that solver never once changed a
  /// colour — Material surfaces are always near-white or near-black, and the
  /// canonical palette already clears the ratio on both — so it was dead code
  /// dressed as a safeguard. The check now lives in
  /// `test/structured_tools_test.dart`, where it guards the same property
  /// without pretending to fix it. If a future theme does fail that test, the
  /// solver is the answer; it is deliberately not here in advance.
  static Color colorFor(StructuredTokenKind kind, ColorScheme scheme) {
    return switch (kind) {
      // Roles, not syntax: the scheme has already decided these.
      StructuredTokenKind.invalid => scheme.error,
      StructuredTokenKind.punctuation => scheme.onSurfaceVariant,
      StructuredTokenKind.text => scheme.onSurface,
      _ => _tintToward(_canonical(kind, scheme.brightness), scheme.primary),
    };
  }

  /// How far a token colour is pulled toward the scheme's primary. Small on
  /// purpose: enough to relate the palette to the theme, not enough to move a
  /// hue into a neighbouring convention.
  static const double _tint = 0.12;

  /// Blend [base] a little way toward [accent], keeping [base]'s character.
  static Color _tintToward(Color base, Color accent) =>
      Color.lerp(base, accent, _tint)!;

  /// The reference colour for a token kind, before the theme is taken into
  /// account.
  ///
  /// Two palettes, chosen by theme brightness. Both follow the convention the
  /// reference editors use — warm for literal data, cool for names and
  /// structure, green for comments, red for anything invalid — so a document
  /// reads the same way in either theme. [colorFor] keeps these hues and fits
  /// them to the scheme actually in use.
  static Color _canonical(StructuredTokenKind kind, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (kind) {
      // Names: keys, attributes, aliases.
      StructuredTokenKind.key || StructuredTokenKind.attributeName =>
        dark ? const Color(0xFF9CDCFE) : const Color(0xFF0451A5),
      // Element names get their own colour so open/close tags stand out from
      // the attributes sitting next to them.
      StructuredTokenKind.tagName =>
        dark ? const Color(0xFF4EC9B0) : const Color(0xFF800000),
      StructuredTokenKind.str =>
        dark ? const Color(0xFFCE9178) : const Color(0xFFA31515),
      StructuredTokenKind.number =>
        dark ? const Color(0xFFB5CEA8) : const Color(0xFF098658),
      StructuredTokenKind.keyword =>
        dark ? const Color(0xFF569CD6) : const Color(0xFF0000FF),
      StructuredTokenKind.punctuation =>
        dark ? const Color(0xFFD4D4D4) : const Color(0xFF505050),
      StructuredTokenKind.comment =>
        dark ? const Color(0xFF6A9955) : const Color(0xFF008000),
      // Element content: the document's actual text, so it stays the plainest
      // thing on screen.
      StructuredTokenKind.text =>
        dark ? const Color(0xFFD4D4D4) : const Color(0xFF1E1E1E),
      StructuredTokenKind.cData =>
        dark ? const Color(0xFFD7BA7D) : const Color(0xFF7A5B00),
      StructuredTokenKind.doctype ||
      StructuredTokenKind.processingInstruction ||
      StructuredTokenKind.directive =>
        dark ? const Color(0xFFC586C0) : const Color(0xFF7B2E8E),
      StructuredTokenKind.entity || StructuredTokenKind.alias =>
        dark ? const Color(0xFFDCDCAA) : const Color(0xFF795E26),
      StructuredTokenKind.invalid =>
        dark ? const Color(0xFFF48771) : const Color(0xFFCC0000),
    };
  }

  /// Background wash for a matched delimiter pair.
  ///
  /// A wash rather than a colour change: the delimiters keep their syntax
  /// colour, so highlighting the pair adds information instead of replacing it.
  ///
  /// Derived from the scheme's primary rather than fixed, so the wash belongs
  /// to the theme; the alpha is what keeps the token underneath legible.
  static Color matchHighlight(ColorScheme scheme) =>
      scheme.primary.withValues(alpha: 0.40);

  /// Colour for the fold gutter's boxes and guide lines. Deliberately quiet —
  /// the gutter is chrome, so it takes the scheme's most muted on-surface
  /// colour rather than competing with the code.
  static Color foldGuide(ColorScheme scheme) => scheme.outline;

  /// The rule drawn across a collapsed row, marking hidden content. Stronger
  /// than [foldGuide]: it stands for text the reader cannot see.
  static Color collapsedRule(ColorScheme scheme) => scheme.onSurfaceVariant;

  /// Squiggle colour for a row carrying a diagnostic.
  ///
  /// The error squiggle is the scheme's own error colour, so it matches every
  /// other error the app shows. Warning has no scheme role, so it keeps its
  /// canonical amber, fitted to the surface like any token colour.
  static Color diagnosticUnderline(
    StructuredSeverity severity,
    ColorScheme scheme,
  ) {
    return switch (severity) {
      StructuredSeverity.error => scheme.error,
      StructuredSeverity.warning =>
        scheme.brightness == Brightness.dark
            ? const Color(0xFFCCA700)
            : const Color(0xFF9A6700),
    };
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/panel_scope_note.dart';

/// The line telling the user whether a transform hits the selection or the
/// whole document. The whole-document case is a warning and has to read as one
/// in both themes — a grey that blends in, or an amber too pale for a light
/// surface, both fail the only job this widget has.
void main() {
  Widget host(
    Widget child, {
    Brightness brightness = Brightness.dark,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(body: child),
  );

  Color colorOf(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).style!.color!;

  /// Relative luminance, for checking contrast against the surface.
  double luminance(Color c) => c.computeLuminance();

  testWidgets('with a selection it states the scope plainly', (tester) async {
    await tester.pumpWidget(
      host(
        const PanelScopeNote(
          enabled: true,
          hasSelection: true,
          disabledMessage: 'nope',
        ),
      ),
    );
    expect(find.text('Transforms the selection.'), findsOneWidget);
  });

  testWidgets('with no selection it warns about the whole document', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const PanelScopeNote(
          enabled: false,
          hasSelection: false,
          disabledMessage: 'Open a document first.',
        ),
      ),
    );
    expect(find.text('Open a document first.'), findsOneWidget);

    await tester.pumpWidget(
      host(
        const PanelScopeNote(
          enabled: true,
          hasSelection: false,
          disabledMessage: 'nope',
        ),
      ),
    );
    expect(find.text('⚠️ Transforms the whole document.'), findsOneWidget);
  });

  testWidgets('the warning is amber, not the ordinary body colour', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        host(
          const PanelScopeNote(
            enabled: true,
            hasSelection: false,
            disabledMessage: 'nope',
          ),
          brightness: brightness,
        ),
      );
      final warning = colorOf(
        tester,
        const ValueKey('panel-scope-document'),
      );
      // Amber: red and green well ahead of blue.
      expect(warning.r, greaterThan(warning.b), reason: '$brightness');
      expect(warning.g, greaterThan(warning.b), reason: '$brightness');

      await tester.pumpWidget(
        host(
          const PanelScopeNote(
            enabled: true,
            hasSelection: true,
            disabledMessage: 'nope',
          ),
          brightness: brightness,
        ),
      );
      final plain = colorOf(tester, const ValueKey('panel-scope-selection'));
      expect(warning, isNot(plain), reason: '$brightness');
    }
  });

  /// The light theme needs a *darker* amber than the dark theme, or it washes
  /// out against a pale surface. Getting this backwards is the bug that made
  /// the first version unreadable in light mode.
  testWidgets('the light-theme amber is dark enough to read', (tester) async {
    final light = PanelScopeNote.warningColor(Brightness.light);
    final dark = PanelScopeNote.warningColor(Brightness.dark);
    expect(
      luminance(light),
      lessThan(luminance(dark)),
      reason: 'light mode needs the darker amber',
    );
    // Comfortably below a white-ish surface, so the text carries real contrast.
    expect(luminance(light), lessThan(0.3));
    // And comfortably above a dark surface.
    expect(luminance(dark), greaterThan(0.3));
  });
}

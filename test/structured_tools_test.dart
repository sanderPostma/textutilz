import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/markup_styling.dart';
import 'package:textutilz/src/rust/api/structured.dart';
import 'package:textutilz/src/rust/frb_generated.dart';
import 'package:textutilz/structured_tools_panel.dart';
import 'package:textutilz/tool_bar.dart';

/// Dart-side tests for the structured-format tooling.
///
/// The formats themselves — lexing, folding, validation, formatting, escaping,
/// detection — are tested in Rust (`rust/src/markup/`), where they live. What
/// is checked here is the part that is genuinely Dart: that token spans become
/// the right [TextSpan]s, that the panels expose the right operations, and that
/// results cross the bridge intact.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  group('markup styling', () {
    test('labels every language', () {
      expect(MarkupStyling.label(StructuredLanguage.json), 'JSON');
      expect(MarkupStyling.label(StructuredLanguage.json5), 'JSON5');
      expect(MarkupStyling.label(StructuredLanguage.yaml), 'YAML');
      expect(MarkupStyling.label(StructuredLanguage.xml), 'XML');
      expect(MarkupStyling.label(StructuredLanguage.plainText), 'Plain Text');
    });

    test('only the lexed formats count as structured', () {
      expect(MarkupStyling.isStructured(StructuredLanguage.plainText), isFalse);
      for (final language in [
        StructuredLanguage.json,
        StructuredLanguage.json5,
        StructuredLanguage.yaml,
        StructuredLanguage.xml,
      ]) {
        expect(MarkupStyling.isStructured(language), isTrue);
      }
    });

    test('a row with no tokens is one plain span', () {
      final span = MarkupStyling.styledLine(
        line: 'hello',
        tokens: const [],
        baseStyle: const TextStyle(fontSize: 12),
        brightness: Brightness.light,
      );
      expect(span.text, 'hello');
      expect(span.children, isNull);
    });

    test('tokens become coloured spans, with the gaps preserved', () {
      const line = '{"a": 1}';
      final span = MarkupStyling.styledLine(
        line: line,
        tokens: const [
          StructuredToken(start: 1, end: 4, kind: StructuredTokenKind.key),
          StructuredToken(start: 6, end: 7, kind: StructuredTokenKind.number),
        ],
        baseStyle: const TextStyle(fontSize: 12),
        brightness: Brightness.light,
      );
      // Every character of the row survives, in order.
      expect(span.children!.map((c) => (c as TextSpan).text).join(), line);
      final coloured = span.children!
          .cast<TextSpan>()
          .where((s) => s.style?.color != null)
          .map((s) => s.text)
          .toList();
      expect(coloured, ['"a"', '1']);
    });

    test('token offsets past the row end are clamped, not thrown', () {
      // The row can change between the token call and the paint.
      final span = MarkupStyling.styledLine(
        line: 'ab',
        tokens: const [
          StructuredToken(start: 1, end: 99, kind: StructuredTokenKind.str),
        ],
        baseStyle: const TextStyle(fontSize: 12),
        brightness: Brightness.light,
      );
      expect(span.children!.map((c) => (c as TextSpan).text).join(), 'ab');
    });

    test('light and dark palettes differ for every kind', () {
      for (final kind in StructuredTokenKind.values) {
        expect(
          MarkupStyling.colorFor(kind, Brightness.light),
          isNot(MarkupStyling.colorFor(kind, Brightness.dark)),
          reason: '$kind should be legible in both themes',
        );
      }
    });
  });

  group('structured operations across the bridge', () {
    test('pretty-print and compact round-trip JSON', () {
      const pretty = StructuredTextOp(
        StructuredLanguage.json,
        StructuredTextAction.prettyPrint,
      );
      const compact = StructuredTextOp(
        StructuredLanguage.json,
        StructuredTextAction.compact,
      );
      final expanded = pretty.apply('{"a":[1,2]}');
      expect(expanded, '{\n  "a": [\n    1,\n    2\n  ]\n}');
      expect(compact.apply(expanded), '{"a":[1,2]}');
    });

    test('an invalid document raises a tool exception naming the position', () {
      const pretty = StructuredTextOp(
        StructuredLanguage.json,
        StructuredTextAction.prettyPrint,
      );
      expect(
        () => pretty.apply('{"a" 1}'),
        throwsA(
          isA<StructuredToolException>().having(
            (e) => e.message,
            'message',
            contains('Line 1'),
          ),
        ),
      );
    });

    test('JSON5 keeps its comments through a pretty-print', () {
      const pretty = StructuredTextOp(
        StructuredLanguage.json5,
        StructuredTextAction.prettyPrint,
      );
      expect(pretty.apply('{\n// note\na: 1}'), contains('// note'));
    });

    test('XML unescape turns entities back into markup', () {
      const unescape = StructuredTextOp(
        StructuredLanguage.xml,
        StructuredTextAction.unescape,
      );
      expect(
        unescape.apply('&lt;field&gt;38&lt;/field&gt;'),
        '<field>38</field>',
      );
    });

    test('escape and unescape are inverses', () {
      const escape = StructuredTextOp(
        StructuredLanguage.xml,
        StructuredTextAction.escape,
      );
      const unescape = StructuredTextOp(
        StructuredLanguage.xml,
        StructuredTextAction.unescape,
      );
      const source = '<a b="1">&</a>';
      expect(unescape.apply(escape.apply(source)), source);
    });

    test('validate reports problems and leaves the text alone', () {
      const validate = StructuredTextOp(
        StructuredLanguage.json,
        StructuredTextAction.validate,
      );
      expect(validate.transformsText, isFalse);
      expect(validate.apply('{"a" 1}'), '{"a" 1}');

      final problems = validate.validate('{"a" 1}');
      expect(problems, hasLength(1));
      expect(problems.first.row, 0);
      expect(problems.first.severity, StructuredSeverity.error);

      expect(validate.validate('{"a": 1}'), isEmpty);
    });
  });

  group('tool bar', () {
    test('handles a docked bar for every structured language', () {
      for (final id in [
        'structured.json',
        'structured.yaml',
        'structured.xml',
      ]) {
        expect(ToolBar.handles(id), isTrue, reason: id);
      }
      // JSON5 is a switch on the JSON bar, not a bar of its own.
      expect(ToolBar.handles('structured.json5'), isFalse);
    });

    testWidgets('the JSON bar exposes every operation', (tester) async {
      StructuredTextOp? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolBar(
              panelId: 'structured.json',
              editToolsEnabled: true,
              mimeToolsEnabled: true,
              mimeHasSelection: false,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onRunStructuredOp: (op) => selected = op,
              onClose: () {},
            ),
          ),
        ),
      );

      expect(find.text('JSON tools'), findsOneWidget);
      expect(find.text('Pretty-print'), findsOneWidget);
      expect(find.text('Compact / minify'), findsOneWidget);
      expect(find.text('Validate'), findsOneWidget);
      expect(find.text('Escape'), findsOneWidget);
      expect(find.text('Unescape'), findsOneWidget);
      expect(find.text('⚠️ Transforms the whole document.'), findsOneWidget);

      await tester.tap(find.text('Compact / minify'));
      expect(selected?.language, StructuredLanguage.json);
      expect(selected?.action, StructuredTextAction.compact);

      await tester.tap(find.text('Validate'));
      expect(selected?.action, StructuredTextAction.validate);
    });

    /// Every operation button should look the same; the first one used to be a
    /// filled button among tonal ones for no reason.
    testWidgets('all operation buttons share one style', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolBar(
              panelId: 'structured.xml',
              editToolsEnabled: true,
              mimeToolsEnabled: true,
              mimeHasSelection: false,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onRunStructuredOp: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      final buttons = tester
          .widgetList<FilledButton>(find.byType(FilledButton))
          .toList();
      expect(buttons, hasLength(5));
      final styles = buttons.map((b) => b.style).toSet();
      expect(styles, hasLength(1), reason: 'one shared ButtonStyle');
    });

    testWidgets('the JSON5 switch retitles the bar and retargets the ops', (
      tester,
    ) async {
      StructuredTextOp? selected;
      var json5 = false;

      Widget host() => MaterialApp(
        home: Scaffold(
          body: ToolBar(
            panelId: 'structured.json',
            editToolsEnabled: true,
            mimeToolsEnabled: true,
            mimeHasSelection: true,
            onRunEditOp: (_) {},
            onRunMimeOp: (_) {},
            onRunStructuredOp: (op) => selected = op,
            structuredUseJson5: json5,
            onStructuredUseJson5Changed: (on) => json5 = on,
            onClose: () {},
          ),
        ),
      );

      await tester.pumpWidget(host());
      expect(find.text('JSON tools'), findsOneWidget);
      await tester.tap(find.text('Pretty-print'));
      expect(selected?.language, StructuredLanguage.json);

      await tester.tap(find.byKey(const ValueKey('structured-json5-switch')));
      expect(json5, isTrue);

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.text('JSON5 tools'), findsOneWidget);
      await tester.tap(find.text('Pretty-print'));
      expect(selected?.language, StructuredLanguage.json5);
    });

    testWidgets('only the JSON bar offers the dialect switch', (tester) async {
      for (final entry in {
        'structured.json': true,
        'structured.yaml': false,
        'structured.xml': false,
      }.entries) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ToolBar(
                panelId: entry.key,
                editToolsEnabled: true,
                mimeToolsEnabled: true,
                mimeHasSelection: true,
                onRunEditOp: (_) {},
                onRunMimeOp: (_) {},
                onRunStructuredOp: (_) {},
                onClose: () {},
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('structured-json5-switch')),
          entry.value ? findsOneWidget : findsNothing,
          reason: entry.key,
        );
        // Auto-validate is offered by every structured bar.
        expect(
          find.byKey(const ValueKey('structured-autovalidate-switch')),
          findsOneWidget,
          reason: entry.key,
        );
      }
    });

    testWidgets('the auto-validate switch reports its changes', (tester) async {
      bool? reported;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolBar(
              panelId: 'structured.yaml',
              editToolsEnabled: true,
              mimeToolsEnabled: true,
              mimeHasSelection: true,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onRunStructuredOp: (_) {},
              structuredAutoValidate: false,
              onStructuredAutoValidateChanged: (on) => reported = on,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('structured-autovalidate-switch')),
      );
      expect(reported, isTrue);
    });

    /// Validate sits last, next to the switch that supersedes it.
    testWidgets('validate is the last operation button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolBar(
              panelId: 'structured.xml',
              editToolsEnabled: true,
              mimeToolsEnabled: true,
              mimeHasSelection: true,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onRunStructuredOp: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      final actions = tester
          .widgetList<FilledButton>(find.byType(FilledButton))
          .map((b) => ((b.key as ValueKey<String>).value).split('-')[1])
          .toList();
      expect(actions.last, 'validate');
      expect(actions, [
        'prettyPrint',
        'compact',
        'escape',
        'unescape',
        'validate',
      ]);
    });

    testWidgets('auto-validate disables the Validate button', (tester) async {
      Widget host(bool autoValidate) => MaterialApp(
        home: Scaffold(
          body: ToolBar(
            panelId: 'structured.yaml',
            editToolsEnabled: true,
            mimeToolsEnabled: true,
            mimeHasSelection: true,
            onRunEditOp: (_) {},
            onRunMimeOp: (_) {},
            onRunStructuredOp: (_) {},
            structuredAutoValidate: autoValidate,
            onClose: () {},
          ),
        ),
      );

      final validate = find.byKey(
        const ValueKey('structured-validate-yaml'),
      );

      await tester.pumpWidget(host(false));
      expect(tester.widget<FilledButton>(validate).onPressed, isNotNull);

      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(validate).onPressed, isNull);
      // The other operations stay available.
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('structured-prettyPrint-yaml')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a disabled bar disables its switches too', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolBar(
              panelId: 'structured.json',
              editToolsEnabled: false,
              mimeToolsEnabled: false,
              mimeHasSelection: false,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onRunStructuredOp: (_) {},
              onStructuredUseJson5Changed: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      final toggle = tester.widget<Switch>(
        find.byKey(const ValueKey('structured-json5-switch')),
      );
      expect(toggle.onChanged, isNull);
    });
  });
}

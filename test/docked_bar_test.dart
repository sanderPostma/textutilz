import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/docked_bar.dart';

void main() {
  Widget host(Widget bar) => MaterialApp(
    home: Scaffold(body: Column(children: [bar])),
  );

  testWidgets('shows the title tab when a title is given', (tester) async {
    await tester.pumpWidget(
      host(
        DockedBar(
          title: 'Comment/Uncomment',
          onClose: () {},
          child: const Text('content'),
        ),
      ),
    );
    expect(find.text('Comment/Uncomment'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('shows no tab when the title is null', (tester) async {
    // Only the child's text is present — no title chrome at all.
    await tester.pumpWidget(
      host(DockedBar(onClose: () {}, child: const Text('content'))),
    );
    expect(find.byType(Text), findsOneWidget);

    // Geometry, not just widget count: a zero-height padded row or empty box
    // standing in for the tab would still leave exactly one Text in the
    // tree, but would still add height. Compare against the same child with
    // a title to confirm the untitled bar is strictly shorter, and pins
    // down its height exactly: the child's own height plus the bar's fixed
    // vertical padding (4 top + 4 bottom, from the padding in `build`).
    const child = SizedBox(height: 40, child: Text('content'));
    await tester.pumpWidget(host(DockedBar(onClose: () {}, child: child)));
    final untitledHeight = tester.getSize(find.byType(DockedBar)).height;

    await tester.pumpWidget(
      host(DockedBar(title: 'Some Title', onClose: () {}, child: child)),
    );
    final titledHeight = tester.getSize(find.byType(DockedBar)).height;

    expect(untitledHeight, lessThan(titledHeight));
    expect(untitledHeight, 40 + 4 + 4);
  });

  testWidgets('close button invokes onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      host(
        DockedBar(
          title: 'Convert Case',
          onClose: () => closed = true,
          child: const Text('content'),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Close (Esc)'));
    expect(closed, isTrue);
  });

  testWidgets('does not overflow at a narrow width', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        DockedBar(
          title: 'Blank Operations',
          onClose: () {},
          child: Wrap(
            children: List.generate(
              8,
              (i) => Padding(
                padding: const EdgeInsets.all(2),
                child: Text('Operation number $i'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'close button stays pinned to the first row when the child grows',
    (tester) async {
      // Single-row child.
      await tester.pumpWidget(
        host(
          DockedBar(
            onClose: () {},
            child: const SizedBox(height: 40, child: Text('one row')),
          ),
        ),
      );
      final singleRowY = tester.getCenter(find.byTooltip('Close (Esc)')).dy;

      // Two-row child, as the find bar looks in replace mode.
      await tester.pumpWidget(
        host(
          DockedBar(
            onClose: () {},
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: 40, child: Text('one row')),
                SizedBox(height: 40, child: Text('two rows')),
              ],
            ),
          ),
        ),
      );
      final twoRowY = tester.getCenter(find.byTooltip('Close (Esc)')).dy;

      expect(
        twoRowY,
        singleRowY,
        reason:
            'the close button must stay with the first row, not drift to the '
            'centre of a taller child',
      );
    },
  );

  /// The title band spans the bar's full width and takes its colours from the
  /// active ColorScheme, so it tracks both themes without either being
  /// special-cased. A hardcoded colour would look right in one theme and
  /// unreadable in the other, which no other test here would notice.
  Widget themedHost(Brightness brightness, Widget bar) => MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: brightness),
    home: Scaffold(body: Column(children: [bar])),
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'title band uses scheme colours and full width in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(900, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          themedHost(
            brightness,
            DockedBar(
              title: 'MIME tools',
              onClose: () {},
              child: const Text('content'),
            ),
          ),
        );

        final context = tester.element(find.text('MIME tools'));
        final scheme = Theme.of(context).colorScheme;

        final band = tester.widget<Container>(
          find
              .ancestor(
                of: find.text('MIME tools'),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          band.color,
          scheme.secondaryContainer,
          reason: 'the band must follow the theme, not a fixed colour',
        );

        final label = tester.widget<Text>(find.text('MIME tools'));
        expect(
          label.style?.color,
          scheme.onSecondaryContainer,
          reason: 'label colour must be the scheme pairing for the band',
        );
        expect(
          label.style?.color,
          isNot(scheme.onSurfaceVariant),
          reason: 'the label is meant to read differently from body text',
        );

        expect(
          tester.getSize(find.byWidget(band)).width,
          900,
          reason: 'the band spans the full bar width',
        );
      },
    );
  }
}

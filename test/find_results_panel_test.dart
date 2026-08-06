import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/find_results_panel.dart';
import 'package:textutilz/find_state.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/search.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  EditSession sessionWith(String content) {
    final path =
        '${Directory.systemTemp.path}/textutilz_results_${DateTime.now().microsecondsSinceEpoch}.txt';
    return EditSession.createScratch(path: path, content: content);
  }

  test(
    'FindController.findAll populates searchResults list and isSearchResultsVisible',
    () async {
      final session = sessionWith('first match\nsecond line\nthird match\n');
      final c = FindController();
      c.attach(session, session.lineCount().toInt());
      c.query.text = 'match';

      final count = await c.findAll();
      expect(count, equals(2));
      expect(c.isSearchResultsVisible, isTrue);
      expect(c.searchResults.length, equals(2));
      expect(c.searchResults[0].span.startRow.toInt(), equals(0));
      expect(c.searchResults[0].lineText, equals('first match'));
      expect(c.searchResults[1].span.startRow.toInt(), equals(2));
      expect(c.searchResults[1].lineText, equals('third match'));

      final beforeSelect = c.revealTick;
      c.selectSearchResult(c.searchResults[1].span);
      expect(c.currentIndex, 1);
      expect(c.currentMatch, same(c.searchResults[1].span));
      expect(c.counterLabel, '2 of 2');
      expect(c.revealTick, greaterThan(beforeSelect));

      c.closeSearchResults();
      expect(c.isSearchResultsVisible, isFalse);
    },
  );

  test('attaching another document clears Find All results', () async {
    final first = sessionWith('match\n');
    final second = sessionWith('no result\n');
    final c = FindController();
    c.attach(first, first.lineCount().toInt());
    c.query.text = 'match';

    await c.findAll();
    expect(c.isSearchResultsVisible, isTrue);

    c.attach(second, second.lineCount().toInt());
    expect(c.isSearchResultsVisible, isFalse);
    expect(c.searchResults, isEmpty);
  });

  test('invalid regex is reported in the results pane state', () async {
    final session = sessionWith('anything\n');
    final c = FindController();
    c.attach(session, session.lineCount().toInt());
    c.searchMode = SearchMode.regex;
    c.query.text = '[';

    expect(await c.findAll(), 0);
    expect(c.isSearchResultsVisible, isTrue);
    expect(c.searchResults, isEmpty);
    expect(c.searchResultsError, isNotNull);
  });

  test(
    'Find All includes matches on both sides of a paging boundary',
    () async {
      final lines = List<String>.generate(
        kSearchWindowRows + 2,
        (index) => index == kSearchWindowRows - 1 || index == kSearchWindowRows
            ? 'context match line $index'
            : 'line $index',
      );
      final session = sessionWith(lines.join('\n'));
      final c = FindController();
      c.attach(session, session.lineCount().toInt());
      c.query.text = 'match';

      expect(await c.findAll(), 2);
      expect(c.searchResults.map((item) => item.span.startRow.toInt()), [
        kSearchWindowRows - 1,
        kSearchWindowRows,
      ]);
      expect(c.searchResults.first.lineText, contains('context match'));
    },
  );

  testWidgets('FindResultsPanel renders match header and list items', (
    tester,
  ) async {
    final item1 = FindResultItem(
      MatchSpan(
        startRow: BigInt.from(0),
        startCol: BigInt.from(6),
        endRow: BigInt.from(0),
        endCol: BigInt.from(11),
      ),
      'first match',
    );
    final item2 = FindResultItem(
      MatchSpan(
        startRow: BigInt.from(2),
        startCol: BigInt.from(6),
        endRow: BigInt.from(2),
        endCol: BigInt.from(11),
      ),
      'third match',
    );

    MatchSpan? selectedSpan;
    bool closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FindResultsPanel(
            query: 'match',
            results: [item1, item2],
            onClose: () => closed = true,
            onSelectResult: (span) => selectedSpan = span,
          ),
        ),
      ),
    );

    expect(find.text('Search Results: 2 matches for "match"'), findsOneWidget);
    expect(find.text('Line 1, Col 7'), findsOneWidget);
    expect(find.text('first match'), findsOneWidget);
    expect(find.text('Line 3, Col 7'), findsOneWidget);
    expect(find.text('third match'), findsOneWidget);

    await tester.tap(find.text('third match'));
    await tester.pumpAndSettle();
    expect(selectedSpan, isNull);

    await tester.tap(find.text('third match'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('third match'));
    await tester.pumpAndSettle();

    expect(selectedSpan, equals(item2.span));
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('find-result-highlight-1')),
          )
          .color,
      isNot(Colors.transparent),
    );

    await tester.tap(find.text('first match'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('first match'));
    await tester.pumpAndSettle();

    expect(selectedSpan, equals(item1.span));
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('find-result-highlight-0')),
          )
          .color,
      isNot(Colors.transparent),
    );
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('find-result-highlight-1')),
          )
          .color,
      Colors.transparent,
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closed, isTrue);
  });

  testWidgets('results header scroll buttons navigate the list', (
    tester,
  ) async {
    final results = List<FindResultItem>.generate(30, (index) {
      return FindResultItem(
        MatchSpan(
          startRow: BigInt.from(index),
          startCol: BigInt.zero,
          endRow: BigInt.from(index),
          endCol: BigInt.one,
        ),
        'result $index',
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FindResultsPanel(
            query: 'result',
            results: results,
            onClose: () {},
            onSelectResult: (_) {},
          ),
        ),
      ),
    );

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, 0);

    await tester.tap(find.byTooltip('Page down'));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));

    await tester.tap(find.byTooltip('Bottom'));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);

    await tester.tap(find.byTooltip('Page up'));
    await tester.pumpAndSettle();
    expect(
      scrollable.position.pixels,
      lessThan(scrollable.position.maxScrollExtent),
    );

    await tester.tap(find.byTooltip('Top'));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, 0);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

/// Why the title bar's controls must sit *outside* `DragToMoveArea`.
///
/// `DragToMoveArea` is a `GestureDetector` carrying an `onDoubleTap` for
/// double-click-to-maximise. Its `DoubleTapGestureRecognizer` holds the gesture
/// arena open for `kDoubleTapTimeout` (300ms) after the first tap, and while the
/// arena is held it cannot be swept — so a button underneath cannot be declared
/// the winner and its `onPressed` never runs. That is a 300ms tax on every
/// control in the bar, which is what made the menu button feel slow next to the
/// Alt-X shortcut (which fires on key *down*).
///
/// These tests pin the behaviour with a minimal reproduction rather than by
/// pumping the whole app, so they stay fast and say plainly what the rule is.
void main() {
  Widget host({required bool wrapButton}) {
    final button = Builder(
      builder: (context) => IconButton(
        key: const ValueKey('probe-button'),
        icon: const Icon(Icons.menu),
        onPressed: () =>
            (context.findAncestorStateOfType<_CounterState>())!.bump(),
      ),
    );
    return MaterialApp(
      home: Scaffold(
        body: _Counter(
          child: Row(
            children: [
              if (wrapButton) DragToMoveArea(child: button) else button,
              const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
            ],
          ),
        ),
      ),
    );
  }

  int pressesAfter(WidgetTester tester) =>
      tester.state<_CounterState>(find.byType(_Counter)).presses;

  testWidgets('a button inside the drag area does not fire on release', (
    tester,
  ) async {
    await tester.pumpWidget(host(wrapButton: true));
    await tester.tap(find.byKey(const ValueKey('probe-button')));
    await tester.pump();
    expect(
      pressesAfter(tester),
      0,
      reason: 'the double-tap recognizer is still holding the arena',
    );

    // It only lands once the double-tap window closes.
    await tester.pump(const Duration(milliseconds: 300));
    expect(pressesAfter(tester), 1);
  });

  testWidgets('a button outside the drag area fires immediately', (
    tester,
  ) async {
    await tester.pumpWidget(host(wrapButton: false));
    await tester.tap(find.byKey(const ValueKey('probe-button')));
    await tester.pump();
    expect(
      pressesAfter(tester),
      1,
      reason: 'nothing competes for the arena, so the tap resolves at once',
    );
  });
}

class _Counter extends StatefulWidget {
  final Widget child;

  const _Counter({required this.child});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int presses = 0;

  void bump() => setState(() => presses++);

  @override
  Widget build(BuildContext context) => widget.child;
}

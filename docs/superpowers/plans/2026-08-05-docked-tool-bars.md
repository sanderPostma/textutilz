# Docked Tool Bars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the 11 MIME/edit ribbon panels into slim bars docked above the editor, so the selection they transform stays visible, and cut their height from ~190px to ~52–84px.

**Architecture:** Extract the find bar's chrome into a shared `DockedBar` (surface, centered title tab, right-pinned close, overflow-proof layout). The find bar adopts it with no visual change, then the edit and MIME panels become bar content. `main.dart` holds one extra piece of state, `_activeToolPanelId`, and enforces "one bar at a time" in the two open functions.

**Tech Stack:** Flutter/Dart only. No Rust changes, no `flutter_rust_bridge_codegen` run.

Spec: `docs/superpowers/specs/2026-08-05-docked-tool-bars-design.md`

## Global Constraints

- **No Rust changes and no codegen in this plan.** It is presentation only.
- Dart is a thin UI shell; domain logic lives in Rust. Do not move or reimplement any operation logic.
- **The find bar's appearance must not change.** It adopts `DockedBar` but passes no title, so no tab appears. `test/find_panel_layout_test.dart` is the guard — it must keep passing untouched.
- **Only one bar at a time.** Opening the find bar closes any tool bar and vice versa. Enforced in `_openFind` / `_openToolBar` and nowhere else.
- **Both bars dock between the window chrome and the document tab bar** — NOT between the tab bar and the editor. The title tab must hang from the window chrome; below the tab bar it appears to dangle off the file tabs. This moves the find bar up from where it sits today; its appearance is unchanged, only its slot in the column.
- Bars must never overflow at any width. Rigid: the close button. Flexible/wrapping: everything else.
- Panels that stay in the ribbon: `new` and `autodelete`. `RibbonPanelScaffold` is NOT deleted.
- Verification for every task:
  ```
  flutter analyze                                   # 0 errors (32 pre-existing lint infos are fine)
  cd rust && cargo build && cd .. && \
    LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test
  ```
  Baseline: **Dart 50 passed / 0 failed** — the suite is fully green, so ANY failure is yours. Rust is 134/0 and you should not be touching it.
- The cargo target dir is `~/.cargo/target`, NOT `rust/target`. Without `LD_LIBRARY_PATH` any test calling `RustLib.init()` fails to load the `.so` — that is environment, not your code.

## File Structure

| File | Responsibility |
|---|---|
| `lib/docked_bar.dart` (create) | `DockedBar` — shared chrome: surface, padding, optional centered title tab, right-pinned close button. |
| `lib/find_panel.dart` (modify) | Adopts `DockedBar` for its outer shell. No visual change. |
| `lib/edit_tools_panel.dart` (modify) | Becomes stateless; chips become immediate-apply action buttons; `Apply` removed. |
| `lib/mime_tools_panel.dart` (modify) | Frame only: drop `Align`/`ConstrainedBox`, fold `Apply` into the `Wrap`. |
| `lib/tool_bar.dart` (create) | `ToolBar` — maps a `panelId` to its title and content widget, wrapped in a `DockedBar`. |
| `lib/menu_ribbon.dart` (modify) | New `onOpenToolBar` callback; the 11 mime/edit commands route to it. |
| `lib/main.dart` (modify) | `_activeToolPanelId` state, `_openToolBar`, mutual exclusion, Esc generalisation, bar placement. |
| `test/docked_bar_test.dart` (create) | Title tab rendering and close button behaviour. |
| `test/tool_bar_layout_test.dart` (create) | Width sweep 400→1600 over the widest edit bar and a MIME bar. |

---

### Task 1: `DockedBar` — the shared chrome

Phase 1 of the spec, and deliberately a visual no-op. If `test/find_panel_layout_test.dart` still passes after the find bar adopts `DockedBar`, the component is sound.

**Files:**
- Create: `lib/docked_bar.dart`
- Create: `test/docked_bar_test.dart`
- Modify: `lib/find_panel.dart` (the `Container` at the root of `build`, ~line 420)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class DockedBar extends StatelessWidget`
  - `const DockedBar({Key? key, String? title, required Widget child, required VoidCallback onClose})`
  - Renders: optional centered title tab row, then a `Row` of `[Expanded(child), closeButton]`.

- [ ] **Step 1: Write the failing test**

Create `test/docked_bar_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/docked_bar.dart';

void main() {
  Widget host(Widget bar) => MaterialApp(home: Scaffold(body: Column(children: [bar])));

  testWidgets('shows the title tab when a title is given', (tester) async {
    await tester.pumpWidget(host(DockedBar(
      title: 'Comment/Uncomment',
      onClose: () {},
      child: const Text('content'),
    )));
    expect(find.text('Comment/Uncomment'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('shows no tab when the title is null', (tester) async {
    await tester.pumpWidget(host(DockedBar(
      onClose: () {},
      child: const Text('content'),
    )));
    // Only the child's text is present — no title chrome at all.
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('close button invokes onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(host(DockedBar(
      title: 'Convert Case',
      onClose: () => closed = true,
      child: const Text('content'),
    )));
    await tester.tap(find.byTooltip('Close (Esc)'));
    expect(closed, isTrue);
  });

  testWidgets('does not overflow at a narrow width', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(DockedBar(
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
    )));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test test/docked_bar_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:textutilz/docked_bar.dart'`.

- [ ] **Step 3: Write the implementation**

Create `lib/docked_bar.dart`:

```dart
import 'package:flutter/material.dart';

/// The chrome shared by every bar docked above the editor — the find bar and
/// the MIME/edit tool bars.
///
/// Owns the surface, the optional centered title tab, and the close button.
/// The caller supplies only its controls.
///
/// Layout contract, inherited from the find bar and guarded by width-sweep
/// tests: the close button is RIGID and must stay reachable at every width;
/// [child] is given the remaining space and must be able to shrink or wrap
/// rather than overflow.
class DockedBar extends StatelessWidget {
  /// Shown in a rounded tab centered on the bar's top edge. When null no tab
  /// is drawn at all — that is how the find bar keeps its original look.
  final String? title;

  final Widget child;
  final VoidCallback onClose;

  const DockedBar({
    super.key,
    this.title,
    required this.child,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) _titleTab(scheme, title!),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: child),
              _closeButton(),
            ],
          ),
        ],
      ),
    );
  }

  /// A pill with rounded BOTTOM corners in the bar's own colour, sitting in an
  /// otherwise transparent row, so it reads as hanging from the chrome above
  /// rather than as a heading inside the bar.
  Widget _titleTab(ColorScheme scheme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _closeButton() => IconButton(
        icon: const Icon(Icons.close, size: 18),
        tooltip: 'Close (Esc)',
        onPressed: onClose,
        visualDensity: VisualDensity.compact,
      );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test test/docked_bar_test.dart`
Expected: PASS, 4 tests.

- [ ] **Step 5: Adopt it in the find bar**

In `lib/find_panel.dart`, add the import:

```dart
import 'docked_bar.dart';
```

The find bar's `build` currently returns a `Container(color: ..., padding: ..., child: Column(...))` whose `Column` ends with its own close button inside `_findRow`. Replace ONLY the outer `Container` with a `DockedBar` that passes no title, and hand it the existing `Column` as `child`.

The find bar already has its own close button inside `_findRow`. To avoid two close buttons, delete `_closeButton()` from `_findRow`'s children and let `DockedBar` supply it — the tooltip text is identical, so `test/find_panel_layout_test.dart`'s `find.byTooltip('Close (Esc)')` assertion keeps working.

- [ ] **Step 6: Verify the find bar is unchanged**

Run: `LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test`
Expected: 54 passed / 0 failed (50 baseline + 4 new). `test/find_panel_layout_test.dart`'s width sweep must pass untouched — that is the proof the shared chrome preserves the overflow-proof contract.

Run: `flutter analyze`
Expected: 0 errors.

- [ ] **Step 7: Commit**

```bash
git add lib/docked_bar.dart lib/find_panel.dart test/docked_bar_test.dart
git commit -m "feat(ui): extract DockedBar chrome and adopt it in the find bar"
```

---

### Task 2: Edit tools become immediate-apply actions

**Files:**
- Modify: `lib/edit_tools_panel.dart` (whole file — it loses its state)

**Interfaces:**
- Consumes: `EditOp({required String opId, required String label})` — unchanged.
- Produces:
  - `class EditToolsPanel extends StatelessWidget` (was `StatefulWidget`)
  - `const EditToolsPanel({Key? key, required bool enabled, required ValueChanged<EditOp> onRun, required EditCategory category})` — the constructor signature is UNCHANGED, so `menu_ribbon.dart` needs no edit for this task.

- [ ] **Step 1: Write the failing test**

Create `test/edit_tools_panel_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/edit_tools_panel.dart';

void main() {
  Widget host({required bool enabled, required ValueChanged<EditOp> onRun}) =>
      MaterialApp(
        home: Scaffold(
          body: EditToolsPanel(
            enabled: enabled,
            onRun: onRun,
            category: EditCategory.commentOps,
          ),
        ),
      );

  testWidgets('clicking an operation runs it immediately', (tester) async {
    EditOp? ran;
    await tester.pumpWidget(host(enabled: true, onRun: (op) => ran = op));
    await tester.tap(find.text('Block Comment'));
    await tester.pump();
    expect(ran, isNotNull);
    expect(ran!.opId, 'edit.comment.block_comment');
  });

  testWidgets('there is no Apply button', (tester) async {
    await tester.pumpWidget(host(enabled: true, onRun: (_) {}));
    expect(find.textContaining('Apply'), findsNothing);
  });

  testWidgets('operations do not run when disabled', (tester) async {
    var ran = false;
    await tester.pumpWidget(host(enabled: false, onRun: (_) => ran = true));
    await tester.tap(find.text('Block Comment'), warnIfMissed: false);
    await tester.pump();
    expect(ran, isFalse);
  });
}
```

(`edit.comment.block_comment` is the real id, verified against the `_commentOps` list in `lib/edit_tools_panel.dart:99`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test test/edit_tools_panel_test.dart`
Expected: FAIL — the Apply-button test fails because "Apply …" is still rendered, and the click test fails because clicking a chip only selects it.

- [ ] **Step 3: Rewrite the panel as stateless actions**

In `lib/edit_tools_panel.dart`:

1. Change `class EditToolsPanel extends StatefulWidget` to `extends StatelessWidget`, delete `createState` and the whole `_EditToolsPanelState` scaffolding, and move `build` onto the widget. Fields become `widget.enabled` → `enabled`, etc.
2. Delete the four `_selected*Op` fields and the `_currentOp` getter — with immediate apply there is nothing to remember.
3. Keep the four `(String, String)` op lists exactly as they are.
4. Replace `build` with:

```dart
  @override
  Widget build(BuildContext context) {
    final ops = switch (category) {
      EditCategory.caseConv => _caseOps,
      EditCategory.eolConv => _eolOps,
      EditCategory.blankOps => _blankOps,
      EditCategory.commentOps => _commentOps,
    };
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: ops
          .map((op) => ActionChip(
                label: Text(op.$2),
                onPressed: enabled ? () => onRun(EditOp(opId: op.$1, label: op.$2)) : null,
              ))
          .toList(),
    );
  }
```

Delete `_buildChoiceList` — `ActionChip` replaces `ChoiceChip`, and an `ActionChip` with a null `onPressed` renders disabled, which is what the third test asserts.

Note the outer `Align` + `ConstrainedBox(maxWidth: 680)` are gone: the bar owns width now.

- [ ] **Step 4: Run the test to verify it passes**

Run: `LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test test/edit_tools_panel_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 5: Verify nothing else broke**

Run: `flutter analyze && LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test`
Expected: 0 analyzer errors. The panel is still referenced by `menu_ribbon.dart` with an unchanged constructor, so it keeps compiling.

- [ ] **Step 6: Commit**

```bash
git add lib/edit_tools_panel.dart test/edit_tools_panel_test.dart
git commit -m "feat(ui): edit tools apply on click, drop the Apply button"
```

---

### Task 3: `ToolBar` — panel id to a docked bar

**Files:**
- Create: `lib/tool_bar.dart`
- Create: `test/tool_bar_layout_test.dart`
- Modify: `lib/mime_tools_panel.dart` (the `build` of `SingleMimeToolPanel`, ~line 147)

**Interfaces:**
- Consumes: `DockedBar` (Task 1), `EditToolsPanel` (Task 2), `SingleMimeToolPanel`, `MimeCategory`, `EditCategory`.
- Produces:
  - `class ToolBar extends StatelessWidget`
  - `const ToolBar({Key? key, required String panelId, required bool editToolsEnabled, required bool mimeToolsEnabled, required bool mimeHasSelection, required ValueChanged<EditOp> onRunEditOp, required ValueChanged<MimeOp> onRunMimeOp, required VoidCallback onClose})`
  - `static bool handles(String panelId)` — true for the 11 mime/edit ids, false for `new` and `autodelete`.

- [ ] **Step 1: Write the failing test**

Create `test/tool_bar_layout_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/tool_bar.dart';

void main() {
  Widget host(String panelId) => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ToolBar(
              panelId: panelId,
              editToolsEnabled: true,
              mimeToolsEnabled: true,
              mimeHasSelection: true,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onClose: () {},
            ),
          ]),
        ),
      );

  /// Pump the bar across a range of widths, asserting no overflow at any of
  /// them. Two hand-picked widths have twice failed to catch real overflow in
  /// this codebase; a sweep is what actually bites.
  Future<void> sweep(WidgetTester tester, String panelId) async {
    for (double w = 400; w <= 1600; w += 40) {
      tester.view.physicalSize = Size(w, 600);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(host(panelId));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
    }
  }

  testWidgets('handles() claims the mime/edit panels only', (tester) async {
    expect(ToolBar.handles('edit.comment'), isTrue);
    expect(ToolBar.handles('mime.base64.encode'), isTrue);
    expect(ToolBar.handles('new'), isFalse);
    expect(ToolBar.handles('autodelete'), isFalse);
  });

  testWidgets('edit bar shows its title tab', (tester) async {
    await tester.pumpWidget(host('edit.comment'));
    expect(find.text('Comment/Uncomment'), findsOneWidget);
  });

  testWidgets('mime bar shows its title tab', (tester) async {
    await tester.pumpWidget(host('mime.base64.encode'));
    expect(find.text('Base64 Encode'), findsOneWidget);
  });

  testWidgets('widest edit bar does not overflow across a width sweep',
      (tester) async {
    addTearDown(tester.view.reset);
    // Blank Operations has 8 long labels — the worst case.
    await sweep(tester, 'edit.blank');
  });

  testWidgets('mime bar does not overflow across a width sweep',
      (tester) async {
    addTearDown(tester.view.reset);
    await sweep(tester, 'mime.base64.encode');
  });

  testWidgets('close button stays reachable at 400px', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host('edit.blank'));
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test test/tool_bar_layout_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:textutilz/tool_bar.dart'`.

- [ ] **Step 3: Compact the MIME panel's frame**

In `lib/mime_tools_panel.dart`, in `SingleMimeToolPanel.build`, remove the outer `Align` + `ConstrainedBox(maxWidth: 560)` and the `Column`, and return a single `Wrap` holding the option checkboxes followed by the `Apply` button, so it lays out as one flowing row that wraps when tight:

```dart
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...optionWidgets,          // the existing _check(...) widgets
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow, size: 16),
          label: const Text('Apply'),
          onPressed: enabled ? () => onRun(currentOp) : null,
        ),
      ],
    );
```

Keep the existing option and op-building logic exactly as it is — only the surrounding layout changes. The `Apply` label shortens from `Apply <op name>` to just `Apply`, because the title tab now names the operation.

- [ ] **Step 4: Write `ToolBar`**

Create `lib/tool_bar.dart`:

```dart
import 'package:flutter/material.dart';

import 'docked_bar.dart';
import 'edit_tools_panel.dart';
import 'mime_tools_panel.dart';

/// One row of tool controls, docked above the editor.
///
/// Maps a ribbon `panelId` to its title and content. Only the MIME and edit
/// panels become bars — `new` and `autodelete` are forms and stay inside the
/// ribbon, which is what [handles] distinguishes.
class ToolBar extends StatelessWidget {
  final String panelId;
  final bool editToolsEnabled;
  final bool mimeToolsEnabled;
  final bool mimeHasSelection;
  final ValueChanged<EditOp> onRunEditOp;
  final ValueChanged<MimeOp> onRunMimeOp;
  final VoidCallback onClose;

  const ToolBar({
    super.key,
    required this.panelId,
    required this.editToolsEnabled,
    required this.mimeToolsEnabled,
    required this.mimeHasSelection,
    required this.onRunEditOp,
    required this.onRunMimeOp,
    required this.onClose,
  });

  /// Panel ids that dock as a bar. Everything else stays in the ribbon.
  static bool handles(String panelId) =>
      _editSpecs.containsKey(panelId) || _mimeSpecs.containsKey(panelId);

  static const Map<String, (EditCategory, String)> _editSpecs = {
    'edit.case': (EditCategory.caseConv, 'Convert Case'),
    'edit.eol': (EditCategory.eolConv, 'EOL Conversion'),
    'edit.blank': (EditCategory.blankOps, 'Blank Operations'),
    'edit.comment': (EditCategory.commentOps, 'Comment/Uncomment'),
  };

  static const Map<String, (MimeCategory, bool, String)> _mimeSpecs = {
    'mime.base64.encode': (MimeCategory.base64, false, 'Base64 Encode'),
    'mime.base64.decode': (MimeCategory.base64, true, 'Base64 Decode'),
    'mime.qp.encode': (MimeCategory.quotedPrintable, false, 'Quoted-printable Encode'),
    'mime.qp.decode': (MimeCategory.quotedPrintable, true, 'Quoted-printable Decode'),
    'mime.url.encode': (MimeCategory.url, false, 'URL Encode'),
    'mime.url.decode': (MimeCategory.url, true, 'URL Decode'),
    'mime.saml.decode': (MimeCategory.saml, true, 'SAML Decode'),
  };

  @override
  Widget build(BuildContext context) {
    final edit = _editSpecs[panelId];
    if (edit != null) {
      return DockedBar(
        title: edit.$2,
        onClose: onClose,
        child: EditToolsPanel(
          enabled: editToolsEnabled,
          category: edit.$1,
          onRun: onRunEditOp,
        ),
      );
    }
    final mime = _mimeSpecs[panelId]!;
    return DockedBar(
      title: mime.$3,
      onClose: onClose,
      child: SingleMimeToolPanel(
        enabled: mimeToolsEnabled,
        hasSelection: mimeHasSelection,
        category: mime.$1,
        initialDecode: mime.$2,
        onRun: onRunMimeOp,
      ),
    );
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test test/tool_bar_layout_test.dart`
Expected: PASS, 6 tests.

If a sweep fails, the fix is in the content widget's `Wrap`, not in `DockedBar` — something in it is rigid. Do NOT widen the test viewport to make it pass.

- [ ] **Step 6: Verify the whole suite**

Run: `flutter analyze && LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test`
Expected: 0 analyzer errors, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/tool_bar.dart lib/mime_tools_panel.dart test/tool_bar_layout_test.dart
git commit -m "feat(ui): add ToolBar mapping panel ids to docked bars"
```

---

### Task 4: Wire tool bars into the app

**Files:**
- Modify: `lib/menu_ribbon.dart` (`_openCommandPanel` ~line 217, `entry()` ~line 357, widget params)
- Modify: `lib/main.dart` (state near `_isFindVisible` ~line 108, `_openFind` ~line 818, Esc handling ~line 761, layout ~line 1178, `MenuRibbon(...)` ~line 1452)

**Interfaces:**
- Consumes: `ToolBar` and `ToolBar.handles` (Task 3).
- Produces: no new public API — app wiring only.

- [ ] **Step 1: Add the ribbon callback**

In `lib/menu_ribbon.dart`, add a widget field beside the other callbacks:

```dart
  /// Opens a tool panel as a docked bar instead of an in-ribbon panel.
  /// Only called for ids `ToolBar.handles` claims.
  final ValueChanged<String>? onOpenToolBar;
```

with `this.onOpenToolBar,` in the constructor. Then change `_openCommandPanel` so bar-capable panels route to the host instead of opening in the ribbon:

```dart
  void _openCommandPanel(CommandDescriptor cmd) {
    final id = cmd.panelId;
    if (id != null && ToolBar.handles(id) && widget.onOpenToolBar != null) {
      widget.onOpenToolBar!(id);
      return;
    }
    setState(() => _activeCommand = cmd);
  }
```

Add `import 'tool_bar.dart';` at the top.

`new` and `autodelete` fall through to the existing behaviour, so `RibbonPanelScaffold` and `_buildMimePanel`/`_buildEditPanel` remain in use for nothing else — you may leave `_buildMimePanel` and `_buildEditPanel` in place; they become unreachable but removing them is a separate cleanup.

- [ ] **Step 2: Add host state and the open/close functions**

In `lib/main.dart`, beside `bool _isFindVisible = false;`:

```dart
  /// The docked tool bar's panel id, or null when none is open. Mutually
  /// exclusive with the find bar — see _openFind / _openToolBar.
  String? _activeToolPanelId;
```

Add:

```dart
  /// Dock a tool bar, closing the find bar. Only one bar shows at a time.
  void _openToolBar(String panelId) {
    setState(() {
      _isRibbonVisible = false;
      _isFindVisible = false;
      _activeToolPanelId = panelId;
    });
  }

  void _closeToolBar() {
    setState(() => _activeToolPanelId = null);
    _activeEditor?.focusEditor();
  }
```

And in `_openFind`, before its existing `setState`, add the other half of the exclusion:

```dart
    _activeToolPanelId = null;
```

- [ ] **Step 3: Generalise Esc**

In `main.dart`'s key handler, the Esc case currently reads:

```dart
    if (event.logicalKey == LogicalKeyboardKey.escape && _isFindVisible) {
      _closeFind();
      return KeyEventResult.handled;
    }
```

Replace it with:

```dart
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_activeToolPanelId != null) {
        _closeToolBar();
        return KeyEventResult.handled;
      }
      if (_isFindVisible) {
        _closeFind();
        return KeyEventResult.handled;
      }
    }
```

- [ ] **Step 4: Move both bars above the document tab bar**

Today the find bar sits inside the `ViewMode.edit` branch, immediately before `Expanded(child: CustomEditor(...))` — i.e. BELOW the document tab bar. Both bars must move ABOVE it, so the title tab hangs from the window chrome.

Find the enclosing `Column` whose first child is the document tab bar:

```dart
                Column(
                  children: [
                    if (_tabs.isNotEmpty)
                      Container(
                        height: 36,
                        color: tabBarColor,
                        child: ListView.builder(   // the document tabs
```

**Cut** the existing `if (_isFindVisible) FindPanel(...)` block out of the `ViewMode.edit` branch and **insert both bars before** that `if (_tabs.isNotEmpty)` tab bar, like this:

```dart
                Column(
                  children: [
                    if (_isFindVisible && _activeTab?.mode == ViewMode.edit)
                      FindPanel(
                        controller: _findController,
                        onClose: _closeFind,
                        onReveal: (span) => _activeEditor?.revealSpan(span),
                      ),
                    if (_activeToolPanelId != null &&
                        _activeTab?.mode == ViewMode.edit)
                      ToolBar(
                        panelId: _activeToolPanelId!,
                        editToolsEnabled: _activeEditor != null,
                        mimeToolsEnabled: _activeEditor != null,
                        mimeHasSelection:
                            _activeEditor?.hasLinearSelection ?? false,
                        onRunEditOp: _runEditOp,
                        onRunMimeOp: _runMimeOp,
                        onClose: _closeToolBar,
                      ),
                    if (_tabs.isNotEmpty)
                      Container(
                        height: 36,
                        // … the existing document tab bar, unchanged
```

The explicit `_activeTab?.mode == ViewMode.edit` guard on BOTH bars matters: in its old position the find bar was already inside the edit-mode branch and got that guard for free. Outside the branch it would otherwise render over hex view.

Add `import 'tool_bar.dart';` at the top of `main.dart`.

- [ ] **Step 5: Pass the callback to the ribbon**

In `main.dart`'s `MenuRibbon(...)` construction, add:

```dart
                      onOpenToolBar: _openToolBar,
```

- [ ] **Step 6: Close the bar when the tab is no longer editable**

`_retargetFind` already handles the find bar on tab switch. Add the tool bar to the same place — inside `_retargetFind`, when the new tab is null or not in `ViewMode.edit`:

```dart
      if (_activeToolPanelId != null) {
        setState(() => _activeToolPanelId = null);
      }
```

Make sure this runs regardless of whether the find bar is visible: `_retargetFind` currently returns early when `!_isFindVisible`. Move the tool-bar check ABOVE that early return, or the bar will survive a switch into hex mode.

- [ ] **Step 7: Verify**

Run: `flutter analyze && LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test`
Expected: 0 analyzer errors, all tests pass.

Then build and check by hand — this task's behaviour lives in `_MyHomePageState`, which no test harness drives:

```bash
flutter build linux --debug
```

Confirm: choosing Convert Case from the ribbon closes the ribbon and docks a bar; the document and selection stay visible; clicking an operation applies it immediately; Esc and ✕ both close it; opening find closes the tool bar and vice versa; `New` and `Auto-delete` still open inside the ribbon.

- [ ] **Step 8: Commit**

```bash
git add lib/main.dart lib/menu_ribbon.dart
git commit -m "feat(ui): dock MIME and edit tool bars above the editor"
```

---

## Verification checklist

After Task 4:

- [ ] `flutter analyze` — 0 errors
- [ ] `flutter test` — fully green, no failures
- [ ] `cd rust && cargo test --lib` — still 134/0 (nothing here touches Rust)
- [ ] Both bars appear ABOVE the document tab bar, directly under the window chrome
- [ ] Neither bar renders in hex view
- [ ] Choosing a MIME or edit tool closes the ribbon and docks a bar
- [ ] The title tab is centered and reads as attached to the chrome above
- [ ] An edit action applies on a single click; one Ctrl+Z reverts it
- [ ] A MIME bar requires Apply and honours its checkboxes
- [ ] The bar stays open after applying
- [ ] Opening find closes a tool bar, and opening a tool bar closes find
- [ ] Esc and ✕ both close the open bar
- [ ] `New` and `Auto-delete` still open inside the ribbon
- [ ] At 800px the chips wrap without overflow and ✕ stays reachable
- [ ] Switching to a hex tab closes the tool bar

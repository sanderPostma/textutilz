# Keyboard access to folding — design

Date: 2026-08-06
Status: approved

## Problem

Folding shipped with the structured-format work, but the only way to collapse a
region is to click the ⊟ box in the gutter (`lib/editor.dart:1783`, inside
`GestureDetector.onTapDown`). There is no keyboard path at all, no fold-all, and
no fold-to-level. A keyboard-driven user cannot collapse anything, and a large
document cannot be surveyed at a chosen nesting depth.

Carried in `TODO.md` §0 as *"Folding has no keyboard shortcut and no fold-all"*,
and in the structured-formats spec under "Deferred to TODO.md".

## Bindings

Notepad++'s actual View-menu bindings, so muscle memory transfers:

| Keys | Command |
|---|---|
| `Alt+0` | Fold all |
| `Alt+Shift+0` | Unfold all |
| `Alt+1` … `Alt+8` | Fold to level N |
| `Alt+Shift+1` … `Alt+Shift+8` | Unfold level N |
| `Ctrl+Alt+F` | Collapse the innermost fold containing the caret |
| `Ctrl+Alt+Shift+F` | Expand the innermost fold containing the caret |

`Ctrl+Alt+F` is N++'s "Collapse Current Level". Here it is defined on the caret's
innermost enclosing region rather than on a level, which is the same thing in
practice and is what gives keyboard users single-block folding.

The pair is deliberately two keys rather than one toggle: a toggle is ambiguous
when the caret sits inside a collapsed region — the caret is then on the header
row, and "toggle" would have to guess between re-collapsing what the user just
opened and opening the next one out.

## Semantics

Levels are 1-based in the UI, 0-based in the domain. `level: 0` is an outermost
region.

- **Fold all** — collapse every region.
- **Unfold all** — collapse nothing.
- **Fold to level N** — collapse every region at depth >= N-1, leaving
  shallower ones open. `N=1` is therefore equivalent to fold all, which matches
  Notepad++.
- **Unfold level N** — expand the regions at depth exactly N-1, leaving the
  collapsed state of deeper regions untouched. Re-collapsing the parent hides
  them again with their own state intact, because `FoldMap` merges overlapping
  hidden ranges and a collapsed region nested inside another contributes nothing
  new.
- **Collapse / expand at caret** — the innermost region whose
  `[start_row, end_row]` contains the caret row. No enclosing region is a no-op.

A caret left hidden by a collapse is moved to the nearest visible row above, as
`toggleFoldAt` already does today.

## Where the logic lives

`TODO.md:9` — non-UI logic in Rust, UI-only logic may be in Dart. Assigning a
nesting level to a fold region is domain logic, so it goes to Rust; choosing
which rows to hide is `FoldMap`, which already exists.

### Rust

`FoldRegion` (`rust/src/markup/token.rs:86`) gains:

```rust
/// Nesting depth, outermost = 0. Assigned after lexing by containment, so
/// every language agrees on what a level is.
pub level: u32,
```

It is filled by one shared pass in `markup::analyse_rows` (`rust/src/markup/mod.rs`)
— a stack walk over the region list, popping regions whose `end_row` is behind
the current region's `start_row` — rather than inside each lexer. JSON's brace
stack, XML's element nesting and YAML's indentation therefore produce identical
level numbering by construction, and none of the three lexers needs to carry a
depth counter into its fold bookkeeping.

Regions arrive from the lexers in start order. The shared pass asserts that in
debug and sorts defensively if it does not hold, so a future lexer emitting out
of order degrades to a sort rather than to wrong levels.

`StructuredFold` (`rust/src/api/structured.rs:108`) and `wire_fold` carry the
field through; the generated Dart mirror follows.

No new FFI entry point. Level *selection* is a one-line filter over a list the
editor already holds.

### Dart

`CustomEditorState` gains four public commands beside the existing
`toggleFoldAt`:

```dart
void foldAll();
void unfoldAll();
void foldToLevel(int level);      // 1-based
void unfoldLevel(int level);      // 1-based
void collapseAtCursor();
void expandAtCursor();
```

All of them, and `toggleFoldAt`, route through one private helper:

```dart
void _applyCollapseChange(void Function() mutate)
```

which runs the mutation inside `setState`, rebuilds the fold map, and rescues a
hidden caret. That rescue is inline in `toggleFoldAt` today
(`lib/editor.dart:225-238`); without the helper it would be copied six times.

Folding stays display-only. Nothing here touches the document, the undo stack,
the gutter painter or `FoldMap`.

## Dispatch

The app has no `Shortcuts`/`Actions`/`CallbackShortcuts` widget anywhere — every
binding is hand-rolled `Focus(onKeyEvent:)` plus `HardwareKeyboard.instance`
modifier queries. This work follows that pattern rather than introducing a
second mechanism for one feature.

- `_handleGlobalShortcut` (`lib/main.dart:1062`) gains the fold bindings,
  dispatched to `_activeEditor` (`lib/main.dart:1142`). Its current shape bails
  early with `if (!isControlPressed) return ignored;`, so the Alt-only bindings
  are handled *before* that guard, next to the existing `Alt+X` ribbon toggle.
- The editor swallows keys it handles, so app-level shortcuts only work because
  it explicitly declines them (`_bubbleShortcutKeys`, `lib/editor.dart:302`).
  That set is keyed on Ctrl alone. It is extended with a second condition: an
  Alt-modified digit `0`–`8`, and `Ctrl+Alt+F`, bubble rather than being taken
  as text input.

## Menu

Two entries in the View column (`lib/menu_ribbon.dart:496`), following the
existing route — a `CommandDescriptor` in `rust/src/api/commands.rs` carrying
the display shortcut string, a `case` in `_getAction`, a `VoidCallback?` prop on
`MenuRibbon`, and the wiring in `main.dart`:

- `view.foldall` — "Fold All", `Alt+0`
- `view.unfoldall` — "Unfold All", `Alt+Shift+0`

The eight fold-to-level bindings and the caret pair stay keyboard-only. The
ribbon has no submenus, and eighteen more rows would swamp a two-entry column.

## Testing

Rust:

- Level assignment on nested JSON, on nested XML elements, and on nested YAML
  indentation — same document shape, same expected levels, proving the shared
  pass rather than three lexers that happen to agree.
- A sibling-after-sibling case (`{"a":{...},"b":{...}}`) where a naive
  "increment on every region" would mis-level the second sibling.

Dart, through the `GlobalKey<CustomEditorState>` harness that
`test/fold_gutter_test.dart` already builds:

- `foldAll` then `unfoldAll` returns the display row count to the document row
  count.
- `foldToLevel(2)` on the nested JSON fixture hides the inner region and leaves
  the outer one open.
- `unfoldLevel(N)` leaves a deeper collapsed region collapsed when its parent is
  re-collapsed and expanded again.
- `collapseAtCursor` with the caret inside the inner object collapses the inner
  region, not the outer one; with the caret outside every region it is a no-op.
- The document text is unchanged after all of the above.

Widget tests must do the `EditSession` setup inside `tester.runAsync` — awaiting
a Rust FFI call directly in a `testWidgets` body hangs forever under `FakeAsync`
(`TODO.md` §6).

## Out of scope

- Persisting collapsed regions with the session — separate `TODO.md` §0 item.
- Any change to the gutter, which works.

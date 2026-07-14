# Rust-owned editable document (EditSession)

Date: 2026-07-14
Status: Approved

## Mandate

Flutter/Dart is a thin UI shell; document logic lives in Rust. Undo/redo and the
mutable text model belong in Rust. This spec moves the editable document out of
`editor.dart` (where it had crept in as `_editBuffer`) and into a Rust
`EditSession`, correcting that creep.

## Goals

- Rust owns the editable document text and the undo/redo stacks.
- Preserve large-file performance: keep the read-only `mmap` base; edits are a
  copy-on-write overlay, so memory is proportional to edits, not file size.
- Dart keeps only view/cursor concerns (caret, selection, boundaries, scroll,
  paint, blink).
- Ctrl+Z undo, Ctrl+Shift+Z redo.

## Non-goals

- No rope/piece-table at character granularity. Line-oriented overlay is enough
  and matches the existing renderer.
- Clipboard copy stays Dart-side (no model change).
- sqlite persistence is out of scope (separate future work).

## Rust: `EditSession`

Wraps a `FileBuffer` (immutable mmap base + `read_line`). State:

- `overlay: HashMap<usize, Vec<String>>` — base line index → replacement lines
  (0..n). A base line is materialized to a `String` only when first edited
  (copy-on-write). Same shape as the old Dart overlay.
- `edited_rows: Vec<usize>` — sorted keys of `overlay`, for visual↔logical
  mapping.
- `added_lines: isize` — net lines added/removed by edits.
- `undo: Vec<UndoEntry>`, `redo: Vec<UndoEntry>` — bounded stacks.
- `dirty: bool`.

### Visual/logical mapping

`get_line(visual_row) -> String` and `line_count() -> usize` port
`_getLogicalRow` / `_getLineText` / `_visualLineCount` from Dart. Base lines are
read lazily from the mmap; overlaid lines from the map.

### Mutation primitives

Everything composes from two ops (text may contain `\n`):

- `insert(row, col, text) -> CaretPos`
- `delete(start_row, start_col, end_row, end_col) -> CaretPos`

`CaretPos { row, col }` is where the caret should land after the op. If `col`
exceeds the target line length, the line is space-padded (matches current
behavior for block edits / virtual space).

Derived editor actions map to these:

| Action | Primitive |
|---|---|
| type char | `insert(row, col, ch)` |
| Enter | `insert(row, col, "\n")` |
| Tab | `insert(row, col, " " * n)` |
| paste | `insert(row, col, clip)` |
| backspace | `delete(row, col-1, row, col)` or join with prev line |
| delete key | `delete(row, col, row, col+1)` or join with next line |
| delete selection | `delete(selStart, cursor)` normalized |
| duplicate line (Ctrl+D) | `insert(row, len, "\n" + line)` |
| move line up/down | `delete` + `insert` (one undo step) |

### Undo/redo

Each primitive records an `UndoEntry` capturing the inverse plus the caret to
restore. `insert` of text T at P records a `delete` of the inserted span;
`delete` records an `insert` of the exact removed text at the start position.

- `undo() -> Option<CaretPos>` pops from `undo`, applies the inverse, pushes the
  forward op to `redo`.
- `redo() -> Option<CaretPos>` mirrors.
- **Coalescing:** consecutive single-character `insert`s at a contiguous caret
  merge into one `UndoEntry` until a boundary: Enter, a `delete`, a paste
  (multi-char insert), or an explicit `break_undo_coalescing()` call Dart issues
  on caret moves / focus changes / clicks.
- A mutation clears the `redo` stack.

### Save

- `save() -> ()` writes the resolved document via the existing temp-file+rename
  path, then refreshes the base from the new file and clears the overlay +
  stacks + dirty. (Undo history does not survive save — acceptable.)
- `save_as(path) -> ()` same, but writes to `path` and rebinds the base to it.

### Queries

`line_count()`, `is_dirty()`, and `line(i)` for the renderer.

## Dart: `editor.dart`

- Remove `_editBuffer`, `_editedRows`, `_totalAddedLines`, `_prepareEdit`,
  `_getLogicalRow`, `_getLineText` local storage; replace with an `EditSession`
  handle. `_getLineText(row)` becomes `session.getLine(row)`;
  `_visualLineCount` becomes `session.lineCount()`.
- Keep: cursor row/col, selection, `_nextWordBoundary`/camel boundaries, scroll,
  `EditorPainter`, blink, zoom.
- Each mutation path calls `session.insert/delete` and adopts the returned
  `CaretPos`, then repaints. `onContentChanged` fires from the session's dirty
  transition.
- New shortcuts: Ctrl+Z → `session.undo()`, Ctrl+Shift+Z → `session.redo()`;
  both set the caret from the returned `CaretPos` and repaint. They bubble from
  the editor like the other Ctrl shortcuts are handled locally (they are editor
  actions, not app-global).
- Caret moves / clicks call `session.breakUndoCoalescing()`.

## TabRuntime / main

- `TabRuntime` holds the `EditSession` (or the editor owns it and exposes
  count/dirty). Line count and dirty come from the session.
- Save-as (separate item #8) uses `session.save_as`.

## Testing

Rust unit tests:
- insert single char, multi-char, multiline (paste) round-trip vs `get_line`.
- delete within a line, across lines, whole-line join.
- undo/redo restores exact bytes and caret; redo cleared on new edit.
- coalescing: N char inserts = 1 undo step; boundary splits steps.
- save output equals a naive line-by-line rebuild of the overlay.

Then `flutter analyze`, `cargo test`, and a driven app pass (type, undo, redo,
save).

## Sequencing

1. Rust `EditSession` + unit tests green.
2. `flutter_rust_bridge_codegen generate`.
3. Port `editor.dart` to the session.
4. Wire Ctrl+Z / Ctrl+Shift+Z.
5. Build & drive the app.

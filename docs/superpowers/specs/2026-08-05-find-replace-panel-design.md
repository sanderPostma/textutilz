# Persistent find/replace panel

Date: 2026-08-05
Status: Approved

## Mandate

Flutter/Dart is a thin UI shell; document logic lives in Rust. All matching,
escape expansion, replacement expansion and document mutation belong in Rust.
Dart owns only view state: which match is current, how many pages have been
loaded, and what the panel looks like.

## Problem

`commands.rs` already declares `search.find`, `search.replace` and
`search.goto`, and `menu_ribbon.dart` lists them in the Search column, but
`_getAction` has no case for any of them — choosing them does nothing. There is
no search capability anywhere in the codebase: `EditSession` exposes no matching
primitive, and `regex` is not a dependency.

The user needs Notepad++-equivalent find/replace, but as a **persistent panel**
rather than a modal dialog, so the editor stays visible and navigable while
stepping through matches.

## Goals

- A slim panel docked above the editor, with a close button, that does not
  occlude the document.
- Forward/backward arrow buttons for stepping through matches, replacing
  Notepad++'s "Backward direction" checkbox.
- Find and Replace modes in one panel; switching modes preserves the query text.
- Search modes: Normal, Extended, Regular expression.
- Options: match case, whole word, wrap around, in selection.
- All matches highlighted in the viewport, with the current match accented.
- Replace current match, Replace All, and Replace All in selection.
- Count.
- Constant-time responsiveness independent of document size.

## Non-goals (deferred to their own specs)

- **Mark mode** (Mark All / Clear all marks / Copy Marked Text, bookmark line,
  purge for each search) — its own UI surface and persistent highlight layer.
- **Find All results pane** — a bottom dock listing every match with context;
  its own UI surface.
- **Hex byte search** — a different data model (byte offsets, not rows) with a
  different set of applicable options.
- Find in Files / Find in Projects — a directory-tree search, a separate feature.
- Go to Line (`search.goto`) — already declared, still unwired, out of scope here.

These are deliberate follow-ups. Nothing in this spec should preclude them; in
particular `MatchSpan` and `find_in_rows` are the primitives Mark and Find All
will both build on.

## Architecture

### The single primitive

```rust
find_in_rows(query: &SearchQuery, from_row: usize, to_row: usize)
    -> anyhow::Result<Vec<MatchSpan>>
```

Every feature is a paging policy over this one call:

| Job | Policy |
|---|---|
| ▶ / ◀ stepping | Step within loaded matches. At an edge, scan the next/previous row window until ≥1 match or EOF/BOF. |
| Prefetch | Within `PREFETCH_MARGIN` matches of either edge and not exhausted, scan the adjacent window on the worker thread and append/prepend. The arrow press never blocks on it. |
| Viewport highlighting | `find_in_rows(query, firstVisibleRow, lastVisibleRow)` on scroll. Decoupled from the stepping cursor, so highlighting costs the same on a 2KB file as on a 2GB one. |
| Count | Full sweep on the worker thread, progress reported. Started automatically after the debounce so the counter can resolve on its own; the Count button re-runs it and surfaces the result immediately if one is not already in flight. |
| Replace All | Never materializes a list in Dart; Rust scans and replaces in one backwards pass. |

Rejected alternatives: a single eager `find_all` (stalls on large files, and
highlighting does not need the whole document anyway); separate
`find_next`/`find_prev` incremental cursors (two matching code paths that can
disagree, with no saving once viewport highlighting is required).

### Paging parameters

- `SEARCH_WINDOW_ROWS = 4096`
- `SEARCH_WINDOW_OVERLAP_ROWS = 64`
- `PREFETCH_MARGIN = 20` matches
- `MATCH_DEBOUNCE = 150ms`

A window joins its rows with `\n` before matching, so a cross-line pattern
matches within a window. Consecutive windows overlap by
`SEARCH_WINDOW_OVERLAP_ROWS`, and matches are deduped by absolute
`(start_row, start_col)`.

**Stated limitation:** a multi-line match spanning more than 64 rows will not be
found. This is accepted; it is not worth a second scanning strategy.

## Rust

### New module: `rust/src/api/search.rs`

Pure functions, unit-tested in place, no `EditSession` dependency.

```rust
pub enum SearchMode { Normal, Extended, Regex }

pub struct SearchQuery {
    pub pattern: String,
    pub mode: SearchMode,
    pub match_case: bool,
    pub whole_word: bool,
    pub dot_matches_newline: bool,
}

/// Columns are UTF-16 code units, matching CaretPos and the Dart renderer.
pub struct MatchSpan {
    pub start_row: usize,
    pub start_col: usize,
    pub end_row: usize,
    pub end_col: usize,
}
```

- `compile(query) -> anyhow::Result<Regex>` — the one lowering point. All three
  modes become a regex:
  - Normal → `regex::escape(pattern)`
  - Extended → `regex::escape(unescape_extended(pattern)?)`
  - Regex → `pattern` verbatim
  - then `whole_word` wraps the result in `\b(?:…)\b`, `!match_case` prepends
    `(?i)`, `dot_matches_newline` prepends `(?s)`.
- `unescape_extended(s) -> anyhow::Result<String>` — `\n \r \t \0 \\ \xHH
  \uXXXX`. An unrecognized escape is an error, not a silent literal.
- `expand_replacement(mode, caps, template) -> String` — `$1`/`${name}` capture
  refs in Regex mode, escape expansion in Extended mode, literal otherwise.

Adds `regex = "1"` to `rust/Cargo.toml`.

### `EditSession` additions

All non-`sync`, so flutter_rust_bridge runs them on the worker thread.

- `find_in_rows(query, from_row, to_row) -> Result<Vec<MatchSpan>>` — clamps to
  `line_count()`, joins the rows, matches, maps byte offsets back to
  `(row, utf16_col)` using the existing `u16_len`/`u16_to_byte` helpers.
- `count_matches(query, scope: Option<SpanScope>) -> Result<usize>` — full sweep.
- `replace_span(span, replacement, query) -> Result<CaretPos>` — expands the
  replacement against that match's captures, then `begin_group` / `delete` /
  `insert` / `end_group` so it is one undo step.
- `replace_all_in_rows(query, replacement, from_row, to_row) -> Result<usize>` —
  a single **backwards** pass inside one `begin_group`/`end_group`, so earlier
  spans stay valid as later ones are rewritten. Returns the replacement count.

`SpanScope { start_row, start_col, end_row, end_col }` is declared in
`search.rs` alongside `MatchSpan` and carries the "In selection" range.

Zero-length matches (e.g. regex `a*`) must advance by one position rather than
looping forever — guarded in `find_in_rows` and in `replace_all_in_rows`.

## Dart

### `lib/find_state.dart` — `FindController extends ChangeNotifier`

The paging state machine. The only non-trivial Dart logic in this feature, and
it is view state, not domain logic, so it belongs on this side of the bridge.

Holds:
- `TextEditingController query`, `TextEditingController replacement` — created
  once and **reused across mode switches**, which is what makes find→replace
  carry the typed text over. No copy step to drift.
- `FindPanelMode mode` — `find` | `replace`.
- Options: `matchCase`, `wholeWord`, `wrapAround`, `inSelection`,
  `dotMatchesNewline`, `SearchMode searchMode`.
- `List<MatchSpan> loaded`, `int currentIndex`, `int loadedFromRow`,
  `int loadedToRow`, `bool exhaustedForward`, `bool exhaustedBackward`.
- `int? exactTotal` — null until a full sweep completes.
- `String? regexError`.
- `int _generation` — incremented on every query/option change; a scan result
  carrying a stale generation is discarded.

Responsibilities: debounce, prefetch, wrap-around, re-anchoring after edits, and
generation-based cancellation.

### `lib/find_panel.dart`

Docked **between the tab bar and the editor, pushing the editor down** — not an
overlay. The panel must never cover the text the user is stepping through.

```
[🔍 Find what        ] [Aa][ab|][.*][↵\t][↺][⌗]  ◀ ▶  3 of 17+  [Count]  ✕
[   Replace with     ]                             [Replace][Replace All]
```

Options are inline icon toggles, each with a tooltip naming it and its
Notepad++ equivalent: `Aa` match case, `ab|` whole word only, `.*` regular
expression, `↵\t` extended, `↺` wrap around, `⌗` in selection. The second row
appears only in replace mode. "Replace All" respects the in-selection toggle.

Keyboard: Ctrl+F opens in find mode, Ctrl+H in replace mode, F3 / Shift+F3 step
forward / backward, Enter steps forward, Esc closes the panel and returns focus
to the editor. Ctrl+F and Ctrl+H are added to `_bubbleShortcutKeys` in
`editor.dart` so the editor forwards them instead of consuming them.

### Other Dart changes

- `lib/editor.dart` — `EditorPainter` gains `matches` and `currentMatch` and
  paints them beneath the text (soft fill for matches, accented fill plus border
  for the current one). `CustomEditorState` gains `revealSpan(span)` (select and
  scroll into view) and exposes its visible row range so the panel can request
  viewport highlighting on scroll.
- `lib/main.dart` — hosts one app-level `FindController`, wires the shortcuts,
  and inserts the panel into the column above the editor.
- `lib/menu_ribbon.dart` — `_getAction` cases for `search.find` and
  `search.replace`, calling new `onFind` / `onReplace` callbacks.

## Error handling and edge cases

- **Invalid regex** — `compile` returns `Err`; the field takes an error border
  and the Rust message appears in a tooltip. No scan is fired.
- **No match** — counter reads "No results", arrows disabled.
- **Wrap around off, at the last match** — the arrow is disabled, rather than
  clicking to no effect.
- **Document edited during an active search** — matches are invalidated and
  recomputed after the debounce; `currentIndex` re-anchors to the nearest match
  at or after the caret.
- **Tab switched** — loaded matches are cleared and recomputed for the new tab;
  query text and option toggles persist across tabs (Notepad++ behavior).
- **Superseded scan** — generation counter; stale results are dropped rather
  than appended out of order.
- **Empty query** — no scan, no highlighting, arrows disabled.
- **Zero-length matches** — advance by one position, never loop.
- **In selection with no selection** — the toggle is disabled.

## Testing

### Rust unit tests in `search.rs`

- `unescape_extended`: each supported escape; `\xHH` and `\uXXXX`; an
  unrecognized escape returns `Err`.
- `compile`: all three modes × match_case × whole_word produce patterns that
  match and reject the expected inputs; regex mode surfaces a compile error.
- `expand_replacement`: `$1` capture refs in regex mode; escapes expanded in
  extended mode; `$1` stays literal in normal mode.

### Rust tests on `EditSession`

The cases that actually break paging:

- Match at row 0, column 0.
- Match at the very end of the document.
- A multi-line match wholly inside one window.
- **A multi-line match straddling a window boundary** — proves the 64-row
  overlap catches it.
- Dedupe: a match inside the overlap region is returned once, not twice.
- Scope-limited search returns nothing outside the scope.
- `replace_all_in_rows` undoes as a single step, and redoes as a single step.
- `replace_all_in_rows` with a pattern whose replacement is longer and shorter
  than the match, verifying the backwards pass keeps spans valid.
- Zero-length match pattern terminates.

### Dart tests for `FindController`

Following the existing `test/undo_coalescing_test.dart` pattern:

- Stepping past the loaded edge triggers a fetch and continues.
- Backward paging past the loaded start.
- Wrap around at both ends, and disabled arrows when wrap is off.
- `17+` resolves to `17` when the sweep completes.
- A stale-generation result is discarded.
- Switching find→replace preserves the query text.

## Implementation phases

1. Rust matcher, `find_in_rows`, and their tests. No UI.
2. `FindController` paging and its tests. No UI.
3. Panel UI, viewport highlighting, ▶/◀ stepping.
4. Replace: current match, Replace All, Replace All in selection.

Phases 1 and 2 are independently testable before any pixel is drawn, which is
the point of splitting them out.

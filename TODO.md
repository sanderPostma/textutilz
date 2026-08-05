# TODO

Deferred work, carried forward from the find/replace panel build (2026-08-05).
Nothing here is blocking — the feature is merged and the suite is green
(Rust 123/0, Dart 48/0, `flutter analyze` 0 errors).

Detail for most of these lives in
`docs/superpowers/specs/2026-08-05-find-replace-panel-design.md`.

---

## 0. Docked tool bars — carried over from that build (2026-08-05)

Detail in `docs/superpowers/specs/2026-08-05-docked-tool-bars-design.md`.

- **The spec's vertical budget is not met.** Measured at 800px: `edit.blank`
  163px, `edit.case`/`edit.comment` 129px, MIME bars 86px, one-row floor 71px
  — against a promised ~52px one-row / ~84px two-row. These are upper bounds
  (the widget-test font is fixed-width at ~1em/glyph; the real proportional
  font should put `edit.blank` nearer 101–131px), but the target is still
  missed. Two independent walls: the 71px floor is `DockedBar`'s own 40px
  close `IconButton` plus the ~23px title tab, so reaching ~52px means
  changing chrome the find bar shares; and `edit.blank`'s eight long labels
  need ~4 wrap runs at 800px. `test/tool_bar_layout_test.dart` now pins all
  11 bar heights with zero slack, so this cannot regress silently.
- **The MIME title tab is stale on Encode/Decode** — tap Decode and the tab
  still reads "Base64 Encode"; only the Apply label updates. `ToolBar`
  holds a fixed title per panel id (`lib/tool_bar.dart:43-51`). Fixing it
  means hoisting the decode flag out of `SingleMimeToolPanel`, which makes
  that widget half-controlled and `ToolBar` stateful.
- **Three behaviours have no automated test** — `_openToolBar`'s early
  return, the ViewMode retarget, and the live selection marker. All need a
  `_TextEditorState` harness that does not exist; they are manual checks.
- **Manual GUI verification is owed**, same as §1 below: the spec's
  9-point checklist, plus confirming the find bar is pixel-identical to
  before it adopted `DockedBar`.

---

## 1. Verify the find/replace panel in the running app

**The entire feature was built headless. Nobody has ever looked at it.** Every
claim about how it behaves rests on tests and code reading. Do this first.

- [ ] Ctrl+F opens the panel docked above the editor; it pushes the document
      down and covers no text
- [ ] Typing highlights every visible match, with the current one accented
- [ ] ▲/▼ and F3/Shift+F3 step and scroll to matches; Esc closes and returns
      focus to the editor
- [ ] Esc, then Ctrl+F again, re-shows results for the retained query (must not
      say "No results")
- [ ] Choosing Replace from the menu while Find is open keeps the typed query
- [ ] Replace walks forward through matches; one Ctrl+Z reverts an entire
      Replace All
- [ ] Select text, then Ctrl+F: "In selection" is enabled, and with it on the
      highlights, counter and Replace All all agree
- [ ] Edit the document with the panel open: highlights follow the edit and the
      caret is **not** stolen mid-word
- [ ] Scroll far down a large file: matches highlight in regions never stepped to
- [ ] Narrow the window: the panel degrades without an overflow stripe; query
      field, arrows and close button stay usable
- [ ] Highlight colours are legible against the selection layer in **both**
      light and dark themes

Three code paths have no automated coverage at all and rest entirely on these
checks: `_openFind` and `_retargetFind` (both in `_MyHomePageState`, which no
test harness drives) and `stepForward`'s paged-branch prefetch (no observable
output).

---

## 2. Follow-up features (deliberately out of scope, each wants its own spec)

These were scoped out during design. `MatchSpan` and `find_in_rows` are the
primitives the first two build on.

- [ ] **Mark mode** — Mark All / Clear all marks / Copy Marked Text, bookmark
      line, purge for each search. Needs a persistent highlight layer separate
      from the viewport scan.
- [ ] **Find All results pane** — bottom dock listing every match with line
      number and context, click to jump. Its own UI surface.
- [ ] **Hex byte search** — find/replace in hex view. Different data model
      (byte offsets, not rows); regex/whole-word/extended don't apply, so the
      panel must adapt its toggles. `HexSession` needs a `find_bytes` primitive.
- [ ] **Find in Files / Find in Projects** — directory-tree search. Large,
      separate feature; needs a results pane and background scanning.
- [ ] **Go to Line** — `search.goto` is already declared in `commands.rs` and
      already appears in the ribbon's Search column, but `_getAction` in
      `menu_ribbon.dart` has no case for it, so choosing it does nothing.
      Smallest item on this list.

---

## 3. Performance

- [ ] **Replace All is quadratic in match count.** Measured in release: 10k
      matches 0.6s, 20k 2.1s, 40k 7.3s. Extrapolated, ~200k matches is minutes
      with no progress indicator and no cancel.

      Root cause predates find/replace: `prepare_edit` pushes to `edited_rows`
      and re-sorts (O(n log n) per edit), and `get_logical` scans `edited_rows`
      linearly. `replace_all_in_rows` is just the first API that drives it tens
      of thousands of times in one call.

      Two directions: keep `edited_rows` sorted by insertion rather than
      re-sorting, and replace `get_logical`'s linear scan with a binary search
      or prefix-sum index. **Both touch the copy-on-write overlay and undo
      bookkeeping that all editing depends on** — this needs its own review
      cycle, not a drive-by fix.

      Interim option if it bites before then: warn or confirm above some match
      count, so nobody hits a multi-minute freeze.

---

## 4. Code follow-ups (parked, none blocking)

- [ ] **Burst stepping can wrap early** (`lib/find_state.dart`, `stepForward`).
      With several `stepForward()` calls in flight, a step whose window load
      joins another's may still see `_currentIndex == _loaded.length - 1` and
      wrap to the first match while unscanned windows remain. Only reachable by
      holding key-repeat across a window boundary; sequential stepping is exact.
      One-line hardening: require `_loadedTo >= _lineCount` before taking the
      wrap branch.

- [ ] **Fix the misleading comment on scope clamping** (`scope_row_bounds` in
      `rust/src/api/edit_session.rs`, and its test comment). The comment says
      clamping "changes no output". That is wrong: for a greedy dot-all pattern
      the clamp can *add* a match, because match extent depends on how much text
      was scanned. The behaviour is correct and arguably better — the clamp can
      only add, never drop — but the stated rationale should not be trusted by
      the next reader.

- [ ] **`dispose()` does not invalidate `_generation`** (`lib/find_state.dart`).
      A `_loadForward` loop already in flight keeps paging the whole document
      after the panel closes. No crash (`_notify()` guards the disposed case),
      just wasted work on a large file.

- [ ] **Two concurrent sweeps are possible** — `refresh`'s unawaited
      `_startSweep` plus `recount`'s awaited one. Harmless and pre-existing.

- [ ] **Painted and counted matches can diverge for greedy multi-line regexes.**
      `find_in_rows` scans `[from_row, to_row + 64)`, so a greedy dot-all
      pattern's extent depends on the requested range; `count_matches` pages in
      4096-row windows while viewport highlighting pages in screen-sized ones.
      Measured with `a.*b` over 300 rows: count says 1, viewport tiling says 6.
      Inherent to windowed scanning without a streaming regex engine. Affects
      only greedy patterns spanning rows. Note the comment in `find_state.dart`
      claiming the two sets can never disagree is true for *scope*, not for
      greedy dot-all.

---

## 5. Test-quality debt

This feature produced **five tests that passed while proving nothing** — a loose
upper bound, a document too small to exercise its named path, a race that masked
its own target bug, a test duplicating production logic in its harness, and a
guard test that only ever took the fast path. Four were caught and fixed; one
real defect (zero-length Replace All dirtying the document) existed *only*
because a loose assertion hid it.

Treat "the tests pass" with more suspicion than usual in this area.

- [ ] **`test/find_panel_selection_test.dart` duplicates production logic.** Its
      harness hand-writes the same `scope = selectionScope; attach(...)` sequence
      `_openFind` uses, so it would still pass if the real code were reverted. It
      also mirrored `_openFind`'s missing `refresh()` — which is why that bug
      shipped. If `_openFind` changes, update this harness to match, or find a
      way to drive the real path.

- [ ] **The width sweep asserts only "no exception"** (`sweepWidths` in
      `test/find_panel_layout_test.dart`). `expectCoreControlsUsable` runs only
      in the two fixed 500px tests, not inside the sweep loop. Folding it into
      the loop would make "the panel stays usable" self-verifying at every width
      rather than at two hand-picked ones.

- [ ] **`selectionScope`'s "no selection returns null" branch is untested**
      (`test/editor_selection_scope_test.dart`). The normalization logic is
      covered via the `normalizeSelection` helper; the guard itself is not,
      because no harness drives `CustomEditorState`.

- [ ] **`overlap_constant_is_used` is redundant**
      (`rust/src/api/edit_session.rs`). It only re-asserts
      `SEARCH_WINDOW_OVERLAP_ROWS == 64`, duplicating a `search.rs` test and
      verifying nothing about the constant being *used*. The straddling-boundary
      pair supersedes it. Delete.

- [ ] **`paintSpan` wants a clarifying comment** (`lib/editor.dart`). It filters
      rows against the viewport inside its loop rather than clamping the bounds
      up front. Harmless — callers hand it viewport-scoped spans — but a reader
      could mistake that filter for the scoping guarantee itself, which lives in
      `_runViewportScan`.

---

## 6. Housekeeping

- [ ] **No smoke test for the app shell.** `test/widget_test.dart` was the stock
      Flutter counter-app template test, asserting on a `+` button and a `0`
      counter this app never had; it had been failing since before the
      find/replace work and was deleted so the suite could go green. Nothing
      replaced it. A test that pumps the app shell and asserts it builds would
      be worth having.

- [ ] **Flutter test hazard, documented for whoever writes the next widget
      test:** awaiting a Rust FFI call directly inside a `testWidgets` body
      **hangs forever** — the body runs in a `FakeAsync` zone whose clock never
      advances the real cross-isolate work. Use `tester.runAsync` for the async
      setup, scoped tightly so it does not wrap the `pumpWidget`/`pump` calls
      that exercise widget behaviour. See the comments in
      `test/find_panel_layout_test.dart`.

- [ ] **Dart tests need the Rust library on the path.** The cargo target
      directory is `~/.cargo/target`, *not* `rust/target`:
      ```
      cd rust && cargo build && cd .. && \
        LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test
      ```
      Without it, anything calling `RustLib.init()` fails with "Failed to load
      dynamic library". Re-run `cargo build` after any Rust change or the tests
      exercise a stale library.

- [ ] **`master` is 24 commits ahead of `origin/master`** and has not been
      pushed.

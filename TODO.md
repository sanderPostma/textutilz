# TODO

Outstanding work carried forward from the find/replace panel build
(2026-08-05). Nothing here is currently blocking.

Detail for most of these lives in
`docs/superpowers/specs/2026-08-05-find-replace-panel-design.md`.

IMPORTANT: make sure non-ui logic is done in rust, direct ui related logic may be in dart)

---

## 0. Structured formats (JSON / JSON5 / YAML / XML)

Detail in `docs/superpowers/specs/2026-08-06-structured-formats-design.md`.

Shipped: the Rust port (`rust/src/markup/`), format-aware comment/uncomment,
JSON5 as a dialect switch on the JSON bar, escape/unescape, validation with a
double-clickable error list and red squiggles in the editor, auto-validation on
a 2 s idle debounce, syntax colouring from a real lexer, matched bracket/tag
highlighting, block collapse with a fold gutter, and silent format
autodetection reported in the status bar and used to narrow the Tools menu.
Since 2026-08-06 also Notepad++'s folding keys — Alt+0 / Alt+Shift+0 for all,
Alt+1..8 and Alt+Shift+1..8 per nesting level, Ctrl+Alt+F / Ctrl+Alt+Shift+F
around the caret — plus Fold All and Unfold All in the View menu, and
collapsed regions that survive a tab switch and a restart
(`DocumentMeta.collapsedFolds`, a `collapsed_folds` column on `documents`).
Since 2026-08-06 also a per-document format pin — a status-bar picker offering
Auto-detect plus the five formats, persisted as `DocumentMeta.languageOverride`
and a `language_override` column. The JSON5 dialect is now one of those pins
rather than an app-wide switch, so two JSON documents can be read as different
dialects at once; the JSON bar's JSON5 toggle writes the pin.
`EditSession::detect_markup_language` applies the precedence (pin beats every
detection signal) so colouring, folding, comment syntax, the Tools menu, the
status bar and validation cannot disagree about what a document is.

Three notes for the next change in this area:

1. `AppStore::init_schema` runs `ensure_column` after the `CREATE TABLE IF NOT
   EXISTS` pair, because that DDL does nothing to a database that already
   exists — a new column added to the DDL alone would make `load_session` fail
   with "no such column" and silently cost the user every tab. Add to both, and
   copy `a_database_from_before_the_language_column_still_loads`, which starts
   from the schema users are actually running.
2. `documents` passed diesel's default 16-column ceiling with
   `language_override`, so `rust/Cargo.toml` now enables diesel's
   `32-column-tables`. The next ceiling is 32, and the failure is a compile
   error in the `diesel::table!` macro, not a runtime one.
3. Anything cached on `EditSession` alongside the markup checkpoints belongs
   *inside* `MarkupCache`, not next to it. That struct is rebuilt whenever the
   document revision or the language changes, so a field added to it is
   invalidated correctly with no new code — which is how the token window
   avoids having an invalidation bug to get wrong.

Since 2026-08-06 there is also an **app-shell harness** (`test/app_shell.dart`),
which pumps the real `MyApp` against a seeded temp session and made the two
"needs a `_TextEditorState` harness" items testable. It found two live bugs the
moment it existed — Alt+0/Alt+1..8 never reached the fold commands at all, and
the picker's Auto-detect entry could never be chosen — so treat anything else
still marked "manual check" as unverified rather than working. Read its doc
comment before writing shell tests: the surface must be sized to at least the
runner's 980px minimum, and the store must be opened through `AppStore.openAt`
so a test never touches the real session.

Since 2026-08-06 the harness also covers §1's three formerly untested docked-bar
behaviours (`test/shell_tool_bar_test.dart`), and found a third live bug on the
way: the status bar overflowed by 97px at the app's own 1000px default width as
soon as text was selected, because the `Sel: n | n` segment appears without any
width threshold accounting for it. The row is now a reversed horizontal
`SingleChildScrollView`, so it stays pinned right and degrades by scrolling
rather than by painting a stripe.

Four of the five items below were closed on 2026-08-06 by measuring them
rather than by assuming; what is left is one that needs a decision, not code.

- [x] **Auto-validation runs the full document pass** — measured, and it is
      not a problem. `markup::cost::whole_document_pass_timing` (an `#[ignore]`d
      timing test; `cargo test --release -- --ignored --nocapture markup::cost`)
      puts valid JSON at ~0.9 µs/row, linear: 1 ms at 1k rows, 9 ms at 10k,
      73 ms at 50k, and the `MAX_ANALYSIS_ROWS` cap cuts in at 100k. So the
      worst pass the app can run is ~150 ms, once per 2 s idle pause. Re-run
      the test if the lexers grow a second pass over the rows.

- [x] **YAML autodetection: the flow-collection half is fixed.** A row
      continuing an open `[`/`{` (`hosts: [alpha,` / `beta]`) is now skipped
      instead of judged, via `flow_delta` in `rust/src/markup/language.rs`,
      which ignores quoted text and `#` comments.
      The other half — a top-level sequence with no `---` marker (`- a\n- b`)
      reading as plain text — is **not fixable and has been closed as such**.
      Those two lines are equally a Markdown bullet list; nothing in the text
      tells them apart. Plain text is the safe side of the tie, and the
      status-bar format pin now makes being wrong cheap to correct.

- [x] **Read and Tail called the lexer once per row build** — this one was
      real, and much worse than the note claimed. The cost was never the FFI
      crossing: `markup_tokens` resumes from the nearest checkpoint, so a
      one-row request re-lexes up to `CHECKPOINT_ROWS` (128) rows to reach it.
      A 50-row viewport therefore did ~64× the necessary lexing — **measured
      at 5.3 ms per frame against a release build**, a third of a 60 Hz frame
      budget, purely to colour what was on screen.
      Fixed in Rust rather than Dart, so every caller benefits and the UI stays
      thin: `EditSession` now keeps a `TokenWindow` of the last
      `TOKEN_WINDOW_ROWS` (512) rows lexed, aligned to a checkpoint and started
      slightly before the request so scrolling up hits too. Requests larger
      than the window bypass it — they already amortise the warm-up. The window
      lives inside `MarkupCache`, so the existing document-revision and
      language checks invalidate it for free. Same measurement after: **0.48 ms
      per frame**, 11× better.

- [x] **XML DOCTYPE with an internal subset** — fixed. `scan_doctype`
      (`rust/src/markup/xml.rs`) tracks the `[ ... ]` block, across rows, so
      the `>` of an inner `<!ENTITY>` no longer ends the declaration and
      strands the rest of the subset as element content. That also mattered
      beyond colouring: the stranded rows lexed as `Invalid`, and
      `looks_like_xml` rejects a sample with too many of those.

- [ ] **The token palette is hardcoded** — the one item left, and it needs a
      decision before any code. `MarkupStyling.colorFor`
      (`lib/markup_styling.dart`) holds a light and a dark colour per token
      kind, following VS Code's convention. That is a defensible default, not
      a defect, so "fix" could mean either of two quite different things:
      derive the palette from the active `ColorScheme` (automatic, but the
      accepted syntax-colour conventions do not survive being derived), or add
      named themes the user picks and stores in the `settings` table (more
      work, and the thing people actually ask for). Worth choosing
      deliberately rather than drifting into the first one.

---

## 1. Docked tool bars

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
  15 bar heights with zero slack, so this cannot regress silently. The
  structured bars are the tallest at 127px (JSON) and 115px (YAML, XML):
  five operation buttons, the scope note, a divider and the auto-validate
  switch need three runs at 800px.
- **The MIME title tab is stale on Encode/Decode** — tap Decode and the tab
  still reads "Base64 Encode"; only the Apply label updates. `ToolBar`
  holds a fixed title per panel id (`lib/tool_bar.dart:43-51`). Fixing it
  means hoisting the decode flag out of `SingleMimeToolPanel`, which makes
  that widget half-controlled and `ToolBar` stateful.
- **The ribbon's menu table has no overflow behaviour** — `_buildMenuTable`
  (`lib/menu_ribbon.dart`) is a bare `Row` of five intrinsic-width cards in a
  non-scrolling ribbon, so a column that does not fit is simply unreachable.
  Measured at 1000px the Tools column's centre lands at x≈1131, but that is
  the fixed-width test font, which is materially wider than the real
  proportional one — **not reproduced in the running app**, and parked as
  such. Worth a glance at narrow widths; `test/shell_tool_bar_test.dart`
  opens its MIME bar through ribbon search regardless, which is the more
  robust path for a test.
- **Manual GUI verification is still owed** for the docked-tool-bar spec's
  9-point checklist, including confirming that the find bar is pixel-identical
  to its pre-`DockedBar` appearance. The separate find/replace checklist has
  been completed in the running Linux app.

---

## 2. Follow-up features

These larger features were scoped out during the original find/replace design.

- [ ] **Find in Files / Find in Projects** — directory-tree search. Large,
      separate feature; needs a results pane and background scanning.

- [ ] **Window size and position are not persisted.** The GTK runner opens at a
      hardcoded `gtk_window_set_default_size(window, 1000, 600)`
      (`linux/runner/my_application.cc:59`) every launch, and nothing reads or
      writes geometry. The `settings` key/value table already exists and is the
      natural home — the same place `word_wrap` is kept. Needs care on two
      points: a restored position can land off-screen when a monitor is
      unplugged, so it has to be validated against the current screen; and
      Wayland ignores programmatic window positioning entirely, so this is
      size-and-maximised-state on Wayland and full geometry on X11. Note the
      980px minimum width already enforced in the runner.

- [ ] **The tab strip has no overflow affordance.** It is a bare horizontal
      `ListView.builder` (`lib/main.dart:1821`): with more tabs than fit, the
      extra ones are reachable only by dragging or wheel-scrolling the strip.
      There are no scroll arrows, no scrollbar, and — the sharper problem —
      nothing scrolls the active tab into view, so switching tabs by any means
      other than clicking can leave the highlighted tab off-screen. A
      `ScrollController` with `Scrollable.ensureVisible` on activation is the
      minimum; chevron buttons at the ends are the Notepad++ shape.

- [ ] **No Ctrl+Tab tab switcher.** There is no Tab binding at app level at all
      (`_handleGlobalShortcut`, `lib/main.dart`) — the only Tab handler is the
      editor inserting an indent (`lib/editor.dart:1406`).
      Wanted: Ctrl+Tab / Ctrl+Shift+Tab cycling in most-recently-used order,
      with an overlay listing the open tabs while Ctrl is held. The editor's
      existing `_onHardwareKey` already tracks Ctrl being held, which is what
      the overlay needs to know when to dismiss. Pairs with the overflow item
      above: a switcher is the answer to 200 tabs, not a longer strip.

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

- [ ] **What does 200 open tabs of large files actually cost?** Established so
      far, by reading the code rather than measuring: nothing is mmap'd (there
      is no `memmap` dependency, despite the word appearing in the specs).
      `FileBuffer` (`rust/src/api/file_manager.rs:38`) holds an open `File`
      handle plus `line_offsets: Vec<usize>` — **8 bytes per line, resident for
      as long as the tab is open** — and reads rows from disk on demand. File
      *contents* are therefore not in memory, but the index is: a 10M-line log
      is ~80MB of `line_offsets` alone, and 200 of those would be ~16GB.
      That index, not the file bytes, is the thing to measure and to bound.

      On top of it, per open tab: the `overlay` HashMap (only lines actually
      edited), the undo and redo stacks (which are unbounded), the markup
      checkpoint cache (one `LexState` per 128 rows, and only for a document
      someone coloured), and one OS file descriptor.

      Worth answering with real numbers before deciding anything. If it does
      bite, the shapes are: a sparser line index (every Nth line plus a scan),
      or evicting the index for tabs that have not been looked at, rebuilding
      it on activation.

---

## 4. Code follow-ups (parked, none blocking)

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

---

## 6. Housekeeping

- [x] **No smoke test for the app shell.** Covered incidentally:
      `test/app_shell.dart` pumps the real `MyApp` and every test in
      `test/fold_keys_test.dart` and `test/status_bar_picker_test.dart` fails
      if the shell cannot build. The stock counter-app `test/widget_test.dart`
      that used to occupy this slot stays deleted.

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

- [x] **`master` is 29 commits ahead of `origin/master`** — pushed 2026-08-06,
      along with `feature/docked-tool-bars`; both are at the same commit.

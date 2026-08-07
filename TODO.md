# TODO

Outstanding work carried forward from the find/replace panel build
(2026-08-05). Nothing here is currently blocking.

Specs live in `docs/superpowers/specs/`.

IMPORTANT: make sure non-ui logic is done in rust, direct ui related logic may be in dart)

---

## 0. Notes that outlive their tasks

The structured-formats work (`rust/src/markup/`) is done: lexing, folding,
validation, colouring, autodetection, the per-document format pin, and a
palette derived from the active `ColorScheme`. What is worth keeping is not
the list of what shipped but the handful of things that cost time to learn.

1. **Adding a column to `documents` needs `ensure_column` as well as the
   DDL.** `AppStore::init_schema` runs `CREATE TABLE IF NOT EXISTS`, which does
   nothing to a database that already exists — so a column added to the DDL
   alone makes `load_session` fail with "no such column" and silently costs the
   user every tab. Add it in both places, and copy
   `a_database_from_before_the_language_column_still_loads`, which starts from
   the schema users are actually running.
2. **`documents` is past diesel's default 16-column ceiling**, so
   `rust/Cargo.toml` enables `32-column-tables`. The next ceiling is 32, and
   the failure is a compile error in the `diesel::table!` macro, not a runtime
   one.
3. **Anything cached on `EditSession` alongside the markup checkpoints belongs
   *inside* `MarkupCache`.** That struct is rebuilt whenever the document
   revision or the language changes, so a field added to it is invalidated
   correctly with no new code — which is how the token window avoids having an
   invalidation bug to get wrong.
4. **Syntax hues are deliberately not derived from the theme.** The scheme
   supplies a tint and the neutral roles; the hues stay canonical, because
   green-means-comment is a convention shared with every other editor and a
   pink-seeded theme must not produce pink comments.

### The app-shell harness

`test/app_shell.dart` pumps the real `MyApp` against a seeded temp session, and
is how anything living on the private `_TextEditorState` gets tested. Two rules
from its doc comment: size the surface to at least the runner's 980px minimum,
and open the store through `AppStore.openAt` so a test never touches the real
session.

A third, learned later: `flutter test` runs each test *file* in its own
isolate, so any counter the harness keeps restarts at zero in every one of
them. Two files racing on the same temp database name produced intermittent
"database is locked" and "attempt to write a readonly database" failures in
whichever test lost. Each harness now takes its own `createTempSync` directory.

**Assume anything still marked "manual check" is broken until a test says
otherwise.** The harness found three live bugs in the first five behaviours it
was pointed at — Alt+0/Alt+1..8 never reached the fold commands, the
status-bar picker's Auto-detect entry could never be chosen, and the status bar
overflowed by 97px as soon as text was selected. All three had shipped.

---

## 1. Docked tool bars

Detail in `docs/superpowers/specs/2026-08-05-docked-tool-bars-design.md`.

- [x] **The vertical budget is met.** The one-row floor is **49px** against a
      promised ~52px, and `edit.blank` — the worst case, eight long labels —
      went from 163px to 93px. Two changes did it, and the second was much the
      larger: `DockedBar`'s close button dropped from Material's 40px square to
      28px, and then the edit bars' `ActionChip`s became the same `FilledButton`
      every other bar uses. Chips carry more horizontal padding than they look
      like they do, so eight of them needed four wrap runs where eight buttons
      need two. All 15 heights re-measured and pinned with zero slack in
      `test/tool_bar_layout_test.dart`; they remain upper bounds, since the
      widget-test font is fixed-width at ~1em/glyph, roughly double a real
      proportional font.

- [ ] **The ribbon's menu table has no overflow behaviour** — `_buildMenuTable`
      (`lib/menu_ribbon.dart`) is a bare `Row` of five intrinsic-width cards in
      a non-scrolling ribbon, so a column that does not fit is unreachable.
      Measured at 1000px the Tools column's centre lands at x≈1131, but in the
      fixed-width test font — **not reproduced in the running app**, and parked
      as such. `test/shell_tool_bar_test.dart` opens its MIME bar through
      ribbon search regardless, which is the more robust path for a test.

- [ ] **Manual GUI verification is still owed** for the spec's 9-point
      checklist, including confirming the find bar is pixel-identical to its
      pre-`DockedBar` appearance. The find/replace checklist has been completed
      in the running Linux app.

      Four things now rest on that check because no widget test can reach
      them:
      - **Focus after opening a tool bar.** `_openToolBar` returns focus to the
        editor for every bar except the ones `ToolBar.ownsFocus` names (Go to
        Line, which has a field). Under the test binding focus lands in the
        editor by itself and the root `Focus` gets key events regardless, so
        every phrasing tried passed with the production code deleted.
      - **Window geometry**, including un-maximizing to a sensible size — it
        needs `window_manager` platform channels.
      - **Ctrl+Tab's overlay**, which depends on the Ctrl key-up reaching the
        shell through real GTK key handling.
      - **The tool-bar button restyle**, which is a judgement about how it
        looks, not a property a test can assert.

---

## 2. Follow-up features

- [ ] **Find in Files / Find in Projects** — directory-tree search. Large and
      separate: needs a results pane, background scanning and cancellation.

- [ ] **Named syntax themes.** The other half of the palette work: a set of
      named schemes (Monokai, Solarized, …) the user picks and the app
      remembers. The pieces are in place — `MarkupStyling` takes a
      `ColorScheme`, and the `settings` table is where `word_wrap` lives — so
      the work is a picker, a stored key, and a decision about whether a syntax
      theme also restyles the app chrome or only the editor. A named theme is
      exactly the case the palette's contrast test exists to catch: a
      hand-authored scheme has no obligation to keep its surface near-white or
      near-black.

---

## 3. Performance

Both items here have been measured; what is left is written against numbers.
The `#[ignore]`d timing tests are the way to re-check them:
`cargo test --release -- --ignored --nocapture <name>`.

- [ ] **Replace All is no longer quadratic, but not yet linear**
      (`replace_all_timing`). 40k matches went 6.86 s → 552 ms and 200k went
      from minutes to 4.8 s, by inserting into `edited_rows` in place instead
      of pushing and re-sorting. What remains is `get_logical`'s linear scan,
      which runs twice per match and still shows: 200k takes 2.8x the time of
      100k, not 2x.
      A prefix-sum or Fenwick index over the overlay is the fix. **An
      `added_lines == 0` short-circuit is not** — it was tried and is wrong,
      because a split and a join cancel out and leave the counter at zero while
      the mapping is not the identity; two existing tests catch it. A correct
      short-circuit needs a count of rows whose overlay holds other than
      exactly one line, maintained at every site that mutates an overlay
      vector. Still its own review cycle — but 4.8 s without a progress bar is
      a different problem from minutes without one, so the "warn above N
      matches" interim is no longer urgent.

- [ ] **Decide whether 8 MB per million lines per open tab is worth fixing**
      (`open_tab_cost`). 200 tabs over a 1M-line file measured +1592.8 MB, i.e.
      8.00 MB per tab against 8.00 MB for the `line_offsets` index alone — the
      index is not the dominant cost, it is the entire measurable one. Nothing
      is mmap'd, as the code always said and the specs always denied.
      Linear in lines, so a 10M-line log is ~80 MB of index and 200 of those
      would be ~16 GB. Whether that matters is a product question; if it does,
      the shapes are a sparser index (every Nth line plus a short scan) or
      evicting the index for tabs nobody has looked at, rebuilding on
      activation. The harness to judge either now exists.

---

## 4. Code follow-ups (parked, none blocking)

- [ ] **Two concurrent sweeps are possible** — `refresh`'s unawaited
      `_startSweep` plus `recount`'s awaited one. Harmless and pre-existing.

- [ ] **Painted and counted matches can diverge for greedy multi-line regexes.**
      `find_in_rows` scans `[from_row, to_row + 64)`, so a greedy dot-all
      pattern's extent depends on the requested range; `count_matches` pages in
      4096-row windows while viewport highlighting pages in screen-sized ones.
      Measured with `a.*b` over 300 rows: count says 1, viewport tiling says 6.
      Inherent to windowed scanning without a streaming regex engine. Note the
      comment in `find_state.dart` claiming the two sets can never disagree is
      true for *scope*, not for greedy dot-all.

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

## 6. Standing notes

Not tasks — things the next person needs to know before they lose an hour.

- **Awaiting a Rust FFI call inside a `testWidgets` body hangs forever.** The
  body runs in a `FakeAsync` zone whose clock never advances the real
  cross-isolate work. Use `tester.runAsync` for the async setup, scoped tightly
  so it does not wrap the `pumpWidget`/`pump` calls that exercise widget
  behaviour. See the comments in `test/find_panel_layout_test.dart`.

- **Dart tests need the Rust library on the path.** The cargo target directory
  is `~/.cargo/target`, *not* `rust/target`:
  ```
  cd rust && cargo build && cd .. && \
    LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test
  ```
  Without it, anything calling `RustLib.init()` fails with "Failed to load
  dynamic library". Re-run `cargo build` after any Rust change or the tests
  exercise a stale library.

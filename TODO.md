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
Since 2026-08-06 also a lexed-row window cached on `EditSession`, which took
colouring a Read/Tail viewport from 5.3 ms per frame to 0.48 ms; XML DOCTYPE
internal subsets scanned as one declaration; and YAML rows continuing an open
flow collection treated as continuations rather than judged. Since 2026-08-06
the token palette is derived from the active `ColorScheme` instead of being two
hardcoded tables: hues stay canonical (green comments, red errors — the
convention is the point), the scheme supplies a 12% tint toward its primary,
and `invalid`, `punctuation` and `text` come from the scheme's roles outright.
`MarkupStyling` now takes a `ColorScheme` everywhere it used to take a
`Brightness`, which also themes the fold guides, the collapsed-row rule and the
matched-pair wash.

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
4. There is a timing test for the whole-document pass, kept `#[ignore]`d
   because it measures rather than asserts and means nothing in a debug build:
   `cargo test --release -- --ignored --nocapture markup::cost`. Valid JSON
   currently costs ~0.9 µs/row, linear, against a `MAX_ANALYSIS_ROWS` cap of
   100k — so the worst pass is ~150 ms, once per 2 s idle pause. Re-run it if
   a lexer grows a second pass over the rows.

Since 2026-08-06 there is an **app-shell harness** (`test/app_shell.dart`) that
pumps the real `MyApp` against a seeded temp session, and it is how anything
living on the private `_TextEditorState` gets tested — the fold keys, the
status-bar picker, the docked-bar behaviours in §1. Read its doc comment first:
the surface must be sized to at least the runner's 980px minimum, and the store
must be opened through `AppStore.openAt` so a test never touches the real
session.

**Anything still marked "manual check" should be assumed broken until a test
says otherwise.** The harness found three live bugs in the first five
behaviours it was pointed at: Alt+0/Alt+1..8 never reached the fold commands,
the status-bar picker's Auto-detect entry could never be chosen, and the status
bar overflowed by 97px as soon as text was selected. All three had shipped.

Nothing outstanding here. Named syntax themes are deferred to §2.

---

## 1. Docked tool bars

Detail in `docs/superpowers/specs/2026-08-05-docked-tool-bars-design.md`.

- **The spec's vertical budget is nearly met, and the rest is a design
  choice.** `DockedBar`'s close button was Material's 40px square, which — not
  the controls — set every one-row bar's height. Trimming it to 28px took the
  one-row floor from 71px to **59px**, against a promised ~52px, and took 2px
  off every other bar (`edit.blank` 163→161, `structured.json` 127→125). All
  15 ceilings in `test/tool_bar_layout_test.dart` were re-measured, still with
  zero slack.
  The remaining 7px is the title band. It can go, but that is a decision about
  what a docked bar *is* rather than a tuning exercise: the find bar passes
  `title: null` and has no band, so the spec's 52px was measured on a bar with
  no title in the first place. Two other figures are unchanged and unrelated to
  the chrome: `edit.blank`'s eight long labels still need ~4 wrap runs at
  800px, and the structured bars still need three. Note all these numbers are
  upper bounds — the widget-test font is fixed-width at ~1em/glyph, roughly
  double a real proportional font.
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

Done 2026-08-07: the tab strip now scrolls the active tab into view whenever it
changes (`_activateTab` / `_revealActiveTab`) and grows chevrons at both ends
when it overflows, and Ctrl+Tab / Ctrl+Shift+Tab walk the open tabs in
most-recently-used order behind a held-Ctrl overlay. Two editor guards were in
the way and are worth knowing about: the editor swallowed Ctrl+Tab as an indent,
and it swallowed Escape entirely — which had also been quietly breaking
Escape-to-close-a-docked-bar in Edit mode.

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

- [ ] **Named syntax themes.** Deferred from §0 on 2026-08-06 in favour of
      deriving the palette, which is now done. This is the other half people
      ask for: a set of named schemes (Monokai, Solarized, and so on) the user
      picks and the app remembers. The pieces are in place — `MarkupStyling`
      takes a `ColorScheme`, and the `settings` key/value table is where
      `word_wrap` already lives — so the work is a picker, a stored key, and a
      decision about whether a syntax theme also restyles the app chrome or
      only the editor. Note that a named theme is exactly the case the derived
      palette's contrast test exists to catch: a hand-authored scheme has no
      obligation to keep its surface near-white or near-black.

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

## 6. Standing notes

Not tasks — things the next person needs to know before they lose an hour.

- **Flutter test hazard, documented for whoever writes the next widget
      test:** awaiting a Rust FFI call directly inside a `testWidgets` body
      **hangs forever** — the body runs in a `FakeAsync` zone whose clock never
      advances the real cross-isolate work. Use `tester.runAsync` for the async
      setup, scoped tightly so it does not wrap the `pumpWidget`/`pump` calls
      that exercise widget behaviour. See the comments in
      `test/find_panel_layout_test.dart`.

- **Dart tests need the Rust library on the path.** The cargo target
      directory is `~/.cargo/target`, *not* `rust/target`:
      ```
      cd rust && cargo build && cd .. && \
        LD_LIBRARY_PATH=$HOME/.cargo/target/debug flutter test
      ```
      Without it, anything calling `RustLib.init()` fails with "Failed to load
      dynamic library". Re-run `cargo build` after any Rust change or the tests
      exercise a stale library.

# Find/Replace Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent find/replace panel docked above the editor, with forward/backward match stepping, three search modes, and replace — without ever occluding or stalling the editor.

**Architecture:** All matching lives in Rust behind one primitive, `EditSession::find_in_rows(query, from_row, to_row)`. Everything else is a paging policy over it: stepping pages by 4096-row windows with background prefetch, viewport highlighting scans only the visible rows, and Replace All is a single backwards Rust pass in one undo group. Dart holds only view state — the current match index and which windows have been loaded.

**Scanning always begins at row 0 and pages forward only.** The caret decides which *loaded* match is current, via anchoring in `refresh()` — it does not decide where scanning starts. Backward window paging is therefore unreachable and deliberately absent; an earlier draft of this plan specified it, and it was dead code. The accepted cost is that the first search on a very large document scans from the top rather than from the caret.

**Tech Stack:** Rust (`regex` crate, `flutter_rust_bridge` 2.12.0), Flutter/Dart, `cargo test` for Rust, `flutter test` for Dart.

## Global Constraints

- **Mandate:** Dart is a thin UI shell; domain logic lives in Rust. Matching, escape expansion, replacement expansion, window/overlap policy and document mutation are all Rust-side. Dart owns only the current-match index, loaded-window bookkeeping, and widgets.
- **`usize` maps to `BigInt` in generated Dart.** Pass `BigInt.from(n)` into Rust, call `.toInt()` on returned values. This is how the existing code does it (`_session.lineCount().toInt()`, `c.row.toInt()`).
- **Columns are UTF-16 code units**, matching `CaretPos` and the Dart renderer. Use the existing `u16_len` / `u16_to_byte` helpers in `edit_session.rs` for byte↔column conversion.
- **Regen bindings after every Rust API change:** `flutter_rust_bridge_codegen generate` from the repo root. Commit the regenerated `lib/src/rust/**` and `rust/src/frb_generated.rs` together with the Rust change.
- **Paging constants** (declared once in `rust/src/api/search.rs`, referenced everywhere): `SEARCH_WINDOW_ROWS = 4096`, `SEARCH_WINDOW_OVERLAP_ROWS = 64`. Dart-side: `PREFETCH_MARGIN = 20` matches, `MATCH_DEBOUNCE = 150ms`.
- **Search functions are non-`sync`** (no `#[flutter_rust_bridge::frb(sync)]`) so they run on the worker thread and never block a frame. `validate_query` is the sole exception — it is `sync` because it must run on every keystroke.
- **Stated limitation, do not try to fix:** a multi-line match spanning more than `SEARCH_WINDOW_OVERLAP_ROWS` rows will not be found.

## File Structure

| File | Responsibility |
|---|---|
| `rust/src/api/search.rs` (create) | Pure matching logic: mode lowering to regex, escape expansion, replacement expansion, shared types and paging constants. No `EditSession` dependency. |
| `rust/src/api/edit_session.rs` (modify) | Document-facing search: `find_in_rows`, `count_matches`, `replace_span`, `replace_all_in_rows`. |
| `rust/src/api/mod.rs` (modify) | Register `search` module. |
| `rust/Cargo.toml` (modify) | Add `regex` dependency. |
| `lib/find_state.dart` (create) | `FindController` — paging state machine, debounce, prefetch, generation-based cancellation. |
| `lib/find_panel.dart` (create) | The docked panel widget. |
| `lib/editor.dart` (modify) | Match highlighting in `EditorPainter`; `revealSpan()` and visible-row reporting in `CustomEditorState`. |
| `lib/main.dart` (modify) | Hosts the app-level `FindController`, panel placement, keyboard shortcuts. |
| `lib/menu_ribbon.dart` (modify) | Wire `search.find` / `search.replace` menu actions. |
| `test/find_search_test.dart` (create) | Dart tests for Rust search behavior through the bridge. |
| `test/find_controller_test.dart` (create) | Dart tests for `FindController` paging. |

---

### Task 1: Rust search primitives (pure logic)

Pure functions with no `EditSession` dependency, so they are testable in isolation with `cargo test`. This follows the existing pattern in `rust/src/api/edit_ops.rs` (pure functions + `#[cfg(test)] mod tests` at the bottom).

**Files:**
- Create: `rust/src/api/search.rs`
- Modify: `rust/src/api/mod.rs`
- Modify: `rust/Cargo.toml`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pub enum SearchMode { Normal, Extended, Regex }`
  - `pub struct SearchQuery { pub pattern: String, pub mode: SearchMode, pub match_case: bool, pub whole_word: bool, pub dot_matches_newline: bool }`
  - `pub struct MatchSpan { pub start_row: usize, pub start_col: usize, pub end_row: usize, pub end_col: usize }`
  - `pub struct SpanScope { pub start_row: usize, pub start_col: usize, pub end_row: usize, pub end_col: usize }`
  - `pub const SEARCH_WINDOW_ROWS: usize = 4096;`
  - `pub const SEARCH_WINDOW_OVERLAP_ROWS: usize = 64;`
  - `pub fn compile(query: &SearchQuery) -> anyhow::Result<regex::Regex>`
  - `pub fn unescape_extended(s: &str) -> anyhow::Result<String>`
  - `pub fn expand_replacement(mode: &SearchMode, caps: &regex::Captures, template: &str) -> anyhow::Result<String>`
  - `pub fn validate_query(query: SearchQuery) -> Option<String>` — frb `sync`, returns the error message or `None`.

- [ ] **Step 1: Add the regex dependency**

In `rust/Cargo.toml`, add to `[dependencies]` (keep alphabetical ordering — after `quoted_printable`):

```toml
regex = "1"
```

- [ ] **Step 2: Register the module**

In `rust/src/api/mod.rs`, add:

```rust
pub mod search;
```

- [ ] **Step 3: Write the failing tests**

Create `rust/src/api/search.rs` containing ONLY this test module for now (the file will not compile yet — that is expected):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn q(pattern: &str, mode: SearchMode) -> SearchQuery {
        SearchQuery {
            pattern: pattern.to_string(),
            mode,
            match_case: true,
            whole_word: false,
            dot_matches_newline: false,
        }
    }

    #[test]
    fn unescape_handles_supported_escapes() {
        assert_eq!(unescape_extended(r"a\nb").unwrap(), "a\nb");
        assert_eq!(unescape_extended(r"a\rb").unwrap(), "a\rb");
        assert_eq!(unescape_extended(r"a\tb").unwrap(), "a\tb");
        assert_eq!(unescape_extended(r"a\0b").unwrap(), "a\0b");
        assert_eq!(unescape_extended(r"a\\b").unwrap(), r"a\b");
        assert_eq!(unescape_extended(r"\x41").unwrap(), "A");
        assert_eq!(unescape_extended(r"A").unwrap(), "A");
    }

    #[test]
    fn unescape_rejects_unknown_escape() {
        assert!(unescape_extended(r"a\qb").is_err());
        assert!(unescape_extended(r"trailing\").is_err());
        assert!(unescape_extended(r"\xZZ").is_err());
    }

    #[test]
    fn normal_mode_treats_pattern_as_literal() {
        let re = compile(&q("a.c", SearchMode::Normal)).unwrap();
        assert!(re.is_match("a.c"));
        assert!(!re.is_match("abc"));
    }

    #[test]
    fn extended_mode_expands_escapes_then_matches_literally() {
        let re = compile(&q(r"a\tb", SearchMode::Extended)).unwrap();
        assert!(re.is_match("a\tb"));
        assert!(!re.is_match("atb"));
    }

    #[test]
    fn regex_mode_matches_as_regex() {
        let re = compile(&q("a.c", SearchMode::Regex)).unwrap();
        assert!(re.is_match("abc"));
    }

    #[test]
    fn regex_mode_surfaces_compile_error() {
        assert!(compile(&q("a(", SearchMode::Regex)).is_err());
    }

    #[test]
    fn match_case_off_matches_case_insensitively() {
        let mut query = q("abc", SearchMode::Normal);
        query.match_case = false;
        let re = compile(&query).unwrap();
        assert!(re.is_match("ABC"));
    }

    #[test]
    fn whole_word_requires_word_boundaries() {
        let mut query = q("cat", SearchMode::Normal);
        query.whole_word = true;
        let re = compile(&query).unwrap();
        assert!(re.is_match("a cat here"));
        assert!(!re.is_match("concatenate"));
    }

    #[test]
    fn whole_word_wraps_alternation_correctly() {
        // Without the non-capturing group, `\bcat|dog\b` would bind wrongly.
        let mut query = q("cat|dog", SearchMode::Regex);
        query.whole_word = true;
        let re = compile(&query).unwrap();
        assert!(re.is_match("a dog here"));
        assert!(!re.is_match("dogma"));
    }

    #[test]
    fn dot_matches_newline_flag_applies() {
        let mut query = q("a.b", SearchMode::Regex);
        query.dot_matches_newline = true;
        let re = compile(&query).unwrap();
        assert!(re.is_match("a\nb"));
    }

    #[test]
    fn expand_replacement_uses_captures_in_regex_mode() {
        let re = compile(&q(r"(\w+)@(\w+)", SearchMode::Regex)).unwrap();
        let caps = re.captures("user@host").unwrap();
        let out = expand_replacement(&SearchMode::Regex, &caps, "$2:$1").unwrap();
        assert_eq!(out, "host:user");
    }

    #[test]
    fn expand_replacement_is_literal_in_normal_mode() {
        let re = compile(&q("user", SearchMode::Normal)).unwrap();
        let caps = re.captures("user").unwrap();
        let out = expand_replacement(&SearchMode::Normal, &caps, "$1x").unwrap();
        assert_eq!(out, "$1x");
    }

    #[test]
    fn expand_replacement_expands_escapes_in_extended_mode() {
        let re = compile(&q("user", SearchMode::Extended)).unwrap();
        let caps = re.captures("user").unwrap();
        let out = expand_replacement(&SearchMode::Extended, &caps, r"a\tb").unwrap();
        assert_eq!(out, "a\tb");
    }

    #[test]
    fn validate_query_reports_bad_regex_and_accepts_good_one() {
        assert!(validate_query(q("a(", SearchMode::Regex)).is_some());
        assert!(validate_query(q("a(", SearchMode::Normal)).is_none());
        assert!(validate_query(q("abc", SearchMode::Regex)).is_none());
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cd rust && cargo test --lib search::`
Expected: FAIL — compile errors, `cannot find function unescape_extended`, `cannot find type SearchQuery`, etc.

- [ ] **Step 5: Write the implementation**

Prepend this to `rust/src/api/search.rs`, above the test module:

```rust
use regex::{Captures, Regex};

/// Rows scanned per paged search window.
pub const SEARCH_WINDOW_ROWS: usize = 4096;

/// Rows each window extends past its end, so a multi-line match straddling a
/// window boundary is still found. A match taller than this is not found —
/// an accepted limitation.
pub const SEARCH_WINDOW_OVERLAP_ROWS: usize = 64;

/// How a search pattern is interpreted. Mirrors Notepad++'s Search Mode.
pub enum SearchMode {
    /// Literal text.
    Normal,
    /// Literal text after `\n \r \t \0 \\ \xHH \uXXXX` expansion.
    Extended,
    /// A regular expression.
    Regex,
}

impl Clone for SearchMode {
    fn clone(&self) -> Self {
        match self {
            SearchMode::Normal => SearchMode::Normal,
            SearchMode::Extended => SearchMode::Extended,
            SearchMode::Regex => SearchMode::Regex,
        }
    }
}

pub struct SearchQuery {
    pub pattern: String,
    pub mode: SearchMode,
    pub match_case: bool,
    pub whole_word: bool,
    /// Regex mode only: `.` also matches '\n'.
    pub dot_matches_newline: bool,
}

/// A match, in the editor's coordinate system. Columns are UTF-16 code units.
pub struct MatchSpan {
    pub start_row: usize,
    pub start_col: usize,
    pub end_row: usize,
    pub end_col: usize,
}

/// A row/column range limiting a search ("In selection").
pub struct SpanScope {
    pub start_row: usize,
    pub start_col: usize,
    pub end_row: usize,
    pub end_col: usize,
}

/// Expand `\n \r \t \0 \\ \xHH \uXXXX`. An unrecognized escape is an error
/// rather than a silent literal, so a typo surfaces in the panel.
pub fn unescape_extended(s: &str) -> anyhow::Result<String> {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        let esc = it
            .next()
            .ok_or_else(|| anyhow::anyhow!("trailing backslash"))?;
        match esc {
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            '0' => out.push('\0'),
            '\\' => out.push('\\'),
            'x' => {
                let hex: String = (&mut it).take(2).collect();
                if hex.len() != 2 {
                    anyhow::bail!("\\x needs 2 hex digits");
                }
                let v = u8::from_str_radix(&hex, 16)
                    .map_err(|_| anyhow::anyhow!("bad \\x escape: \\x{}", hex))?;
                out.push(v as char);
            }
            'u' => {
                let hex: String = (&mut it).take(4).collect();
                if hex.len() != 4 {
                    anyhow::bail!("\\u needs 4 hex digits");
                }
                let v = u32::from_str_radix(&hex, 16)
                    .map_err(|_| anyhow::anyhow!("bad \\u escape: \\u{}", hex))?;
                out.push(
                    char::from_u32(v)
                        .ok_or_else(|| anyhow::anyhow!("invalid code point \\u{}", hex))?,
                );
            }
            other => anyhow::bail!("unknown escape: \\{}", other),
        }
    }
    Ok(out)
}

/// Lower any search mode to a single regex. This is the one place a mode is
/// interpreted; every caller goes through it.
pub fn compile(query: &SearchQuery) -> anyhow::Result<Regex> {
    if query.pattern.is_empty() {
        anyhow::bail!("empty pattern");
    }
    let body = match query.mode {
        SearchMode::Normal => regex::escape(&query.pattern),
        SearchMode::Extended => regex::escape(&unescape_extended(&query.pattern)?),
        SearchMode::Regex => query.pattern.clone(),
    };
    // The non-capturing group keeps `\b` binding to the whole alternation.
    let body = if query.whole_word {
        format!(r"\b(?:{})\b", body)
    } else {
        body
    };
    let mut flags = String::new();
    if !query.match_case {
        flags.push('i');
    }
    if query.dot_matches_newline {
        flags.push('s');
    }
    let full = if flags.is_empty() {
        body
    } else {
        format!("(?{}){}", flags, body)
    };
    Regex::new(&full).map_err(|e| anyhow::anyhow!("{}", e))
}

/// Build the replacement text for one match. Capture references are honored
/// only in Regex mode; Normal mode keeps `$1` literal, as Notepad++ does.
pub fn expand_replacement(
    mode: &SearchMode,
    caps: &Captures,
    template: &str,
) -> anyhow::Result<String> {
    match mode {
        SearchMode::Regex => {
            let mut out = String::new();
            caps.expand(template, &mut out);
            Ok(out)
        }
        SearchMode::Extended => unescape_extended(template),
        SearchMode::Normal => Ok(template.to_string()),
    }
}

/// Cheap validity check for the panel to call on every keystroke. Returns the
/// error message when the query cannot compile, or None when it is usable.
#[flutter_rust_bridge::frb(sync)]
pub fn validate_query(query: SearchQuery) -> Option<String> {
    if query.pattern.is_empty() {
        return None;
    }
    match compile(&query) {
        Ok(_) => None,
        Err(e) => Some(e.to_string()),
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd rust && cargo test --lib search::`
Expected: PASS, 13 tests.

- [ ] **Step 7: Regenerate bindings**

Run from the repo root: `flutter_rust_bridge_codegen generate`
Expected: `lib/src/rust/api/search.dart` is created, `frb_generated.*` updated.

- [ ] **Step 8: Verify the Dart side still analyzes**

Run: `flutter analyze`
Expected: no new errors.

- [ ] **Step 9: Commit**

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/src/api/search.rs rust/src/api/mod.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "feat(search): add Rust search primitives for find/replace"
```

---

### Task 2: `find_in_rows` — the paged scan primitive

The single primitive every feature pages over. The window/overlap policy lives **here**, not in Dart: the scan reaches `SEARCH_WINDOW_OVERLAP_ROWS` past `to_row` so a straddling multi-line match is found, but returns only matches *starting* in `[from_row, to_row)`. That makes consecutive windows tile exactly, so the Dart pager needs no dedupe.

**Files:**
- Modify: `rust/src/api/edit_session.rs` (add to the `impl EditSession` block; tests into the existing `#[cfg(test)] mod tests` at line ~614)

**Interfaces:**
- Consumes: `SearchQuery`, `MatchSpan`, `SEARCH_WINDOW_OVERLAP_ROWS`, `compile` from Task 1. The existing private helpers `u16_len`, `u16_to_byte`, `get_line_visual`, `line_count`.
- Produces: `pub fn find_in_rows(&self, query: SearchQuery, from_row: usize, to_row: usize) -> anyhow::Result<Vec<MatchSpan>>`

- [ ] **Step 1: Write the failing tests**

Add to the existing `#[cfg(test)] mod tests` in `rust/src/api/edit_session.rs`:

```rust
    use crate::api::search::{SearchMode, SearchQuery, SEARCH_WINDOW_OVERLAP_ROWS};

    fn query(pattern: &str) -> SearchQuery {
        SearchQuery {
            pattern: pattern.to_string(),
            mode: SearchMode::Normal,
            match_case: true,
            whole_word: false,
            dot_matches_newline: false,
        }
    }

    fn regex_query(pattern: &str, dot_nl: bool) -> SearchQuery {
        SearchQuery {
            pattern: pattern.to_string(),
            mode: SearchMode::Regex,
            match_case: true,
            whole_word: false,
            dot_matches_newline: dot_nl,
        }
    }

    #[test]
    fn find_matches_at_document_start() {
        let (s, _p) = session("needle here\nother\n");
        let m = s.find_in_rows(query("needle"), 0, 10).unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!((m[0].start_row, m[0].start_col), (0, 0));
        assert_eq!((m[0].end_row, m[0].end_col), (0, 6));
    }

    #[test]
    fn find_matches_at_document_end() {
        let (s, _p) = session("alpha\nbeta needle");
        let m = s.find_in_rows(query("needle"), 0, 10).unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!((m[0].start_row, m[0].start_col), (1, 5));
        assert_eq!((m[0].end_row, m[0].end_col), (1, 11));
    }

    #[test]
    fn find_returns_matches_in_order() {
        let (s, _p) = session("x\nax\nbx\n");
        let m = s.find_in_rows(query("x"), 0, 10).unwrap();
        assert_eq!(m.len(), 3);
        assert_eq!(m[0].start_row, 0);
        assert_eq!(m[1].start_row, 1);
        assert_eq!(m[2].start_row, 2);
    }

    #[test]
    fn find_uses_utf16_columns() {
        // "😀" is 2 UTF-16 code units, so the match starts at column 2.
        let (s, _p) = session("😀needle\n");
        let m = s.find_in_rows(query("needle"), 0, 10).unwrap();
        assert_eq!(m[0].start_col, 2);
    }

    #[test]
    fn find_matches_multiline_pattern_inside_window() {
        let (s, _p) = session("alpha\nbeta\ngamma\n");
        let m = s.find_in_rows(regex_query("alpha.beta", true), 0, 10).unwrap();
        assert_eq!(m.len(), 1);
        assert_eq!((m[0].start_row, m[0].start_col), (0, 0));
        assert_eq!((m[0].end_row, m[0].end_col), (1, 4));
    }

    fn n_row_document(n: usize) -> String {
        let mut content = String::new();
        for i in 0..n {
            content.push_str(&format!("row{}\n", i));
        }
        content
    }

    #[test]
    fn find_matches_multiline_pattern_straddling_window_boundary() {
        // Enough rows that `to_row + SEARCH_WINDOW_OVERLAP_ROWS` (10 + 64 =
        // 74) does NOT clamp to the document end — otherwise the whole
        // document gets scanned regardless of the overlap constant's value,
        // and the test passes vacuously. A match starting at row 9 (just
        // before `to_row`) and ending at row 73 — the very LAST row the scan
        // reaches with the real overlap of 64 — is only found because the
        // overlap is exactly that big.
        //
        // Row 73 is hardcoded, NOT derived from SEARCH_WINDOW_OVERLAP_ROWS:
        // deriving it would move the goalposts along with the constant and
        // test nothing. Pinning it means shrinking the constant breaks this.
        assert_eq!(SEARCH_WINDOW_OVERLAP_ROWS, 64, "test rows below assume this");
        let (s, _p) = session(&n_row_document(100));
        let m = s.find_in_rows(regex_query("row9.*row73", true), 0, 10).unwrap();
        assert_eq!(m.len(), 1, "overlap should catch the straddling match");
        assert_eq!((m[0].start_row, m[0].start_col), (9, 0));
        assert_eq!((m[0].end_row, m[0].end_col), (73, 5));
    }

    #[test]
    fn find_does_not_reach_past_the_overlap_window() {
        // The companion that bounds the overlap from ABOVE. Together with the
        // test before it, the pair pins the constant to exactly 64: shrink it
        // and that test fails, grow it and this one does.
        //
        // A match starting at row 9 but needing text one row past what the
        // overlap covers (row 74) must not be found — it belongs to no
        // window's scan text. This is the documented limitation.
        assert_eq!(SEARCH_WINDOW_OVERLAP_ROWS, 64, "test rows below assume this");
        let (s, _p) = session(&n_row_document(100));
        let m = s.find_in_rows(regex_query("row9.*row74", true), 0, 10).unwrap();
        assert!(
            m.is_empty(),
            "a match reaching past the overlap window must not be found"
        );
    }

    #[test]
    fn find_excludes_matches_starting_at_or_after_to_row() {
        // Consecutive windows must tile exactly, with no duplicates.
        let (s, _p) = session("hit\nhit\nhit\nhit\n");
        let first = s.find_in_rows(query("hit"), 0, 2).unwrap();
        let second = s.find_in_rows(query("hit"), 2, 4).unwrap();
        assert_eq!(first.len(), 2);
        assert_eq!(second.len(), 2);
        assert_eq!(first[0].start_row, 0);
        assert_eq!(second[0].start_row, 2);
    }

    #[test]
    fn find_clamps_range_beyond_document() {
        let (s, _p) = session("only\n");
        let m = s.find_in_rows(query("only"), 0, 100_000).unwrap();
        assert_eq!(m.len(), 1);
        let none = s.find_in_rows(query("only"), 50, 100).unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn find_with_inverted_range_returns_empty() {
        let (s, _p) = session("hit\n");
        assert!(s.find_in_rows(query("hit"), 5, 2).unwrap().is_empty());
    }

    #[test]
    fn find_terminates_on_zero_length_match() {
        let (s, _p) = session("ab\n");
        // `x*` matches empty at every position; must advance, not loop.
        // Assert the exact spans — a bare "fewer than N" bound tests neither
        // termination (the process not hanging proves that) nor correctness.
        //
        // The document is TWO rows: "ab" and the trailing empty row left by
        // the final newline. It is scanned as the joined text "ab\n" (3
        // bytes), so a zero-length match occurs at every byte offset 0..=3:
        // before 'a', before 'b', before '\n' (still row 0 — '\n' is the row
        // separator, not row 1's content), and at the start of empty row 1.
        let m = s.find_in_rows(regex_query("x*", false), 0, 10).unwrap();
        let spans: Vec<(usize, usize, usize, usize)> = m
            .iter()
            .map(|sp| (sp.start_row, sp.start_col, sp.end_row, sp.end_col))
            .collect();
        assert_eq!(
            spans,
            vec![(0, 0, 0, 0), (0, 1, 0, 1), (0, 2, 0, 2), (1, 0, 1, 0)],
            "zero-length matches must advance one position at a time and stop at document end"
        );
    }

    #[test]
    fn find_reports_error_for_invalid_regex() {
        let (s, _p) = session("anything\n");
        assert!(s.find_in_rows(regex_query("a(", false), 0, 10).is_err());
    }

    #[test]
    fn overlap_constant_is_used() {
        assert_eq!(SEARCH_WINDOW_OVERLAP_ROWS, 64);
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd rust && cargo test --lib edit_session::`
Expected: FAIL — `no method named find_in_rows found for struct EditSession`.

- [ ] **Step 3: Write the implementation**

Add inside the `impl EditSession` block in `rust/src/api/edit_session.rs`. Note there is **no** `frb(sync)` attribute — this runs on the worker thread.

```rust
    /// Find every match whose start row is in `[from_row, to_row)`.
    ///
    /// The scan itself reaches `SEARCH_WINDOW_OVERLAP_ROWS` rows past
    /// `to_row` so a multi-line match straddling the boundary is still found,
    /// but such a match is only returned by the window its *start* falls in.
    /// Consecutive windows therefore tile exactly, with no duplicates.
    pub fn find_in_rows(
        &self,
        query: crate::api::search::SearchQuery,
        from_row: usize,
        to_row: usize,
    ) -> anyhow::Result<Vec<crate::api::search::MatchSpan>> {
        use crate::api::search::{compile, MatchSpan, SEARCH_WINDOW_OVERLAP_ROWS};

        let total = self.line_count();
        let from = from_row.min(total);
        let to = to_row.min(total);
        if from >= to {
            return Ok(Vec::new());
        }
        let scan_to = (to + SEARCH_WINDOW_OVERLAP_ROWS).min(total);

        let re = compile(&query)?;

        // Join the scanned rows, remembering each row's byte offset in the
        // joined string so byte positions map back to (row, utf16 col).
        let mut text = String::new();
        let mut row_starts: Vec<usize> = Vec::with_capacity(scan_to - from);
        for row in from..scan_to {
            row_starts.push(text.len());
            text.push_str(&self.get_line_visual(row));
            if row + 1 < scan_to {
                text.push('\n');
            }
        }

        // Byte offset in `text` -> (absolute row, UTF-16 column).
        let locate = |byte: usize| -> (usize, usize) {
            // The last row whose start is <= byte.
            let idx = match row_starts.binary_search(&byte) {
                Ok(i) => i,
                Err(i) => i.saturating_sub(1),
            };
            let line = self.get_line_visual(from + idx);
            let within = byte - row_starts[idx];
            (from + idx, u16_len(&line[..within.min(line.len())]))
        };

        let mut out = Vec::new();
        let mut at = 0usize;
        while at <= text.len() {
            let Some(m) = re.find_at(&text, at) else { break };
            let (srow, scol) = locate(m.start());
            if srow >= to {
                break;
            }
            let (erow, ecol) = locate(m.end());
            out.push(MatchSpan {
                start_row: srow,
                start_col: scol,
                end_row: erow,
                end_col: ecol,
            });
            // A zero-length match must advance, or this loops forever.
            at = if m.end() > m.start() {
                m.end()
            } else {
                let mut next = m.end() + 1;
                while next < text.len() && !text.is_char_boundary(next) {
                    next += 1;
                }
                next
            };
        }
        Ok(out)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rust && cargo test --lib edit_session::`
Expected: PASS — all new tests plus the pre-existing `edit_session` tests.

- [ ] **Step 5: Regenerate bindings and verify**

Run: `flutter_rust_bridge_codegen generate && flutter analyze`
Expected: `findInRows` appears in `lib/src/rust/api/edit_session.dart`; no analyzer errors.

- [ ] **Step 6: Commit**

```bash
git add rust/src/api/edit_session.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "feat(search): add paged find_in_rows scan to EditSession"
```

---

### Task 3: `count_matches` with scope

The full sweep behind the counter and the Count button. Also introduces scope filtering, which Task 4's "Replace All in selection" reuses.

**Files:**
- Modify: `rust/src/api/edit_session.rs`

**Interfaces:**
- Consumes: `find_in_rows` (Task 2), `SpanScope`, `SEARCH_WINDOW_ROWS` (Task 1).
- Produces:
  - `pub fn count_matches(&self, query: SearchQuery, scope: Option<SpanScope>) -> anyhow::Result<usize>`
  - private `fn span_in_scope(span: &MatchSpan, scope: &SpanScope) -> bool`

- [ ] **Step 1: Write the failing tests**

Add to `#[cfg(test)] mod tests` in `rust/src/api/edit_session.rs`:

```rust
    use crate::api::search::SpanScope;

    #[test]
    fn count_matches_counts_whole_document() {
        let (s, _p) = session("hit\nmiss\nhit\nhit\n");
        assert_eq!(s.count_matches(query("hit"), None).unwrap(), 3);
    }

    #[test]
    fn count_matches_returns_zero_when_absent() {
        let (s, _p) = session("alpha\nbeta\n");
        assert_eq!(s.count_matches(query("gamma"), None).unwrap(), 0);
    }

    #[test]
    fn count_matches_spans_many_windows() {
        // More rows than one window, so the sweep must page.
        let mut content = String::new();
        for _ in 0..(crate::api::search::SEARCH_WINDOW_ROWS + 500) {
            content.push_str("hit\n");
        }
        let (s, _p) = session(&content);
        let expected = crate::api::search::SEARCH_WINDOW_ROWS + 500;
        assert_eq!(s.count_matches(query("hit"), None).unwrap(), expected);
    }

    #[test]
    fn count_matches_respects_scope() {
        let (s, _p) = session("hit\nhit\nhit\nhit\n");
        let scope = SpanScope {
            start_row: 1,
            start_col: 0,
            end_row: 3,
            end_col: 0,
        };
        assert_eq!(s.count_matches(query("hit"), Some(scope)).unwrap(), 2);
    }

    #[test]
    fn count_matches_scope_respects_columns() {
        // Scope starts mid-row 0, so row 0's match at col 0 is excluded.
        let (s, _p) = session("hit hit\n");
        let scope = SpanScope {
            start_row: 0,
            start_col: 4,
            end_row: 0,
            end_col: 7,
        };
        assert_eq!(s.count_matches(query("hit"), Some(scope)).unwrap(), 1);
    }

    #[test]
    fn count_matches_excludes_match_crossing_scope_end() {
        let (s, _p) = session("hit\n");
        let scope = SpanScope {
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 2,
        };
        assert_eq!(s.count_matches(query("hit"), Some(scope)).unwrap(), 0);
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd rust && cargo test --lib edit_session::count_`
Expected: FAIL — `no method named count_matches`.

- [ ] **Step 3: Write the implementation**

Add to `rust/src/api/edit_session.rs`. Put `span_in_scope` as a free function near `u16_to_byte` (it needs no `self`):

```rust
/// True when `span` lies wholly inside `scope`.
fn span_in_scope(
    span: &crate::api::search::MatchSpan,
    scope: &crate::api::search::SpanScope,
) -> bool {
    let after_start = (span.start_row, span.start_col) >= (scope.start_row, scope.start_col);
    let before_end = (span.end_row, span.end_col) <= (scope.end_row, scope.end_col);
    after_start && before_end
}
```

And inside `impl EditSession`:

```rust
    /// Total matches in the document, or within `scope` when given. Pages the
    /// whole document one window at a time so peak memory stays bounded.
    pub fn count_matches(
        &self,
        query: crate::api::search::SearchQuery,
        scope: Option<crate::api::search::SpanScope>,
    ) -> anyhow::Result<usize> {
        use crate::api::search::{SearchQuery, SEARCH_WINDOW_ROWS};

        let total = self.line_count();
        let mut count = 0usize;
        let mut row = 0usize;
        while row < total {
            let to = (row + SEARCH_WINDOW_ROWS).min(total);
            // SearchQuery is not Copy; rebuild it per window.
            let q = SearchQuery {
                pattern: query.pattern.clone(),
                mode: query.mode.clone(),
                match_case: query.match_case,
                whole_word: query.whole_word,
                dot_matches_newline: query.dot_matches_newline,
            };
            for span in self.find_in_rows(q, row, to)? {
                match &scope {
                    Some(sc) if !span_in_scope(&span, sc) => continue,
                    _ => count += 1,
                }
            }
            row = to;
        }
        Ok(count)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rust && cargo test --lib edit_session::`
Expected: PASS.

- [ ] **Step 5: Regenerate bindings and verify**

Run: `flutter_rust_bridge_codegen generate && flutter analyze`
Expected: `countMatches` in `lib/src/rust/api/edit_session.dart`; no analyzer errors.

- [ ] **Step 6: Commit**

```bash
git add rust/src/api/edit_session.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "feat(search): add scoped count_matches sweep"
```

---

### Task 4: Replace primitives

`replace_span` for the current match, `replace_all_in_rows` for the bulk case. Both mutate through the existing `begin_group`/`delete`/`insert`/`end_group` machinery so undo treats them as single steps.

**Files:**
- Modify: `rust/src/api/edit_session.rs`

**Interfaces:**
- Consumes: `find_in_rows` (Task 2), `span_in_scope` (Task 3), `compile`/`expand_replacement` (Task 1), and the existing `begin_group`, `end_group`, `delete`, `insert`, `get_line_visual`, `u16_to_byte`.
- Produces:
  - `pub fn replace_span(&mut self, query: SearchQuery, span: MatchSpan, replacement: String) -> anyhow::Result<CaretPos>`
  - `pub fn replace_all_in_rows(&mut self, query: SearchQuery, replacement: String, scope: Option<SpanScope>) -> anyhow::Result<usize>`

- [ ] **Step 1: Write the failing tests**

Add to `#[cfg(test)] mod tests` in `rust/src/api/edit_session.rs`:

```rust
    #[test]
    fn replace_span_replaces_one_match() {
        let (mut s, _p) = session("hit hit\n");
        let spans = s.find_in_rows(query("hit"), 0, 10).unwrap();
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        s.replace_span(query("hit"), first, "X".to_string()).unwrap();
        assert_eq!(doc(&s), "X hit");
    }

    #[test]
    fn replace_span_undoes_as_one_step() {
        let (mut s, _p) = session("hit hit\n");
        let spans = s.find_in_rows(query("hit"), 0, 10).unwrap();
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        s.replace_span(query("hit"), first, "LONGER".to_string()).unwrap();
        s.undo();
        assert_eq!(doc(&s), "hit hit");
    }

    #[test]
    fn replace_span_expands_captures_in_regex_mode() {
        let (mut s, _p) = session("user@host\n");
        let q = regex_query(r"(\w+)@(\w+)", false);
        let spans = s.find_in_rows(regex_query(r"(\w+)@(\w+)", false), 0, 10).unwrap();
        let first = MatchSpan {
            start_row: spans[0].start_row,
            start_col: spans[0].start_col,
            end_row: spans[0].end_row,
            end_col: spans[0].end_col,
        };
        s.replace_span(q, first, "$2:$1".to_string()).unwrap();
        assert_eq!(doc(&s), "host:user");
    }

    #[test]
    fn replace_all_replaces_every_match() {
        let (mut s, _p) = session("hit\nmiss\nhit\n");
        let n = s.replace_all_in_rows(query("hit"), "X".to_string(), None).unwrap();
        assert_eq!(n, 2);
        assert_eq!(doc(&s), "X\nmiss\nX");
    }

    #[test]
    fn replace_all_handles_longer_replacement() {
        // A backwards pass keeps earlier spans valid as later ones grow.
        let (mut s, _p) = session("a a a\n");
        s.replace_all_in_rows(query("a"), "LONG".to_string(), None).unwrap();
        assert_eq!(doc(&s), "LONG LONG LONG");
    }

    #[test]
    fn replace_all_handles_shorter_replacement() {
        let (mut s, _p) = session("aaa aaa\n");
        s.replace_all_in_rows(query("aaa"), "b".to_string(), None).unwrap();
        assert_eq!(doc(&s), "b b");
    }

    #[test]
    fn replace_all_undoes_and_redoes_as_one_step() {
        let (mut s, _p) = session("hit\nhit\nhit\n");
        s.replace_all_in_rows(query("hit"), "X".to_string(), None).unwrap();
        assert_eq!(doc(&s), "X\nX\nX");
        s.undo();
        assert_eq!(doc(&s), "hit\nhit\nhit", "one undo must revert all");
        s.redo();
        assert_eq!(doc(&s), "X\nX\nX", "one redo must reapply all");
    }

    #[test]
    fn replace_all_respects_scope() {
        let (mut s, _p) = session("hit\nhit\nhit\n");
        let scope = SpanScope {
            start_row: 1,
            start_col: 0,
            end_row: 2,
            end_col: 3,
        };
        let n = s
            .replace_all_in_rows(query("hit"), "X".to_string(), Some(scope))
            .unwrap();
        assert_eq!(n, 2);
        assert_eq!(doc(&s), "hit\nX\nX");
    }

    #[test]
    fn replace_all_with_no_match_makes_no_undo_entry() {
        let (mut s, _p) = session("alpha\n");
        let n = s.replace_all_in_rows(query("zzz"), "X".to_string(), None).unwrap();
        assert_eq!(n, 0);
        assert!(!s.can_undo(), "a no-op replace must not push an undo step");
    }

    #[test]
    fn replace_all_terminates_on_zero_length_match() {
        let (mut s, _p) = session("ab\n");
        let n = s
            .replace_all_in_rows(regex_query("x*", false), "".to_string(), None)
            .unwrap();
        assert!(n < 100, "zero-length matches must not loop");
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd rust && cargo test --lib edit_session::replace_span edit_session::replace_all`
Expected: FAIL — `no method named replace_span`.

- [ ] **Step 3: Write the implementation**

Add inside `impl EditSession` in `rust/src/api/edit_session.rs`:

```rust
    /// Replace one match. `query` is needed so capture references in
    /// `replacement` can be expanded against that match. One undo step.
    pub fn replace_span(
        &mut self,
        query: crate::api::search::SearchQuery,
        span: crate::api::search::MatchSpan,
        replacement: String,
    ) -> anyhow::Result<CaretPos> {
        let text = self.expand_for_span(&query, &span, &replacement)?;
        self.begin_group();
        self.delete(span.start_row, span.start_col, span.end_row, span.end_col);
        let caret = self.insert(span.start_row, span.start_col, text);
        self.end_group();
        Ok(caret)
    }

    /// Replace every match (optionally limited to `scope`) as ONE undo step.
    /// Matches are collected first, then applied back-to-front so earlier
    /// spans stay valid as later ones change length. Returns the count.
    pub fn replace_all_in_rows(
        &mut self,
        query: crate::api::search::SearchQuery,
        replacement: String,
        scope: Option<crate::api::search::SpanScope>,
    ) -> anyhow::Result<usize> {
        use crate::api::search::{SearchQuery, SEARCH_WINDOW_ROWS};

        // Collect first: the document must not change while scanning.
        let total = self.line_count();
        let mut spans = Vec::new();
        let mut row = 0usize;
        while row < total {
            let to = (row + SEARCH_WINDOW_ROWS).min(total);
            let q = SearchQuery {
                pattern: query.pattern.clone(),
                mode: query.mode.clone(),
                match_case: query.match_case,
                whole_word: query.whole_word,
                dot_matches_newline: query.dot_matches_newline,
            };
            for span in self.find_in_rows(q, row, to)? {
                match &scope {
                    Some(sc) if !span_in_scope(&span, sc) => continue,
                    _ => spans.push(span),
                }
            }
            row = to;
        }
        if spans.is_empty() {
            return Ok(0);
        }

        // Expand replacements before mutating, for the same reason.
        let mut texts = Vec::with_capacity(spans.len());
        for span in &spans {
            texts.push(self.expand_for_span(&query, span, &replacement)?);
        }

        let n = spans.len();
        self.begin_group();
        for i in (0..n).rev() {
            let span = &spans[i];
            self.delete(span.start_row, span.start_col, span.end_row, span.end_col);
            self.insert(span.start_row, span.start_col, texts[i].clone());
        }
        self.end_group();
        Ok(n)
    }

    /// Re-run the pattern against the matched text so capture groups are
    /// available, then expand `replacement` against them.
    fn expand_for_span(
        &self,
        query: &crate::api::search::SearchQuery,
        span: &crate::api::search::MatchSpan,
        replacement: &str,
    ) -> anyhow::Result<String> {
        use crate::api::search::{compile, expand_replacement};

        let mut matched = String::new();
        for row in span.start_row..=span.end_row {
            let line = self.get_line_visual(row);
            let start = if row == span.start_row {
                u16_to_byte(&line, span.start_col)
            } else {
                0
            };
            let end = if row == span.end_row {
                u16_to_byte(&line, span.end_col)
            } else {
                line.len()
            };
            matched.push_str(&line[start..end]);
            if row < span.end_row {
                matched.push('\n');
            }
        }
        let re = compile(query)?;
        let caps = re
            .captures(&matched)
            .ok_or_else(|| anyhow::anyhow!("match text no longer matches the pattern"))?;
        expand_replacement(&query.mode, &caps, replacement)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rust && cargo test --lib edit_session::`
Expected: PASS.

- [ ] **Step 5: Regenerate bindings and verify**

Run: `flutter_rust_bridge_codegen generate && flutter analyze`
Expected: `replaceSpan` and `replaceAllInRows` in `lib/src/rust/api/edit_session.dart`; no analyzer errors.

- [ ] **Step 6: Commit**

```bash
git add rust/src/api/edit_session.rs rust/src/frb_generated.rs lib/src/rust
git commit -m "feat(search): add replace_span and replace_all_in_rows"
```

---

### Task 5: `FindController` — the paging state machine

The one piece of non-trivial Dart logic. It is view state (which match is current, which windows are loaded), not domain logic, so it belongs on this side of the bridge.

> **AMENDED AFTER IMPLEMENTATION — `lib/find_state.dart` is the authority, not the sample below.**
> Review found one Critical and three Important defects in the sample code in this section.
> The delivered implementation differs from it in four ways:
>
> 1. **Generation is rechecked after every await in `stepForward`/`stepBackward`**, not only
>    inside the loaders. The sample mutated `_currentIndex` and notified against state that
>    could belong to a newer query — reachable by typing while a step is in flight.
> 2. **`_maybePrefetch` holds an in-flight flag** cleared via `whenComplete`. Without it two
>    prefetches could request the same window and both append, duplicating matches and
>    breaking the exact-tiling contract that exists so Dart never has to dedupe.
> 3. **All backward window paging is deleted** — `_loadBackward`, `_loadedFrom`, and their call
>    sites. `_loadedFrom` was permanently 0, so none of it could ever execute. See the
>    forward-only note in the Architecture section.
> 4. **`_resetMatches()` clears `_sweepRunning`**, closing a leak where clearing the query
>    mid-sweep left the flag set for the controller's lifetime.
>
> The sample below is retained as the design record of what was specified. Read the amendment
> above before treating any of it as current.

**Files:**
- Create: `lib/find_state.dart`
- Create: `test/find_controller_test.dart`

**Interfaces:**
- Consumes: `EditSession.findInRows`, `EditSession.countMatches`, `EditSession.replaceSpan`, `EditSession.replaceAllInRows`, `validateQuery` — all `BigInt`-taking, per the Global Constraints.
- Produces:
  - `enum FindPanelMode { find, replace }`
  - `class FindController extends ChangeNotifier` with:
    - `TextEditingController query`, `TextEditingController replacement`
    - `FindPanelMode mode`, `void setMode(FindPanelMode m)`
    - `SearchMode searchMode`, `bool matchCase`, `bool wholeWord`, `bool wrapAround`, `bool inSelection`, `bool dotMatchesNewline`
    - `void attach(EditSession? session, int lineCount)`
    - `List<MatchSpan> get loaded`, `int get currentIndex`, `MatchSpan? get currentMatch`
    - `int? get exactTotal`, `bool get sweepRunning`, `String? get regexError`
    - `Future<void> stepForward()`, `Future<void> stepBackward()`
    - `Future<void> refresh({int? anchorRow, int? anchorCol})`, `Future<int> replaceCurrent()`, `Future<int> replaceAll()`
    - `Future<int?> recount()` — the Count button
    - `void scheduleRefresh()`, `Future<void> awaitSweep()`
    - `bool get canStepForward`, `bool get canStepBackward`
    - `String get counterLabel`
    - `SpanScope? scope` (set by the host from the editor selection)

- [ ] **Step 1: Write the failing tests**

Create `test/find_controller_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
        '${Directory.systemTemp.path}/textutilz_find_${DateTime.now().microsecondsSinceEpoch}.txt';
    return EditSession.createScratch(path: path, content: content);
  }

  Future<FindController> controllerOver(String content, String pattern) async {
    final session = sessionWith(content);
    final c = FindController();
    c.attach(session, session.lineCount().toInt());
    c.query.text = pattern;
    await c.refresh();
    return c;
  }

  test('finds matches and reports the first as current', () async {
    final c = await controllerOver('hit\nmiss\nhit\n', 'hit');
    expect(c.loaded.length, 2);
    expect(c.currentIndex, 0);
    expect(c.currentMatch!.startRow.toInt(), 0);
  });

  test('stepForward advances through matches', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 1);
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 2);
  });

  test('stepBackward moves back through matches', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    await c.stepForward();
    await c.stepBackward();
    expect(c.currentMatch!.startRow.toInt(), 0);
  });

  test('wraps to the first match past the end when wrapAround is on', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.wrapAround = true;
    await c.stepForward();
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 0, reason: 'should wrap to start');
  });

  test('wraps to the last match before the start when wrapAround is on', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.wrapAround = true;
    await c.stepBackward();
    expect(c.currentMatch!.startRow.toInt(), 1, reason: 'should wrap to end');
  });

  test('stays on the last match when wrapAround is off', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.wrapAround = false;
    await c.stepForward();
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 1);
  });

  test('pages in matches beyond the first window', () async {
    // More rows than one window, with a match only far past the first window.
    final filler = List.filled(5000, 'x').join('\n');
    final c = await controllerOver('$filler\nneedle\n', 'needle');
    expect(c.loaded.isNotEmpty, true,
        reason: 'must page past the first window to find it');
    expect(c.currentMatch!.startRow.toInt(), 5000);
  });

  test('counter shows a provisional total then resolves to exact', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    expect(c.counterLabel, contains('1 of 3'));
    await c.awaitSweep();
    expect(c.exactTotal, 3);
    expect(c.counterLabel, '1 of 3');
  });

  test('reports no results for a pattern that does not occur', () async {
    final c = await controllerOver('alpha\nbeta\n', 'gamma');
    expect(c.loaded, isEmpty);
    expect(c.currentMatch, isNull);
    expect(c.counterLabel, 'No results');
  });

  test('surfaces a regex error and does not scan', () async {
    final c = await controllerOver('alpha\n', 'alpha');
    c.searchMode = SearchMode.regex;
    c.query.text = 'a(';
    await c.refresh();
    expect(c.regexError, isNotNull);
    expect(c.loaded, isEmpty);
  });

  test('clears the regex error once the pattern becomes valid', () async {
    final c = await controllerOver('alpha\n', 'alpha');
    c.searchMode = SearchMode.regex;
    c.query.text = 'a(';
    await c.refresh();
    c.query.text = 'a.pha';
    await c.refresh();
    expect(c.regexError, isNull);
    expect(c.loaded.length, 1);
  });

  test('discards results from a superseded generation', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    final stale = c.refresh(); // in flight
    c.query.text = 'miss';
    await c.refresh();
    await stale;
    expect(c.loaded, isEmpty, reason: 'stale results must not be applied');
  });

  test('switching find to replace preserves the query text', () async {
    final c = await controllerOver('hit\n', 'hit');
    c.setMode(FindPanelMode.replace);
    expect(c.query.text, 'hit');
    expect(c.mode, FindPanelMode.replace);
  });

  test('replaceCurrent replaces only the current match', () async {
    final c = await controllerOver('hit hit\n', 'hit');
    c.replacement.text = 'X';
    final n = await c.replaceCurrent();
    expect(n, 1);
    expect(c.session!.line(vrow: BigInt.zero), 'X hit');
  });

  test('replaceAll replaces every match', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.replacement.text = 'X';
    final n = await c.replaceAll();
    expect(n, 2);
    expect(c.session!.line(vrow: BigInt.zero), 'X');
    expect(c.session!.line(vrow: BigInt.one), 'X');
  });

  test('recount resolves the exact total', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    final total = await c.recount();
    expect(total, 3);
    expect(c.counterLabel, '1 of 3');
  });

  test('anchoring picks the first match at or after the given position', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    await c.refresh(anchorRow: 1, anchorCol: 0);
    expect(c.currentMatch!.startRow.toInt(), 1);
  });

  test('anchoring past the last match falls back to the first', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    await c.refresh(anchorRow: 99, anchorCol: 0);
    expect(c.currentMatch!.startRow.toInt(), 0);
  });

  test('matchCase off finds differently-cased text', () async {
    final c = await controllerOver('HIT\n', 'hit');
    expect(c.loaded, isEmpty);
    c.matchCase = false;
    await c.refresh();
    expect(c.loaded.length, 1);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/find_controller_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:textutilz/find_state.dart'`.

- [ ] **Step 3: Write the implementation**

Create `lib/find_state.dart`:

```dart
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'src/rust/api/edit_session.dart';
import 'src/rust/api/search.dart';

/// Which face the panel is showing. The query controller is shared between
/// them, so switching carries the typed text over.
enum FindPanelMode { find, replace }

/// Matches loaded per paged scan. Mirrors SEARCH_WINDOW_ROWS in search.rs.
const int kSearchWindowRows = 4096;

/// Load the next window once the cursor is this close to a loaded edge.
const int kPrefetchMargin = 20;

/// Coalesce keystrokes before scanning.
const Duration kMatchDebounce = Duration(milliseconds: 150);

/// Owns the find/replace view state: the query, the options, which windows
/// have been scanned, and which match is current. All matching itself happens
/// in Rust — this class only decides *what to ask for and when*.
class FindController extends ChangeNotifier {
  final TextEditingController query = TextEditingController();
  final TextEditingController replacement = TextEditingController();

  FindPanelMode _mode = FindPanelMode.find;
  FindPanelMode get mode => _mode;

  SearchMode searchMode = SearchMode.normal;
  bool matchCase = true;
  bool wholeWord = false;
  bool wrapAround = true;
  bool inSelection = false;
  bool dotMatchesNewline = false;

  /// Limits the search when [inSelection] is on. Set by the host from the
  /// editor's current selection.
  SpanScope? scope;

  EditSession? _session;
  EditSession? get session => _session;
  int _lineCount = 0;

  final List<MatchSpan> _loaded = [];
  List<MatchSpan> get loaded => List.unmodifiable(_loaded);

  int _currentIndex = -1;
  int get currentIndex => _currentIndex;
  MatchSpan? get currentMatch =>
      (_currentIndex >= 0 && _currentIndex < _loaded.length)
          ? _loaded[_currentIndex]
          : null;

  /// Rows already scanned: [_loadedFrom, _loadedTo).
  int _loadedFrom = 0;
  int _loadedTo = 0;

  int? _exactTotal;
  int? get exactTotal => _exactTotal;

  bool _sweepRunning = false;
  bool get sweepRunning => _sweepRunning;

  String? _regexError;
  String? get regexError => _regexError;

  /// Bumped on every query/option change. A scan result carrying a stale
  /// generation is discarded rather than appended out of order.
  int _generation = 0;

  Timer? _debounce;
  Future<void>? _sweep;

  /// Point the controller at a document. Clears matches; query and options
  /// persist across tabs, matching Notepad++.
  void attach(EditSession? session, int lineCount) {
    _session = session;
    _lineCount = lineCount;
    _resetMatches();
    notifyListeners();
  }

  void setMode(FindPanelMode m) {
    _mode = m;
    notifyListeners();
  }

  /// Re-run the search after a debounce. Call on every keystroke.
  void scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(kMatchDebounce, refresh);
  }

  void _resetMatches() {
    _loaded.clear();
    _currentIndex = -1;
    _loadedFrom = 0;
    _loadedTo = 0;
    _exactTotal = null;
  }

  SearchQuery _buildQuery() => SearchQuery(
        pattern: query.text,
        mode: searchMode,
        matchCase: matchCase,
        wholeWord: wholeWord,
        dotMatchesNewline: dotMatchesNewline,
      );

  SpanScope? get _activeScope => inSelection ? scope : null;

  /// Discard loaded matches and scan forward from the top until at least one
  /// match is found or the document is exhausted.
  ///
  /// When [anchorRow]/[anchorCol] are given, the current match becomes the
  /// first match at or after that position instead of the first in the
  /// document. This is what keeps the cursor from jumping backwards after an
  /// edit or a single replace.
  Future<void> refresh({int? anchorRow, int? anchorCol}) async {
    _debounce?.cancel();
    final gen = ++_generation;

    if (_session == null || query.text.isEmpty) {
      _resetMatches();
      _regexError = null;
      notifyListeners();
      return;
    }

    final error = validateQuery(query: _buildQuery());
    if (error != null) {
      _resetMatches();
      _regexError = error;
      notifyListeners();
      return;
    }
    _regexError = null;
    _resetMatches();

    await _loadForward(gen);
    if (gen != _generation) return;

    _currentIndex = _anchorIndex(anchorRow, anchorCol);
    notifyListeners();
    unawaited(_startSweep(gen));
  }

  /// Index of the first loaded match at or after the anchor, or 0 when there
  /// is no anchor or nothing follows it.
  int _anchorIndex(int? anchorRow, int? anchorCol) {
    if (_loaded.isEmpty) return -1;
    if (anchorRow == null || anchorCol == null) return 0;
    for (int i = 0; i < _loaded.length; i++) {
      final s = _loaded[i];
      final row = s.startRow.toInt();
      final col = s.startCol.toInt();
      if (row > anchorRow || (row == anchorRow && col >= anchorCol)) return i;
    }
    return 0;
  }

  /// Scan windows forward until a match is found or the end is reached.
  Future<void> _loadForward(int gen) async {
    while (_loadedTo < _lineCount) {
      final from = _loadedTo;
      final to = (from + kSearchWindowRows).clamp(0, _lineCount);
      final found = await _session!.findInRows(
        query: _buildQuery(),
        fromRow: BigInt.from(from),
        toRow: BigInt.from(to),
      );
      if (gen != _generation) return;
      _loadedTo = to;
      _loaded.addAll(_inScope(found));
      if (_loaded.isNotEmpty) return;
    }
  }

  /// Scan windows backward until a match is found or the top is reached.
  Future<void> _loadBackward(int gen) async {
    while (_loadedFrom > 0) {
      final to = _loadedFrom;
      final from = (to - kSearchWindowRows).clamp(0, _lineCount);
      final found = await _session!.findInRows(
        query: _buildQuery(),
        fromRow: BigInt.from(from),
        toRow: BigInt.from(to),
      );
      if (gen != _generation) return;
      _loadedFrom = from;
      final fresh = _inScope(found);
      _loaded.insertAll(0, fresh);
      _currentIndex += fresh.length;
      if (fresh.isNotEmpty) return;
    }
  }

  List<MatchSpan> _inScope(List<MatchSpan> spans) {
    final sc = _activeScope;
    if (sc == null) return spans;
    return spans.where((s) {
      final afterStart = s.startRow > sc.startRow ||
          (s.startRow == sc.startRow && s.startCol >= sc.startCol);
      final beforeEnd = s.endRow < sc.endRow ||
          (s.endRow == sc.endRow && s.endCol <= sc.endCol);
      return afterStart && beforeEnd;
    }).toList();
  }

  bool get canStepForward =>
      _loaded.isNotEmpty &&
      (wrapAround || _currentIndex < _loaded.length - 1 || _loadedTo < _lineCount);

  bool get canStepBackward =>
      _loaded.isNotEmpty && (wrapAround || _currentIndex > 0 || _loadedFrom > 0);

  Future<void> stepForward() async {
    if (_loaded.isEmpty) return;
    if (_currentIndex < _loaded.length - 1) {
      _currentIndex++;
      notifyListeners();
      _maybePrefetch();
      return;
    }
    if (_loadedTo < _lineCount) {
      await _loadForward(_generation);
      if (_currentIndex < _loaded.length - 1) {
        _currentIndex++;
        notifyListeners();
        return;
      }
    }
    if (wrapAround) {
      _currentIndex = 0;
      notifyListeners();
    }
  }

  Future<void> stepBackward() async {
    if (_loaded.isEmpty) return;
    if (_currentIndex > 0) {
      _currentIndex--;
      notifyListeners();
      _maybePrefetch();
      return;
    }
    if (_loadedFrom > 0) {
      await _loadBackward(_generation);
      if (_currentIndex > 0) {
        _currentIndex--;
        notifyListeners();
        return;
      }
    }
    if (wrapAround) {
      // Wrapping to the end needs every match loaded.
      while (_loadedTo < _lineCount) {
        await _loadForwardOneWindow(_generation);
      }
      _currentIndex = _loaded.length - 1;
      notifyListeners();
    }
  }

  Future<void> _loadForwardOneWindow(int gen) async {
    final from = _loadedTo;
    final to = (from + kSearchWindowRows).clamp(0, _lineCount);
    final found = await _session!.findInRows(
      query: _buildQuery(),
      fromRow: BigInt.from(from),
      toRow: BigInt.from(to),
    );
    if (gen != _generation) return;
    _loadedTo = to;
    _loaded.addAll(_inScope(found));
  }

  /// Load the adjacent window in the background when the cursor nears an edge,
  /// so the next arrow press never waits on a scan.
  void _maybePrefetch() {
    final gen = _generation;
    if (_loaded.length - _currentIndex <= kPrefetchMargin &&
        _loadedTo < _lineCount) {
      unawaited(_loadForwardOneWindow(gen).then((_) {
        if (gen == _generation) notifyListeners();
      }));
    } else if (_currentIndex <= kPrefetchMargin && _loadedFrom > 0) {
      unawaited(_loadBackward(gen).then((_) {
        if (gen == _generation) notifyListeners();
      }));
    }
  }

  /// Count every match in the background so the counter can resolve from
  /// "1 of 3+" to "1 of 3".
  Future<void> _startSweep(int gen) async {
    if (_session == null) return;
    _sweepRunning = true;
    notifyListeners();
    _sweep = () async {
      final total = await _session!.countMatches(
        query: _buildQuery(),
        scope: _activeScope,
      );
      if (gen != _generation) return;
      _exactTotal = total.toInt();
      _sweepRunning = false;
      notifyListeners();
    }();
    await _sweep;
  }

  /// Test hook: wait for the in-flight sweep to finish.
  Future<void> awaitSweep() async => _sweep == null ? null : await _sweep;

  /// The Count button: resolve the exact total now. Reuses the in-flight
  /// sweep when there is one rather than scanning the document twice.
  Future<int?> recount() async {
    if (_sweepRunning) {
      await awaitSweep();
    } else {
      await _startSweep(_generation);
    }
    return _exactTotal;
  }

  String get counterLabel {
    if (_regexError != null) return 'Invalid pattern';
    if (query.text.isEmpty) return '';
    if (_loaded.isEmpty) return 'No results';
    final position = _currentIndex + 1;
    if (_exactTotal != null) return '$position of $_exactTotal';
    final soFar = _loaded.length;
    return _loadedTo >= _lineCount
        ? '$position of $soFar'
        : '$position of $soFar+';
  }

  /// Replace the current match and advance. Returns the number replaced (0 or 1).
  Future<int> replaceCurrent() async {
    final span = currentMatch;
    if (span == null || _session == null) return 0;
    final caret = await _session!.replaceSpan(
      query: _buildQuery(),
      span: span,
      replacement: replacement.text,
    );
    _lineCount = _session!.lineCount().toInt();
    // Anchor past the text just written, so the next match is the one after
    // it rather than an earlier one that is still in the document.
    await refresh(anchorRow: caret.row.toInt(), anchorCol: caret.col.toInt());
    return 1;
  }

  /// Replace every match (within scope when In selection is on) as one undo
  /// step. Returns the number replaced.
  Future<int> replaceAll() async {
    if (_session == null) return 0;
    final n = await _session!.replaceAllInRows(
      query: _buildQuery(),
      replacement: replacement.text,
      scope: _activeScope,
    );
    _lineCount = _session!.lineCount().toInt();
    await refresh();
    return n.toInt();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    replacement.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/find_controller_test.dart`
Expected: PASS, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/find_state.dart test/find_controller_test.dart
git commit -m "feat(search): add FindController paging state machine"
```

---

### Task 6: Match highlighting in the editor

Viewport-scoped highlighting: the painter draws whatever spans it is handed, and the host hands it only the visible rows' matches. This keeps highlighting constant-cost regardless of document size, and is independent of the stepping cursor.

**Files:**
- Modify: `lib/editor.dart` (`EditorPainter` fields/constructor/paint at ~1374–1420; `CustomEditorState`)

**Interfaces:**
- Consumes: `MatchSpan` from `lib/src/rust/api/search.dart`.
- Produces:
  - `EditorPainter({..., List<MatchSpan> matches = const [], MatchSpan? currentMatch, Color matchColor, Color currentMatchColor})`
  - `CustomEditorState.revealSpan(MatchSpan span)` — selects the span and scrolls it into view
  - `CustomEditorState.visibleRowRange` → `(int firstRow, int lastRow)`
  - `CustomEditor.matches` / `CustomEditor.currentMatch` widget parameters

- [ ] **Step 1: Add the painter fields**

In `lib/editor.dart`, add to `EditorPainter`'s field list (after `gutterFg`):

```dart
  /// Matches visible in the current viewport. Painted beneath the text.
  final List<MatchSpan> matches;

  /// The match the find panel is currently on, accented above the rest.
  final MatchSpan? currentMatch;

  final Color matchColor;
  final Color currentMatchColor;
```

And to the constructor's parameter list (after `this.gutterFg = ...`):

```dart
    this.matches = const [],
    this.currentMatch,
    this.matchColor = const Color(0x40FFD54F),
    this.currentMatchColor = const Color(0x80FF9800),
```

Add the import at the top of `lib/editor.dart`:

```dart
import 'src/rust/api/search.dart';
```

- [ ] **Step 2: Paint the matches**

In `EditorPainter.paint`, immediately **before** the existing selection drawing (the block commented "Draw selection first so text renders on top"), insert:

```dart
    // Match highlights sit under the selection and the text.
    void paintSpan(MatchSpan span, Color color) {
      final paint = Paint()..color = color;
      final startRow = span.startRow.toInt();
      final endRow = span.endRow.toInt();
      for (int r = startRow; r <= endRow; r++) {
        if (r < firstVisibleRow || r > firstVisibleRow + (size.height / rowHeight).ceil()) {
          continue;
        }
        final line = getLineText(r);
        final from = (r == startRow) ? span.startCol.toInt() : 0;
        final to = (r == endRow) ? span.endCol.toInt() : line.length;
        final y = (r * rowHeight) - scrollY;
        canvas.drawRect(
          Rect.fromLTWH(from * charWidth, y, (to - from) * charWidth, rowHeight),
          paint,
        );
      }
    }

    for (final m in matches) {
      paintSpan(m, matchColor);
    }
    if (currentMatch != null) {
      paintSpan(currentMatch!, currentMatchColor);
    }
```

Note: `firstVisibleRow` is already computed just above this point in `paint`.

- [ ] **Step 3: Add `shouldRepaint` coverage**

Find `EditorPainter.shouldRepaint` and add these clauses to the returned condition so highlight changes actually repaint:

```dart
        || oldDelegate.matches != matches
        || oldDelegate.currentMatch != currentMatch
```

- [ ] **Step 4: Expose the visible row range and `revealSpan`**

Add to `CustomEditorState` (near `_visualLineCount`):

```dart
  /// First and last row currently on screen, for viewport-scoped search
  /// highlighting. Clamped to the document.
  (int, int) get visibleRowRange {
    if (!_vScroll.hasClients) return (0, 0);
    final first = (_vScroll.offset / _rowHeight).floor();
    final visible = (_vScroll.position.viewportDimension / _rowHeight).ceil();
    final last = (first + visible).clamp(0, _visualLineCount);
    return (first.clamp(0, _visualLineCount), last);
  }

  /// Select [span] and scroll it into view. Used by the find panel when the
  /// current match changes.
  void revealSpan(MatchSpan span) {
    setState(() {
      _selStartRow = span.startRow.toInt();
      _selStartCol = span.startCol.toInt();
      _isBlockSelection = false;
      _cursorRow = span.endRow.toInt();
      _cursorCol = span.endCol.toInt();
    });
    _scrollToCursor();
  }

  /// Return keyboard focus to the document. Used when the find panel closes.
  void focusEditor() => _focusNode.requestFocus();

  /// The current linear selection as a search scope, or null when there is
  /// none. Backs the panel's "In selection" option.
  SpanScope? get selectionScope {
    if (!hasLinearSelection) return null;
    var sr = _selStartRow!;
    var sc = _selStartCol!;
    var er = _cursorRow;
    var ec = _cursorCol;
    if (sr > er || (sr == er && sc > ec)) {
      final tr = sr, tc = sc;
      sr = er;
      sc = ec;
      er = tr;
      ec = tc;
    }
    return SpanScope(
      startRow: BigInt.from(sr),
      startCol: BigInt.from(sc),
      endRow: BigInt.from(er),
      endCol: BigInt.from(ec),
    );
  }
```

- [ ] **Step 5: Thread the parameters through `CustomEditor`**

Add to the `CustomEditor` widget's fields and constructor:

```dart
  /// Matches to highlight, and which of them is current. Supplied by the host
  /// from the find panel; already scoped to the visible rows.
  final List<MatchSpan> matches;
  final MatchSpan? currentMatch;
```

with `this.matches = const []`, `this.currentMatch` in the constructor, and pass them into the `EditorPainter(...)` construction inside `build`:

```dart
                  matches: widget.matches,
                  currentMatch: widget.currentMatch,
```

- [ ] **Step 6: Verify it compiles and nothing regressed**

Run: `flutter analyze && flutter test`
Expected: no analyzer errors; all existing tests still pass (including `editor_content_width_test.dart`).

- [ ] **Step 7: Commit**

```bash
git add lib/editor.dart
git commit -m "feat(search): paint match highlights and add revealSpan"
```

---

### Task 7: The panel widget and its wiring

The panel docks **between the tab bar and the editor and pushes the editor down** — never an overlay, so it cannot cover the text being stepped through. Find mode only in this task; replace mode lands in Task 8.

**Files:**
- Create: `lib/find_panel.dart`
- Modify: `lib/main.dart`
- Modify: `lib/menu_ribbon.dart`
- Modify: `lib/editor.dart` (`_bubbleShortcutKeys` at ~line 67)

**Interfaces:**
- Consumes: `FindController` (Task 5), `CustomEditorState.revealSpan` / `visibleRowRange` (Task 6).
- Produces:
  - `class FindPanel extends StatefulWidget` taking `FindController controller`, `VoidCallback onClose`, `ValueChanged<MatchSpan> onReveal`
  - `MenuRibbon` gains `VoidCallback? onFind` and `VoidCallback? onReplace` parameters

- [ ] **Step 1: Create the panel widget**

Create `lib/find_panel.dart`:

```dart
import 'package:flutter/material.dart';

import 'find_state.dart';
import 'src/rust/api/search.dart';

/// The persistent find/replace panel. Docked above the editor rather than
/// floating over it, so the document stays fully visible while stepping.
class FindPanel extends StatefulWidget {
  final FindController controller;
  final VoidCallback onClose;

  /// Called whenever the current match changes, so the host can scroll to it.
  final ValueChanged<MatchSpan> onReveal;

  const FindPanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onReveal,
  });

  @override
  State<FindPanel> createState() => _FindPanelState();
}

class _FindPanelState extends State<FindPanel> {
  final FocusNode _queryFocus = FocusNode();

  FindController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _queryFocus.requestFocus());
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    _queryFocus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    final m = c.currentMatch;
    if (m != null) widget.onReveal(m);
  }

  Future<void> _next() async => c.stepForward();
  Future<void> _prev() async => c.stepBackward();

  /// A compact inline option toggle. Every one carries a tooltip naming the
  /// option and its Notepad++ equivalent.
  Widget _toggle({
    required String label,
    required String tooltip,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: value ? scheme.primary.withValues(alpha: 0.20) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: enabled
                  ? (value ? scheme.primary : scheme.onSurfaceVariant)
                  : scheme.outline,
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchModeSelector() {
    return Tooltip(
      message: 'Search mode',
      child: DropdownButton<SearchMode>(
        value: c.searchMode,
        isDense: true,
        underline: const SizedBox.shrink(),
        style: const TextStyle(fontSize: 12),
        items: const [
          DropdownMenuItem(value: SearchMode.normal, child: Text('Normal')),
          DropdownMenuItem(value: SearchMode.extended, child: Text('Extended')),
          DropdownMenuItem(value: SearchMode.regex, child: Text('Regex')),
        ],
        onChanged: (m) {
          if (m == null) return;
          setState(() => c.searchMode = m);
          c.scheduleRefresh();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasError = c.regexError != null;

    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16),
          const SizedBox(width: 6),
          SizedBox(
            width: 260,
            child: Tooltip(
              message: c.regexError ?? 'Find what',
              child: TextField(
                controller: c.query,
                focusNode: _queryFocus,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Find what…',
                  border: const OutlineInputBorder(),
                  enabledBorder: hasError
                      ? OutlineInputBorder(
                          borderSide: BorderSide(color: scheme.error))
                      : null,
                ),
                onChanged: (_) => c.scheduleRefresh(),
                onSubmitted: (_) => _next(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _toggle(
            label: 'Aa',
            tooltip: 'Match case',
            value: c.matchCase,
            onChanged: (v) {
              setState(() => c.matchCase = v);
              c.scheduleRefresh();
            },
          ),
          _toggle(
            label: 'ab|',
            tooltip: 'Match whole word only',
            value: c.wholeWord,
            onChanged: (v) {
              setState(() => c.wholeWord = v);
              c.scheduleRefresh();
            },
          ),
          _toggle(
            label: '↺',
            tooltip: 'Wrap around',
            value: c.wrapAround,
            onChanged: (v) => setState(() => c.wrapAround = v),
          ),
          _toggle(
            label: '⌗',
            tooltip: 'In selection',
            value: c.inSelection,
            enabled: c.scope != null,
            onChanged: (v) {
              setState(() => c.inSelection = v);
              c.scheduleRefresh();
            },
          ),
          _toggle(
            label: '. *',
            tooltip: '. matches newline (regex mode only)',
            value: c.dotMatchesNewline,
            enabled: c.searchMode == SearchMode.regex,
            onChanged: (v) {
              setState(() => c.dotMatchesNewline = v);
              c.scheduleRefresh();
            },
          ),
          const SizedBox(width: 6),
          _searchModeSelector(),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            tooltip: 'Previous match (Shift+F3)',
            onPressed: c.canStepBackward ? _prev : null,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            tooltip: 'Next match (F3)',
            onPressed: c.canStepForward ? _next : null,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          Text(
            c.counterLabel,
            style: TextStyle(
              fontSize: 12,
              color: hasError ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Count all matches',
            child: TextButton(
              onPressed: c.query.text.isEmpty || hasError ? null : c.recount,
              child: const Text('Count'),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close (Esc)',
            onPressed: widget.onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Let Ctrl+F and Ctrl+H bubble out of the editor**

In `lib/editor.dart`, add to `_bubbleShortcutKeys` (~line 67):

```dart
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyH,
```

- [ ] **Step 3: Host the controller and panel in `main.dart`**

Add the imports:

```dart
import 'find_panel.dart';
import 'find_state.dart';
```

Add fields to the app state (near `_isRibbonVisible`):

```dart
  final FindController _findController = FindController();
  bool _isFindVisible = false;
```

Add the open/close helpers:

```dart
  /// Show the find panel in [mode], pointed at the active tab's document.
  void _openFind(FindPanelMode mode) {
    final tab = _activeTab;
    if (tab == null || tab.mode != ViewMode.edit) return;
    _findController.attach(tab.session, tab.session.lineCount().toInt());
    _findController.setMode(mode);
    setState(() => _isFindVisible = true);
  }

  void _closeFind() {
    setState(() => _isFindVisible = false);
    _activeEditor?.focusEditor();
  }

  /// Re-point the panel at the newly active tab. Loaded matches are dropped
  /// and rescanned; the query text and option toggles persist across tabs,
  /// matching Notepad++.
  void _retargetFind() {
    if (!_isFindVisible) return;
    final tab = _activeTab;
    if (tab == null || tab.mode != ViewMode.edit) {
      _findController.attach(null, 0);
      return;
    }
    _findController.scope = _activeEditor?.selectionScope;
    _findController.attach(tab.session, tab.session.lineCount().toInt());
    _findController.refresh();
  }
```

Call `_retargetFind()` from wherever the app switches the active tab — the same place `_activeTabIndex` is assigned — after the `setState` that commits the switch.

`focusEditor()` and `selectionScope` were both added to `CustomEditorState` in Task 6.

- [ ] **Step 4: Insert the panel into the layout**

In `main.dart`'s build, immediately **before** the `else if (_activeTab != null && _activeTab!.mode == ViewMode.edit)` branch that wraps `CustomEditor` in `Expanded` (~line 1090), the surrounding `Column` must gain the panel as a sibling above it:

```dart
                    if (_isFindVisible && _activeTab?.mode == ViewMode.edit)
                      FindPanel(
                        controller: _findController,
                        onClose: _closeFind,
                        onReveal: (span) => _activeEditor?.revealSpan(span),
                      ),
```

Then pass the highlight spans into `CustomEditor`:

```dart
                          matches: _isFindVisible ? _findController.loaded : const [],
                          currentMatch:
                              _isFindVisible ? _findController.currentMatch : null,
```

- [ ] **Step 5: Wire the keyboard shortcuts**

In `main.dart`'s key handler (the `switch (event.logicalKey)` at ~line 745, inside the `isControlPressed` guard), add:

```dart
      case LogicalKeyboardKey.keyF:
        _openFind(FindPanelMode.find);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyH:
        _openFind(FindPanelMode.replace);
        return KeyEventResult.handled;
```

And **above** the `isControlPressed` guard (so they work unmodified), add:

```dart
    if (event.logicalKey == LogicalKeyboardKey.escape && _isFindVisible) {
      _closeFind();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.f3 && _isFindVisible) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _findController.stepBackward();
      } else {
        _findController.stepForward();
      }
      return KeyEventResult.handled;
    }
```

- [ ] **Step 6: Wire the menu entries**

In `lib/menu_ribbon.dart`, add the two widget parameters alongside the existing callbacks:

```dart
  final VoidCallback? onFind;
  final VoidCallback? onReplace;
```

(with `this.onFind,` and `this.onReplace,` in the constructor), and add the cases to `_getAction` (~line 283):

```dart
      case 'search.find': return widget.onFind;
      case 'search.replace': return widget.onReplace;
```

Then in `main.dart`'s `MenuRibbon(...)` construction, pass:

```dart
                      onFind: _activeTab?.mode == ViewMode.edit
                          ? () {
                              setState(() => _isRibbonVisible = false);
                              _openFind(FindPanelMode.find);
                            }
                          : null,
                      onReplace: _activeTab?.mode == ViewMode.edit
                          ? () {
                              setState(() => _isRibbonVisible = false);
                              _openFind(FindPanelMode.replace);
                            }
                          : null,
```

- [ ] **Step 7: Verify**

Run: `flutter analyze && flutter test`
Expected: no analyzer errors; all tests pass.

Then run the app and confirm by hand: Ctrl+F opens the panel above the editor without covering text; typing highlights matches; ▼/▲ step and scroll; the counter reads "n of m"; Esc closes and returns focus to the document; Search ▸ Find in the menu opens the same panel.

- [ ] **Step 8: Commit**

```bash
git add lib/find_panel.dart lib/main.dart lib/menu_ribbon.dart lib/editor.dart
git commit -m "feat(search): add persistent find panel with stepping and shortcuts"
```

---

### Task 8: Replace mode

Adds the second row to the panel and the three replace actions. Switching find→replace preserves the query text automatically, because `FindController` owns one `TextEditingController` that both modes render.

**Files:**
- Modify: `lib/find_panel.dart`
- Modify: `test/find_controller_test.dart`

**Interfaces:**
- Consumes: `FindController.replaceCurrent`, `FindController.replaceAll`, `FindController.mode`, `FindController.setMode` (Task 5).
- Produces: no new public API — the panel gains a second row and a mode toggle.

- [ ] **Step 1: Write the failing test**

Add to `test/find_controller_test.dart`:

```dart
  test('replaceAll honours the in-selection scope', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    c.scope = SpanScope(
      startRow: BigInt.one,
      startCol: BigInt.zero,
      endRow: BigInt.two,
      endCol: BigInt.from(3),
    );
    c.inSelection = true;
    await c.refresh();
    c.replacement.text = 'X';
    final n = await c.replaceAll();
    expect(n, 2);
    expect(c.session!.line(vrow: BigInt.zero), 'hit',
        reason: 'outside the selection must be untouched');
  });

  test('replaceCurrent advances so repeated calls walk the document', () async {
    final c = await controllerOver('hit hit\n', 'hit');
    c.replacement.text = 'X';
    await c.replaceCurrent();
    await c.replaceCurrent();
    expect(c.session!.line(vrow: BigInt.zero), 'X X');
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/find_controller_test.dart`
Expected: FAIL — the in-selection test replaces 3 instead of 2, or `SpanScope` is unbound.

If `SpanScope` is unbound, add `import 'package:textutilz/src/rust/api/search.dart';` — it should already be there from Task 5.

- [ ] **Step 3: Make the tests pass**

Both exercise code written in Task 5, so they should pass once that task is complete. If either fails, the cause is one of exactly two things:

- **Scope test replaces 3 instead of 2** — `replaceAll` is passing `null` rather than `_activeScope` to `replaceAllInRows`. Fix in `lib/find_state.dart`:

```dart
    final n = await _session!.replaceAllInRows(
      query: _buildQuery(),
      replacement: replacement.text,
      scope: _activeScope,   // not null
    );
```

- **Repeated `replaceCurrent` produces `X hit` instead of `X X`** — the post-replace `refresh` is not anchored, so it snaps back to the first match. Fix in `lib/find_state.dart`:

```dart
    await refresh(anchorRow: caret.row.toInt(), anchorCol: caret.col.toInt());
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/find_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Add the replace row to the panel**

In `lib/find_panel.dart`, wrap the existing `Row` in a `Column` and add the second row. Replace the `child: Row(` in `build` with:

```dart
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // ... the entire existing find row, unchanged ...
            ],
          ),
          if (c.mode == FindPanelMode.replace) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 22),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: c.replacement,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Replace with…',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _replaceCurrent(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: c.currentMatch != null ? _replaceCurrent : null,
                  child: const Text('Replace'),
                ),
                TextButton(
                  onPressed: c.loaded.isNotEmpty ? _replaceAll : null,
                  child: Text(c.inSelection ? 'Replace All in selection' : 'Replace All'),
                ),
              ],
            ),
          ],
        ],
      ),
```

Add the two handlers to `_FindPanelState`:

```dart
  Future<void> _replaceCurrent() async => c.replaceCurrent();

  Future<void> _replaceAll() async {
    final n = await c.replaceAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(n == 1 ? '1 replacement' : '$n replacements')),
    );
  }
```

- [ ] **Step 6: Add the mode toggle to the find row**

Insert into the find row, immediately after the leading `Icon(Icons.search)`:

```dart
          Tooltip(
            message: c.mode == FindPanelMode.find
                ? 'Switch to Replace'
                : 'Switch to Find',
            child: IconButton(
              icon: Icon(
                c.mode == FindPanelMode.find
                    ? Icons.keyboard_arrow_right
                    : Icons.keyboard_arrow_down,
                size: 16,
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () => c.setMode(
                c.mode == FindPanelMode.find
                    ? FindPanelMode.replace
                    : FindPanelMode.find,
              ),
            ),
          ),
```

- [ ] **Step 7: Keep the scope in sync with the editor selection**

In `main.dart`'s `_openFind`, before `setState`, populate the scope from the editor's selection so the In-selection toggle can enable:

```dart
    _findController.scope = _activeEditor?.selectionScope;
```

`selectionScope` was added to `CustomEditorState` in Task 6 — no editor change is needed here, only this one line in `_openFind`.

- [ ] **Step 8: Verify**

Run: `flutter analyze && flutter test`
Expected: no analyzer errors; all tests pass.

Then confirm by hand: with the find panel open and text typed, choosing Search ▸ Replace from the menu keeps the typed query and adds the Replace row; Replace swaps one match and moves to the next; Replace All reports its count; a single Ctrl+Z reverts an entire Replace All.

- [ ] **Step 9: Commit**

```bash
git add lib/find_panel.dart lib/editor.dart lib/main.dart test/find_controller_test.dart
git commit -m "feat(search): add replace mode to the find panel"
```

---

## Verification checklist

After Task 8, all of these must hold:

- [ ] `cd rust && cargo test` — all Rust tests pass
- [ ] `flutter analyze` — no errors
- [ ] `flutter test` — all Dart tests pass, including the pre-existing suites
- [ ] Ctrl+F opens the panel above the editor; the document is never occluded
- [ ] Typing highlights every visible match, with the current one accented
- [ ] ▲/▼ step through matches and scroll them into view
- [ ] The counter resolves from "1 of 20+" to "1 of 20"; the Count button forces it
- [ ] Editing the document mid-search keeps the current match at or after the caret, never jumping backwards
- [ ] Switching tabs rescans the new document while keeping the typed query and toggles
- [ ] An invalid regex shows an error border and message, and fires no scan
- [ ] Choosing Replace from the menu while Find is open preserves the typed query
- [ ] One Ctrl+Z reverts an entire Replace All
- [ ] Esc closes the panel and returns focus to the document

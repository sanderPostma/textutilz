//! The lexer interface every format implements, plus the drivers that turn it
//! into painting tokens and into a whole-document lexeme stream.
//!
//! A lexer is a row-driven state machine: given a row and the [`LexState`] left
//! over from the previous row, it emits that row's lexemes and returns the
//! state for the next row. That single shape serves both callers — the painter,
//! which lexes only the viewport starting from a stored checkpoint, and the
//! analysis pass, which walks every row once to build folds, brackets and
//! diagnostics.

use super::token::{
    LexState, MarkupTokenKind, RowTokenSink, RowTokens, Utf16Cols, CHECKPOINT_ROWS,
};

/// One lexeme, positioned by row and by **byte** offset within that row.
///
/// Byte offsets, not UTF-16 columns: this stream is consumed by validators and
/// formatters that slice the row text directly. Conversion to columns happens
/// only where a position crosses into Dart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Lexeme {
    pub row: u32,
    pub start: u32,
    pub end: u32,
    pub kind: MarkupTokenKind,
}

impl Lexeme {
    /// The lexeme's source text, given the row it came from.
    pub fn text<'a>(&self, row: &'a str) -> &'a str {
        let start = (self.start as usize).min(row.len());
        let end = (self.end as usize).clamp(start, row.len());
        &row[start..end]
    }
}

/// Collects one row's lexemes during lexing.
#[derive(Default)]
pub struct RowLexemes {
    items: Vec<(u32, u32, MarkupTokenKind)>,
}

impl RowLexemes {
    pub fn new() -> RowLexemes {
        RowLexemes::default()
    }

    /// Record a lexeme spanning `[start, end)` bytes of the current row.
    /// Empty spans are dropped, so lexers may emit them freely.
    pub fn push(&mut self, start: usize, end: usize, kind: MarkupTokenKind) {
        if end > start {
            self.items.push((start as u32, end as u32, kind));
        }
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &(u32, u32, MarkupTokenKind)> {
        self.items.iter()
    }
}

/// A row-driven markup lexer.
pub trait MarkupLexer {
    /// Lex one row, appending its lexemes to `out`, and return the state the
    /// next row starts in.
    ///
    /// `row` never contains a line terminator. Implementations must be pure:
    /// the same `(row, state)` must always give the same lexemes and the same
    /// returned state, or checkpoint resume would disagree with a full pass.
    fn lex_row(&self, row: &str, state: LexState, out: &mut RowLexemes) -> LexState;
}

/// Lex `rows` for painting, starting from `start_state`.
///
/// `first_row` is the document row number of `rows[0]`, so the returned
/// [`RowTokens`] carry absolute row numbers the editor can use directly.
pub fn tokenize_rows(
    lexer: &dyn MarkupLexer,
    rows: &[String],
    start_state: LexState,
    first_row: u32,
) -> Vec<RowTokens> {
    let mut state = start_state;
    let mut scratch = RowLexemes::new();
    let mut out = Vec::with_capacity(rows.len());
    for (i, row) in rows.iter().enumerate() {
        scratch.clear();
        state = lexer.lex_row(row, state, &mut scratch);
        let cols = Utf16Cols::new(row);
        let mut sink = RowTokenSink::new(&cols);
        for &(start, end, kind) in scratch.iter() {
            sink.push(start as usize, end as usize, kind);
        }
        out.push(RowTokens {
            row: first_row + i as u32,
            tokens: sink.finish(),
        });
    }
    out
}

/// The result of walking every row once.
pub struct DocumentLex {
    /// Every lexeme in the document, in row-then-position order.
    pub lexemes: Vec<Lexeme>,
    /// Resume states, one per [`CHECKPOINT_ROWS`] rows. `checkpoints[0]` is
    /// always the state at row 0.
    pub checkpoints: Vec<LexState>,
    /// The state after the final row. A document that ends mid-string or
    /// mid-comment leaves this unclean.
    pub end_state: LexState,
}

/// Walk every row once, collecting the full lexeme stream and the resume
/// checkpoints. This is the input to folding, bracket matching, validation and
/// formatting.
pub fn lex_document(lexer: &dyn MarkupLexer, rows: &[String]) -> DocumentLex {
    let mut state = LexState::top();
    let mut scratch = RowLexemes::new();
    let mut lexemes = Vec::new();
    let mut checkpoints = Vec::with_capacity(rows.len() / CHECKPOINT_ROWS + 1);
    for (i, row) in rows.iter().enumerate() {
        if i % CHECKPOINT_ROWS == 0 {
            checkpoints.push(state);
        }
        scratch.clear();
        state = lexer.lex_row(row, state, &mut scratch);
        for &(start, end, kind) in scratch.iter() {
            lexemes.push(Lexeme {
                row: i as u32,
                start,
                end,
                kind,
            });
        }
    }
    if checkpoints.is_empty() {
        checkpoints.push(state);
    }
    DocumentLex {
        lexemes,
        checkpoints,
        end_state: state,
    }
}

/// The checkpoint to resume from when the caller wants tokens starting at
/// `row`, and the row that checkpoint sits on.
///
/// The caller re-lexes from `resume_row` up to `row` to warm the state, which
/// is at most [`CHECKPOINT_ROWS`] rows of work.
pub fn resume_point(checkpoints: &[LexState], row: u32) -> (u32, LexState) {
    if checkpoints.is_empty() {
        return (0, LexState::top());
    }
    let index = (row as usize / CHECKPOINT_ROWS).min(checkpoints.len() - 1);
    ((index * CHECKPOINT_ROWS) as u32, checkpoints[index])
}

/// Split text into rows the way the rest of the app does, tolerating CRLF and
/// bare CR. The terminator itself is never part of a row.
pub fn split_rows(text: &str) -> Vec<String> {
    let mut rows = Vec::new();
    let mut current = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\n' => {
                rows.push(std::mem::take(&mut current));
            }
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                rows.push(std::mem::take(&mut current));
            }
            _ => current.push(ch),
        }
    }
    rows.push(current);
    rows
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A toy lexer: every `"` toggles string mode, and whatever is inside is a
    /// string lexeme. Enough to exercise the drivers' cross-row state handling
    /// without depending on a real format.
    pub struct ToyLexer;

    impl MarkupLexer for ToyLexer {
        fn lex_row(&self, row: &str, state: LexState, out: &mut RowLexemes) -> LexState {
            let mut state = state;
            let bytes = row.as_bytes();
            let mut i = 0;
            let mut run_start = if state.mode == 1 { Some(0) } else { None };
            while i < bytes.len() {
                if bytes[i] == b'"' {
                    match run_start.take() {
                        Some(start) => {
                            out.push(start, i + 1, MarkupTokenKind::Str);
                            state.mode = 0;
                        }
                        None => {
                            run_start = Some(i);
                            state.mode = 1;
                        }
                    }
                }
                i += 1;
            }
            if let Some(start) = run_start {
                out.push(start, bytes.len(), MarkupTokenKind::Str);
            }
            state
        }
    }

    #[test]
    fn split_rows_handles_all_three_line_endings() {
        assert_eq!(split_rows("a\nb"), vec!["a", "b"]);
        assert_eq!(split_rows("a\r\nb"), vec!["a", "b"]);
        assert_eq!(split_rows("a\rb"), vec!["a", "b"]);
        assert_eq!(split_rows("a\n"), vec!["a", ""]);
        assert_eq!(split_rows(""), vec![""]);
    }

    #[test]
    fn document_lex_carries_state_across_rows() {
        let rows = split_rows("\"open\nstill inside\nclosed\"");
        let doc = lex_document(&ToyLexer, &rows);
        // All three rows are inside the string, so all three yield a lexeme.
        assert_eq!(doc.lexemes.len(), 3);
        assert!(doc.end_state.mode == 0);
    }

    #[test]
    fn checkpoints_are_one_per_checkpoint_rows() {
        let rows: Vec<String> = (0..CHECKPOINT_ROWS * 3 + 1)
            .map(|i| format!("row {i}"))
            .collect();
        let doc = lex_document(&ToyLexer, &rows);
        assert_eq!(doc.checkpoints.len(), 4);
    }

    #[test]
    fn resume_point_picks_the_checkpoint_at_or_before_the_row() {
        let rows: Vec<String> = (0..CHECKPOINT_ROWS * 2).map(|_| "x".to_string()).collect();
        let doc = lex_document(&ToyLexer, &rows);
        assert_eq!(resume_point(&doc.checkpoints, 0).0, 0);
        assert_eq!(
            resume_point(&doc.checkpoints, CHECKPOINT_ROWS as u32 - 1).0,
            0
        );
        assert_eq!(
            resume_point(&doc.checkpoints, CHECKPOINT_ROWS as u32).0,
            CHECKPOINT_ROWS as u32
        );
    }

    /// The property the whole checkpoint scheme rests on: resuming from a
    /// stored state must produce exactly what a full pass would.
    #[test]
    fn resuming_from_a_checkpoint_matches_a_full_pass() {
        let mut text = String::new();
        for i in 0..CHECKPOINT_ROWS * 2 + 30 {
            // Sprinkle in strings that stay open across a row boundary.
            if i % 7 == 0 {
                text.push_str("\"open\n");
            } else {
                text.push_str("plain \"closed\" text\n");
            }
        }
        let rows = split_rows(&text);
        let doc = lex_document(&ToyLexer, &rows);

        let target = CHECKPOINT_ROWS as u32 + 17;
        let (resume_row, state) = resume_point(&doc.checkpoints, target);

        // Warm up from the checkpoint to the target row.
        let mut warm = state;
        let mut scratch = RowLexemes::new();
        for row in &rows[resume_row as usize..target as usize] {
            scratch.clear();
            warm = ToyLexer.lex_row(row, warm, &mut scratch);
        }

        let partial = tokenize_rows(&ToyLexer, &rows[target as usize..], warm, target);
        let full = tokenize_rows(&ToyLexer, &rows, LexState::top(), 0);
        assert_eq!(partial, full[target as usize..].to_vec());
    }
}

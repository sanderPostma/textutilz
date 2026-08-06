//! The vocabulary shared by every markup lexer.
//!
//! One lexer pass over a document produces all four outputs below — tokens for
//! colouring, fold regions for collapse, bracket pairs for match highlighting,
//! and diagnostics for validation — so the four can never disagree about what
//! the document contains.
//!
//! All columns are UTF-16 code units, matching `search::MatchSpan` and Dart's
//! native string indices. Lexers work in bytes internally and convert on the
//! way out; see [`Utf16Cols`].

/// What a run of characters means. The Dart side maps these to colours; that
/// mapping is the only part of styling that stays in the UI layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkupTokenKind {
    /// An object key (JSON/JSON5) or a mapping key (YAML).
    Key,
    /// A quoted or otherwise delimited string scalar.
    Str,
    Number,
    /// `true`, `false`, `null`, and the YAML spellings of the same.
    Keyword,
    /// Structural characters: braces, brackets, commas, colons, dashes.
    Punctuation,
    /// An XML element name.
    TagName,
    /// An XML attribute name.
    AttributeName,
    Comment,
    /// XML character data between tags.
    Text,
    /// An XML `<![CDATA[ ]]>` section, including its delimiters.
    CData,
    /// An XML `<!DOCTYPE ...>` declaration.
    Doctype,
    /// An XML `<? ... ?>` processing instruction, including the declaration.
    ProcessingInstruction,
    /// An XML entity reference such as `&amp;`, or a YAML anchor `&name`.
    Entity,
    /// A YAML alias `*name`.
    Alias,
    /// A YAML directive line such as `%YAML 1.2`.
    Directive,
    /// Text the lexer could not make sense of. Always paired with a diagnostic.
    Invalid,
}

/// A token, as a half-open UTF-16 column range within one row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkupToken {
    pub start: u32,
    pub end: u32,
    pub kind: MarkupTokenKind,
}

/// Every token on one row, in ascending `start` order and non-overlapping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowTokens {
    pub row: u32,
    pub tokens: Vec<MarkupToken>,
}

/// What kind of structure a fold region covers. Drives the gutter glyph and
/// the placeholder text shown on a collapsed row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoldKind {
    /// `{ ... }`
    Object,
    /// `[ ... ]`
    Array,
    /// An XML element with children.
    Element,
    /// A YAML block mapping or sequence held together by indentation.
    Block,
    /// A multi-row comment.
    Comment,
}

/// A collapsible span of rows.
///
/// `start_row` is the row carrying the fold marker in the gutter and stays
/// visible when collapsed; `end_row` is the last row hidden by the collapse.
/// A region is only emitted when `end_row > start_row`, so a fold always hides
/// at least one row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoldRegion {
    pub start_row: u32,
    pub end_row: u32,
    /// Column of the opening delimiter, for drawing the gutter guide.
    pub start_col: u32,
    pub kind: FoldKind,
    /// Placeholder shown on the collapsed row, e.g. `{…}` or `<layout …>`.
    pub label: String,
    /// Nesting depth, outermost = 0. Not produced by the lexers — assigned
    /// afterwards by containment (`markup::assign_fold_levels`), so a brace
    /// stack, element nesting and indentation all mean the same thing by it.
    pub level: u32,
}

/// A matched pair of delimiters: braces, brackets, or an XML open/close tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BracketPair {
    pub open_row: u32,
    pub open_col: u32,
    pub open_len: u32,
    pub close_row: u32,
    pub close_col: u32,
    pub close_len: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiagnosticSeverity {
    Error,
    Warning,
}

/// A validation problem, positioned so the UI can reveal it on double-click.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
    pub row: u32,
    pub col: u32,
    pub end_row: u32,
    pub end_col: u32,
    pub severity: DiagnosticSeverity,
    pub message: String,
}

/// How many rows apart the analysis pass stores resume checkpoints.
///
/// Storing a [`LexState`] for every row of a large document would cost more
/// memory than the structure it describes; storing one every `CHECKPOINT_ROWS`
/// costs 1/128th of that, and viewport tokenisation only has to re-lex at most
/// this many rows to reach any starting point. Re-lexing 128 rows is far below
/// a frame budget, so nothing is lost.
pub const CHECKPOINT_ROWS: usize = 128;

/// Everything a lexer needs to resume at a row boundary.
///
/// `Copy` and small on purpose — the analysis pass stores one per checkpoint
/// for the whole document. The fields are deliberately generic; each lexer
/// interprets `mode` and `indent` in its own terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LexState {
    /// Format-specific resume mode. `0` always means "nothing carried over
    /// from the previous row".
    pub mode: u8,
    /// The quote character currently open, or `0` when none is.
    pub quote: u8,
    /// Grammar position inside the innermost container. See the per-lexer
    /// `PENDING_*` constants.
    pub pending: u8,
    /// Structural nesting depth at the start of the row.
    pub depth: u32,
    /// One bit per nesting level, innermost at bit 0: set means "object /
    /// mapping", clear means "array / sequence".
    ///
    /// Below 64 levels this is what lets the JSON family tell an object key
    /// from a string value without lookahead. Deeper than 64 the bits are no
    /// longer tracked and key detection degrades to line-local lookahead,
    /// which is the behaviour the old Dart scanner had everywhere.
    pub stack: u64,
    /// YAML block-scalar indent. Unused by the other lexers.
    pub indent: u32,
}

/// The deepest nesting level [`LexState::stack`] can represent.
pub const MAX_TRACKED_DEPTH: u32 = 64;

impl LexState {
    pub fn top() -> LexState {
        LexState::default()
    }

    /// True when the row starts clean, with no string, comment or block scalar
    /// carried over. Rows in this state are safe fold boundaries.
    pub fn is_clean(&self) -> bool {
        self.mode == 0 && self.quote == 0
    }

    /// True when the innermost container is an object/mapping.
    pub fn in_object(&self) -> bool {
        self.depth > 0 && self.depth <= MAX_TRACKED_DEPTH && (self.stack & 1) != 0
    }

    /// True when the nesting is too deep for [`Self::stack`] to track.
    pub fn stack_overflowed(&self) -> bool {
        self.depth > MAX_TRACKED_DEPTH
    }

    /// Enter a container. `object` selects mapping vs sequence semantics.
    pub fn push_container(&mut self, object: bool) {
        if self.depth < MAX_TRACKED_DEPTH {
            self.stack = (self.stack << 1) | u64::from(object);
        }
        self.depth += 1;
    }

    /// Leave the innermost container. Bottoming out at depth 0 is a no-op, so a
    /// document with unbalanced closers still lexes rather than panicking.
    pub fn pop_container(&mut self) {
        if self.depth == 0 {
            return;
        }
        self.depth -= 1;
        if self.depth < MAX_TRACKED_DEPTH {
            self.stack >>= 1;
        }
    }
}

/// Byte offset → UTF-16 column conversion for one row.
///
/// Lexers scan bytes because that is what `&str` indexing gives them, but every
/// column that crosses into Dart must be a UTF-16 code unit or non-ASCII rows
/// would paint their tokens in the wrong place. Building this once per row and
/// converting at emit time keeps the conversion off the hot scanning path.
pub struct Utf16Cols {
    /// `map[i]` is the UTF-16 column at byte offset `i`; length is `len + 1`.
    /// `None` when the row is pure ASCII, where byte offset == column.
    map: Option<Vec<u32>>,
    len: usize,
}

impl Utf16Cols {
    pub fn new(row: &str) -> Utf16Cols {
        if row.is_ascii() {
            return Utf16Cols {
                map: None,
                len: row.len(),
            };
        }
        let mut map = vec![0u32; row.len() + 1];
        let mut col = 0u32;
        for (byte, ch) in row.char_indices() {
            map[byte] = col;
            col += ch.len_utf16() as u32;
        }
        map[row.len()] = col;
        Utf16Cols {
            map: Some(map),
            len: row.len(),
        }
    }

    /// The UTF-16 column at a byte offset. Offsets past the row end clamp to
    /// the row's total column count.
    pub fn col(&self, byte: usize) -> u32 {
        let byte = byte.min(self.len);
        match &self.map {
            None => byte as u32,
            Some(map) => map[byte],
        }
    }

    /// Total UTF-16 columns in the row.
    pub fn end(&self) -> u32 {
        self.col(self.len)
    }
}

/// Collects tokens for one row, converting byte offsets to UTF-16 columns and
/// dropping empty spans.
pub struct RowTokenSink<'a> {
    cols: &'a Utf16Cols,
    tokens: Vec<MarkupToken>,
}

impl<'a> RowTokenSink<'a> {
    pub fn new(cols: &'a Utf16Cols) -> RowTokenSink<'a> {
        RowTokenSink {
            cols,
            tokens: Vec::new(),
        }
    }

    /// Record a token spanning `[start_byte, end_byte)`.
    pub fn push(&mut self, start_byte: usize, end_byte: usize, kind: MarkupTokenKind) {
        if end_byte <= start_byte {
            return;
        }
        let start = self.cols.col(start_byte);
        let end = self.cols.col(end_byte);
        if end > start {
            self.tokens.push(MarkupToken { start, end, kind });
        }
    }

    pub fn finish(self) -> Vec<MarkupToken> {
        self.tokens
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_rows_skip_the_mapping_table() {
        let cols = Utf16Cols::new("abc");
        assert!(cols.map.is_none());
        assert_eq!(cols.col(2), 2);
        assert_eq!(cols.end(), 3);
    }

    #[test]
    fn multibyte_chars_map_bytes_to_utf16_columns() {
        // "é" is 2 bytes / 1 unit; "𝄞" is 4 bytes / 2 units (a surrogate pair).
        let row = "é𝄞x";
        let cols = Utf16Cols::new(row);
        assert_eq!(cols.col(0), 0);
        assert_eq!(cols.col(2), 1);
        assert_eq!(cols.col(6), 3);
        assert_eq!(cols.end(), 4);
    }

    #[test]
    fn offsets_past_the_row_end_clamp() {
        let cols = Utf16Cols::new("ab");
        assert_eq!(cols.col(99), 2);
    }

    #[test]
    fn sink_drops_empty_spans_and_converts_columns() {
        let cols = Utf16Cols::new("é{}");
        let mut sink = RowTokenSink::new(&cols);
        sink.push(2, 2, MarkupTokenKind::Punctuation); // empty, dropped
        sink.push(2, 3, MarkupTokenKind::Punctuation);
        let tokens = sink.finish();
        assert_eq!(
            tokens,
            vec![MarkupToken {
                start: 1,
                end: 2,
                kind: MarkupTokenKind::Punctuation
            }]
        );
    }

    #[test]
    fn top_state_is_clean() {
        assert!(LexState::top().is_clean());
        assert!(!LexState {
            quote: b'"',
            ..LexState::top()
        }
        .is_clean());
    }

    #[test]
    fn container_stack_tracks_object_vs_array() {
        let mut s = LexState::top();
        assert!(!s.in_object());
        s.push_container(true);
        assert!(s.in_object());
        s.push_container(false);
        assert!(!s.in_object());
        s.pop_container();
        assert!(s.in_object());
        s.pop_container();
        assert_eq!(s.depth, 0);
    }

    #[test]
    fn popping_past_the_bottom_is_a_no_op() {
        let mut s = LexState::top();
        s.pop_container();
        assert_eq!(s.depth, 0);
    }

    #[test]
    fn depth_beyond_the_tracked_limit_reports_overflow() {
        let mut s = LexState::top();
        for _ in 0..MAX_TRACKED_DEPTH + 5 {
            s.push_container(true);
        }
        assert!(s.stack_overflowed());
        // Unwinding restores an exactly-tracked state rather than corrupting it.
        for _ in 0..5 {
            s.pop_container();
        }
        assert!(!s.stack_overflowed());
        assert!(s.in_object());
    }
}

//! JSON and JSON5.
//!
//! One lexer serves both: JSON5 is strict JSON plus comments, unquoted keys,
//! single-quoted strings, trailing commas, hex and extended numbers, and string
//! line continuations. The `json5` flag switches those on, and the validator
//! reports them as errors when it is off — so "this is JSON5-only syntax" is a
//! real diagnostic rather than a silent acceptance.
//!
//! Everything downstream — folds, bracket pairs, validation and formatting —
//! consumes the lexeme stream this module produces, so they cannot disagree
//! about what the document contains.

use super::lexer::{lex_document, split_rows, Lexeme, MarkupLexer, RowLexemes};
use super::token::{
    Diagnostic, DiagnosticSeverity, FoldKind, FoldRegion, LexState, MarkupTokenKind, Utf16Cols,
};

/// Nothing carried over from the previous row.
const MODE_NORMAL: u8 = 0;
/// Inside a `/* ... */` comment.
const MODE_BLOCK_COMMENT: u8 = 1;
/// Inside a string continued across a row boundary by a trailing backslash.
const MODE_STRING_VALUE: u8 = 2;
/// As above, but the string is an object key.
const MODE_STRING_KEY: u8 = 3;

/// Start of a container, or just past a comma: a string here is a key.
const PENDING_KEY_OR_VALUE: u8 = 0;
/// A key has been read; a `:` is expected.
const PENDING_COLON: u8 = 1;
/// A `:` has been read; a value is expected.
const PENDING_VALUE: u8 = 2;
/// A value has been read; a `,` or a closer is expected.
const PENDING_AFTER_VALUE: u8 = 3;

pub struct JsonLexer {
    pub json5: bool,
}

impl JsonLexer {
    pub fn new(json5: bool) -> JsonLexer {
        JsonLexer { json5 }
    }

    /// Whether a scalar starting here should be coloured as an object key.
    ///
    /// Normally the container stack answers this exactly. Past
    /// `MAX_TRACKED_DEPTH` the stack is no longer maintained, so we fall back
    /// to the line-local heuristic of looking ahead for a `:` — the same
    /// approximation the old Dart scanner used at every depth.
    fn is_key_position(&self, state: &LexState, row: &str, after: usize) -> bool {
        if state.stack_overflowed() {
            return next_significant_byte(row, after) == Some(b':');
        }
        state.in_object() && state.pending == PENDING_KEY_OR_VALUE
    }
}

impl MarkupLexer for JsonLexer {
    fn lex_row(&self, row: &str, state: LexState, out: &mut RowLexemes) -> LexState {
        let mut st = state;
        let bytes = row.as_bytes();
        let mut i = 0usize;

        // ---- resume whatever the previous row left open --------------------
        match st.mode {
            MODE_BLOCK_COMMENT => match find_from(row, 0, "*/") {
                Some(end) => {
                    out.push(0, end + 2, MarkupTokenKind::Comment);
                    i = end + 2;
                    st.mode = MODE_NORMAL;
                }
                None => {
                    out.push(0, bytes.len(), MarkupTokenKind::Comment);
                    return st;
                }
            },
            MODE_STRING_VALUE | MODE_STRING_KEY => {
                let is_key = st.mode == MODE_STRING_KEY;
                let scan = scan_string_body(row, 0, st.quote, self.json5);
                let kind = if is_key {
                    MarkupTokenKind::Key
                } else {
                    MarkupTokenKind::Str
                };
                out.push(0, scan.end, kind);
                if scan.continued {
                    return st;
                }
                i = scan.end;
                st.mode = MODE_NORMAL;
                st.quote = 0;
                st.pending = if is_key {
                    PENDING_COLON
                } else {
                    PENDING_AFTER_VALUE
                };
            }
            _ => {}
        }

        // ---- main scan -----------------------------------------------------
        while i < bytes.len() {
            let c = bytes[i];
            if c.is_ascii_whitespace() {
                i += 1;
                continue;
            }

            // Comments (JSON5). In strict JSON they are still lexed, so the
            // colouring stays sane while the validator flags them as errors.
            if c == b'/' && i + 1 < bytes.len() {
                if bytes[i + 1] == b'/' {
                    out.push(i, bytes.len(), MarkupTokenKind::Comment);
                    return st;
                }
                if bytes[i + 1] == b'*' {
                    match find_from(row, i + 2, "*/") {
                        Some(end) => {
                            out.push(i, end + 2, MarkupTokenKind::Comment);
                            i = end + 2;
                        }
                        None => {
                            out.push(i, bytes.len(), MarkupTokenKind::Comment);
                            st.mode = MODE_BLOCK_COMMENT;
                            return st;
                        }
                    }
                    continue;
                }
            }

            match c {
                b'{' | b'[' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    st.push_container(c == b'{');
                    st.pending = PENDING_KEY_OR_VALUE;
                    i += 1;
                }
                b'}' | b']' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    st.pop_container();
                    st.pending = PENDING_AFTER_VALUE;
                    i += 1;
                }
                b':' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    st.pending = PENDING_VALUE;
                    i += 1;
                }
                b',' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    st.pending = PENDING_KEY_OR_VALUE;
                    i += 1;
                }
                b'"' | b'\'' => {
                    let is_key = self.is_key_position(&st, row, i);
                    let scan = scan_string_body(row, i + 1, c, self.json5);
                    let kind = if is_key {
                        MarkupTokenKind::Key
                    } else {
                        MarkupTokenKind::Str
                    };
                    out.push(i, scan.end, kind);
                    if scan.continued {
                        st.mode = if is_key {
                            MODE_STRING_KEY
                        } else {
                            MODE_STRING_VALUE
                        };
                        st.quote = c;
                        return st;
                    }
                    i = scan.end;
                    st.pending = if is_key {
                        PENDING_COLON
                    } else {
                        PENDING_AFTER_VALUE
                    };
                }
                _ => {
                    if let Some(end) = scan_number(row, i, self.json5) {
                        out.push(i, end, MarkupTokenKind::Number);
                        i = end;
                        st.pending = PENDING_AFTER_VALUE;
                        continue;
                    }
                    if let Some(end) = scan_identifier(row, i) {
                        let word = &row[i..end];
                        let kind = if matches!(word, "true" | "false" | "null") {
                            MarkupTokenKind::Keyword
                        } else if self.json5 && matches!(word, "Infinity" | "NaN") {
                            MarkupTokenKind::Number
                        } else if self.is_key_position(&st, row, i) {
                            MarkupTokenKind::Key
                        } else {
                            MarkupTokenKind::Invalid
                        };
                        out.push(i, end, kind);
                        st.pending = if kind == MarkupTokenKind::Key {
                            PENDING_COLON
                        } else {
                            PENDING_AFTER_VALUE
                        };
                        i = end;
                        continue;
                    }
                    // A byte that starts nothing valid. Emit one lexeme per
                    // character so the invalid run does not swallow the rest of
                    // the row's structure.
                    let end = next_char_boundary(row, i);
                    out.push(i, end, MarkupTokenKind::Invalid);
                    i = end;
                }
            }
        }
        st
    }
}

struct StringScan {
    /// Byte offset just past the closing quote, or the row end.
    end: usize,
    /// The string is still open at the row end via a trailing backslash.
    continued: bool,
}

/// Scan a string body starting at `from` (just past the opening quote).
fn scan_string_body(row: &str, from: usize, quote: u8, json5: bool) -> StringScan {
    let bytes = row.as_bytes();
    let mut i = from;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'\\' {
            if i + 1 >= bytes.len() {
                // A backslash at end of row continues the string in JSON5.
                // In strict JSON it is simply an unterminated string; either
                // way the row's lexeme runs to the end.
                return StringScan {
                    end: bytes.len(),
                    continued: json5,
                };
            }
            i += 2;
            continue;
        }
        if c == quote {
            return StringScan {
                end: i + 1,
                continued: false,
            };
        }
        i += 1;
    }
    StringScan {
        end: bytes.len(),
        continued: false,
    }
}

/// Scan a number at `i`, returning its end offset. Accepts JSON's grammar, plus
/// hex, leading `+`, and bare leading/trailing dots when `json5` is set.
fn scan_number(row: &str, i: usize, json5: bool) -> Option<usize> {
    let bytes = row.as_bytes();
    let mut p = i;
    if p < bytes.len() && (bytes[p] == b'-' || (json5 && bytes[p] == b'+')) {
        p += 1;
    }
    if json5 && p + 1 < bytes.len() && bytes[p] == b'0' && (bytes[p + 1] | 0x20) == b'x' {
        let start = p + 2;
        let mut q = start;
        while q < bytes.len() && bytes[q].is_ascii_hexdigit() {
            q += 1;
        }
        return if q > start { Some(q) } else { None };
    }
    let int_start = p;
    while p < bytes.len() && bytes[p].is_ascii_digit() {
        p += 1;
    }
    let had_int = p > int_start;
    let mut had_frac = false;
    if p < bytes.len() && bytes[p] == b'.' {
        let frac_start = p + 1;
        let mut q = frac_start;
        while q < bytes.len() && bytes[q].is_ascii_digit() {
            q += 1;
        }
        // Strict JSON needs digits on both sides of the dot; JSON5 needs one.
        if q > frac_start || (json5 && had_int) {
            had_frac = true;
            p = q;
        }
    }
    if !had_int && !had_frac {
        return None;
    }
    if p < bytes.len() && (bytes[p] | 0x20) == b'e' {
        let mut q = p + 1;
        if q < bytes.len() && (bytes[q] == b'+' || bytes[q] == b'-') {
            q += 1;
        }
        let digits = q;
        while q < bytes.len() && bytes[q].is_ascii_digit() {
            q += 1;
        }
        if q > digits {
            p = q;
        }
    }
    Some(p)
}

/// Scan an identifier at `i` — a bare word, used for keywords everywhere and
/// for unquoted object keys in JSON5.
fn scan_identifier(row: &str, i: usize) -> Option<usize> {
    let bytes = row.as_bytes();
    let first = *bytes.get(i)?;
    if !(first.is_ascii_alphabetic() || first == b'_' || first == b'$') {
        return None;
    }
    let mut p = i + 1;
    while p < bytes.len() {
        let c = bytes[p];
        if c.is_ascii_alphanumeric() || c == b'_' || c == b'$' {
            p += 1;
        } else {
            break;
        }
    }
    Some(p)
}

fn find_from(row: &str, from: usize, needle: &str) -> Option<usize> {
    if from > row.len() {
        return None;
    }
    row[from..].find(needle).map(|p| p + from)
}

fn next_char_boundary(row: &str, i: usize) -> usize {
    let mut p = i + 1;
    while p < row.len() && !row.is_char_boundary(p) {
        p += 1;
    }
    p.min(row.len())
}

/// The next non-whitespace byte at or after `from`, ignoring the current token.
fn next_significant_byte(row: &str, from: usize) -> Option<u8> {
    row.as_bytes()[from.min(row.len())..]
        .iter()
        .copied()
        .find(|c| !c.is_ascii_whitespace())
}

// ---- Structure: folds and bracket pairs ------------------------------------

/// Fold regions and bracket pairs, derived together from one bracket stack so a
/// fold's extent and its matching pair can never disagree.
pub struct JsonStructure {
    pub folds: Vec<FoldRegion>,
    pub pairs: Vec<super::token::BracketPair>,
}

pub fn structure(rows: &[String], lexemes: &[Lexeme]) -> JsonStructure {
    let mut stack: Vec<(u8, u32, u32)> = Vec::new(); // (opener byte, row, byte col)
    let mut folds = Vec::new();
    let mut pairs = Vec::new();
    for lex in lexemes {
        if lex.kind != MarkupTokenKind::Punctuation {
            continue;
        }
        let row = &rows[lex.row as usize];
        let text = lex.text(row);
        match text {
            "{" | "[" => stack.push((text.as_bytes()[0], lex.row, lex.start)),
            "}" | "]" => {
                let want = if text == "}" { b'{' } else { b'[' };
                // Tolerate mismatch: unwind to the nearest matching opener so a
                // single stray closer does not desynchronise the whole file.
                if let Some(pos) = stack.iter().rposition(|&(o, _, _)| o == want) {
                    let (opener, open_row, open_col) = stack[pos];
                    stack.truncate(pos);
                    let open_cols = Utf16Cols::new(&rows[open_row as usize]);
                    let close_cols = Utf16Cols::new(row);
                    pairs.push(super::token::BracketPair {
                        open_row,
                        open_col: open_cols.col(open_col as usize),
                        open_len: 1,
                        close_row: lex.row,
                        close_col: close_cols.col(lex.start as usize),
                        close_len: 1,
                    });
                    if lex.row > open_row {
                        folds.push(FoldRegion {
                            start_row: open_row,
                            end_row: lex.row,
                            start_col: open_cols.col(open_col as usize),
                            kind: if opener == b'{' {
                                FoldKind::Object
                            } else {
                                FoldKind::Array
                            },
                            label: if opener == b'{' { "{…}" } else { "[…]" }.to_string(),
                            level: 0,
                        });
                    }
                }
            }
            _ => {}
        }
    }
    folds.sort_by_key(|f| (f.start_row, f.end_row));
    JsonStructure { folds, pairs }
}

// ---- Validation ------------------------------------------------------------

/// A lexeme stripped of comments and whitespace, with its source text — the
/// input the grammar checker walks.
struct Sig<'a> {
    lex: Lexeme,
    text: &'a str,
}

fn significant<'a>(rows: &'a [String], lexemes: &'a [Lexeme]) -> Vec<Sig<'a>> {
    lexemes
        .iter()
        .filter(|l| l.kind != MarkupTokenKind::Comment)
        .map(|l| Sig {
            lex: *l,
            text: l.text(&rows[l.row as usize]),
        })
        .collect()
}

struct Validator<'a> {
    rows: &'a [String],
    sigs: Vec<Sig<'a>>,
    pos: usize,
    json5: bool,
    out: Vec<Diagnostic>,
}

impl<'a> Validator<'a> {
    fn error(&mut self, lex: Option<Lexeme>, message: String) {
        let d = match lex {
            Some(l) => diagnostic_for(self.rows, l, message),
            None => end_of_document_diagnostic(self.rows, message),
        };
        self.out.push(d);
    }

    fn peek(&self) -> Option<&Sig<'a>> {
        self.sigs.get(self.pos)
    }

    fn next(&mut self) -> Option<Lexeme> {
        let l = self.sigs.get(self.pos).map(|s| s.lex);
        if l.is_some() {
            self.pos += 1;
        }
        l
    }

    fn peek_text(&self) -> Option<&'a str> {
        self.sigs.get(self.pos).map(|s| s.text)
    }

    /// Consume a value. Returns false once an error is recorded, so the caller
    /// can stop rather than cascade.
    fn value(&mut self, depth: u32) -> bool {
        if depth > 512 {
            let lex = self.peek().map(|s| s.lex);
            self.error(lex, "Nesting is too deep to validate.".to_string());
            return false;
        }
        let Some(sig) = self.peek() else {
            self.error(None, "Unexpected end of input; a value was expected.".into());
            return false;
        };
        let lex = sig.lex;
        let text = sig.text;
        match lex.kind {
            MarkupTokenKind::Punctuation if text == "{" => {
                self.pos += 1;
                self.object(depth)
            }
            MarkupTokenKind::Punctuation if text == "[" => {
                self.pos += 1;
                self.array(depth)
            }
            MarkupTokenKind::Str | MarkupTokenKind::Key => {
                self.pos += 1;
                self.check_string(lex, text)
            }
            MarkupTokenKind::Number => {
                self.pos += 1;
                self.check_number(lex, text)
            }
            MarkupTokenKind::Keyword => {
                self.pos += 1;
                true
            }
            _ => {
                self.error(Some(lex), format!("Unexpected `{}`; a value was expected.", elide(text)));
                false
            }
        }
    }

    fn check_string(&mut self, lex: Lexeme, text: &str) -> bool {
        if text.starts_with('\'') && !self.json5 {
            self.error(
                Some(lex),
                "Single-quoted strings are JSON5 only; JSON requires double quotes.".into(),
            );
            return false;
        }
        let quote = text.as_bytes()[0];
        if text.len() < 2 || !text.ends_with(quote as char) {
            self.error(Some(lex), "Unterminated string.".into());
            return false;
        }
        true
    }

    fn check_number(&mut self, lex: Lexeme, text: &str) -> bool {
        if self.json5 {
            return true;
        }
        let bad = text.starts_with('+')
            || text.starts_with('.')
            || text.ends_with('.')
            || text.contains("0x")
            || text.contains("0X")
            || matches!(text, "Infinity" | "-Infinity" | "NaN");
        if bad {
            self.error(
                Some(lex),
                format!("`{}` is a JSON5 number; JSON does not allow it.", elide(text)),
            );
            return false;
        }
        true
    }

    fn object(&mut self, depth: u32) -> bool {
        if self.peek_text() == Some("}") {
            self.pos += 1;
            return true;
        }
        loop {
            // Key.
            let Some(sig) = self.peek() else {
                self.error(None, "Unexpected end of input; `}` was expected.".into());
                return false;
            };
            let lex = sig.lex;
            let text = sig.text;
            match lex.kind {
                MarkupTokenKind::Key | MarkupTokenKind::Str => {
                    self.pos += 1;
                    if !text.starts_with('"') && !text.starts_with('\'') {
                        if !self.json5 {
                            self.error(
                                Some(lex),
                                "Unquoted keys are JSON5 only; JSON requires a quoted key.".into(),
                            );
                            return false;
                        }
                    } else if !self.check_string(lex, text) {
                        return false;
                    }
                }
                _ => {
                    self.error(
                        Some(lex),
                        format!("Unexpected `{}`; an object key was expected.", elide(text)),
                    );
                    return false;
                }
            }
            // Colon.
            match self.peek_text() {
                Some(":") => {
                    self.pos += 1;
                }
                other => {
                    let lex = self.peek().map(|s| s.lex);
                    self.error(
                        lex,
                        match other {
                            Some(t) => format!("Expected `:` after the key, found `{}`.", elide(t)),
                            None => "Expected `:` after the key.".to_string(),
                        },
                    );
                    return false;
                }
            }
            if !self.value(depth + 1) {
                return false;
            }
            // Separator or close.
            match self.peek_text() {
                Some(",") => {
                    let comma = self.next().unwrap();
                    if self.peek_text() == Some("}") {
                        if !self.json5 {
                            self.error(
                                Some(comma),
                                "Trailing commas are JSON5 only; JSON does not allow them.".into(),
                            );
                            return false;
                        }
                        self.pos += 1;
                        return true;
                    }
                }
                Some("}") => {
                    self.pos += 1;
                    return true;
                }
                other => {
                    let lex = self.peek().map(|s| s.lex);
                    self.error(
                        lex,
                        match other {
                            Some(t) => format!("Expected `,` or `}}`, found `{}`.", elide(t)),
                            None => "Expected `,` or `}` before the end of input.".to_string(),
                        },
                    );
                    return false;
                }
            }
        }
    }

    fn array(&mut self, depth: u32) -> bool {
        if self.peek_text() == Some("]") {
            self.pos += 1;
            return true;
        }
        loop {
            if !self.value(depth + 1) {
                return false;
            }
            match self.peek_text() {
                Some(",") => {
                    let comma = self.next().unwrap();
                    if self.peek_text() == Some("]") {
                        if !self.json5 {
                            self.error(
                                Some(comma),
                                "Trailing commas are JSON5 only; JSON does not allow them.".into(),
                            );
                            return false;
                        }
                        self.pos += 1;
                        return true;
                    }
                }
                Some("]") => {
                    self.pos += 1;
                    return true;
                }
                other => {
                    let lex = self.peek().map(|s| s.lex);
                    self.error(
                        lex,
                        match other {
                            Some(t) => format!("Expected `,` or `]`, found `{}`.", elide(t)),
                            None => "Expected `,` or `]` before the end of input.".to_string(),
                        },
                    );
                    return false;
                }
            }
        }
    }
}

/// Validate a JSON or JSON5 document, returning diagnostics in document order.
pub fn validate(text: &str, json5: bool) -> Vec<Diagnostic> {
    let rows = split_rows(text);
    let lexer = JsonLexer::new(json5);
    let doc = lex_document(&lexer, &rows);
    let mut out = Vec::new();

    if !json5 {
        for lex in doc.lexemes.iter().filter(|l| l.kind == MarkupTokenKind::Comment) {
            out.push(diagnostic_for(
                &rows,
                *lex,
                "Comments are JSON5 only; JSON does not allow them.".to_string(),
            ));
        }
    }
    if !doc.end_state.is_clean() {
        out.push(end_of_document_diagnostic(
            &rows,
            match doc.end_state.mode {
                MODE_BLOCK_COMMENT => "Unterminated block comment.".to_string(),
                _ => "Unterminated string.".to_string(),
            },
        ));
    }

    let sigs = significant(&rows, &doc.lexemes);
    if sigs.is_empty() {
        if out.is_empty() {
            out.push(end_of_document_diagnostic(
                &rows,
                "The document is empty.".to_string(),
            ));
        }
        return out;
    }

    let mut v = Validator {
        rows: &rows,
        sigs,
        pos: 0,
        json5,
        out: Vec::new(),
    };
    if v.value(0) {
        if let Some(sig) = v.peek() {
            let (lex, text) = (sig.lex, sig.text);
            v.error(
                Some(lex),
                format!("Unexpected `{}` after the end of the document.", elide(text)),
            );
        }
    }
    out.extend(v.out);
    out.sort_by_key(|d| (d.row, d.col));
    out
}

fn diagnostic_for(rows: &[String], lex: Lexeme, message: String) -> Diagnostic {
    let row = &rows[lex.row as usize];
    let cols = Utf16Cols::new(row);
    Diagnostic {
        row: lex.row,
        col: cols.col(lex.start as usize),
        end_row: lex.row,
        end_col: cols.col(lex.end as usize),
        severity: DiagnosticSeverity::Error,
        message,
    }
}

fn end_of_document_diagnostic(rows: &[String], message: String) -> Diagnostic {
    let row = rows.len().saturating_sub(1);
    let end = Utf16Cols::new(&rows[row]).end();
    Diagnostic {
        row: row as u32,
        col: end,
        end_row: row as u32,
        end_col: end,
        severity: DiagnosticSeverity::Error,
        message,
    }
}

/// Shorten a token for an error message so a huge string literal does not fill
/// the diagnostics panel.
fn elide(text: &str) -> String {
    const LIMIT: usize = 24;
    if text.chars().count() <= LIMIT {
        return text.to_string();
    }
    let head: String = text.chars().take(LIMIT).collect();
    format!("{head}…")
}

// ---- Formatting ------------------------------------------------------------

/// Pretty-print, driven by the lexeme stream rather than by a parsed value.
///
/// Working from tokens is what keeps comments and key order intact: a
/// parse-and-re-serialise round trip through a `Value` type would discard both,
/// which is exactly what the Dart implementation did.
pub fn pretty(text: &str, json5: bool, indent: &str) -> Result<String, String> {
    format_tokens(text, json5, Some(indent))
}

/// Minify. Comments are dropped — they cannot survive a document with no
/// whitespace, and a minified document is not meant to be read.
pub fn compact(text: &str, json5: bool) -> Result<String, String> {
    format_tokens(text, json5, None)
}

fn format_tokens(text: &str, json5: bool, indent: Option<&str>) -> Result<String, String> {
    let diagnostics = validate(text, json5);
    if let Some(first) = diagnostics.first() {
        return Err(format!(
            "Line {}, column {}: {}",
            first.row + 1,
            first.col + 1,
            first.message
        ));
    }

    let rows = split_rows(text);
    let lexer = JsonLexer::new(json5);
    let doc = lex_document(&lexer, &rows);
    let pretty = indent.is_some();
    let indent = indent.unwrap_or("");

    let mut out = String::new();
    let mut depth = 0usize;
    // True when the last thing written still needs a separator before the next
    // token — used to decide newline-vs-nothing without peeking backwards.
    let mut at_line_start = true;
    let mut pending_newline = false;

    let items: Vec<(&str, MarkupTokenKind, u32)> = doc
        .lexemes
        .iter()
        .filter(|l| pretty || l.kind != MarkupTokenKind::Comment)
        .map(|l| (l.text(&rows[l.row as usize]), l.kind, l.row))
        .collect();

    let newline = |out: &mut String, depth: usize, at_line_start: &mut bool| {
        if !pretty {
            return;
        }
        out.push('\n');
        for _ in 0..depth {
            out.push_str(indent);
        }
        *at_line_start = true;
    };

    for (i, &(text, kind, row)) in items.iter().enumerate() {
        let next = items.get(i + 1);
        if pending_newline {
            newline(&mut out, depth, &mut at_line_start);
            pending_newline = false;
        }
        match (kind, text) {
            (MarkupTokenKind::Punctuation, "{") | (MarkupTokenKind::Punctuation, "[") => {
                out.push_str(text);
                depth += 1;
                let closes_immediately = matches!(next, Some(&(t, _, _)) if t == "}" || t == "]");
                if !closes_immediately {
                    pending_newline = true;
                } else {
                    at_line_start = false;
                }
            }
            (MarkupTokenKind::Punctuation, "}") | (MarkupTokenKind::Punctuation, "]") => {
                depth = depth.saturating_sub(1);
                // An empty container closes on the opener's own line: `{}`.
                let empty = i > 0 && matches!(items[i - 1].0, "{" | "[");
                if empty {
                    out.push_str(text);
                    at_line_start = false;
                    continue;
                }
                if !at_line_start {
                    newline(&mut out, depth, &mut at_line_start);
                } else if pretty {
                    // Already at a line start, but indented for the old depth.
                    trim_trailing_indent(&mut out, indent);
                    for _ in 0..depth {
                        out.push_str(indent);
                    }
                }
                out.push_str(text);
                at_line_start = false;
            }
            (MarkupTokenKind::Punctuation, ",") => {
                out.push_str(text);
                pending_newline = true;
                at_line_start = false;
            }
            (MarkupTokenKind::Punctuation, ":") => {
                out.push_str(text);
                if pretty {
                    out.push(' ');
                }
                at_line_start = false;
            }
            (MarkupTokenKind::Comment, _) => {
                // A comment that sat on its own row keeps its own row; one that
                // trailed a value stays on that value's row.
                let trailing = i > 0 && items[i - 1].2 == row;
                if trailing {
                    out.push(' ');
                } else if !at_line_start {
                    newline(&mut out, depth, &mut at_line_start);
                }
                out.push_str(text);
                pending_newline = true;
                at_line_start = false;
            }
            _ => {
                out.push_str(text);
                at_line_start = false;
            }
        }
    }
    Ok(out)
}

/// Remove one trailing indent unit written for a depth we have since left.
fn trim_trailing_indent(out: &mut String, indent: &str) {
    if !indent.is_empty() && out.ends_with(indent) {
        out.truncate(out.len() - indent.len());
    }
    while out.ends_with(' ') || out.ends_with('\t') {
        out.pop();
    }
}

/// Does this text use JSON5-only syntax?
///
/// Uses the real lexer rather than a regular expression, so a `//` inside a
/// string literal is not mistaken for a comment.
pub fn uses_json5_syntax(text: &str) -> bool {
    let rows = split_rows(text);
    let doc = lex_document(&JsonLexer::new(true), &rows);
    for lex in &doc.lexemes {
        let row = &rows[lex.row as usize];
        match lex.kind {
            MarkupTokenKind::Comment => return true,
            MarkupTokenKind::Str | MarkupTokenKind::Key => {
                let t = lex.text(row);
                if t.starts_with('\'') {
                    return true;
                }
                if lex.kind == MarkupTokenKind::Key && !t.starts_with('"') {
                    return true;
                }
            }
            _ => {}
        }
    }
    // Constructs with no distinguishing token — trailing commas, JSON5 numbers.
    // These show up as "JSON5 parses it, JSON does not".
    validate(text, true).is_empty() && !validate(text, false).is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::lexer::tokenize_rows;
    use crate::markup::token::MarkupToken;

    fn tokens(text: &str, json5: bool) -> Vec<Vec<MarkupToken>> {
        let rows = split_rows(text);
        tokenize_rows(&JsonLexer::new(json5), &rows, LexState::top(), 0)
            .into_iter()
            .map(|r| r.tokens)
            .collect()
    }

    fn kinds(text: &str, json5: bool) -> Vec<MarkupTokenKind> {
        tokens(text, json5)
            .into_iter()
            .flatten()
            .map(|t| t.kind)
            .collect()
    }

    #[test]
    fn object_keys_are_keys_and_array_strings_are_not() {
        let k = kinds(r#"{"a": "b"}"#, false);
        assert_eq!(
            k,
            vec![
                MarkupTokenKind::Punctuation,
                MarkupTokenKind::Key,
                MarkupTokenKind::Punctuation,
                MarkupTokenKind::Str,
                MarkupTokenKind::Punctuation,
            ]
        );
        let k = kinds(r#"["a", "b"]"#, false);
        assert!(k.iter().all(|&x| x != MarkupTokenKind::Key));
    }

    /// The container stack, not a line-local guess, is what makes this work:
    /// the string is on a row of its own with no `:` in sight.
    #[test]
    fn a_key_split_from_its_colon_across_rows_is_still_a_key() {
        let k = kinds("{\n  \"a\"\n  : 1\n}", false);
        assert!(k.contains(&MarkupTokenKind::Key));
    }

    #[test]
    fn a_string_containing_a_colon_inside_an_array_is_not_a_key() {
        let k = kinds(r#"["http://x"]"#, false);
        assert!(!k.contains(&MarkupTokenKind::Key));
    }

    #[test]
    fn json5_comments_are_lexed_as_comments() {
        let k = kinds("{ // hi\n \"a\": 1 }", true);
        assert!(k.contains(&MarkupTokenKind::Comment));
    }

    #[test]
    fn a_block_comment_spanning_rows_stays_a_comment() {
        let rows = tokens("/* a\nb\nc */ 1", true);
        assert_eq!(rows[0][0].kind, MarkupTokenKind::Comment);
        assert_eq!(rows[1][0].kind, MarkupTokenKind::Comment);
        assert_eq!(rows[2][0].kind, MarkupTokenKind::Comment);
        assert_eq!(rows[2][1].kind, MarkupTokenKind::Number);
    }

    #[test]
    fn a_double_slash_inside_a_string_is_not_a_comment() {
        let k = kinds(r#"{"url": "http://x"}"#, true);
        assert!(!k.contains(&MarkupTokenKind::Comment));
    }

    #[test]
    fn numbers_cover_the_json_grammar() {
        assert_eq!(scan_number("-1.5e-3", 0, false), Some(7));
        assert_eq!(scan_number("0", 0, false), Some(1));
        assert_eq!(scan_number("0x1F", 0, true), Some(4));
        assert_eq!(scan_number("0x1F", 0, false), Some(1)); // just the `0`
        assert_eq!(scan_number("+5", 0, true), Some(2));
        assert_eq!(scan_number("+5", 0, false), None);
        assert_eq!(scan_number("abc", 0, false), None);
    }

    // ---- validation --------------------------------------------------------

    #[test]
    fn valid_json_has_no_diagnostics() {
        assert!(validate(r#"{"a": [1, 2, {"b": null}]}"#, false).is_empty());
    }

    #[test]
    fn a_missing_colon_is_reported_at_the_offending_token() {
        let d = validate("{\"a\" 1}", false);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].row, 0);
        assert!(d[0].message.contains("Expected `:`"));
    }

    #[test]
    fn a_trailing_comma_is_an_error_in_json_but_not_json5() {
        let d = validate("[1, 2,]", false);
        assert_eq!(d.len(), 1);
        assert!(d[0].message.contains("Trailing commas"));
        assert!(validate("[1, 2,]", true).is_empty());
    }

    #[test]
    fn comments_are_an_error_in_json_but_not_json5() {
        let d = validate("// x\n{}", false);
        assert!(d.iter().any(|d| d.message.contains("Comments are JSON5")));
        assert!(validate("// x\n{}", true).is_empty());
    }

    #[test]
    fn unquoted_keys_are_json5_only() {
        assert!(validate("{a: 1}", true).is_empty());
        let d = validate("{a: 1}", false);
        assert!(d.iter().any(|d| d.message.contains("Unquoted keys")));
    }

    #[test]
    fn single_quoted_strings_are_json5_only() {
        assert!(validate("['x']", true).is_empty());
        assert!(!validate("['x']", false).is_empty());
    }

    #[test]
    fn an_unterminated_string_is_reported() {
        let d = validate("{\"a\": \"oops}", false);
        assert!(!d.is_empty());
    }

    #[test]
    fn diagnostics_carry_the_row_of_the_problem() {
        let d = validate("{\n  \"a\": 1\n  \"b\": 2\n}", false);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].row, 2);
    }

    #[test]
    fn trailing_content_after_the_document_is_reported() {
        let d = validate("{} []", false);
        assert!(d.iter().any(|d| d.message.contains("after the end")));
    }

    #[test]
    fn an_empty_document_is_reported() {
        assert!(!validate("   ", false).is_empty());
    }

    // ---- structure ---------------------------------------------------------

    #[test]
    fn folds_cover_multi_row_containers_only() {
        let rows = split_rows("{\n  \"a\": [1,\n    2]\n}");
        let doc = lex_document(&JsonLexer::new(false), &rows);
        let s = structure(&rows, &doc.lexemes);
        let mut spans: Vec<(u32, u32)> = s.folds.iter().map(|f| (f.start_row, f.end_row)).collect();
        spans.sort();
        assert_eq!(spans, vec![(0, 3), (1, 2)]);
    }

    #[test]
    fn a_single_row_container_produces_no_fold_but_still_pairs() {
        let rows = split_rows("{\"a\": 1}");
        let doc = lex_document(&JsonLexer::new(false), &rows);
        let s = structure(&rows, &doc.lexemes);
        assert!(s.folds.is_empty());
        assert_eq!(s.pairs.len(), 1);
    }

    #[test]
    fn a_stray_closer_does_not_desynchronise_the_stack() {
        let rows = split_rows("{\n]\n\"a\": 1\n}");
        let doc = lex_document(&JsonLexer::new(false), &rows);
        let s = structure(&rows, &doc.lexemes);
        // The `{` still finds its `}` on row 3.
        assert!(s.pairs.iter().any(|p| p.open_row == 0 && p.close_row == 3));
    }

    // ---- formatting --------------------------------------------------------

    #[test]
    fn pretty_expands_and_compact_collapses() {
        let src = r#"{"a":[1,2],"b":{"c":true}}"#;
        let p = pretty(src, false, "  ").unwrap();
        assert_eq!(
            p,
            "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {\n    \"c\": true\n  }\n}"
        );
        assert_eq!(compact(&p, false).unwrap(), src);
    }

    #[test]
    fn empty_containers_stay_on_one_line() {
        assert_eq!(pretty(r#"{"a":{},"b":[]}"#, false, "  ").unwrap(), "{\n  \"a\": {},\n  \"b\": []\n}");
    }

    #[test]
    fn pretty_printing_json5_keeps_comments_and_key_order() {
        let src = "{\n// leading\nb: 1, // trailing\na: 2,\n}";
        let out = pretty(src, true, "  ").unwrap();
        assert!(out.contains("// leading"));
        assert!(out.contains("// trailing"));
        assert!(out.find("b:").unwrap() < out.find("a:").unwrap());
    }

    #[test]
    fn minifying_drops_comments() {
        let out = compact("{\n// x\n\"a\": 1\n}", true).unwrap();
        assert_eq!(out, r#"{"a":1}"#);
    }

    #[test]
    fn formatting_refuses_an_invalid_document_and_says_where() {
        let err = pretty("{\"a\" 1}", false, "  ").unwrap_err();
        assert!(err.starts_with("Line 1, column"));
    }

    #[test]
    fn pretty_printing_is_idempotent() {
        let src = r#"{"a":[1,{"b":2}],"c":"x"}"#;
        let once = pretty(src, false, "  ").unwrap();
        assert_eq!(pretty(&once, false, "  ").unwrap(), once);
    }

    #[test]
    fn json5_detection_sees_comments_but_not_urls() {
        assert!(uses_json5_syntax("{\n// c\n\"a\":1}"));
        assert!(uses_json5_syntax("{a:1}"));
        assert!(!uses_json5_syntax(r#"{"url":"http://x"}"#));
    }

    #[test]
    fn non_ascii_rows_report_utf16_columns() {
        // "é" is one UTF-16 unit but two bytes. Counting units, the `:` sits at
        // column 4; counting bytes it would wrongly be reported at 5.
        let rows = tokens("{\"é\": 1}", false);
        let colon = rows[0].iter().find(|t| t.start == 4).unwrap();
        assert_eq!(colon.kind, MarkupTokenKind::Punctuation);
        assert_eq!(colon.end, 5);
        // And the number lands where UTF-16 counting puts it.
        let number = rows[0]
            .iter()
            .find(|t| t.kind == MarkupTokenKind::Number)
            .unwrap();
        assert_eq!(number.start, 6);
    }
}

//! YAML.
//!
//! Colouring, folding and bracket matching come from a hand-written lexer, the
//! same shape as the JSON and XML ones. Validation delegates to `yaml-rust2`,
//! whose scanner already implements the full YAML grammar and reports a marker
//! we can turn into a positioned diagnostic — reimplementing that would be a
//! large amount of code to arrive at a worse answer.
//!
//! Pretty-printing re-indents rather than round-tripping through a loader and
//! emitter, because a round trip discards every comment and every deliberate
//! quoting choice in the document. Re-indenting keeps them, and the result is
//! checked against the original by parsing both and comparing the values, so a
//! reformat that would have changed the document's meaning is refused instead
//! of applied.

use super::lexer::{lex_document, split_rows, Lexeme, MarkupLexer, RowLexemes};
use super::token::{
    BracketPair, Diagnostic, DiagnosticSeverity, FoldKind, FoldRegion, LexState, MarkupTokenKind,
    Utf16Cols,
};
use yaml_rust2::{yaml::Yaml, YamlLoader};

const MODE_NORMAL: u8 = 0;
/// Inside a `|` or `>` block scalar; `LexState::indent` holds the indent of the
/// row that introduced it.
const MODE_BLOCK_SCALAR: u8 = 1;
/// Inside a quoted scalar that ran past the row end.
const MODE_QUOTED: u8 = 2;

pub struct YamlLexer;

impl MarkupLexer for YamlLexer {
    fn lex_row(&self, row: &str, state: LexState, out: &mut RowLexemes) -> LexState {
        let mut st = state;
        let bytes = row.as_bytes();

        // ---- block scalar continuation -------------------------------------
        if st.mode == MODE_BLOCK_SCALAR {
            let indent = leading_spaces(row);
            let blank = row.trim().is_empty();
            if blank || indent > st.indent as usize {
                out.push(0, bytes.len(), MarkupTokenKind::Str);
                return st;
            }
            st.mode = MODE_NORMAL;
            st.indent = 0;
        }

        // ---- quoted scalar continuation ------------------------------------
        if st.mode == MODE_QUOTED {
            let scan = scan_quoted(row, 0, st.quote);
            out.push(0, scan.end, MarkupTokenKind::Str);
            if !scan.closed {
                return st;
            }
            return self.scan_row(row, st_reset(st), out, scan.end);
        }

        self.scan_row(row, st, out, 0)
    }
}

fn st_reset(st: LexState) -> LexState {
    LexState {
        mode: MODE_NORMAL,
        quote: 0,
        ..st
    }
}

impl YamlLexer {
    fn scan_row(
        &self,
        row: &str,
        mut st: LexState,
        out: &mut RowLexemes,
        from: usize,
    ) -> LexState {
        let bytes = row.as_bytes();
        let indent = leading_spaces(row);
        let mut i = from;

        // Directives and document markers own the whole row.
        if from == 0 {
            let trimmed = row.trim_end();
            if trimmed.starts_with('%') {
                out.push(0, bytes.len(), MarkupTokenKind::Directive);
                return st;
            }
            if trimmed == "---" || trimmed == "..." {
                out.push(0, trimmed.len(), MarkupTokenKind::Punctuation);
                return st;
            }
        }

        while i < bytes.len() {
            let c = bytes[i];
            if c.is_ascii_whitespace() {
                i += 1;
                continue;
            }

            // A `#` starts a comment only at the row start or after whitespace,
            // so `a#b` stays a plain scalar as YAML requires.
            if c == b'#' && (i == 0 || bytes[i - 1].is_ascii_whitespace()) {
                out.push(i, bytes.len(), MarkupTokenKind::Comment);
                return st;
            }

            match c {
                b'{' | b'[' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    st.push_container(c == b'{');
                    i += 1;
                }
                b'}' | b']' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    st.pop_container();
                    i += 1;
                }
                b',' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    i += 1;
                }
                b'-' if st.depth == 0 && is_block_indicator(row, i) => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    i += 1;
                }
                b'?' if st.depth == 0 && is_block_indicator(row, i) => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    i += 1;
                }
                b'&' | b'*' => {
                    let end = scan_plain_name(row, i + 1);
                    let kind = if c == b'&' {
                        MarkupTokenKind::Entity
                    } else {
                        MarkupTokenKind::Alias
                    };
                    out.push(i, end, kind);
                    i = end;
                }
                b'!' => {
                    let end = scan_tag(row, i);
                    out.push(i, end, MarkupTokenKind::Keyword);
                    i = end;
                }
                b'|' | b'>' if rest_is_block_header(row, i) => {
                    out.push(i, bytes.len(), MarkupTokenKind::Punctuation);
                    st.mode = MODE_BLOCK_SCALAR;
                    st.indent = indent as u32;
                    return st;
                }
                b'"' | b'\'' => {
                    let scan = scan_quoted(row, i + 1, c);
                    let is_key = !scan.closed
                        || next_significant(row, scan.end)
                            .map(|(b, _)| b == b':')
                            .unwrap_or(false);
                    out.push(
                        i,
                        scan.end,
                        if is_key && scan.closed {
                            MarkupTokenKind::Key
                        } else {
                            MarkupTokenKind::Str
                        },
                    );
                    if !scan.closed {
                        st.mode = MODE_QUOTED;
                        st.quote = c;
                        return st;
                    }
                    i = scan.end;
                }
                b':' => {
                    out.push(i, i + 1, MarkupTokenKind::Punctuation);
                    i += 1;
                }
                _ => {
                    let end = scan_plain(row, i, st.depth > 0);
                    if end == i {
                        i = next_char_boundary(row, i);
                        continue;
                    }
                    let text = row[i..end].trim_end();
                    let span_end = i + text.len();
                    let followed_by_colon = row.as_bytes().get(end) == Some(&b':')
                        || (end < bytes.len() && bytes[end] == b':');
                    let kind = if followed_by_colon {
                        MarkupTokenKind::Key
                    } else if is_number(text) {
                        MarkupTokenKind::Number
                    } else if is_keyword(text) {
                        MarkupTokenKind::Keyword
                    } else {
                        MarkupTokenKind::Str
                    };
                    out.push(i, span_end, kind);
                    i = end;
                }
            }
        }
        st
    }
}

struct QuotedScan {
    end: usize,
    closed: bool,
}

/// Scan from just past an opening quote. Single quotes escape by doubling;
/// double quotes escape with a backslash.
fn scan_quoted(row: &str, from: usize, quote: u8) -> QuotedScan {
    let bytes = row.as_bytes();
    let mut i = from;
    while i < bytes.len() {
        let c = bytes[i];
        if quote == b'"' && c == b'\\' {
            i += 2;
            continue;
        }
        if c == quote {
            if quote == b'\'' && bytes.get(i + 1) == Some(&b'\'') {
                i += 2;
                continue;
            }
            return QuotedScan {
                end: i + 1,
                closed: true,
            };
        }
        i += 1;
    }
    QuotedScan {
        end: bytes.len(),
        closed: false,
    }
}

/// A plain (unquoted) scalar, ending at a comment, a `: ` separator, or a flow
/// delimiter when inside a flow collection.
fn scan_plain(row: &str, from: usize, in_flow: bool) -> usize {
    let bytes = row.as_bytes();
    let mut i = from;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'#' && i > from && bytes[i - 1].is_ascii_whitespace() {
            break;
        }
        if c == b':' && (i + 1 >= bytes.len() || bytes[i + 1].is_ascii_whitespace() || in_flow) {
            break;
        }
        if in_flow && matches!(c, b',' | b'{' | b'}' | b'[' | b']') {
            break;
        }
        i += 1;
    }
    i
}

fn scan_plain_name(row: &str, from: usize) -> usize {
    let bytes = row.as_bytes();
    let mut i = from;
    while i < bytes.len() && !bytes[i].is_ascii_whitespace() && !matches!(bytes[i], b',' | b'}' | b']')
    {
        i += 1;
    }
    i
}

fn scan_tag(row: &str, from: usize) -> usize {
    let bytes = row.as_bytes();
    let mut i = from;
    while i < bytes.len() && !bytes[i].is_ascii_whitespace() {
        i += 1;
    }
    i
}

/// True when `|`/`>` at `i` opens a block scalar: only a header (chomping and
/// indent indicators) and an optional comment may follow.
fn rest_is_block_header(row: &str, i: usize) -> bool {
    let rest = row[i + 1..].trim();
    let rest = rest.split('#').next().unwrap_or("").trim();
    rest.chars().all(|c| c == '+' || c == '-' || c.is_ascii_digit())
}

/// True when a `-` or `?` at `i` is a block indicator rather than part of a
/// scalar: it must be followed by whitespace or end the row.
fn is_block_indicator(row: &str, i: usize) -> bool {
    match row.as_bytes().get(i + 1) {
        None => true,
        Some(c) => c.is_ascii_whitespace(),
    }
}

fn next_significant(row: &str, from: usize) -> Option<(u8, usize)> {
    row.as_bytes()[from.min(row.len())..]
        .iter()
        .enumerate()
        .find(|(_, c)| !c.is_ascii_whitespace())
        .map(|(offset, &c)| (c, from + offset))
}

fn leading_spaces(row: &str) -> usize {
    row.len() - row.trim_start_matches([' ', '\t']).len()
}

fn next_char_boundary(row: &str, i: usize) -> usize {
    let mut p = i + 1;
    while p < row.len() && !row.is_char_boundary(p) {
        p += 1;
    }
    p.min(row.len())
}

fn is_number(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    let lower = text.to_ascii_lowercase();
    if matches!(lower.as_str(), ".inf" | "-.inf" | "+.inf" | ".nan") {
        return true;
    }
    text.parse::<f64>().is_ok() || text.parse::<i64>().is_ok()
}

fn is_keyword(text: &str) -> bool {
    matches!(
        text.to_ascii_lowercase().as_str(),
        "true" | "false" | "null" | "yes" | "no" | "on" | "off" | "~"
    )
}

// ---- Structure: indentation folds and flow pairs ---------------------------

pub struct YamlStructure {
    pub folds: Vec<FoldRegion>,
    pub pairs: Vec<BracketPair>,
}

/// YAML blocks are held together by indentation, so a fold runs from a row to
/// the last row indented further than it. Rows inside a block scalar are more
/// indented by definition, so the scalar folds along with its key for free.
pub fn structure(rows: &[String], lexemes: &[Lexeme]) -> YamlStructure {
    let mut folds = Vec::new();
    for (i, row) in rows.iter().enumerate() {
        if row.trim().is_empty() {
            continue;
        }
        let indent = leading_spaces(row);
        // Find the extent of the more-indented block below this row, ignoring
        // blank rows so a paragraph break does not cut a fold short.
        let mut end = i;
        let mut j = i + 1;
        while j < rows.len() {
            let next = &rows[j];
            if next.trim().is_empty() {
                j += 1;
                continue;
            }
            if leading_spaces(next) > indent {
                end = j;
                j += 1;
            } else {
                break;
            }
        }
        if end > i {
            folds.push(FoldRegion {
                start_row: i as u32,
                end_row: end as u32,
                start_col: Utf16Cols::new(row).col(indent),
                kind: FoldKind::Block,
                label: "…".to_string(),
                level: 0,
            });
        }
    }

    // Flow collections still get real bracket pairs.
    let mut stack: Vec<(u8, u32, u32)> = Vec::new();
    let mut pairs = Vec::new();
    for lex in lexemes {
        if lex.kind != MarkupTokenKind::Punctuation {
            continue;
        }
        let row = &rows[lex.row as usize];
        match lex.text(row) {
            t @ ("{" | "[") => stack.push((t.as_bytes()[0], lex.row, lex.start)),
            t @ ("}" | "]") => {
                let want = if t == "}" { b'{' } else { b'[' };
                if let Some(pos) = stack.iter().rposition(|&(o, _, _)| o == want) {
                    let (_, open_row, open_col) = stack[pos];
                    stack.truncate(pos);
                    pairs.push(BracketPair {
                        open_row,
                        open_col: Utf16Cols::new(&rows[open_row as usize]).col(open_col as usize),
                        open_len: 1,
                        close_row: lex.row,
                        close_col: Utf16Cols::new(row).col(lex.start as usize),
                        close_len: 1,
                    });
                }
            }
            _ => {}
        }
    }
    YamlStructure { folds, pairs }
}

// ---- Validation ------------------------------------------------------------

/// Validate by loading with `yaml-rust2` and converting its scan error into a
/// positioned diagnostic.
pub fn validate(text: &str) -> Vec<Diagnostic> {
    let rows = split_rows(text);
    match YamlLoader::load_from_str(text) {
        Ok(docs) => {
            if docs.is_empty() && !text.trim().is_empty() {
                return vec![end_diagnostic(
                    &rows,
                    "The document could not be parsed.".to_string(),
                )];
            }
            Vec::new()
        }
        Err(err) => {
            let marker = err.marker();
            let row = marker.line().saturating_sub(1) as u32;
            let col = marker.col() as u32;
            let row = row.min(rows.len().saturating_sub(1) as u32);
            let end_col = Utf16Cols::new(&rows[row as usize]).end();
            vec![Diagnostic {
                row,
                col,
                end_row: row,
                end_col: end_col.max(col),
                severity: DiagnosticSeverity::Error,
                message: capitalise(err.info()),
            }]
        }
    }
}

fn capitalise(message: &str) -> String {
    let mut chars = message.chars();
    let out = match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => "Invalid YAML.".to_string(),
    };
    if out.ends_with('.') {
        out
    } else {
        out + "."
    }
}

fn end_diagnostic(rows: &[String], message: String) -> Diagnostic {
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

// ---- Formatting ------------------------------------------------------------

/// Re-indent to a consistent step, preserving comments, key order and scalar
/// styles.
///
/// The result is verified against the input — both are parsed and their values
/// compared — so a document whose meaning the re-indent would have changed is
/// reported as an error rather than silently rewritten.
pub fn pretty(text: &str, step: usize) -> Result<String, String> {
    let diagnostics = validate(text);
    if let Some(first) = diagnostics.first() {
        return Err(format!(
            "Line {}, column {}: {}",
            first.row + 1,
            first.col + 1,
            first.message
        ));
    }
    let out = reindent(text, step);
    let before = YamlLoader::load_from_str(text).map_err(|e| e.to_string())?;
    let after = YamlLoader::load_from_str(&out).map_err(|e| {
        format!("Re-indenting produced invalid YAML and was not applied ({e}).")
    })?;
    if before != after {
        return Err(
            "Re-indenting would have changed this document's meaning, so it was not applied."
                .to_string(),
        );
    }
    Ok(out)
}

/// Emit the document in flow style — valid YAML 1.2 and, being a subset,
/// valid JSON for documents that use no YAML-only types. Comments are dropped;
/// a document with no whitespace has nowhere to keep them.
pub fn compact(text: &str) -> Result<String, String> {
    let diagnostics = validate(text);
    if let Some(first) = diagnostics.first() {
        return Err(format!(
            "Line {}, column {}: {}",
            first.row + 1,
            first.col + 1,
            first.message
        ));
    }
    let docs = YamlLoader::load_from_str(text).map_err(|e| e.to_string())?;
    let mut out = String::new();
    for (i, doc) in docs.iter().enumerate() {
        if i > 0 {
            out.push('\n');
            out.push_str("--- ");
        }
        write_flow(doc, &mut out);
    }
    Ok(out)
}

fn write_flow(value: &Yaml, out: &mut String) {
    match value {
        Yaml::Hash(map) => {
            out.push('{');
            for (i, (k, v)) in map.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_flow(k, out);
                out.push(':');
                write_flow(v, out);
            }
            out.push('}');
        }
        Yaml::Array(items) => {
            out.push('[');
            for (i, v) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_flow(v, out);
            }
            out.push(']');
        }
        Yaml::String(s) => {
            out.push('"');
            for ch in s.chars() {
                match ch {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\r' => out.push_str("\\r"),
                    '\t' => out.push_str("\\t"),
                    c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                    c => out.push(c),
                }
            }
            out.push('"');
        }
        Yaml::Integer(n) => out.push_str(&n.to_string()),
        Yaml::Real(r) => out.push_str(r),
        Yaml::Boolean(b) => out.push_str(if *b { "true" } else { "false" }),
        Yaml::Null | Yaml::BadValue => out.push_str("null"),
        Yaml::Alias(_) => out.push_str("null"),
    }
}

/// Rewrite each row's indentation as `depth * step`, leaving everything from
/// the first non-space character onward untouched.
///
/// Rows inside a block scalar keep their offset relative to the scalar's own
/// indent, so a code block embedded in YAML is shifted as a unit rather than
/// flattened.
fn reindent(text: &str, step: usize) -> String {
    let rows = split_rows(text);
    let doc = lex_document(&YamlLexer, &rows);
    // Recompute per-row state so we know which rows are block-scalar content.
    let mut states = Vec::with_capacity(rows.len());
    let mut state = LexState::top();
    let mut scratch = RowLexemes::new();
    for row in &rows {
        states.push(state);
        scratch.clear();
        state = YamlLexer.lex_row(row, state, &mut scratch);
    }
    let _ = doc;

    // Stack of (original indent, new indent) for the enclosing block levels.
    let mut stack: Vec<(usize, usize)> = Vec::new();
    let mut out: Vec<String> = Vec::with_capacity(rows.len());
    // While inside a block scalar. `base` is filled from the first non-blank
    // content row: block-scalar indentation is measured from that row, so
    // normalising it to `parent + step` preserves the scalar's value exactly
    // while still tidying the document.
    struct Scalar {
        new_parent: usize,
        base: Option<(usize, usize)>,
    }
    let mut scalar: Option<Scalar> = None;

    for (i, row) in rows.iter().enumerate() {
        let in_scalar = states[i].mode == MODE_BLOCK_SCALAR;
        if !in_scalar {
            scalar = None;
        }
        if row.trim().is_empty() {
            out.push(String::new());
            continue;
        }
        let indent = leading_spaces(row);
        let body = &row[indent..];

        if let Some(active) = scalar.as_mut() {
            let (base_orig, base_new) = *active
                .base
                .get_or_insert((indent, active.new_parent + step));
            // Deeper-than-base rows keep their extra indentation, so a code
            // block embedded in the scalar keeps its own shape.
            let relative = indent.saturating_sub(base_orig);
            out.push(format!("{}{}", " ".repeat(base_new + relative), body));
            continue;
        }

        while stack.last().is_some_and(|&(orig, _)| indent < orig) {
            stack.pop();
        }
        let new_indent = match stack.last() {
            Some(&(orig, new)) if indent == orig => new,
            Some(&(_, new)) => {
                let new = new + step;
                stack.push((indent, new));
                new
            }
            None => {
                stack.push((indent, 0));
                0
            }
        };
        if stack.last().map(|&(orig, _)| orig) != Some(indent) {
            stack.push((indent, new_indent));
        }
        out.push(format!("{}{}", " ".repeat(new_indent), body));

        // A row that opens a block scalar sets the baseline for what follows.
        if states.get(i + 1).is_some_and(|s| s.mode == MODE_BLOCK_SCALAR) {
            scalar = Some(Scalar {
                new_parent: new_indent,
                base: None,
            });
        }
    }
    let mut joined = out.join("\n");
    if text.ends_with('\n') && !joined.ends_with('\n') {
        joined.push('\n');
    }
    joined
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::lexer::tokenize_rows;
    use crate::markup::token::MarkupToken;

    fn tokens(text: &str) -> Vec<Vec<MarkupToken>> {
        let rows = split_rows(text);
        tokenize_rows(&YamlLexer, &rows, LexState::top(), 0)
            .into_iter()
            .map(|r| r.tokens)
            .collect()
    }

    fn kinds(text: &str) -> Vec<MarkupTokenKind> {
        tokens(text).into_iter().flatten().map(|t| t.kind).collect()
    }

    #[test]
    fn a_mapping_row_lexes_key_colon_value() {
        assert_eq!(
            kinds("name: textutilz"),
            vec![
                MarkupTokenKind::Key,
                MarkupTokenKind::Punctuation,
                MarkupTokenKind::Str,
            ]
        );
    }

    #[test]
    fn numbers_and_keywords_are_distinguished_from_plain_strings() {
        assert_eq!(kinds("a: 1")[2], MarkupTokenKind::Number);
        assert_eq!(kinds("a: true")[2], MarkupTokenKind::Keyword);
        assert_eq!(kinds("a: hello")[2], MarkupTokenKind::Str);
        assert_eq!(kinds("a: 1.5")[2], MarkupTokenKind::Number);
    }

    #[test]
    fn a_hash_starts_a_comment_only_after_whitespace() {
        assert!(kinds("a: 1 # note").contains(&MarkupTokenKind::Comment));
        // `#` inside a scalar is part of the scalar, as YAML requires.
        assert!(!kinds("a: c#d").contains(&MarkupTokenKind::Comment));
    }

    #[test]
    fn a_comment_only_row_is_all_comment() {
        assert_eq!(kinds("  # hello"), vec![MarkupTokenKind::Comment]);
    }

    #[test]
    fn sequence_dashes_are_punctuation_but_negative_numbers_are_not() {
        assert_eq!(kinds("- item")[0], MarkupTokenKind::Punctuation);
        assert_eq!(kinds("a: -5")[2], MarkupTokenKind::Number);
    }

    #[test]
    fn anchors_aliases_and_tags_get_their_own_kinds() {
        let k = kinds("a: &anchor 1\nb: *anchor\nc: !!str 2");
        assert!(k.contains(&MarkupTokenKind::Entity));
        assert!(k.contains(&MarkupTokenKind::Alias));
        assert!(k.contains(&MarkupTokenKind::Keyword));
    }

    #[test]
    fn a_block_scalar_swallows_its_indented_rows() {
        let rows = tokens("text: |\n  line one\n  line two\nnext: 1");
        assert_eq!(rows[1][0].kind, MarkupTokenKind::Str);
        assert_eq!(rows[2][0].kind, MarkupTokenKind::Str);
        // The scalar ends when indentation returns.
        assert_eq!(rows[3][0].kind, MarkupTokenKind::Key);
    }

    #[test]
    fn block_headers_are_told_apart_from_a_greater_than_inside_a_scalar() {
        // A header is `|` or `>` followed only by chomping/indent indicators.
        assert_eq!(kinds("a: >")[2], MarkupTokenKind::Punctuation);
        assert_eq!(kinds("a: |-")[2], MarkupTokenKind::Punctuation);
        assert_eq!(kinds("a: >2")[2], MarkupTokenKind::Punctuation);
        // Anything else makes it part of a plain scalar, which YAML reads as
        // the single value `1 > 2`.
        assert_eq!(kinds("a: 1 > 2")[2], MarkupTokenKind::Str);
    }

    #[test]
    fn quoted_scalars_spanning_rows_stay_strings() {
        let rows = tokens("a: \"one\ntwo\"\nb: 1");
        assert!(rows[0].iter().any(|t| t.kind == MarkupTokenKind::Str));
        assert_eq!(rows[1][0].kind, MarkupTokenKind::Str);
        assert_eq!(rows[2][0].kind, MarkupTokenKind::Key);
    }

    #[test]
    fn quoted_keys_are_keys() {
        assert_eq!(kinds(r#""a b": 1"#)[0], MarkupTokenKind::Key);
    }

    #[test]
    fn document_markers_and_directives_own_their_row() {
        assert_eq!(kinds("%YAML 1.2"), vec![MarkupTokenKind::Directive]);
        assert_eq!(kinds("---"), vec![MarkupTokenKind::Punctuation]);
    }

    #[test]
    fn flow_collections_lex_their_delimiters() {
        let k = kinds("a: [1, 2]");
        assert_eq!(
            k.iter()
                .filter(|&&x| x == MarkupTokenKind::Punctuation)
                .count(),
            4 // `:` `[` `,` `]`
        );
    }

    // ---- structure ---------------------------------------------------------

    #[test]
    fn folds_follow_indentation() {
        let src = "a:\n  b: 1\n  c:\n    d: 2\ne: 3";
        let rows = split_rows(src);
        let doc = lex_document(&YamlLexer, &rows);
        let s = structure(&rows, &doc.lexemes);
        let mut spans: Vec<(u32, u32)> = s.folds.iter().map(|f| (f.start_row, f.end_row)).collect();
        spans.sort();
        assert_eq!(spans, vec![(0, 3), (2, 3)]);
    }

    #[test]
    fn a_blank_row_does_not_cut_a_fold_short() {
        let src = "a:\n  b: 1\n\n  c: 2\nd: 3";
        let rows = split_rows(src);
        let doc = lex_document(&YamlLexer, &rows);
        let s = structure(&rows, &doc.lexemes);
        assert_eq!((s.folds[0].start_row, s.folds[0].end_row), (0, 3));
    }

    #[test]
    fn a_block_scalar_folds_with_its_key() {
        let src = "text: |\n  one\n  two\nnext: 1";
        let rows = split_rows(src);
        let doc = lex_document(&YamlLexer, &rows);
        let s = structure(&rows, &doc.lexemes);
        assert_eq!((s.folds[0].start_row, s.folds[0].end_row), (0, 2));
    }

    // ---- validation --------------------------------------------------------

    #[test]
    fn valid_yaml_has_no_diagnostics() {
        assert!(validate("a: 1\nb:\n  - x\n  - y").is_empty());
    }

    #[test]
    fn a_syntax_error_is_reported_with_a_position() {
        let d = validate("a: 1\n  b: 2\n c: 3");
        assert_eq!(d.len(), 1);
        assert!(d[0].row >= 1);
        assert!(!d[0].message.is_empty());
    }

    #[test]
    fn an_unclosed_flow_collection_is_reported() {
        assert!(!validate("a: [1, 2").is_empty());
    }

    // ---- formatting --------------------------------------------------------

    #[test]
    fn reindenting_normalises_the_step_and_keeps_comments() {
        let src = "a:\n    b: 1 # note\n    c:\n            d: 2";
        let out = pretty(src, 2).unwrap();
        assert_eq!(out, "a:\n  b: 1 # note\n  c:\n    d: 2");
    }

    #[test]
    fn reindenting_preserves_quoting_and_key_order() {
        let src = "z: 'single'\na: \"double\"";
        assert_eq!(pretty(src, 2).unwrap(), src);
    }

    #[test]
    fn a_block_scalar_keeps_its_internal_shape() {
        let src = "text: |\n    line one\n      indented\n    line two";
        let out = pretty(src, 2).unwrap();
        assert_eq!(out, "text: |\n  line one\n    indented\n  line two");
    }

    #[test]
    fn reindenting_is_idempotent() {
        let src = "a:\n      b:\n            c: 1";
        let once = pretty(src, 2).unwrap();
        assert_eq!(pretty(&once, 2).unwrap(), once);
    }

    #[test]
    fn formatting_refuses_an_invalid_document() {
        assert!(pretty("a: [1, 2", 2).is_err());
    }

    #[test]
    fn compact_emits_flow_style() {
        assert_eq!(compact("a: 1\nb:\n  - x\n  - y").unwrap(), r#"{"a":1,"b":["x","y"]}"#);
    }

    #[test]
    fn compact_refuses_an_invalid_document() {
        assert!(compact("a: [1").is_err());
    }
}

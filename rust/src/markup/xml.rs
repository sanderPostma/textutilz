//! XML.
//!
//! The lexer recognises elements, attributes, text, comments, CDATA sections,
//! processing instructions, DOCTYPE declarations and entity references. As with
//! JSON, folds, tag pairs, validation and formatting all consume the one lexeme
//! stream, so a fold's extent and its highlighted tag pair are the same fact
//! seen twice.
//!
//! Validation checks well-formedness — matched tags, one root element,
//! well-formed attributes — not validity against a DTD or schema.

use super::lexer::{lex_document, split_rows, Lexeme, MarkupLexer, RowLexemes};
use super::token::{
    BracketPair, Diagnostic, DiagnosticSeverity, FoldKind, FoldRegion, LexState, MarkupTokenKind,
    Utf16Cols,
};

/// In element content.
const MODE_TEXT: u8 = 0;
const MODE_COMMENT: u8 = 1;
const MODE_CDATA: u8 = 2;
const MODE_PI: u8 = 3;
const MODE_DOCTYPE: u8 = 4;
/// Between a tag's name and its `>`, scanning attributes.
const MODE_IN_TAG: u8 = 5;
/// Inside a quoted attribute value that ran past the row end.
const MODE_ATTR_VALUE: u8 = 6;

pub struct XmlLexer;

impl MarkupLexer for XmlLexer {
    fn lex_row(&self, row: &str, state: LexState, out: &mut RowLexemes) -> LexState {
        let mut st = state;
        let bytes = row.as_bytes();
        let mut i = 0usize;

        // ---- finish whatever ran past the previous row end -----------------
        loop {
            match st.mode {
                MODE_COMMENT => match find_from(row, i, "-->") {
                    Some(end) => {
                        out.push(i, end + 3, MarkupTokenKind::Comment);
                        i = end + 3;
                        st.mode = MODE_TEXT;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::Comment);
                        return st;
                    }
                },
                MODE_CDATA => match find_from(row, i, "]]>") {
                    Some(end) => {
                        out.push(i, end + 3, MarkupTokenKind::CData);
                        i = end + 3;
                        st.mode = MODE_TEXT;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::CData);
                        return st;
                    }
                },
                MODE_PI => match find_from(row, i, "?>") {
                    Some(end) => {
                        out.push(i, end + 2, MarkupTokenKind::ProcessingInstruction);
                        i = end + 2;
                        st.mode = MODE_TEXT;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::ProcessingInstruction);
                        return st;
                    }
                },
                MODE_DOCTYPE => match memchr(bytes, i, b'>') {
                    Some(end) => {
                        out.push(i, end + 1, MarkupTokenKind::Doctype);
                        i = end + 1;
                        st.mode = MODE_TEXT;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::Doctype);
                        return st;
                    }
                },
                MODE_ATTR_VALUE => match memchr(bytes, i, st.quote) {
                    Some(end) => {
                        out.push(i, end + 1, MarkupTokenKind::Str);
                        i = end + 1;
                        st.mode = MODE_IN_TAG;
                        st.quote = 0;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::Str);
                        return st;
                    }
                },
                _ => break,
            }
        }

        // ---- main scan -----------------------------------------------------
        while i < bytes.len() {
            if st.mode == MODE_IN_TAG {
                i = self.lex_in_tag(row, &mut st, out, i);
                if st.mode == MODE_ATTR_VALUE {
                    return st;
                }
                continue;
            }

            // MODE_TEXT.
            let Some(lt) = memchr(bytes, i, b'<') else {
                self.push_text(row, out, i, bytes.len());
                return st;
            };
            self.push_text(row, out, i, lt);
            i = lt;

            if row[i..].starts_with("<!--") {
                st.mode = MODE_COMMENT;
                match find_from(row, i + 4, "-->") {
                    Some(end) => {
                        out.push(i, end + 3, MarkupTokenKind::Comment);
                        i = end + 3;
                        st.mode = MODE_TEXT;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::Comment);
                        return st;
                    }
                }
                continue;
            }
            if row[i..].starts_with("<![CDATA[") {
                match find_from(row, i + 9, "]]>") {
                    Some(end) => {
                        out.push(i, end + 3, MarkupTokenKind::CData);
                        i = end + 3;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::CData);
                        st.mode = MODE_CDATA;
                        return st;
                    }
                }
                continue;
            }
            if row[i..].starts_with("<?") {
                match find_from(row, i + 2, "?>") {
                    Some(end) => {
                        out.push(i, end + 2, MarkupTokenKind::ProcessingInstruction);
                        i = end + 2;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::ProcessingInstruction);
                        st.mode = MODE_PI;
                        return st;
                    }
                }
                continue;
            }
            if row[i..].starts_with("<!") {
                match memchr(bytes, i + 2, b'>') {
                    Some(end) => {
                        out.push(i, end + 1, MarkupTokenKind::Doctype);
                        i = end + 1;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::Doctype);
                        st.mode = MODE_DOCTYPE;
                        return st;
                    }
                }
                continue;
            }
            if row[i..].starts_with("</") {
                out.push(i, i + 2, MarkupTokenKind::Punctuation);
                i += 2;
                if let Some(end) = scan_name(row, i) {
                    out.push(i, end, MarkupTokenKind::TagName);
                    i = end;
                }
                st.mode = MODE_IN_TAG;
                continue;
            }
            if scan_name(row, i + 1).is_some() {
                out.push(i, i + 1, MarkupTokenKind::Punctuation);
                i += 1;
                let end = scan_name(row, i).unwrap();
                out.push(i, end, MarkupTokenKind::TagName);
                i = end;
                st.mode = MODE_IN_TAG;
                continue;
            }
            // A bare `<` that starts no markup. Well-formed XML has none.
            out.push(i, i + 1, MarkupTokenKind::Invalid);
            i += 1;
        }
        st
    }
}

impl XmlLexer {
    /// Scan attributes until the tag closes. Returns the new offset.
    fn lex_in_tag(
        &self,
        row: &str,
        st: &mut LexState,
        out: &mut RowLexemes,
        mut i: usize,
    ) -> usize {
        let bytes = row.as_bytes();
        while i < bytes.len() {
            let c = bytes[i];
            if c.is_ascii_whitespace() {
                i += 1;
                continue;
            }
            if row[i..].starts_with("/>") {
                out.push(i, i + 2, MarkupTokenKind::Punctuation);
                st.mode = MODE_TEXT;
                return i + 2;
            }
            if c == b'>' {
                out.push(i, i + 1, MarkupTokenKind::Punctuation);
                st.mode = MODE_TEXT;
                return i + 1;
            }
            if c == b'=' {
                out.push(i, i + 1, MarkupTokenKind::Punctuation);
                i += 1;
                continue;
            }
            if c == b'"' || c == b'\'' {
                match memchr(bytes, i + 1, c) {
                    Some(end) => {
                        out.push(i, end + 1, MarkupTokenKind::Str);
                        i = end + 1;
                    }
                    None => {
                        out.push(i, bytes.len(), MarkupTokenKind::Str);
                        st.mode = MODE_ATTR_VALUE;
                        st.quote = c;
                        return bytes.len();
                    }
                }
                continue;
            }
            if let Some(end) = scan_name(row, i) {
                out.push(i, end, MarkupTokenKind::AttributeName);
                i = end;
                continue;
            }
            out.push(i, next_char_boundary(row, i), MarkupTokenKind::Invalid);
            i = next_char_boundary(row, i);
        }
        i
    }

    /// Emit element content, splitting out `&entity;` references so they can be
    /// coloured apart from the surrounding text.
    fn push_text(&self, row: &str, out: &mut RowLexemes, from: usize, to: usize) {
        if to <= from || row[from..to].trim().is_empty() {
            return;
        }
        let bytes = row.as_bytes();
        let mut i = from;
        let mut run = from;
        while i < to {
            if bytes[i] == b'&' {
                if let Some(end) = scan_entity(row, i, to) {
                    out.push(run, i, MarkupTokenKind::Text);
                    out.push(i, end, MarkupTokenKind::Entity);
                    i = end;
                    run = i;
                    continue;
                }
            }
            i += 1;
        }
        out.push(run, to, MarkupTokenKind::Text);
    }
}

/// An XML Name: letters, digits, `_`, `:`, `-`, `.`, not starting with a digit,
/// `-` or `.`.
fn scan_name(row: &str, i: usize) -> Option<usize> {
    let bytes = row.as_bytes();
    let first = *bytes.get(i)?;
    if !(first.is_ascii_alphabetic() || first == b'_' || first == b':' || first >= 0x80) {
        return None;
    }
    let mut p = i + 1;
    while p < bytes.len() {
        let c = bytes[p];
        if c.is_ascii_alphanumeric() || matches!(c, b'_' | b':' | b'-' | b'.') || c >= 0x80 {
            p += 1;
        } else {
            break;
        }
    }
    Some(p)
}

/// `&name;`, `&#123;` or `&#x1F;` — returns the offset just past the `;`.
fn scan_entity(row: &str, i: usize, limit: usize) -> Option<usize> {
    let bytes = row.as_bytes();
    let mut p = i + 1;
    if p < limit && bytes[p] == b'#' {
        p += 1;
        if p < limit && (bytes[p] | 0x20) == b'x' {
            p += 1;
            let start = p;
            while p < limit && bytes[p].is_ascii_hexdigit() {
                p += 1;
            }
            if p == start {
                return None;
            }
        } else {
            let start = p;
            while p < limit && bytes[p].is_ascii_digit() {
                p += 1;
            }
            if p == start {
                return None;
            }
        }
    } else {
        let start = p;
        while p < limit && (bytes[p].is_ascii_alphanumeric() || bytes[p] == b'_' || bytes[p] == b'.')
        {
            p += 1;
        }
        if p == start {
            return None;
        }
    }
    if p < limit && bytes[p] == b';' {
        Some(p + 1)
    } else {
        None
    }
}

fn memchr(bytes: &[u8], from: usize, needle: u8) -> Option<usize> {
    if needle == 0 || from >= bytes.len() {
        return None;
    }
    bytes[from..].iter().position(|&c| c == needle).map(|p| p + from)
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

// ---- Tag stream ------------------------------------------------------------

/// A tag, reconstructed from the lexeme stream.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Tag {
    row: u32,
    /// Byte offset of the leading `<`.
    start: u32,
    /// Byte offset just past the tag's `>` or `/>`, or the row end if it never
    /// closed on this row.
    name_end: u32,
    name: String,
    closing: bool,
    self_closing: bool,
    /// Row and byte offset just past the tag's terminator.
    end_row: u32,
    end: u32,
}

/// Walk the lexemes and rebuild the sequence of tags. Everything structural —
/// folds, pairs and well-formedness — is derived from this.
fn tags(rows: &[String], lexemes: &[Lexeme]) -> Vec<Tag> {
    let mut out: Vec<Tag> = Vec::new();
    let mut current: Option<Tag> = None;
    for lex in lexemes {
        let row = &rows[lex.row as usize];
        let text = lex.text(row);
        match lex.kind {
            MarkupTokenKind::Punctuation if text == "<" || text == "</" => {
                if let Some(tag) = current.take() {
                    out.push(tag);
                }
                current = Some(Tag {
                    row: lex.row,
                    start: lex.start,
                    name_end: lex.end,
                    name: String::new(),
                    closing: text == "</",
                    self_closing: false,
                    end_row: lex.row,
                    end: lex.end,
                });
            }
            MarkupTokenKind::TagName => {
                if let Some(tag) = current.as_mut() {
                    if tag.name.is_empty() {
                        tag.name = text.to_string();
                        tag.name_end = lex.end;
                        tag.end_row = lex.row;
                        tag.end = lex.end;
                    }
                }
            }
            MarkupTokenKind::Punctuation if text == ">" || text == "/>" => {
                if let Some(mut tag) = current.take() {
                    tag.self_closing = text == "/>";
                    tag.end_row = lex.row;
                    tag.end = lex.end;
                    out.push(tag);
                }
            }
            _ => {}
        }
    }
    if let Some(tag) = current.take() {
        out.push(tag);
    }
    out
}

pub struct XmlStructure {
    pub folds: Vec<FoldRegion>,
    pub pairs: Vec<BracketPair>,
}

/// Fold regions and tag pairs.
///
/// A pair highlights `<name` in the open tag and `</name>` in the close tag —
/// the shape the reference editors use, and the one that reads clearly when the
/// two are far apart.
pub fn structure(rows: &[String], lexemes: &[Lexeme]) -> XmlStructure {
    let tags = tags(rows, lexemes);
    let mut stack: Vec<&Tag> = Vec::new();
    let mut folds = Vec::new();
    let mut pairs = Vec::new();
    for tag in &tags {
        if tag.self_closing || tag.name.is_empty() {
            continue;
        }
        if !tag.closing {
            stack.push(tag);
            continue;
        }
        // Unwind to the nearest matching opener, so one unbalanced tag does not
        // throw off the whole document.
        let Some(pos) = stack.iter().rposition(|t| t.name == tag.name) else {
            continue;
        };
        let open = stack[pos];
        stack.truncate(pos);
        let open_cols = Utf16Cols::new(&rows[open.row as usize]);
        let close_cols = Utf16Cols::new(&rows[tag.row as usize]);
        let open_col = open_cols.col(open.start as usize);
        pairs.push(BracketPair {
            open_row: open.row,
            open_col,
            open_len: open_cols.col(open.name_end as usize) - open_col,
            close_row: tag.row,
            close_col: close_cols.col(tag.start as usize),
            close_len: close_cols.col(tag.end as usize) - close_cols.col(tag.start as usize),
        });
        if tag.row > open.row {
            folds.push(FoldRegion {
                start_row: open.row,
                end_row: tag.row,
                start_col: open_col,
                kind: FoldKind::Element,
                label: format!("<{}…>", open.name),
                level: 0,
            });
        }
    }
    folds.sort_by_key(|f| (f.start_row, f.end_row));
    XmlStructure { folds, pairs }
}

// ---- Validation ------------------------------------------------------------

/// Check well-formedness: matched tags, exactly one root element, closed
/// constructs, and attributes that have values.
pub fn validate(text: &str) -> Vec<Diagnostic> {
    let rows = split_rows(text);
    let doc = lex_document(&XmlLexer, &rows);
    let mut out = Vec::new();

    if !doc.end_state.is_clean() || doc.end_state.mode == MODE_IN_TAG {
        let message = match doc.end_state.mode {
            MODE_COMMENT => "Unterminated comment; `-->` is missing.",
            MODE_CDATA => "Unterminated CDATA section; `]]>` is missing.",
            MODE_PI => "Unterminated processing instruction; `?>` is missing.",
            MODE_DOCTYPE => "Unterminated declaration; `>` is missing.",
            MODE_ATTR_VALUE => "Unterminated attribute value.",
            MODE_IN_TAG => "Unterminated tag; `>` is missing.",
            _ => "Unterminated construct.",
        };
        out.push(end_diagnostic(&rows, message.to_string()));
    }

    for lex in doc.lexemes.iter().filter(|l| l.kind == MarkupTokenKind::Invalid) {
        let row = &rows[lex.row as usize];
        out.push(span_diagnostic(
            &rows,
            *lex,
            if lex.text(row) == "<" {
                "A bare `<` must be written as `&lt;`.".to_string()
            } else {
                format!("Unexpected `{}`.", lex.text(row))
            },
        ));
    }

    let tags = tags(&rows, &doc.lexemes);
    let mut stack: Vec<&Tag> = Vec::new();
    let mut roots = 0usize;
    for tag in &tags {
        if tag.name.is_empty() {
            out.push(tag_diagnostic(&rows, tag, "Tag has no name.".to_string()));
            continue;
        }
        if tag.closing {
            match stack.pop() {
                None => out.push(tag_diagnostic(
                    &rows,
                    tag,
                    format!("`</{}>` closes an element that was never opened.", tag.name),
                )),
                Some(open) if open.name != tag.name => {
                    out.push(tag_diagnostic(
                        &rows,
                        tag,
                        format!(
                            "`</{}>` does not match `<{}>` opened on line {}.",
                            tag.name,
                            open.name,
                            open.row + 1
                        ),
                    ));
                    // Resync: treat the mismatch as closing the open element so
                    // the rest of the document is still checked usefully.
                }
                Some(_) => {
                    if stack.is_empty() {
                        roots += 1;
                    }
                }
            }
            continue;
        }
        if tag.self_closing {
            if stack.is_empty() {
                roots += 1;
            }
            continue;
        }
        stack.push(tag);
    }
    for open in stack {
        out.push(tag_diagnostic(
            &rows,
            open,
            format!("`<{}>` is never closed.", open.name),
        ));
    }
    if roots == 0 && out.is_empty() {
        out.push(end_diagnostic(
            &rows,
            "The document has no root element.".to_string(),
        ));
    } else if roots > 1 {
        out.push(end_diagnostic(
            &rows,
            format!("The document has {roots} root elements; XML allows exactly one."),
        ));
    }

    out.sort_by_key(|d| (d.row, d.col));
    out
}

fn span_diagnostic(rows: &[String], lex: Lexeme, message: String) -> Diagnostic {
    let cols = Utf16Cols::new(&rows[lex.row as usize]);
    Diagnostic {
        row: lex.row,
        col: cols.col(lex.start as usize),
        end_row: lex.row,
        end_col: cols.col(lex.end as usize),
        severity: DiagnosticSeverity::Error,
        message,
    }
}

fn tag_diagnostic(rows: &[String], tag: &Tag, message: String) -> Diagnostic {
    let cols = Utf16Cols::new(&rows[tag.row as usize]);
    let end_cols = Utf16Cols::new(&rows[tag.end_row as usize]);
    Diagnostic {
        row: tag.row,
        col: cols.col(tag.start as usize),
        end_row: tag.end_row,
        end_col: end_cols.col(tag.end as usize),
        severity: DiagnosticSeverity::Error,
        message,
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

/// Pretty-print: one node per row, indented by depth.
///
/// Mixed content — an element holding both text and child elements — is left on
/// one row, because re-indenting it would change the text the document actually
/// carries. That is the difference between formatting XML and formatting JSON,
/// and it is why this walks tags rather than round-tripping through a DOM.
pub fn pretty(text: &str, indent: &str) -> Result<String, String> {
    format_xml(text, Some(indent))
}

/// Minify: drop whitespace-only text between elements, keep everything else.
pub fn compact(text: &str) -> Result<String, String> {
    format_xml(text, None)
}

fn format_xml(text: &str, indent: Option<&str>) -> Result<String, String> {
    let diagnostics = validate(text);
    if let Some(first) = diagnostics.first() {
        return Err(format!(
            "Line {}, column {}: {}",
            first.row + 1,
            first.col + 1,
            first.message
        ));
    }
    let rows = split_rows(text);
    let doc = lex_document(&XmlLexer, &rows);
    let nodes = nodes(&rows, &doc.lexemes);
    let pretty = indent.is_some();
    let indent = indent.unwrap_or("");

    let mut out = String::new();
    let mut depth = 0usize;
    for (i, node) in nodes.iter().enumerate() {
        match node.kind {
            NodeKind::Close => depth = depth.saturating_sub(1),
            _ => {}
        }
        if pretty && !out.is_empty() {
            // An element whose entire content is one text node stays on its own
            // row: `<a>text</a>`.
            let inline = matches!(node.kind, NodeKind::Text)
                || (matches!(node.kind, NodeKind::Close)
                    && matches!(nodes.get(i.wrapping_sub(1)).map(|n| n.kind), Some(NodeKind::Text)));
            if !inline {
                out.push('\n');
                for _ in 0..depth {
                    out.push_str(indent);
                }
            }
        }
        out.push_str(&node.text);
        if matches!(node.kind, NodeKind::Open) {
            depth += 1;
        }
    }
    Ok(out)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NodeKind {
    Open,
    Close,
    SelfClose,
    Text,
    Other,
}

struct Node {
    kind: NodeKind,
    text: String,
}

/// Flatten the lexeme stream into printable nodes: whole tags, text runs, and
/// standalone constructs such as comments and declarations.
fn nodes(rows: &[String], lexemes: &[Lexeme]) -> Vec<Node> {
    let mut out: Vec<Node> = Vec::new();
    let mut tag: Option<(String, bool)> = None; // (accumulated text, is_closing)
    let mut text_run = String::new();

    let flush_text = |out: &mut Vec<Node>, text_run: &mut String| {
        let trimmed = text_run.trim();
        if !trimmed.is_empty() {
            out.push(Node {
                kind: NodeKind::Text,
                text: trimmed.to_string(),
            });
        }
        text_run.clear();
    };

    for lex in lexemes {
        let row = &rows[lex.row as usize];
        let text = lex.text(row);
        match lex.kind {
            MarkupTokenKind::Punctuation if text == "<" || text == "</" => {
                flush_text(&mut out, &mut text_run);
                tag = Some((text.to_string(), text == "</"));
            }
            MarkupTokenKind::Punctuation if text == ">" || text == "/>" => {
                if let Some((mut acc, closing)) = tag.take() {
                    acc.push_str(text);
                    out.push(Node {
                        kind: if closing {
                            NodeKind::Close
                        } else if text == "/>" {
                            NodeKind::SelfClose
                        } else {
                            NodeKind::Open
                        },
                        text: acc,
                    });
                }
            }
            MarkupTokenKind::Comment
            | MarkupTokenKind::CData
            | MarkupTokenKind::Doctype
            | MarkupTokenKind::ProcessingInstruction => {
                flush_text(&mut out, &mut text_run);
                out.push(Node {
                    kind: NodeKind::Other,
                    text: text.to_string(),
                });
            }
            MarkupTokenKind::Text | MarkupTokenKind::Entity => {
                if tag.is_none() {
                    text_run.push_str(text);
                }
            }
            _ => {
                if let Some((acc, _)) = tag.as_mut() {
                    // Rebuild the tag's interior with single spaces between
                    // attributes, which is the only whitespace XML ignores here.
                    if !acc.ends_with('<')
                        && !acc.ends_with("</")
                        && !acc.ends_with('=')
                        && text != "="
                    {
                        acc.push(' ');
                    }
                    acc.push_str(text);
                }
            }
        }
    }
    flush_text(&mut out, &mut text_run);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::lexer::tokenize_rows;
    use crate::markup::token::MarkupToken;

    fn tokens(text: &str) -> Vec<Vec<MarkupToken>> {
        let rows = split_rows(text);
        tokenize_rows(&XmlLexer, &rows, LexState::top(), 0)
            .into_iter()
            .map(|r| r.tokens)
            .collect()
    }

    fn kinds(text: &str) -> Vec<MarkupTokenKind> {
        tokens(text).into_iter().flatten().map(|t| t.kind).collect()
    }

    #[test]
    fn a_simple_element_lexes_to_punctuation_name_and_text() {
        assert_eq!(
            kinds("<a>hi</a>"),
            vec![
                MarkupTokenKind::Punctuation,
                MarkupTokenKind::TagName,
                MarkupTokenKind::Punctuation,
                MarkupTokenKind::Text,
                MarkupTokenKind::Punctuation,
                MarkupTokenKind::TagName,
                MarkupTokenKind::Punctuation,
            ]
        );
    }

    #[test]
    fn attributes_split_into_name_and_quoted_value() {
        let k = kinds(r#"<a id="x" n='2'/>"#);
        assert!(k.contains(&MarkupTokenKind::AttributeName));
        assert_eq!(
            k.iter().filter(|&&x| x == MarkupTokenKind::Str).count(),
            2
        );
    }

    #[test]
    fn the_xml_declaration_is_a_processing_instruction() {
        assert_eq!(
            kinds(r#"<?xml version="1.0"?>"#),
            vec![MarkupTokenKind::ProcessingInstruction]
        );
    }

    #[test]
    fn comments_and_cdata_spanning_rows_stay_intact() {
        let rows = tokens("<a><!-- one\ntwo --><![CDATA[x\ny]]></a>");
        // Row 0 is `<`, `a`, `>`, then the comment's first row.
        assert_eq!(rows[0][3].kind, MarkupTokenKind::Comment);
        assert_eq!(rows[1][0].kind, MarkupTokenKind::Comment);
        assert!(rows[1].iter().any(|t| t.kind == MarkupTokenKind::CData));
        assert_eq!(rows[2][0].kind, MarkupTokenKind::CData);
    }

    #[test]
    fn an_attribute_value_spanning_rows_stays_a_string() {
        let rows = tokens("<a b=\"one\ntwo\">x</a>");
        assert!(rows[0].iter().any(|t| t.kind == MarkupTokenKind::Str));
        assert_eq!(rows[1][0].kind, MarkupTokenKind::Str);
    }

    #[test]
    fn entities_are_lexed_apart_from_surrounding_text() {
        let k = kinds("<a>1 &lt; 2 &#38; 3</a>");
        assert_eq!(
            k.iter().filter(|&&x| x == MarkupTokenKind::Entity).count(),
            2
        );
    }

    #[test]
    fn a_less_than_inside_an_attribute_value_is_not_a_tag() {
        let k = kinds(r#"<a b="1<2">x</a>"#);
        assert!(!k.contains(&MarkupTokenKind::Invalid));
    }

    // ---- structure ---------------------------------------------------------

    #[test]
    fn nested_elements_fold_from_open_row_to_close_row() {
        let src = "<r>\n  <a>\n    <b/>\n  </a>\n</r>";
        let rows = split_rows(src);
        let doc = lex_document(&XmlLexer, &rows);
        let s = structure(&rows, &doc.lexemes);
        let mut spans: Vec<(u32, u32)> = s.folds.iter().map(|f| (f.start_row, f.end_row)).collect();
        spans.sort();
        assert_eq!(spans, vec![(0, 4), (1, 3)]);
        assert_eq!(s.folds[0].label, "<r…>");
    }

    #[test]
    fn a_self_closing_element_neither_folds_nor_pairs() {
        let rows = split_rows("<r>\n<a/>\n</r>");
        let doc = lex_document(&XmlLexer, &rows);
        let s = structure(&rows, &doc.lexemes);
        assert_eq!(s.pairs.len(), 1);
        assert_eq!(s.folds.len(), 1);
    }

    #[test]
    fn a_pair_spans_the_open_tag_name_and_the_whole_close_tag() {
        let rows = split_rows("<layout id=\"x\">\n</layout>");
        let doc = lex_document(&XmlLexer, &rows);
        let p = &structure(&rows, &doc.lexemes).pairs[0];
        assert_eq!((p.open_row, p.open_col, p.open_len), (0, 0, 7)); // `<layout`
        assert_eq!((p.close_row, p.close_col, p.close_len), (1, 0, 9)); // `</layout>`
    }

    // ---- validation --------------------------------------------------------

    #[test]
    fn well_formed_xml_has_no_diagnostics() {
        assert!(validate(r#"<?xml version="1.0"?><r><a b="1"/><c>t</c></r>"#).is_empty());
    }

    #[test]
    fn a_mismatched_close_tag_names_both_sides_and_the_line() {
        let d = validate("<a>\n</b>");
        assert!(d[0].message.contains("`</b>` does not match `<a>` opened on line 1"));
    }

    #[test]
    fn an_unclosed_element_is_reported_at_its_open_tag() {
        let d = validate("<r><a></r>");
        assert!(d.iter().any(|d| d.message.contains("is never closed")
            || d.message.contains("does not match")));
    }

    #[test]
    fn two_root_elements_are_reported() {
        let d = validate("<a/><b/>");
        assert!(d.iter().any(|d| d.message.contains("2 root elements")));
    }

    #[test]
    fn a_bare_less_than_is_reported_with_the_fix() {
        let d = validate("<a>1 < 2</a>");
        assert!(d.iter().any(|d| d.message.contains("&lt;")));
    }

    #[test]
    fn an_unterminated_comment_is_reported() {
        let d = validate("<a><!-- x</a>");
        assert!(d.iter().any(|d| d.message.contains("Unterminated comment")));
    }

    #[test]
    fn a_document_with_no_root_is_reported() {
        assert!(!validate("<!-- just a comment -->").is_empty());
    }

    // ---- formatting --------------------------------------------------------

    #[test]
    fn pretty_indents_one_element_per_row() {
        let out = pretty("<r><a><b/></a></r>", "  ").unwrap();
        assert_eq!(out, "<r>\n  <a>\n    <b/>\n  </a>\n</r>");
    }

    #[test]
    fn text_only_elements_stay_on_one_row() {
        let out = pretty("<r><a>hello</a></r>", "  ").unwrap();
        assert_eq!(out, "<r>\n  <a>hello</a>\n</r>");
    }

    #[test]
    fn attributes_are_preserved_with_single_spaces() {
        let out = pretty("<a   id=\"1\"    n='2'/>", "  ").unwrap();
        assert_eq!(out, r#"<a id="1" n='2'/>"#);
    }

    #[test]
    fn compact_removes_the_whitespace_between_elements() {
        let src = "<r>\n  <a>x</a>\n</r>";
        assert_eq!(compact(src).unwrap(), "<r><a>x</a></r>");
    }

    #[test]
    fn pretty_printing_is_idempotent() {
        let once = pretty("<r><a><b>t</b></a></r>", "  ").unwrap();
        assert_eq!(pretty(&once, "  ").unwrap(), once);
    }

    #[test]
    fn formatting_refuses_a_malformed_document() {
        assert!(pretty("<a></b>", "  ").is_err());
    }

    #[test]
    fn the_declaration_and_comments_survive_formatting() {
        let out = pretty("<?xml version=\"1.0\"?><!-- c --><r/>", "  ").unwrap();
        assert_eq!(out, "<?xml version=\"1.0\"?>\n<!-- c -->\n<r/>");
    }
}

//! The Dart-facing surface for structured formats.
//!
//! The domain logic lives in `crate::markup`; this module is the wire format.
//! Keeping them apart means the lexers can use trait objects and borrowed
//! slices freely, while the types that cross the bridge stay simple owned
//! structs that the code generator can mirror.
//!
//! Nothing here makes decisions. Every function converts arguments, calls into
//! `crate::markup`, and converts the result back.

use flutter_rust_bridge::frb;

use crate::markup::{self, MarkupLanguage};

// ---- Wire types ------------------------------------------------------------

/// A structured format, or `PlainText` for everything else.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructuredLanguage {
    PlainText,
    Json,
    Json5,
    Yaml,
    Xml,
}

impl StructuredLanguage {
    fn to_domain(self) -> MarkupLanguage {
        match self {
            StructuredLanguage::PlainText => MarkupLanguage::PlainText,
            StructuredLanguage::Json => MarkupLanguage::Json,
            StructuredLanguage::Json5 => MarkupLanguage::Json5,
            StructuredLanguage::Yaml => MarkupLanguage::Yaml,
            StructuredLanguage::Xml => MarkupLanguage::Xml,
        }
    }

    fn from_domain(value: MarkupLanguage) -> StructuredLanguage {
        match value {
            MarkupLanguage::PlainText => StructuredLanguage::PlainText,
            MarkupLanguage::Json => StructuredLanguage::Json,
            MarkupLanguage::Json5 => StructuredLanguage::Json5,
            MarkupLanguage::Yaml => StructuredLanguage::Yaml,
            MarkupLanguage::Xml => StructuredLanguage::Xml,
        }
    }
}

/// What a run of characters means. Dart maps these to colours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructuredTokenKind {
    Key,
    Str,
    Number,
    Keyword,
    Punctuation,
    TagName,
    AttributeName,
    Comment,
    Text,
    CData,
    Doctype,
    ProcessingInstruction,
    Entity,
    Alias,
    Directive,
    Invalid,
}

impl StructuredTokenKind {
    fn from_domain(kind: markup::MarkupTokenKind) -> StructuredTokenKind {
        use markup::MarkupTokenKind as K;
        match kind {
            K::Key => StructuredTokenKind::Key,
            K::Str => StructuredTokenKind::Str,
            K::Number => StructuredTokenKind::Number,
            K::Keyword => StructuredTokenKind::Keyword,
            K::Punctuation => StructuredTokenKind::Punctuation,
            K::TagName => StructuredTokenKind::TagName,
            K::AttributeName => StructuredTokenKind::AttributeName,
            K::Comment => StructuredTokenKind::Comment,
            K::Text => StructuredTokenKind::Text,
            K::CData => StructuredTokenKind::CData,
            K::Doctype => StructuredTokenKind::Doctype,
            K::ProcessingInstruction => StructuredTokenKind::ProcessingInstruction,
            K::Entity => StructuredTokenKind::Entity,
            K::Alias => StructuredTokenKind::Alias,
            K::Directive => StructuredTokenKind::Directive,
            K::Invalid => StructuredTokenKind::Invalid,
        }
    }
}

/// A token as a half-open UTF-16 column range within one row.
pub struct StructuredToken {
    pub start: u32,
    pub end: u32,
    pub kind: StructuredTokenKind,
}

/// Every token on one row, ascending and non-overlapping.
pub struct StructuredRowTokens {
    pub row: u32,
    pub tokens: Vec<StructuredToken>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructuredFoldKind {
    Object,
    Array,
    Element,
    Block,
    Comment,
}

/// A collapsible span. `start_row` stays visible when collapsed; `end_row` is
/// the last row hidden.
pub struct StructuredFold {
    pub start_row: u32,
    pub end_row: u32,
    pub start_col: u32,
    pub kind: StructuredFoldKind,
    /// Placeholder drawn on the collapsed row.
    pub label: String,
    /// Nesting depth, outermost = 0. Drives fold-to-level.
    pub level: u32,
}

/// A matched delimiter pair: braces, brackets, or an XML open/close tag.
pub struct StructuredPair {
    pub open_row: u32,
    pub open_col: u32,
    pub open_len: u32,
    pub close_row: u32,
    pub close_col: u32,
    pub close_len: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructuredSeverity {
    Error,
    Warning,
}

/// A validation problem, positioned so the UI can reveal it.
pub struct StructuredDiagnostic {
    pub row: u32,
    pub col: u32,
    pub end_row: u32,
    pub end_col: u32,
    pub severity: StructuredSeverity,
    pub message: String,
}

/// How a language spells comments. Both `line` and `block_start` being `None`
/// means the format has none — see `unsupported_note` for what to tell the user.
pub struct StructuredCommentStyle {
    pub line: Option<String>,
    pub block_start: Option<String>,
    pub block_end: Option<String>,
    pub unsupported_note: Option<String>,
}

/// The result of the whole-document pass.
pub struct StructuredAnalysis {
    pub language: StructuredLanguage,
    pub folds: Vec<StructuredFold>,
    pub pairs: Vec<StructuredPair>,
    pub diagnostics: Vec<StructuredDiagnostic>,
    /// True when the document was too large to analyse. The empty lists then
    /// mean "not computed", not "nothing found".
    pub truncated: bool,
}

// ---- Conversions -----------------------------------------------------------

pub(crate) fn wire_row_tokens(rows: Vec<markup::RowTokens>) -> Vec<StructuredRowTokens> {
    rows.into_iter()
        .map(|r| StructuredRowTokens {
            row: r.row,
            tokens: r
                .tokens
                .into_iter()
                .map(|t| StructuredToken {
                    start: t.start,
                    end: t.end,
                    kind: StructuredTokenKind::from_domain(t.kind),
                })
                .collect(),
        })
        .collect()
}

fn wire_fold(f: markup::FoldRegion) -> StructuredFold {
    use markup::FoldKind as K;
    StructuredFold {
        start_row: f.start_row,
        end_row: f.end_row,
        start_col: f.start_col,
        kind: match f.kind {
            K::Object => StructuredFoldKind::Object,
            K::Array => StructuredFoldKind::Array,
            K::Element => StructuredFoldKind::Element,
            K::Block => StructuredFoldKind::Block,
            K::Comment => StructuredFoldKind::Comment,
        },
        label: f.label,
        level: f.level,
    }
}

pub(crate) fn wire_pair_public(p: markup::BracketPair) -> StructuredPair {
    wire_pair(p)
}

fn wire_pair(p: markup::BracketPair) -> StructuredPair {
    StructuredPair {
        open_row: p.open_row,
        open_col: p.open_col,
        open_len: p.open_len,
        close_row: p.close_row,
        close_col: p.close_col,
        close_len: p.close_len,
    }
}

fn wire_diagnostic(d: markup::Diagnostic) -> StructuredDiagnostic {
    StructuredDiagnostic {
        row: d.row,
        col: d.col,
        end_row: d.end_row,
        end_col: d.end_col,
        severity: match d.severity {
            markup::DiagnosticSeverity::Error => StructuredSeverity::Error,
            markup::DiagnosticSeverity::Warning => StructuredSeverity::Warning,
        },
        message: d.message,
    }
}

pub(crate) fn wire_analysis(a: markup::MarkupAnalysis) -> StructuredAnalysis {
    StructuredAnalysis {
        language: StructuredLanguage::from_domain(a.language),
        folds: a.folds.into_iter().map(wire_fold).collect(),
        pairs: a.pairs.into_iter().map(wire_pair).collect(),
        diagnostics: a.diagnostics.into_iter().map(wire_diagnostic).collect(),
        truncated: a.truncated,
    }
}

// ---- API -------------------------------------------------------------------

/// Detect a document's format from its extension, its content type, and — for
/// unsaved documents where neither says anything — its content.
#[frb(sync)]
pub fn detect_structured_language(
    extension: String,
    content_type: String,
    sample: String,
) -> StructuredLanguage {
    StructuredLanguage::from_domain(markup::detect_language(&extension, &content_type, &sample))
}

/// The display name of a language.
#[frb(sync)]
pub fn structured_language_label(language: StructuredLanguage) -> String {
    language.to_domain().label()
}

/// The stable identifier a language is persisted under, for the per-document
/// override stored on `documents.language_override`.
#[frb(sync)]
pub fn structured_language_id(language: StructuredLanguage) -> String {
    language.to_domain().id().to_string()
}

/// The inverse of [`structured_language_id`]. `None` for anything
/// unrecognised, which the caller reads as "no override, detect instead".
#[frb(sync)]
pub fn structured_language_from_id(id: String) -> Option<StructuredLanguage> {
    MarkupLanguage::from_id(&id).map(StructuredLanguage::from_domain)
}

/// Every language the user can pin a document to, in menu order.
#[frb(sync)]
pub fn structured_languages() -> Vec<StructuredLanguage> {
    vec![
        StructuredLanguage::PlainText,
        StructuredLanguage::Json,
        StructuredLanguage::Json5,
        StructuredLanguage::Yaml,
        StructuredLanguage::Xml,
    ]
}

/// The comment syntax for a document. The detected language wins over the file
/// extension, so a YAML document saved as `.txt` still comments with `#`.
#[frb(sync)]
pub fn structured_comment_style(
    language: StructuredLanguage,
    extension: String,
) -> StructuredCommentStyle {
    let style = markup::comment_style(language.to_domain(), &extension);
    StructuredCommentStyle {
        line: style.line,
        block_start: style.block_start,
        block_end: style.block_end,
        unsupported_note: style.unsupported_note,
    }
}

/// Folds, pairs and diagnostics for a whole document.
#[frb(sync)]
pub fn analyze_structured(text: String, language: StructuredLanguage) -> StructuredAnalysis {
    let rows = markup::rows_of(&text);
    wire_analysis(markup::analyse_rows(&rows, language.to_domain()))
}

/// Validate a document, returning diagnostics in document order.
#[frb(sync)]
pub fn validate_structured(
    text: String,
    language: StructuredLanguage,
) -> Vec<StructuredDiagnostic> {
    markup::validate_text(&text, language.to_domain())
        .into_iter()
        .map(wire_diagnostic)
        .collect()
}

/// Tokens for a whole snippet, lexed from the top. Used for Read and Tail,
/// which render a text slice rather than an edit session.
#[frb(sync)]
pub fn tokenize_structured(
    text: String,
    language: StructuredLanguage,
) -> Vec<StructuredRowTokens> {
    let rows = markup::rows_of(&text);
    wire_row_tokens(markup::tokens_for(
        &rows,
        language.to_domain(),
        markup::LexState::top(),
        0,
    ))
}

/// Pretty-print or minify.
#[frb(sync)]
pub fn format_structured(
    text: String,
    language: StructuredLanguage,
    pretty: bool,
    indent: String,
) -> Result<String, String> {
    let action = if pretty {
        markup::FormatAction::Pretty
    } else {
        markup::FormatAction::Compact
    };
    markup::format_text(&text, language.to_domain(), action, &indent)
}

/// Escape text for embedding in a document of this format.
#[frb(sync)]
pub fn escape_structured(text: String, language: StructuredLanguage) -> Result<String, String> {
    markup::escape::escape(language.to_domain(), &text)
}

/// Turn escape sequences back into the characters they stand for.
#[frb(sync)]
pub fn unescape_structured(text: String, language: StructuredLanguage) -> Result<String, String> {
    markup::escape::unescape(language.to_domain(), &text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detection_crosses_the_bridge_intact() {
        assert_eq!(
            detect_structured_language("txt".into(), "".into(), r#"{"a":1}"#.into()),
            StructuredLanguage::Json
        );
        assert_eq!(
            detect_structured_language("yml".into(), "".into(), "".into()),
            StructuredLanguage::Yaml
        );
    }

    #[test]
    fn json_comment_style_reports_no_syntax_with_a_note() {
        let style = structured_comment_style(StructuredLanguage::Json, "json".into());
        assert!(style.line.is_none() && style.block_start.is_none());
        assert!(style.unsupported_note.is_some());
    }

    #[test]
    fn analysis_carries_folds_pairs_and_diagnostics() {
        let a = analyze_structured("{\n  \"a\": 1\n}".into(), StructuredLanguage::Json);
        assert_eq!(a.folds.len(), 1);
        assert_eq!(a.pairs.len(), 1);
        assert!(a.diagnostics.is_empty());
        assert_eq!(a.language, StructuredLanguage::Json);
    }

    #[test]
    fn tokens_carry_kinds_across_the_bridge() {
        let rows = tokenize_structured(r#"{"a": 1}"#.into(), StructuredLanguage::Json);
        assert!(rows[0]
            .tokens
            .iter()
            .any(|t| t.kind == StructuredTokenKind::Key));
    }

    #[test]
    fn formatting_and_escaping_surface_errors_as_err() {
        assert!(format_structured(
            "{".into(),
            StructuredLanguage::Json,
            true,
            "  ".into()
        )
        .is_err());
        assert!(unescape_structured("a & b".into(), StructuredLanguage::Xml).is_err());
        assert_eq!(
            unescape_structured("&lt;a&gt;".into(), StructuredLanguage::Xml).unwrap(),
            "<a>"
        );
    }
}

impl From<StructuredLanguage> for MarkupLanguage {
    fn from(value: StructuredLanguage) -> MarkupLanguage {
        value.to_domain()
    }
}

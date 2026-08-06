//! Structured-format support: JSON, JSON5, YAML and XML.
//!
//! Every format implements one row-driven lexer ([`lexer::MarkupLexer`]), and a
//! single pass over that lexer yields all four things the UI needs — token
//! spans for colouring, fold regions for collapse, bracket pairs for match
//! highlighting, and diagnostics for validation. Deriving them together is what
//! guarantees a fold's extent, its highlighted pair and its error markers all
//! describe the same document.
//!
//! Dart keeps only what is genuinely presentational: which colour a token kind
//! is painted, and where the gutter glyphs go.

pub mod escape;
pub mod json;
pub mod language;
pub mod lexer;
pub mod token;
pub mod xml;
pub mod yaml;

use lexer::{lex_document, split_rows, tokenize_rows, DocumentLex, MarkupLexer};

pub use language::{comment_style, detect_language, CommentStyle, MarkupLanguage};
pub use token::{
    BracketPair, Diagnostic, DiagnosticSeverity, FoldKind, FoldRegion, LexState, MarkupToken,
    MarkupTokenKind, RowTokens,
};

/// Above this many rows the whole-document pass is skipped.
///
/// Colouring still works — the viewport is lexed from a default state, which is
/// exact except for constructs that began before the visible region — but
/// folding and validation are switched off rather than made to re-scan a very
/// large file on every edit. [`MarkupAnalysis::truncated`] tells the UI to say
/// so instead of silently showing an empty error list.
pub const MAX_ANALYSIS_ROWS: usize = 100_000;

/// What a format transform should produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatAction {
    /// Expand onto multiple indented rows.
    Pretty,
    /// Collapse to the smallest equivalent form.
    Compact,
}

/// Everything the whole-document pass produces.
pub struct MarkupAnalysis {
    pub language: MarkupLanguage,
    pub folds: Vec<FoldRegion>,
    pub pairs: Vec<BracketPair>,
    pub diagnostics: Vec<Diagnostic>,
    /// True when the document was too large to analyse; `folds`, `pairs` and
    /// `diagnostics` are empty and mean "not computed", not "none found".
    pub truncated: bool,
}

/// The lexer for a language, or `None` for plain text.
pub fn lexer_for(language: MarkupLanguage) -> Option<Box<dyn MarkupLexer>> {
    match language {
        MarkupLanguage::Json => Some(Box::new(json::JsonLexer::new(false))),
        MarkupLanguage::Json5 => Some(Box::new(json::JsonLexer::new(true))),
        MarkupLanguage::Xml => Some(Box::new(xml::XmlLexer)),
        MarkupLanguage::Yaml => Some(Box::new(yaml::YamlLexer)),
        MarkupLanguage::PlainText => None,
    }
}

/// Structure and diagnostics for a set of rows.
pub fn analyse_rows(rows: &[String], language: MarkupLanguage) -> MarkupAnalysis {
    let empty = |truncated: bool| MarkupAnalysis {
        language,
        folds: Vec::new(),
        pairs: Vec::new(),
        diagnostics: Vec::new(),
        truncated,
    };
    let Some(lexer) = lexer_for(language) else {
        return empty(false);
    };
    if rows.len() > MAX_ANALYSIS_ROWS {
        return empty(true);
    }
    let doc: DocumentLex = lex_document(lexer.as_ref(), rows);
    let text = rows.join("\n");
    let (mut folds, pairs) = match language {
        MarkupLanguage::Json | MarkupLanguage::Json5 => {
            let s = json::structure(rows, &doc.lexemes);
            (s.folds, s.pairs)
        }
        MarkupLanguage::Xml => {
            let s = xml::structure(rows, &doc.lexemes);
            (s.folds, s.pairs)
        }
        MarkupLanguage::Yaml => {
            let s = yaml::structure(rows, &doc.lexemes);
            (s.folds, s.pairs)
        }
        MarkupLanguage::PlainText => (Vec::new(), Vec::new()),
    };
    assign_fold_levels(&mut folds);
    MarkupAnalysis {
        language,
        folds,
        pairs,
        diagnostics: validate_text(&text, language),
        truncated: false,
    }
}

/// Number every fold region by how deeply it nests, outermost = 0, and leave
/// the list in outer-before-inner order.
///
/// Done here rather than in the lexers so that JSON's brace stack, XML's
/// element nesting and YAML's indentation cannot disagree about what a level
/// is. Containment is the only input: a region is inside the last region whose
/// extent still covers it.
///
/// The ordering matters as much as the numbering — `fold to level N` walks this
/// list, and an inner region seen before its parent would be numbered as the
/// parent. Ties on the start row are broken by the wider region first, and ties
/// on both by the earlier opening column, which is what separates `{ "a": [`
/// from the `[` that closes on the same row as its `}`.
fn assign_fold_levels(folds: &mut [FoldRegion]) {
    folds.sort_by(|a, b| {
        a.start_row
            .cmp(&b.start_row)
            .then(b.end_row.cmp(&a.end_row))
            .then(a.start_col.cmp(&b.start_col))
    });
    // End rows of the regions still open at this point in the walk.
    let mut open: Vec<u32> = Vec::new();
    for fold in folds.iter_mut() {
        // A region that outlives the one above it is not inside it. This also
        // covers the plain "the region above already closed" case, since a
        // region never ends before it starts.
        while open.last().is_some_and(|&end| end < fold.end_row) {
            open.pop();
        }
        fold.level = open.len() as u32;
        open.push(fold.end_row);
    }
}

/// The resume checkpoints for a document, for viewport tokenisation.
pub fn checkpoints_for(rows: &[String], language: MarkupLanguage) -> Vec<LexState> {
    match lexer_for(language) {
        Some(lexer) => lex_document(lexer.as_ref(), rows).checkpoints,
        None => Vec::new(),
    }
}

/// Tokens for `rows`, resuming from `start_state` and numbered from `first_row`.
pub fn tokens_for(
    rows: &[String],
    language: MarkupLanguage,
    start_state: LexState,
    first_row: u32,
) -> Vec<RowTokens> {
    match lexer_for(language) {
        Some(lexer) => tokenize_rows(lexer.as_ref(), rows, start_state, first_row),
        None => Vec::new(),
    }
}

/// Validate a whole document.
pub fn validate_text(text: &str, language: MarkupLanguage) -> Vec<Diagnostic> {
    match language {
        MarkupLanguage::Json => json::validate(text, false),
        MarkupLanguage::Json5 => json::validate(text, true),
        MarkupLanguage::Xml => xml::validate(text),
        MarkupLanguage::Yaml => yaml::validate(text),
        MarkupLanguage::PlainText => Vec::new(),
    }
}

/// Pretty-print or minify.
pub fn format_text(
    text: &str,
    language: MarkupLanguage,
    action: FormatAction,
    indent: &str,
) -> Result<String, String> {
    let pretty = action == FormatAction::Pretty;
    match language {
        MarkupLanguage::Json | MarkupLanguage::Json5 => {
            let json5 = language == MarkupLanguage::Json5;
            if pretty {
                json::pretty(text, json5, indent)
            } else {
                json::compact(text, json5)
            }
        }
        MarkupLanguage::Xml => {
            if pretty {
                xml::pretty(text, indent)
            } else {
                xml::compact(text)
            }
        }
        MarkupLanguage::Yaml => {
            if pretty {
                yaml::pretty(text, indent.len().max(1))
            } else {
                yaml::compact(text)
            }
        }
        MarkupLanguage::PlainText => Err(
            "This document is plain text. Set its type to JSON, JSON5, YAML or XML first."
                .to_string(),
        ),
    }
}

/// The bracket or tag pair a caret is on or inside.
///
/// A delimiter the caret touches wins over an enclosing pair, because having
/// just typed or arrowed onto a brace is the common case; otherwise the
/// innermost enclosing pair is used.
pub fn pair_at(pairs: &[BracketPair], row: u32, col: u32) -> Option<BracketPair> {
    let touches = |r: u32, c: u32, len: u32| row == r && col >= c && col <= c + len;
    if let Some(p) = pairs.iter().find(|p| {
        touches(p.open_row, p.open_col, p.open_len) || touches(p.close_row, p.close_col, p.close_len)
    }) {
        return Some(*p);
    }
    pairs
        .iter()
        .filter(|p| {
            (p.open_row, p.open_col) <= (row, col) && (row, col) <= (p.close_row, p.close_col)
        })
        .min_by_key(|p| (p.close_row - p.open_row, p.close_col))
        .copied()
}

/// Split text into rows the way the editor does.
pub fn rows_of(text: &str) -> Vec<String> {
    split_rows(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn analysis_reports_folds_and_diagnostics_together() {
        let rows = rows_of("{\n  \"a\": [1,\n  2]\n}");
        let a = analyse_rows(&rows, MarkupLanguage::Json);
        assert!(!a.folds.is_empty());
        assert!(a.diagnostics.is_empty());
        assert!(!a.truncated);
    }

    #[test]
    fn analysis_of_an_invalid_document_still_reports_structure() {
        let rows = rows_of("{\n  \"a\" 1\n}");
        let a = analyse_rows(&rows, MarkupLanguage::Json);
        assert!(!a.diagnostics.is_empty());
        assert!(!a.folds.is_empty(), "colouring and folding survive an error");
    }

    /// The three lexers derive folds from three different things — a brace
    /// stack, element nesting, indentation — so the levels are asserted on the
    /// same document shape in each, to prove the shared containment pass rather
    /// than three lexers that happen to agree.
    fn levels_of(text: &str, language: MarkupLanguage) -> Vec<(u32, u32, u32)> {
        analyse_rows(&rows_of(text), language)
            .folds
            .iter()
            .map(|f| (f.start_row, f.end_row, f.level))
            .collect()
    }

    #[test]
    fn json_folds_are_levelled_by_nesting() {
        assert_eq!(
            levels_of("{\n  \"a\": {\n    \"b\": 1\n  }\n}", MarkupLanguage::Json),
            vec![(0, 4, 0), (1, 3, 1)]
        );
    }

    #[test]
    fn xml_folds_are_levelled_by_nesting() {
        assert_eq!(
            levels_of("<a>\n  <b>\n    x\n  </b>\n</a>", MarkupLanguage::Xml),
            vec![(0, 4, 0), (1, 3, 1)]
        );
    }

    #[test]
    fn yaml_folds_are_levelled_by_nesting() {
        assert_eq!(
            levels_of("a:\n  b:\n    c: 1\n", MarkupLanguage::Yaml),
            vec![(0, 2, 0), (1, 2, 1)]
        );
    }

    #[test]
    fn a_sibling_region_returns_to_its_parents_level() {
        // A depth counter that only ever increments would give the second
        // sibling level 2 instead of 1.
        assert_eq!(
            levels_of(
                "{\n  \"a\": {\n    \"x\": 1\n  },\n  \"b\": {\n    \"y\": 2\n  }\n}",
                MarkupLanguage::Json
            ),
            vec![(0, 7, 0), (1, 3, 1), (4, 6, 1)]
        );
    }

    #[test]
    fn an_outer_region_is_levelled_before_an_inner_one_starting_on_the_same_row() {
        // Both regions span rows 0..2; only the opening column tells them
        // apart, so the ordering has to break that tie or the inner `[` can
        // come out as the outer one.
        let folds = analyse_rows(&rows_of("{ \"a\": [\n  1\n] }"), MarkupLanguage::Json).folds;
        let seen: Vec<(u32, u32)> = folds.iter().map(|f| (f.start_col, f.level)).collect();
        assert_eq!(seen, vec![(0, 0), (7, 1)]);
    }

    #[test]
    fn plain_text_analyses_to_nothing_without_claiming_truncation() {
        let a = analyse_rows(&rows_of("hello"), MarkupLanguage::PlainText);
        assert!(a.diagnostics.is_empty() && !a.truncated);
    }

    #[test]
    fn a_document_beyond_the_cap_is_marked_truncated_not_clean() {
        let rows: Vec<String> = (0..MAX_ANALYSIS_ROWS + 1).map(|_| "x".to_string()).collect();
        let a = analyse_rows(&rows, MarkupLanguage::Json);
        assert!(a.truncated);
        assert!(a.diagnostics.is_empty());
    }

    #[test]
    fn formatting_dispatches_per_language() {
        assert_eq!(
            format_text("{\"a\":1}", MarkupLanguage::Json, FormatAction::Pretty, "  ").unwrap(),
            "{\n  \"a\": 1\n}"
        );
        assert_eq!(
            format_text("<a><b/></a>", MarkupLanguage::Xml, FormatAction::Pretty, "  ").unwrap(),
            "<a>\n  <b/>\n</a>"
        );
        assert_eq!(
            format_text("a:\n    b: 1", MarkupLanguage::Yaml, FormatAction::Pretty, "  ").unwrap(),
            "a:\n  b: 1"
        );
    }

    #[test]
    fn formatting_plain_text_explains_rather_than_mangling() {
        assert!(format_text("x", MarkupLanguage::PlainText, FormatAction::Pretty, "  ").is_err());
    }

    #[test]
    fn a_caret_on_a_brace_finds_its_partner() {
        let rows = rows_of("{\n  \"a\": 1\n}");
        let a = analyse_rows(&rows, MarkupLanguage::Json);
        let p = pair_at(&a.pairs, 0, 0).expect("caret on the opening brace");
        assert_eq!((p.close_row, p.close_col), (2, 0));
    }

    #[test]
    fn a_caret_inside_a_pair_finds_the_innermost_one() {
        let rows = rows_of("{\n  \"a\": [\n    1\n  ]\n}");
        let a = analyse_rows(&rows, MarkupLanguage::Json);
        let p = pair_at(&a.pairs, 2, 4).expect("caret inside the array");
        assert_eq!((p.open_row, p.close_row), (1, 3));
    }

    #[test]
    fn a_caret_with_no_enclosing_pair_matches_nothing() {
        let rows = rows_of("1");
        let a = analyse_rows(&rows, MarkupLanguage::Json);
        assert!(pair_at(&a.pairs, 0, 0).is_none());
    }

    #[test]
    fn xml_pairs_match_tags_not_angle_brackets() {
        let rows = rows_of("<r>\n  <a/>\n</r>");
        let a = analyse_rows(&rows, MarkupLanguage::Xml);
        let p = pair_at(&a.pairs, 0, 0).unwrap();
        assert_eq!(p.open_len, 2); // `<r`
        assert_eq!(p.close_len, 4); // `</r>`
    }

    /// The property the viewport-painting path depends on.
    #[test]
    fn viewport_tokens_resume_from_a_checkpoint() {
        let body = (0..300)
            .map(|i| format!("  \"k{i}\": {i},"))
            .collect::<Vec<_>>()
            .join("\n");
        let text = format!("{{\n{body}\n  \"last\": 0\n}}");
        let rows = rows_of(&text);
        let checkpoints = checkpoints_for(&rows, MarkupLanguage::Json);
        let (resume_row, state) = lexer::resume_point(&checkpoints, 200);

        let lexer = lexer_for(MarkupLanguage::Json).unwrap();
        let mut warm = state;
        let mut scratch = lexer::RowLexemes::new();
        for row in &rows[resume_row as usize..200] {
            scratch.clear();
            warm = lexer.lex_row(row, warm, &mut scratch);
        }

        let partial = tokens_for(&rows[200..210], MarkupLanguage::Json, warm, 200);
        let full = tokens_for(&rows, MarkupLanguage::Json, LexState::top(), 0);
        assert_eq!(partial, full[200..210].to_vec());
        // Keys are still recognised as keys that far into the document, which
        // only the carried container stack can tell us.
        assert!(partial[0]
            .tokens
            .iter()
            .any(|t| t.kind == MarkupTokenKind::Key));
    }
}

#[cfg(test)]
mod cost {
    use super::*;

    /// What the whole-document pass actually costs, so the auto-validation
    /// debounce can be judged against a number instead of a worry.
    ///
    /// Ignored by default — it is a measurement, not an assertion, and the
    /// timings are meaningless in a debug build. Run it with:
    /// `cargo test --release -- --ignored --nocapture markup::cost`
    #[test]
    #[ignore]
    fn whole_document_pass_timing() {
        for entries in [1_000usize, 10_000, 50_000, 100_000] {
            let mut rows = vec!["{".to_string()];
            for i in 0..entries {
                let comma = if i + 1 == entries { "" } else { "," };
                rows.push(format!(
                    "  \"key_{i}\": {{ \"a\": {i}, \"b\": \"v{i}\" }}{comma}"
                ));
            }
            rows.push("}".to_string());
            let n = rows.len();
            let start = std::time::Instant::now();
            let a = analyse_rows(&rows, MarkupLanguage::Json);
            println!(
                "{n:>7} rows  {:>8.1} ms  folds {:>6}  diagnostics {:>4}  truncated {}",
                start.elapsed().as_secs_f64() * 1000.0,
                a.folds.len(),
                a.diagnostics.len(),
                a.truncated
            );
        }
    }
}

//! Which format a document is, and what its comment syntax is.
//!
//! This is the single detection path. Before it existed there were two — an
//! extension table in `edit_ops` that drove comment symbols, and an alias table
//! in Dart that drove colouring — which is why a `.json` document was commented
//! with `//` (the C-style default) while being coloured as JSON. Anything that
//! needs to know a document's format asks here.

/// A structured format the app understands, or `PlainText` for everything else.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkupLanguage {
    PlainText,
    Json,
    Json5,
    Yaml,
    Xml,
}

impl MarkupLanguage {
    pub fn label(&self) -> String {
        match self {
            MarkupLanguage::PlainText => "Plain Text",
            MarkupLanguage::Json => "JSON",
            MarkupLanguage::Json5 => "JSON5",
            MarkupLanguage::Yaml => "YAML",
            MarkupLanguage::Xml => "XML",
        }
        .to_string()
    }

    /// True for the formats with a lexer, i.e. everything but `PlainText`.
    pub fn is_structured(&self) -> bool {
        !matches!(self, MarkupLanguage::PlainText)
    }

    /// Stable identifier for persistence.
    ///
    /// Deliberately separate from [`label`](Self::label): a label is display
    /// text and may be reworded at any time, whereas these strings are written
    /// into the user's session database and have to keep meaning the same
    /// thing across releases.
    pub fn id(&self) -> &'static str {
        match self {
            MarkupLanguage::PlainText => "plaintext",
            MarkupLanguage::Json => "json",
            MarkupLanguage::Json5 => "json5",
            MarkupLanguage::Yaml => "yaml",
            MarkupLanguage::Xml => "xml",
        }
    }

    /// The inverse of [`id`](Self::id). `None` for anything unrecognised, so a
    /// database written by a newer build — or a corrupted value — degrades to
    /// automatic detection instead of failing the load.
    pub fn from_id(id: &str) -> Option<MarkupLanguage> {
        match id {
            "plaintext" => Some(MarkupLanguage::PlainText),
            "json" => Some(MarkupLanguage::Json),
            "json5" => Some(MarkupLanguage::Json5),
            "yaml" => Some(MarkupLanguage::Yaml),
            "xml" => Some(MarkupLanguage::Xml),
            _ => None,
        }
    }
}

/// How a language spells comments.
///
/// `None` on both means the format has none. That is a fact worth stating
/// rather than papering over: strict JSON genuinely cannot carry a comment, and
/// inserting `//` would produce a document that no longer parses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommentStyle {
    pub line: Option<String>,
    pub block_start: Option<String>,
    pub block_end: Option<String>,
    /// Shown to the user when the format has no comment syntax, explaining why
    /// the operation is unavailable.
    pub unsupported_note: Option<String>,
}

impl CommentStyle {
    fn none(note: &str) -> CommentStyle {
        CommentStyle {
            line: None,
            block_start: None,
            block_end: None,
            unsupported_note: Some(note.to_string()),
        }
    }

    fn new(line: Option<&str>, block: Option<(&str, &str)>) -> CommentStyle {
        CommentStyle {
            line: line.map(str::to_string),
            block_start: block.map(|(s, _)| s.to_string()),
            block_end: block.map(|(_, e)| e.to_string()),
            unsupported_note: None,
        }
    }

    pub fn block(&self) -> Option<(&str, &str)> {
        match (&self.block_start, &self.block_end) {
            (Some(s), Some(e)) => Some((s.as_str(), e.as_str())),
            _ => None,
        }
    }

    pub fn has_any(&self) -> bool {
        self.line.is_some() || self.block().is_some()
    }
}

/// The comment syntax for a document.
///
/// A detected structured format wins over the extension, because the format is
/// the more specific fact: a YAML document saved as `notes.txt` still comments
/// with `#`. Everything else falls back to the extension table.
pub fn comment_style(language: MarkupLanguage, extension: &str) -> CommentStyle {
    match language {
        MarkupLanguage::Json => CommentStyle::none(
            "JSON has no comment syntax. Save the document as JSON5 to use comments.",
        ),
        MarkupLanguage::Json5 => CommentStyle::new(Some("//"), Some(("/*", "*/"))),
        MarkupLanguage::Yaml => CommentStyle::new(Some("#"), None),
        MarkupLanguage::Xml => CommentStyle::new(None, Some(("<!--", "-->"))),
        MarkupLanguage::PlainText => comment_style_for_extension(extension),
    }
}

/// Comment syntax by file extension, for the languages with no lexer here.
fn comment_style_for_extension(extension: &str) -> CommentStyle {
    match extension.trim().trim_start_matches('.').to_lowercase().as_str() {
        "rs" | "go" | "cpp" | "cc" | "c" | "h" | "hpp" | "java" | "kt" | "kts" | "scala"
        | "swift" | "dart" | "js" | "jsx" | "ts" | "tsx" | "cs" | "php" | "groovy" => {
            CommentStyle::new(Some("//"), Some(("/*", "*/")))
        }
        "py" | "sh" | "bash" | "zsh" | "rb" | "pl" | "pm" | "r" | "coffee" | "toml"
        | "properties" | "conf" | "cfg" | "dockerfile" | "makefile" | "gitignore" => {
            CommentStyle::new(Some("#"), None)
        }
        "html" | "htm" | "svg" | "xhtml" | "vue" | "md" | "markdown" => {
            CommentStyle::new(None, Some(("<!--", "-->")))
        }
        "css" | "scss" | "less" => CommentStyle::new(None, Some(("/*", "*/"))),
        "sql" => CommentStyle::new(Some("--"), Some(("/*", "*/"))),
        "ini" | "bat" | "cmd" | "reg" => CommentStyle::new(Some(";"), None),
        "lua" => CommentStyle::new(Some("--"), Some(("--[[", "]]"))),
        "vim" => CommentStyle::new(Some("\""), None),
        "hs" => CommentStyle::new(Some("--"), Some(("{-", "-}"))),
        "tex" | "erl" => CommentStyle::new(Some("%"), None),
        "asm" | "s" => CommentStyle::new(Some(";"), None),
        // C-style is the least surprising default for an unknown source file.
        _ => CommentStyle::new(Some("//"), Some(("/*", "*/"))),
    }
}

fn normalise(value: &str) -> String {
    value.trim().trim_start_matches('.').to_lowercase()
}

fn by_extension(extension: &str) -> Option<MarkupLanguage> {
    Some(match normalise(extension).as_str() {
        "json" => MarkupLanguage::Json,
        "json5" | "jsonc" => MarkupLanguage::Json5,
        "yaml" | "yml" => MarkupLanguage::Yaml,
        "xml" | "xsd" | "xsl" | "xslt" | "svg" | "xhtml" | "rss" | "atom" | "plist" | "pom"
        | "wsdl" | "xaml" | "csproj" | "props" | "storyboard" => MarkupLanguage::Xml,
        _ => return None,
    })
}

fn by_content_type(content_type: &str) -> Option<MarkupLanguage> {
    let value = normalise(content_type);
    // Strip any `; charset=…` parameter before matching.
    let value = value.split(';').next().unwrap_or("").trim().to_string();
    Some(match value.as_str() {
        "json" | "application/json" | "text/json" => MarkupLanguage::Json,
        "json5" | "application/json5" | "jsonc" => MarkupLanguage::Json5,
        "yaml" | "yml" | "application/yaml" | "text/yaml" | "application/x-yaml" => {
            MarkupLanguage::Yaml
        }
        "xml" | "application/xml" | "text/xml" | "image/svg+xml" => MarkupLanguage::Xml,
        _ => return None,
    })
}

/// How much of an unsaved document to look at when sniffing. Enough to see the
/// shape without reading a large file into the decision.
const SNIFF_BYTES: usize = 8192;

/// Detect a document's format.
///
/// Extension first, then content type, then the content itself. The content
/// pass is what makes an unsaved scratch buffer — no filename, extension
/// defaulted to `txt` — colour and comment correctly as soon as it looks like
/// JSON, YAML or XML.
pub fn detect_language(extension: &str, content_type: &str, sample: &str) -> MarkupLanguage {
    if let Some(language) = by_extension(extension) {
        // `.json` files legitimately contain JSON5 in some toolchains; if the
        // content says so, believe the content.
        if language == MarkupLanguage::Json && super::json::uses_json5_syntax(sample) {
            return MarkupLanguage::Json5;
        }
        return language;
    }
    if let Some(language) = by_content_type(content_type) {
        return language;
    }
    sniff(sample)
}

/// Guess a format from content alone.
fn sniff(sample: &str) -> MarkupLanguage {
    let sample = &sample[..sample.len().min(SNIFF_BYTES)];
    let trimmed = sample.trim_start_matches('\u{feff}').trim_start();
    if trimmed.is_empty() {
        return MarkupLanguage::PlainText;
    }

    if trimmed.starts_with("<?xml") || trimmed.starts_with("<!DOCTYPE") {
        return MarkupLanguage::Xml;
    }
    if looks_like_xml(sample, trimmed) {
        return MarkupLanguage::Xml;
    }

    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        // Decide strict-vs-JSON5 with the real lexer rather than a regex, so a
        // `//` inside a string is not mistaken for a comment.
        if super::json::validate(sample, false).is_empty() {
            return MarkupLanguage::Json;
        }
        if super::json::validate(sample, true).is_empty() {
            return MarkupLanguage::Json5;
        }
        // Looks like JSON but does not parse — most likely a document being
        // typed. Prefer the more permissive dialect so colouring stays useful.
        return if super::json::uses_json5_syntax(sample) {
            MarkupLanguage::Json5
        } else {
            MarkupLanguage::Json
        };
    }

    if looks_like_yaml(trimmed) {
        return MarkupLanguage::Yaml;
    }
    MarkupLanguage::PlainText
}

/// Does this look like XML?
///
/// Structural, not well-formed. Two things make validity the wrong test here:
/// the sample is only the first few kilobytes, so a real document's sample is
/// almost never balanced; and a document being typed is invalid most of the
/// time. Requiring validity meant a large XML file read as plain text, and a
/// single stray character before the root element flipped an XML file back to
/// plain text mid-edit.
///
/// Instead the sample is lexed and its markup counted. Prose containing a
/// stray `<` produces `Invalid` lexemes rather than tag names, which is what
/// keeps "a < b and c < d" out.
fn looks_like_xml(sample: &str, trimmed: &str) -> bool {
    let rows = super::lexer::split_rows(sample);
    let doc = super::lexer::lex_document(&super::xml::XmlLexer, &rows);

    let mut tags = 0usize;
    let mut invalid = 0usize;
    for lexeme in &doc.lexemes {
        match lexeme.kind {
            super::MarkupTokenKind::TagName => tags += 1,
            super::MarkupTokenKind::Invalid => invalid += 1,
            _ => {}
        }
    }
    if tags < 2 || invalid > tags / 4 {
        return false;
    }
    // A document that opens with markup needs no further evidence. One that
    // does not — prose with an `<b>` in it, or XML with a stray character typed
    // in front of the root — has to show sustained markup to qualify.
    trimmed.starts_with('<') || tags >= 4
}

/// A conservative YAML shape test.
///
/// YAML is permissive enough that almost any prose parses as a scalar, so
/// parsing proves nothing — the shape has to be checked directly.
///
/// The rule that does the real work: **every non-blank, non-comment row at
/// indent 0 must be structural** — a mapping row, a sequence item, or a
/// document marker. Indented rows are values or continuations and are not
/// examined. A Markdown file fails this immediately, because its prose sits at
/// indent 0 right alongside its headings, and a prose line is neither a mapping
/// nor a sequence item.
///
/// Two further requirements, when the document carries no `---` marker or
/// `%YAML` directive:
///
/// - at least one *mapping* row, not only sequence items, so a Markdown bullet
///   list under a heading is not claimed; and
/// - at least two structural rows, so a single `Title: something` line in a note
///   is not enough.
///
/// The deliberate cost: a top-level YAML sequence with no marker
/// (`- a\n- b`) reads as plain text, and so does a flow collection wrapped
/// onto an unindented continuation row. Both are rare, both only matter when
/// the file has no extension and no content type, and both are fixed by saving
/// the file or setting its type.
fn looks_like_yaml(sample: &str) -> bool {
    let mut structural = 0usize;
    let mut mappings = 0usize;
    let mut marker = false;
    let mut examined = 0usize;

    for row in sample.lines() {
        let trimmed = row.trim();
        if trimmed.is_empty() {
            continue;
        }
        // Only indent-0 rows are judged; deeper rows are values, sequence
        // entries or block-scalar content belonging to a row above.
        if row.starts_with(' ') || row.starts_with('\t') {
            continue;
        }
        if trimmed.starts_with('#') {
            // Could be a YAML comment or a Markdown heading. Neither confirms
            // nor denies, so it is skipped — the prose *around* a Markdown
            // heading is what gives the file away.
            continue;
        }

        examined += 1;
        if examined > 40 {
            break;
        }

        if trimmed == "---" || trimmed == "..." || trimmed.starts_with("%YAML") {
            // Also Markdown's horizontal rule and front-matter fence, so it is
            // a hint rather than a verdict.
            marker = true;
            continue;
        }
        if trimmed.starts_with("- ") || trimmed == "-" {
            structural += 1;
            continue;
        }
        if is_mapping_row(trimmed) {
            structural += 1;
            mappings += 1;
            continue;
        }
        // An indent-0 row that is none of the above. Whatever this document is,
        // it is not a YAML mapping or sequence.
        return false;
    }

    if structural == 0 {
        return false;
    }
    if marker {
        return true;
    }
    mappings > 0 && structural >= 2
}

/// `key:` or `key: value`, with a key that has no spaces — the shape a YAML
/// mapping row takes and ordinary prose usually does not.
fn is_mapping_row(row: &str) -> bool {
    let Some(colon) = row.find(':') else {
        return false;
    };
    let key = &row[..colon];
    if key.is_empty() || key.contains(' ') || key.contains('\t') {
        return false;
    }
    let rest = &row[colon + 1..];
    rest.is_empty() || rest.starts_with(' ')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detect(ext: &str, ct: &str, sample: &str) -> MarkupLanguage {
        detect_language(ext, ct, sample)
    }

    const ALL: [MarkupLanguage; 5] = [
        MarkupLanguage::PlainText,
        MarkupLanguage::Json,
        MarkupLanguage::Json5,
        MarkupLanguage::Yaml,
        MarkupLanguage::Xml,
    ];

    #[test]
    fn every_language_round_trips_through_its_id() {
        for language in ALL {
            assert_eq!(MarkupLanguage::from_id(language.id()), Some(language));
        }
    }

    #[test]
    fn ids_are_distinct() {
        let mut ids: Vec<&str> = ALL.iter().map(|l| l.id()).collect();
        ids.sort_unstable();
        let count = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), count);
    }

    #[test]
    fn an_unknown_id_is_none_rather_than_a_default() {
        // A store written by a newer build must fall back to detection, not
        // silently pin every document to plain text.
        assert_eq!(MarkupLanguage::from_id("toml"), None);
        assert_eq!(MarkupLanguage::from_id(""), None);
        assert_eq!(MarkupLanguage::from_id("JSON"), None);
    }

    #[test]
    fn the_extension_wins_when_it_is_known() {
        assert_eq!(detect("json", "", "{}"), MarkupLanguage::Json);
        assert_eq!(detect(".YML", "", ""), MarkupLanguage::Yaml);
        assert_eq!(detect("svg", "", ""), MarkupLanguage::Xml);
        assert_eq!(detect("json5", "", ""), MarkupLanguage::Json5);
    }

    #[test]
    fn a_json_file_using_json5_syntax_is_detected_as_json5() {
        assert_eq!(
            detect("json", "", "{\n// a comment\n\"a\": 1}"),
            MarkupLanguage::Json5
        );
    }

    #[test]
    fn the_content_type_is_used_when_the_extension_is_not_known() {
        assert_eq!(detect("txt", "JSON", "{}"), MarkupLanguage::Json);
        assert_eq!(
            detect("txt", "application/xml; charset=utf-8", ""),
            MarkupLanguage::Xml
        );
    }

    /// The unsaved-scratch-buffer case: no useful extension, no content type.
    #[test]
    fn content_alone_identifies_an_unsaved_document() {
        assert_eq!(detect("txt", "Plain Text", r#"{"a": 1}"#), MarkupLanguage::Json);
        assert_eq!(detect("txt", "Plain Text", "<r><a/></r>"), MarkupLanguage::Xml);
        assert_eq!(
            detect("txt", "Plain Text", "<?xml version=\"1.0\"?><r/>"),
            MarkupLanguage::Xml
        );
        assert_eq!(
            detect("txt", "Plain Text", "name: textutilz\nversion: 1.0"),
            MarkupLanguage::Yaml
        );
        assert_eq!(detect("txt", "Plain Text", "---\na: 1"), MarkupLanguage::Yaml);
    }

    #[test]
    fn sniffing_tells_json_from_json5() {
        assert_eq!(detect("txt", "", "{\"a\":1}"), MarkupLanguage::Json);
        assert_eq!(detect("txt", "", "{a: 1, /* c */}"), MarkupLanguage::Json5);
    }

    #[test]
    fn prose_is_not_claimed_as_yaml() {
        assert_eq!(
            detect("txt", "", "Dear Sander,\n\nThanks for the note.\nSee you."),
            MarkupLanguage::PlainText
        );
        // A single colon line among prose is not enough.
        assert_eq!(
            detect(
                "txt",
                "",
                "Shopping\nmilk and bread\nNote: buy cheese\nthen go home\nand rest"
            ),
            MarkupLanguage::PlainText
        );
    }

    /// Markdown is the false positive that mattered: a heading looks like a
    /// YAML comment, and any `Word: text` line looks like a mapping.
    #[test]
    fn markdown_is_not_claimed_as_yaml() {
        let readme = "# textutilz\n\nA text utility.\n\n## Install\n\nRun: make\n\n\
                      ## Notes\n\n- fast\n- small\n";
        assert_eq!(detect("txt", "", readme), MarkupLanguage::PlainText);

        // Headings plus a bullet list and nothing else: valid YAML as a
        // sequence, but the missing mapping row keeps it out.
        assert_eq!(
            detect("txt", "", "# Title\n- one\n- two\n"),
            MarkupLanguage::PlainText
        );

        // A fenced code block sits at indent 0 and is not structural.
        assert_eq!(
            detect("txt", "", "key: value\nother: 1\n```\ncode\n```\n"),
            MarkupLanguage::PlainText
        );

        // Markdown front matter followed by Markdown is Markdown, even though
        // the front matter itself is YAML.
        let front_matter = "---\ntitle: Post\n---\n\n# Heading\n\nSome prose here.\n";
        assert_eq!(detect("txt", "", front_matter), MarkupLanguage::PlainText);

        // A horizontal rule between prose sections must not trigger on `---`.
        assert_eq!(
            detect("txt", "", "Intro text\n\n---\n\nMore text\n"),
            MarkupLanguage::PlainText
        );
    }

    /// The reported failure: a large XML file, and one mid-edit with a stray
    /// character typed before the root element.
    #[test]
    fn xml_is_detected_without_the_sample_being_well_formed() {
        // A sample cut off mid-document, as any file past SNIFF_BYTES is.
        let truncated = "<form-definitions>\n  <form-layouts>\n    <layout id=\"a\">\n      <mode>vertical</mode>\n";
        assert_eq!(detect("txt", "", truncated), MarkupLanguage::Xml);

        // A stray character typed in front of the root element.
        let mid_edit = "x<form-definitions>\n  <layout id=\"a\"/>\n  <layout id=\"b\"/>\n</form-definitions>";
        assert_eq!(detect("txt", "", mid_edit), MarkupLanguage::Xml);

        // Unbalanced tags, as while typing a new element.
        assert_eq!(
            detect("txt", "", "<r>\n  <a>\n    <b>\n"),
            MarkupLanguage::Xml
        );
    }

    /// The file extension is the strongest signal there is and must win
    /// outright, whatever the content currently looks like.
    #[test]
    fn an_xml_extension_wins_over_any_content() {
        assert_eq!(detect("xml", "", ""), MarkupLanguage::Xml);
        assert_eq!(detect("xml", "", "not markup at all"), MarkupLanguage::Xml);
        assert_eq!(detect(".XML", "", "{\"a\": 1}"), MarkupLanguage::Xml);
        assert_eq!(detect("svg", "", "half typed <"), MarkupLanguage::Xml);
    }

    #[test]
    fn prose_with_angle_brackets_is_not_xml() {
        assert_eq!(
            detect("txt", "", "if a < b and c < d then stop\nsee the notes"),
            MarkupLanguage::PlainText
        );
        // A couple of inline tags in prose is not a markup document.
        assert_eq!(
            detect("txt", "", "Some notes with <b>bold</b> in the middle.\nMore prose here."),
            MarkupLanguage::PlainText
        );
    }

    #[test]
    fn real_yaml_is_still_recognised() {
        assert_eq!(
            detect("txt", "", "name: textutilz\nversion: 1.0\n"),
            MarkupLanguage::Yaml
        );
        // Comments and nesting do not get in the way.
        let doc = "# config\nname: x\ndeps:\n  - a\n  - b\nnested:\n  key: 1\n";
        assert_eq!(detect("txt", "", doc), MarkupLanguage::Yaml);
        // A document marker carries a sequence on its own.
        assert_eq!(detect("txt", "", "---\n- a\n- b\n"), MarkupLanguage::Yaml);
        assert_eq!(
            detect("txt", "", "%YAML 1.2\n---\nkey: value\n"),
            MarkupLanguage::Yaml
        );
        // A block scalar's content is indented, so it is never judged.
        assert_eq!(
            detect("txt", "", "script: |\n  not: a mapping\n  just text\nafter: 1\n"),
            MarkupLanguage::Yaml
        );
    }

    /// One mapping row is ambiguous with prose, so it is left as plain text.
    #[test]
    fn a_single_mapping_row_is_not_enough() {
        assert_eq!(detect("txt", "", "Note: something\n"), MarkupLanguage::PlainText);
    }

    #[test]
    fn an_empty_document_is_plain_text() {
        assert_eq!(detect("txt", "", ""), MarkupLanguage::PlainText);
        assert_eq!(detect("txt", "", "   \n  "), MarkupLanguage::PlainText);
    }

    #[test]
    fn a_leading_byte_order_mark_does_not_defeat_sniffing() {
        assert_eq!(detect("txt", "", "\u{feff}{\"a\":1}"), MarkupLanguage::Json);
    }

    // ---- comment styles ----------------------------------------------------

    /// The bug this module exists to fix.
    #[test]
    fn json_reports_no_comment_syntax_instead_of_defaulting_to_slashes() {
        let style = comment_style(MarkupLanguage::Json, "json");
        assert!(!style.has_any());
        assert!(style.unsupported_note.unwrap().contains("JSON5"));
    }

    #[test]
    fn each_format_gets_its_own_comment_syntax() {
        assert_eq!(comment_style(MarkupLanguage::Yaml, "").line.unwrap(), "#");
        assert_eq!(
            comment_style(MarkupLanguage::Xml, "").block().unwrap(),
            ("<!--", "-->")
        );
        assert_eq!(comment_style(MarkupLanguage::Json5, "").line.unwrap(), "//");
        assert!(comment_style(MarkupLanguage::Xml, "").line.is_none());
    }

    /// A YAML document saved as `.txt` must still comment with `#`. Keying on
    /// the extension alone is exactly what got this wrong before.
    #[test]
    fn a_detected_format_beats_the_file_extension() {
        assert_eq!(comment_style(MarkupLanguage::Yaml, "txt").line.unwrap(), "#");
    }

    #[test]
    fn unknown_extensions_still_get_the_c_style_default() {
        assert_eq!(
            comment_style(MarkupLanguage::PlainText, "zzz").line.unwrap(),
            "//"
        );
        assert_eq!(
            comment_style(MarkupLanguage::PlainText, "py").line.unwrap(),
            "#"
        );
        assert_eq!(
            comment_style(MarkupLanguage::PlainText, "sql").line.unwrap(),
            "--"
        );
    }
}

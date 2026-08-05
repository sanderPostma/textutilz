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

impl Clone for SpanScope {
    fn clone(&self) -> Self {
        SpanScope {
            start_row: self.start_row,
            start_col: self.start_col,
            end_row: self.end_row,
            end_col: self.end_col,
        }
    }
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
                let v = u8::from_str_radix(&hex, 16)?;
                out.push(v as char);
            }
            'u' => {
                let hex: String = (&mut it).take(4).collect();
                if hex.len() != 4 {
                    anyhow::bail!("\\u needs 4 hex digits");
                }
                let v = u32::from_str_radix(&hex, 16)?;
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
///
/// Rust-internal only: `Regex` cannot cross the bridge, so this is not
/// callable from Dart.
#[flutter_rust_bridge::frb(ignore)]
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
///
/// Rust-internal only: `Captures` cannot cross the bridge, so this is not
/// callable from Dart.
#[flutter_rust_bridge::frb(ignore)]
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

//! Escaping and unescaping, per format.
//!
//! The operation people actually reach for is unescape: pasting
//! `&lt;field&gt;38&lt;/field&gt;` out of a log or an attribute and wanting the
//! markup back. Escape is its inverse, for pasting markup *into* an attribute
//! or a string literal.
//!
//! Unescape returns a `Result` because malformed input is a real answer worth
//! reporting — a lone `\u12` or a `&#xZZ;` means the selection was not what the
//! user thought it was, and silently leaving it be would hide that.

use super::language::MarkupLanguage;

/// Escape text so it can be embedded in a document of this format.
pub fn escape(language: MarkupLanguage, text: &str) -> Result<String, String> {
    match language {
        MarkupLanguage::Xml => Ok(escape_xml(text)),
        MarkupLanguage::Json | MarkupLanguage::Json5 | MarkupLanguage::Yaml => {
            Ok(escape_json_string(text))
        }
        MarkupLanguage::PlainText => Err(unsupported()),
    }
}

/// Turn escape sequences back into the characters they stand for.
pub fn unescape(language: MarkupLanguage, text: &str) -> Result<String, String> {
    match language {
        MarkupLanguage::Xml => unescape_xml(text),
        MarkupLanguage::Json | MarkupLanguage::Json5 | MarkupLanguage::Yaml => {
            unescape_json_string(text)
        }
        MarkupLanguage::PlainText => Err(unsupported()),
    }
}

fn unsupported() -> String {
    "Plain text has no escaping scheme. Set the document's type to JSON, JSON5, YAML or XML first."
        .to_string()
}

// ---- XML -------------------------------------------------------------------

/// Escape the five characters XML gives predefined entities.
///
/// `>` does not strictly need escaping in content, but escaping it keeps the
/// result safe to paste anywhere, including inside a CDATA-adjacent `]]>`.
fn escape_xml(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c => out.push(c),
        }
    }
    out
}

fn unescape_xml(text: &str) -> Result<String, String> {
    let mut out = String::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut i = 0usize;
    while i < text.len() {
        if bytes[i] != b'&' {
            let next = next_char_boundary(text, i);
            out.push_str(&text[i..next]);
            i = next;
            continue;
        }
        let Some(semi) = text[i..].find(';').map(|p| p + i) else {
            return Err(format!(
                "Unterminated entity reference at position {}; `&` must be written `&amp;`.",
                i + 1
            ));
        };
        let body = &text[i + 1..semi];
        let resolved = match body {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ if body.starts_with("#x") || body.starts_with("#X") => {
                Some(char_from_code(&body[2..], 16, i)?)
            }
            _ if body.starts_with('#') => Some(char_from_code(&body[1..], 10, i)?),
            _ => None,
        };
        match resolved {
            Some(c) => {
                out.push(c);
                i = semi + 1;
            }
            None => {
                return Err(format!(
                    "Unknown entity `&{body};` at position {}. XML predefines only &amp; &lt; &gt; &quot; &apos;.",
                    i + 1
                ))
            }
        }
    }
    Ok(out)
}

fn char_from_code(digits: &str, radix: u32, at: usize) -> Result<char, String> {
    let code = u32::from_str_radix(digits, radix)
        .map_err(|_| format!("`{digits}` is not a valid character code at position {}.", at + 1))?;
    char::from_u32(code)
        .ok_or_else(|| format!("Character code {code} at position {} is not valid.", at + 1))
}

// ---- JSON / JSON5 / YAML double-quoted strings -----------------------------

/// Escape for a double-quoted string. The escapes are the ones JSON defines,
/// which YAML's double-quoted style also accepts.
fn escape_json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn unescape_json_string(text: &str) -> Result<String, String> {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.char_indices().peekable();
    while let Some((at, ch)) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        let Some((_, esc)) = chars.next() else {
            return Err(format!(
                "The text ends with a lone backslash at position {}.",
                at + 1
            ));
        };
        match esc {
            '"' => out.push('"'),
            '\'' => out.push('\''),
            '\\' => out.push('\\'),
            '/' => out.push('/'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'b' => out.push('\u{8}'),
            'f' => out.push('\u{c}'),
            '0' => out.push('\0'),
            'u' => {
                let first = take_hex(&mut chars, 4, at)?;
                // A high surrogate is only half a character; pair it with the
                // low surrogate that must follow, or the result is invalid.
                if (0xD800..0xDC00).contains(&first) {
                    let low = expect_low_surrogate(&mut chars, at)?;
                    let combined =
                        0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00);
                    out.push(char::from_u32(combined).ok_or_else(|| {
                        format!("Invalid surrogate pair at position {}.", at + 1)
                    })?);
                } else {
                    out.push(char::from_u32(first).ok_or_else(|| {
                        format!("`\\u{first:04X}` at position {} is not a character.", at + 1)
                    })?);
                }
            }
            other => {
                return Err(format!(
                    "Unknown escape `\\{other}` at position {}.",
                    at + 1
                ))
            }
        }
    }
    Ok(out)
}

fn take_hex(
    chars: &mut std::iter::Peekable<std::str::CharIndices>,
    count: usize,
    at: usize,
) -> Result<u32, String> {
    let mut value = 0u32;
    for _ in 0..count {
        let Some((_, c)) = chars.next() else {
            return Err(format!(
                "Incomplete `\\u` escape at position {}; four hex digits are required.",
                at + 1
            ));
        };
        let digit = c.to_digit(16).ok_or_else(|| {
            format!("`{c}` is not a hex digit in the `\\u` escape at position {}.", at + 1)
        })?;
        value = value * 16 + digit;
    }
    Ok(value)
}

fn expect_low_surrogate(
    chars: &mut std::iter::Peekable<std::str::CharIndices>,
    at: usize,
) -> Result<u32, String> {
    let missing = || {
        format!(
            "The `\\u` escape at position {} is a high surrogate and must be followed by a low surrogate.",
            at + 1
        )
    };
    match (chars.next(), chars.next()) {
        (Some((_, '\\')), Some((_, 'u'))) => {
            let low = take_hex(chars, 4, at)?;
            if (0xDC00..0xE000).contains(&low) {
                Ok(low)
            } else {
                Err(missing())
            }
        }
        _ => Err(missing()),
    }
}

fn next_char_boundary(text: &str, i: usize) -> usize {
    let mut p = i + 1;
    while p < text.len() && !text.is_char_boundary(p) {
        p += 1;
    }
    p.min(text.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    const XML: MarkupLanguage = MarkupLanguage::Xml;
    const JSON: MarkupLanguage = MarkupLanguage::Json;

    /// The case from the report.
    #[test]
    fn xml_unescapes_the_reported_example() {
        assert_eq!(
            unescape(
                XML,
                "&lt;initial-splitter-position&gt;38&lt;/initial-splitter-position&gt;"
            )
            .unwrap(),
            "<initial-splitter-position>38</initial-splitter-position>"
        );
    }

    #[test]
    fn xml_escaping_covers_the_five_predefined_entities() {
        assert_eq!(
            escape(XML, r#"<a b="1" c='2'>&</a>"#).unwrap(),
            "&lt;a b=&quot;1&quot; c=&apos;2&apos;&gt;&amp;&lt;/a&gt;"
        );
    }

    #[test]
    fn xml_escape_and_unescape_round_trip() {
        let src = r#"<x a="1">&'"</x>"#;
        assert_eq!(unescape(XML, &escape(XML, src).unwrap()).unwrap(), src);
    }

    #[test]
    fn xml_unescapes_numeric_references() {
        assert_eq!(unescape(XML, "&#60;&#x3E;&#38;").unwrap(), "<>&");
        assert_eq!(unescape(XML, "&#128169;").unwrap(), "\u{1F4A9}");
    }

    #[test]
    fn xml_reports_an_unknown_entity_rather_than_dropping_it() {
        let err = unescape(XML, "a &nbsp; b").unwrap_err();
        assert!(err.contains("&nbsp;"));
    }

    #[test]
    fn xml_reports_an_unterminated_entity() {
        assert!(unescape(XML, "a & b").is_err());
    }

    #[test]
    fn xml_leaves_ordinary_text_alone() {
        assert_eq!(unescape(XML, "plain text").unwrap(), "plain text");
        assert_eq!(escape(XML, "plain text").unwrap(), "plain text");
    }

    #[test]
    fn json_escapes_quotes_control_characters_and_backslashes() {
        assert_eq!(
            escape(JSON, "say \"hi\"\n\tpath\\here").unwrap(),
            r#"say \"hi\"\n\tpath\\here"#
        );
    }

    #[test]
    fn json_unescapes_the_standard_sequences() {
        assert_eq!(
            unescape(JSON, r#"a\"b\\c\nd\te\/f"#).unwrap(),
            "a\"b\\c\nd\te/f"
        );
    }

    #[test]
    fn json_unescapes_unicode_and_surrogate_pairs() {
        assert_eq!(unescape(JSON, "\\u00e9").unwrap(), "é");
        // U+1D11E, written as the surrogate pair JSON requires.
        assert_eq!(unescape(JSON, "\\ud834\\udd1e").unwrap(), "\u{1D11E}");
    }

    #[test]
    fn json_escape_and_unescape_round_trip_including_astral_characters() {
        let src = "é \u{1D11E} \"q\" \\ \n\t end";
        assert_eq!(unescape(JSON, &escape(JSON, src).unwrap()).unwrap(), src);
    }

    #[test]
    fn json_reports_a_lone_high_surrogate() {
        assert!(unescape(JSON, r"\ud834 rest").is_err());
    }

    #[test]
    fn json_reports_an_incomplete_or_unknown_escape() {
        assert!(unescape(JSON, r"\u12").is_err());
        assert!(unescape(JSON, r"\q").is_err());
        assert!(unescape(JSON, "ends with \\").is_err());
    }

    #[test]
    fn control_characters_become_u_escapes() {
        assert_eq!(escape(JSON, "\u{1}").unwrap(), "\\u0001");
        assert_eq!(escape(JSON, "\u{8}\u{c}").unwrap(), "\\b\\f");
        assert_eq!(unescape(JSON, "\\u0001").unwrap(), "\u{1}");
    }

    #[test]
    fn yaml_uses_the_same_double_quoted_escapes_as_json() {
        assert_eq!(
            escape(MarkupLanguage::Yaml, "a\nb").unwrap(),
            escape(JSON, "a\nb").unwrap()
        );
    }

    #[test]
    fn plain_text_says_it_has_no_escaping_scheme() {
        assert!(escape(MarkupLanguage::PlainText, "x").is_err());
        assert!(unescape(MarkupLanguage::PlainText, "x").is_err());
    }
}

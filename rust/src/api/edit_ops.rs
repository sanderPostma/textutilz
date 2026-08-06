use flutter_rust_bridge::frb;

use crate::api::structured::StructuredLanguage;
use crate::markup::CommentStyle;

pub fn proper_case(input: &str, blend: bool) -> String {
    let mut result = String::new();
    let mut last_was_alphanumeric = false;
    for c in input.chars() {
        if c.is_alphabetic() {
            if !last_was_alphanumeric {
                for up in c.to_uppercase() {
                    result.push(up);
                }
            } else if !blend {
                for lo in c.to_lowercase() {
                    result.push(lo);
                }
            } else {
                result.push(c);
            }
            last_was_alphanumeric = true;
        } else {
            result.push(c);
            last_was_alphanumeric = c.is_alphanumeric();
        }
    }
    result
}

pub fn sentence_case(input: &str, blend: bool) -> String {
    let mut result = String::new();
    let mut is_new_sentence = true;
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_alphabetic() {
            // Special exception for 'i' in English
            let mut is_i_exception = false;
            if c == 'i' || c == 'I' {
                let prev_ok = if i > 0 {
                    let prev = chars[i - 1];
                    prev.is_whitespace() || prev == '(' || prev == '"'
                } else {
                    false
                };
                let next_ok = if i + 1 < chars.len() {
                    let next = chars[i + 1];
                    next.is_whitespace() || next == '\''
                } else {
                    false
                };
                if prev_ok && next_ok {
                    is_i_exception = true;
                }
            }

            if is_i_exception {
                result.push('I');
            } else if is_new_sentence {
                for up in c.to_uppercase() {
                    result.push(up);
                }
                is_new_sentence = false;
            } else if !blend {
                for lo in c.to_lowercase() {
                    result.push(lo);
                }
            } else {
                result.push(c);
            }
        } else {
            result.push(c);
            if c == '.' || c == '!' || c == '?' {
                let next_is_alphanumeric = if i + 1 < chars.len() {
                    chars[i + 1].is_alphanumeric()
                } else {
                    false
                };
                if !next_is_alphanumeric {
                    is_new_sentence = true;
                }
            } else if c == '\r' || c == '\n' {
                is_new_sentence = true;
            }
        }
        i += 1;
    }
    result
}

pub fn invert_case(input: &str) -> String {
    let mut result = String::new();
    for c in input.chars() {
        if c.is_uppercase() {
            for lo in c.to_lowercase() {
                result.push(lo);
            }
        } else if c.is_lowercase() {
            for up in c.to_uppercase() {
                result.push(up);
            }
        } else {
            result.push(c);
        }
    }
    result
}

pub fn random_case(input: &str) -> String {
    let mut seed = input.len() as u64 + 12345;
    let a: u64 = 1664525;
    let c: u64 = 1013904223;
    let m: u64 = 2u64.pow(32);

    let mut result = String::new();
    for ch in input.chars() {
        if ch.is_alphabetic() {
            seed = (a.wrapping_mul(seed).wrapping_add(c)) % m;
            let uppercase = seed % 2 == 0;
            if uppercase {
                for up in ch.to_uppercase() {
                    result.push(up);
                }
            } else {
                for lo in ch.to_lowercase() {
                    result.push(lo);
                }
            }
        } else {
            result.push(ch);
        }
    }
    result
}

pub fn convert_eol(input: &str, eol_type: &str) -> String {
    let normalized = input.replace("\r\n", "\n").replace('\r', "\n");
    match eol_type {
        "windows" => normalized.replace('\n', "\r\n"),
        "unix" => normalized,
        "mac" => normalized.replace('\n', "\r"),
        _ => normalized,
    }
}

pub fn trim_trailing(input: &str) -> String {
    input
        .split('\n')
        .map(|line| {
            let has_cr = line.ends_with('\r');
            let clean = if has_cr {
                &line[..line.len() - 1]
            } else {
                line
            };
            let trimmed = clean.trim_end_matches(|c| c == ' ' || c == '\t');
            if has_cr {
                format!("{}\r", trimmed)
            } else {
                trimmed.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn trim_leading(input: &str) -> String {
    input
        .split('\n')
        .map(|line| {
            line.trim_start_matches(|c| c == ' ' || c == '\t')
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn trim_both(input: &str) -> String {
    input
        .split('\n')
        .map(|line| {
            let has_cr = line.ends_with('\r');
            let clean = if has_cr {
                &line[..line.len() - 1]
            } else {
                line
            };
            let trimmed = clean.trim_matches(|c| c == ' ' || c == '\t');
            if has_cr {
                format!("{}\r", trimmed)
            } else {
                trimmed.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn eol_to_space(input: &str) -> String {
    input
        .replace("\r\n", " ")
        .replace('\r', " ")
        .replace('\n', " ")
}

pub fn trim_both_and_eol_to_space(input: &str) -> String {
    let trimmed_lines: Vec<String> = input
        .split('\n')
        .map(|line| {
            let clean = line.trim_end_matches('\r');
            clean.trim_matches(|c| c == ' ' || c == '\t').to_string()
        })
        .collect();
    trimmed_lines.join(" ")
}

pub fn tab_to_space(input: &str, tab_width: usize) -> String {
    let mut result = String::new();
    let lines: Vec<&str> = input.split('\n').collect();
    for (line_idx, line) in lines.iter().enumerate() {
        let has_cr = line.ends_with('\r');
        let clean = if has_cr {
            &line[..line.len() - 1]
        } else {
            line
        };

        let mut col = 0;
        for c in clean.chars() {
            if c == '\t' {
                let spaces = tab_width - (col % tab_width);
                for _ in 0..spaces {
                    result.push(' ');
                }
                col += spaces;
            } else {
                result.push(c);
                col += 1;
            }
        }
        if has_cr {
            result.push('\r');
        }
        if line_idx < lines.len() - 1 {
            result.push('\n');
        }
    }
    result
}

pub fn space_to_tab(input: &str, tab_width: usize, leading_only: bool) -> String {
    let mut result = String::new();
    let lines: Vec<&str> = input.split('\n').collect();
    for (line_idx, line) in lines.iter().enumerate() {
        let has_cr = line.ends_with('\r');
        let clean = if has_cr {
            &line[..line.len() - 1]
        } else {
            line
        };

        let mut col = 0;
        let mut i = 0;
        let chars: Vec<char> = clean.chars().collect();
        let mut non_space_found = false;

        while i < chars.len() {
            if leading_only && non_space_found {
                result.push(chars[i]);
                i += 1;
                continue;
            }

            if chars[i] == ' ' {
                let mut space_count = 0;
                while i + space_count < chars.len() && chars[i + space_count] == ' ' {
                    space_count += 1;
                }

                let mut cur_col = col;
                let mut spaces_to_process = space_count;

                while spaces_to_process > 0 {
                    let next_tab_stop = ((cur_col / tab_width) + 1) * tab_width;
                    let dist = next_tab_stop - cur_col;
                    if spaces_to_process >= dist {
                        result.push('\t');
                        spaces_to_process -= dist;
                        cur_col = next_tab_stop;
                    } else {
                        for _ in 0..spaces_to_process {
                            result.push(' ');
                        }
                        cur_col += spaces_to_process;
                        spaces_to_process = 0;
                    }
                }

                col = cur_col;
                i += space_count;
            } else {
                if chars[i] != '\t' {
                    non_space_found = true;
                }
                result.push(chars[i]);
                if chars[i] == '\t' {
                    col = ((col / tab_width) + 1) * tab_width;
                } else {
                    col += 1;
                }
                i += 1;
            }
        }

        if has_cr {
            result.push('\r');
        }
        if line_idx < lines.len() - 1 {
            result.push('\n');
        }
    }
    result
}

// ---- Comments --------------------------------------------------------------

/// Apply `f` to every row, preserving the `\r` of a CRLF ending.
fn map_rows(input: &str, mut f: impl FnMut(&str) -> String) -> String {
    input
        .split('\n')
        .map(|line| {
            let has_cr = line.ends_with('\r');
            let clean = if has_cr { &line[..line.len() - 1] } else { line };
            let mut out = f(clean);
            if has_cr {
                out.push('\r');
            }
            out
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Split a row into its leading whitespace and the rest.
fn split_indent(row: &str) -> (&str, &str) {
    let body = row.trim_start();
    (&row[..row.len() - body.len()], body)
}

/// How one row is marked as commented.
///
/// Formats with a line comment use it. Formats that only have block comments —
/// XML being the one that matters here — wrap each row in the block delimiters
/// instead, so "comment these lines" still means something in an XML document
/// rather than silently doing nothing.
enum LineMarker<'a> {
    Line(&'a str),
    Block(&'a str, &'a str),
}

impl<'a> LineMarker<'a> {
    fn of(style: &'a CommentStyle) -> Option<LineMarker<'a>> {
        if let Some(line) = style.line.as_deref() {
            return Some(LineMarker::Line(line));
        }
        style.block().map(|(s, e)| LineMarker::Block(s, e))
    }

    fn is_applied(&self, body: &str) -> bool {
        match self {
            LineMarker::Line(symbol) => body.starts_with(symbol),
            LineMarker::Block(start, end) => {
                body.len() >= start.len() + end.len()
                    && body.starts_with(start)
                    && body.ends_with(end)
            }
        }
    }

    fn apply(&self, body: &str) -> String {
        match self {
            LineMarker::Line(symbol) => format!("{symbol} {body}"),
            LineMarker::Block(start, end) => format!("{start} {body} {end}"),
        }
    }

    fn remove(&self, body: &str) -> String {
        match self {
            LineMarker::Line(symbol) => match body.strip_prefix(symbol) {
                // Drop the single space this tool inserts, but leave any
                // further indentation the author chose.
                Some(rest) => rest.strip_prefix(' ').unwrap_or(rest).to_string(),
                None => body.to_string(),
            },
            LineMarker::Block(start, end) => {
                match body.strip_prefix(start).and_then(|r| r.strip_suffix(end)) {
                    Some(inner) => inner.trim().to_string(),
                    None => body.to_string(),
                }
            }
        }
    }
}

/// The message for a format that cannot express what was asked.
fn no_comment_syntax(style: &CommentStyle) -> String {
    style.unsupported_note.clone().unwrap_or_else(|| {
        "This file type has no comment syntax.".to_string()
    })
}

fn no_block_syntax(style: &CommentStyle) -> String {
    if style.line.is_some() {
        "This file type has no block comment syntax. Use a single-line comment instead."
            .to_string()
    } else {
        no_comment_syntax(style)
    }
}

fn comment_rows(input: &str, marker: &LineMarker) -> String {
    map_rows(input, |row| {
        let (indent, body) = split_indent(row);
        if body.is_empty() {
            return row.to_string();
        }
        format!("{indent}{}", marker.apply(body))
    })
}

fn uncomment_rows(input: &str, marker: &LineMarker) -> String {
    map_rows(input, |row| {
        let (indent, body) = split_indent(row);
        if !marker.is_applied(body) {
            return row.to_string();
        }
        format!("{indent}{}", marker.remove(body))
    })
}

/// Comment the rows, or uncomment them if every non-blank row already is.
pub fn toggle_single_line_comment(input: &str, style: &CommentStyle) -> Result<String, String> {
    let marker = LineMarker::of(style).ok_or_else(|| no_comment_syntax(style))?;
    let mut has_content = false;
    let mut all_commented = true;
    for line in input.split('\n') {
        let (_, body) = split_indent(line.trim_end_matches('\r'));
        if body.is_empty() {
            continue;
        }
        has_content = true;
        if !marker.is_applied(body) {
            all_commented = false;
            break;
        }
    }
    Ok(if has_content && all_commented {
        uncomment_rows(input, &marker)
    } else {
        comment_rows(input, &marker)
    })
}

pub fn single_line_comment(input: &str, style: &CommentStyle) -> Result<String, String> {
    let marker = LineMarker::of(style).ok_or_else(|| no_comment_syntax(style))?;
    Ok(comment_rows(input, &marker))
}

pub fn single_line_uncomment(input: &str, style: &CommentStyle) -> Result<String, String> {
    let marker = LineMarker::of(style).ok_or_else(|| no_comment_syntax(style))?;
    Ok(uncomment_rows(input, &marker))
}

pub fn block_comment(input: &str, style: &CommentStyle) -> Result<String, String> {
    match style.block() {
        Some((start, end)) => Ok(format!("{start} {input} {end}")),
        None => Err(no_block_syntax(style)),
    }
}

pub fn block_uncomment(input: &str, style: &CommentStyle) -> Result<String, String> {
    let Some((start, end)) = style.block() else {
        return Err(no_block_syntax(style));
    };
    let trimmed = input.trim();
    if trimmed.len() >= start.len() + end.len()
        && trimmed.starts_with(start)
        && trimmed.ends_with(end)
    {
        Ok(trimmed[start.len()..trimmed.len() - end.len()].trim().to_string())
    } else {
        Ok(input.to_string())
    }
}


// ---- Dispatcher -------------------------------------------------------------

#[frb(sync)]
pub fn apply_edit_op(
    input: String,
    op_id: String,
    extension: String,
    language: StructuredLanguage,
    tab_width: usize,
) -> Result<String, String> {
    // The language is detected once, by the caller, from the whole document.
    // Re-sniffing here would see only the selection and could disagree with
    // what the editor is colouring.
    let comments = || crate::markup::comment_style(language.into(), &extension);
    match op_id.as_str() {
        "edit.case.uppercase" => Ok(input.to_uppercase()),
        "edit.case.lowercase" => Ok(input.to_lowercase()),
        "edit.case.proper" => Ok(proper_case(&input, false)),
        "edit.case.proper_blend" => Ok(proper_case(&input, true)),
        "edit.case.sentence" => Ok(sentence_case(&input, false)),
        "edit.case.sentence_blend" => Ok(sentence_case(&input, true)),
        "edit.case.invert" => Ok(invert_case(&input)),
        "edit.case.random" => Ok(random_case(&input)),
        "edit.eol.windows" => Ok(convert_eol(&input, "windows")),
        "edit.eol.unix" => Ok(convert_eol(&input, "unix")),
        "edit.eol.mac" => Ok(convert_eol(&input, "mac")),
        "edit.blank.trim_trailing" => Ok(trim_trailing(&input)),
        "edit.blank.trim_leading" => Ok(trim_leading(&input)),
        "edit.blank.trim_both" => Ok(trim_both(&input)),
        "edit.blank.eol_to_space" => Ok(eol_to_space(&input)),
        "edit.blank.trim_both_and_eol_to_space" => Ok(trim_both_and_eol_to_space(&input)),
        "edit.blank.tab_to_space" => Ok(tab_to_space(&input, tab_width)),
        "edit.blank.space_to_tab_all" => Ok(space_to_tab(&input, tab_width, false)),
        "edit.blank.space_to_tab_leading" => Ok(space_to_tab(&input, tab_width, true)),
        "edit.comment.toggle_single_line" => toggle_single_line_comment(&input, &comments()),
        "edit.comment.block_comment" => block_comment(&input, &comments()),
        "edit.comment.block_uncomment" => block_uncomment(&input, &comments()),
        "edit.comment.single_line_comment" => single_line_comment(&input, &comments()),
        "edit.comment.single_line_uncomment" => single_line_uncomment(&input, &comments()),
        _ => Err(format!("Unknown edit operation ID: {}", op_id)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_proper_case() {
        assert_eq!(proper_case("hello world", false), "Hello World");
        assert_eq!(proper_case("o'connor", false), "O'Connor");
        assert_eq!(proper_case("HTML_parser", false), "Html_Parser");
        assert_eq!(proper_case("HTML_parser", true), "HTML_Parser"); // blend preserves uppercase
    }

    #[test]
    fn test_sentence_case() {
        assert_eq!(
            sentence_case("hello. world? yes!", false),
            "Hello. World? Yes!"
        );
        assert_eq!(
            sentence_case("he told me: \"i am fine\".", false),
            "He told me: \"I am fine\"."
        );
        assert_eq!(
            sentence_case("this is 3.14 value.", false),
            "This is 3.14 value."
        );
    }

    #[test]
    fn test_invert_case() {
        assert_eq!(invert_case("aBcDeF"), "AbCdEf");
    }

    #[test]
    fn test_trim_ops() {
        assert_eq!(trim_trailing("hello  \nworld\t"), "hello\nworld");
        assert_eq!(trim_leading("  hello\n\tworld"), "hello\nworld");
        assert_eq!(trim_both("  hello  \n\tworld\t"), "hello\nworld");
    }

    #[test]
    fn test_tab_to_space() {
        assert_eq!(tab_to_space("a\tb", 4), "a   b");
    }

    #[test]
    fn test_space_to_tab() {
        assert_eq!(space_to_tab("   b", 4, false), "   b"); // 3 spaces starting at col 0 doesn't reach tab stop
        assert_eq!(space_to_tab("    b", 4, false), "\tb"); // 4 spaces starting at col 0 reaches tab stop
        assert_eq!(space_to_tab("a   b", 4, false), "a\tb"); // 3 spaces starting at col 1 reaches tab stop (col 4)
    }

    #[test]
    fn test_comments() {
        let rust = crate::markup::comment_style(crate::markup::MarkupLanguage::PlainText, "rs");

        // Toggle single line comment
        assert_eq!(toggle_single_line_comment("hello", &rust).unwrap(), "// hello");
        assert_eq!(toggle_single_line_comment("// hello", &rust).unwrap(), "hello");

        // Single line comment
        assert_eq!(
            single_line_comment("hello\nworld", &rust).unwrap(),
            "// hello\n// world"
        );

        // Single line uncomment
        assert_eq!(
            single_line_uncomment("// hello\n// world", &rust).unwrap(),
            "hello\nworld"
        );

        // Block comment
        assert_eq!(block_comment("hello", &rust).unwrap(), "/* hello */");
        assert_eq!(block_uncomment("/* hello */", &rust).unwrap(), "hello");
    }

    fn style_for(language: crate::markup::MarkupLanguage) -> crate::markup::CommentStyle {
        crate::markup::comment_style(language, "txt")
    }

    /// The reported bug: JSON was getting `//` from the C-style default,
    /// producing a document that no longer parses.
    #[test]
    fn json_refuses_to_comment_and_explains_why() {
        let style = style_for(crate::markup::MarkupLanguage::Json);
        let err = toggle_single_line_comment("{\"a\": 1}", &style).unwrap_err();
        assert!(err.contains("JSON5"), "{err}");
        assert!(single_line_comment("x", &style).is_err());
        assert!(block_comment("x", &style).is_err());
    }

    #[test]
    fn json5_comments_with_slashes() {
        let style = style_for(crate::markup::MarkupLanguage::Json5);
        assert_eq!(
            toggle_single_line_comment("{a: 1}", &style).unwrap(),
            "// {a: 1}"
        );
        assert_eq!(block_comment("x", &style).unwrap(), "/* x */");
    }

    #[test]
    fn yaml_comments_with_a_hash_and_has_no_block_form() {
        let style = style_for(crate::markup::MarkupLanguage::Yaml);
        assert_eq!(
            toggle_single_line_comment("a: 1\nb: 2", &style).unwrap(),
            "# a: 1\n# b: 2"
        );
        assert_eq!(
            toggle_single_line_comment("# a: 1\n# b: 2", &style).unwrap(),
            "a: 1\nb: 2"
        );
        assert!(block_comment("a: 1", &style).is_err());
    }

    /// XML has no line comment, so each row is wrapped in the block form.
    /// Before, this silently returned the input unchanged.
    #[test]
    fn xml_line_comments_wrap_each_row_in_the_block_form() {
        let style = style_for(crate::markup::MarkupLanguage::Xml);
        assert_eq!(
            single_line_comment("<a/>\n<b/>", &style).unwrap(),
            "<!-- <a/> -->\n<!-- <b/> -->"
        );
        assert_eq!(
            single_line_uncomment("<!-- <a/> -->\n<!-- <b/> -->", &style).unwrap(),
            "<a/>\n<b/>"
        );
        assert_eq!(
            toggle_single_line_comment("<!-- <a/> -->", &style).unwrap(),
            "<a/>"
        );
    }

    /// A YAML document saved as `.txt` must still comment with `#`. Keying on
    /// the extension alone is what produced the original bug.
    #[test]
    fn the_detected_language_beats_the_extension() {
        assert_eq!(
            toggle_single_line_comment(
                "a: 1",
                &crate::markup::comment_style(crate::markup::MarkupLanguage::Yaml, "txt")
            )
            .unwrap(),
            "# a: 1"
        );
    }

    #[test]
    fn commenting_preserves_indentation_blank_rows_and_crlf() {
        let style = style_for(crate::markup::MarkupLanguage::Yaml);
        assert_eq!(
            single_line_comment("  a: 1\n\n  b: 2", &style).unwrap(),
            "  # a: 1\n\n  # b: 2"
        );
        assert_eq!(
            single_line_comment("a: 1\r\nb: 2", &style).unwrap(),
            "# a: 1\r\n# b: 2"
        );
    }

    #[test]
    fn uncommenting_a_row_that_is_not_commented_leaves_it_alone() {
        let style = style_for(crate::markup::MarkupLanguage::Yaml);
        assert_eq!(
            single_line_uncomment("# a: 1\nb: 2", &style).unwrap(),
            "a: 1\nb: 2"
        );
    }

    #[test]
    fn toggling_is_its_own_inverse() {
        let style = style_for(crate::markup::MarkupLanguage::Yaml);
        let src = "  a: 1\n  b: 2";
        let once = toggle_single_line_comment(src, &style).unwrap();
        assert_eq!(toggle_single_line_comment(&once, &style).unwrap(), src);
    }

    #[test]
    fn block_uncomment_leaves_text_that_is_not_a_block_comment_alone() {
        let style = style_for(crate::markup::MarkupLanguage::Xml);
        assert_eq!(block_uncomment("<a/>", &style).unwrap(), "<a/>");
    }
}

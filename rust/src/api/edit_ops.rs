use flutter_rust_bridge::frb;

fn get_comment_symbols(extension: &str) -> (Option<&str>, Option<(&str, &str)>) {
    match extension.to_lowercase().as_str() {
        "rs" | "go" | "cpp" | "c" | "h" | "hpp" | "java" | "kt" | "scala" | "swift" | "dart" | "js" | "ts" | "cs" => {
            (Some("//"), Some(("/*", "*/")))
        }
        "py" | "sh" | "rb" | "pl" | "pm" | "r" | "coffee" | "yaml" | "yml" | "toml" | "properties" | "conf" => {
            (Some("#"), None)
        }
        "html" | "xml" | "svg" | "xhtml" => {
            (None, Some(("<!--", "-->")))
        }
        "css" => {
            (None, Some(("/*", "*/")))
        }
        "sql" => {
            (Some("--"), Some(("/*", "*/")))
        }
        "ini" | "bat" | "cmd" => {
            (Some(";"), None)
        }
        "lua" => {
            (Some("--"), Some(("--[[", "]]")))
        }
        _ => (Some("//"), Some(("/*", "*/"))), // Default to C-style comments
    }
}

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
            line.trim_start_matches(|c| c == ' ' || c == '\t').to_string()
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
    input.replace("\r\n", " ").replace('\r', " ").replace('\n', " ")
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

pub fn toggle_single_line_comment(input: &str, extension: &str) -> String {
    let (line_symbol, block_symbols) = get_comment_symbols(extension);
    
    if let Some(symbol) = line_symbol {
        let prefix = format!("{} ", symbol);
        let lines: Vec<&str> = input.split('\n').collect();
        
        // Check if all non-empty lines are already commented
        let mut all_commented = true;
        let mut has_non_empty = false;
        
        for line in &lines {
            let clean = line.trim_end_matches('\r').trim_start();
            if !clean.is_empty() {
                has_non_empty = true;
                if !clean.starts_with(symbol) {
                    all_commented = false;
                    break;
                }
            }
        }
        
        if has_non_empty && all_commented {
            // Uncomment them
            lines
                .iter()
                .map(|line| {
                    let has_cr = line.ends_with('\r');
                    let clean = if has_cr { &line[..line.len() - 1] } else { line };
                    
                    let mut result = String::new();
                    let trimmed = clean.trim_start();
                    let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                    
                    if trimmed.starts_with(&prefix) {
                        result.push_str(leading_whitespace);
                        result.push_str(&trimmed[prefix.len()..]);
                    } else if trimmed.starts_with(symbol) {
                        result.push_str(leading_whitespace);
                        result.push_str(&trimmed[symbol.len()..]);
                    } else {
                        result.push_str(clean);
                    }
                    
                    if has_cr { result.push('\r'); }
                    result
                })
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            // Comment them
            lines
                .iter()
                .map(|line| {
                    let has_cr = line.ends_with('\r');
                    let clean = if has_cr { &line[..line.len() - 1] } else { line };
                    
                    let mut result = String::new();
                    let trimmed = clean.trim_start();
                    if trimmed.is_empty() {
                        result.push_str(clean);
                    } else {
                        let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                        result.push_str(leading_whitespace);
                        result.push_str(&prefix);
                        result.push_str(trimmed);
                    }
                    
                    if has_cr { result.push('\r'); }
                    result
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
    } else if let Some((start, end)) = block_symbols {
        // Fallback to advanced block comment per line
        let start_prefix = format!("{} ", start);
        let end_suffix = format!(" {}", end);
        
        let lines: Vec<&str> = input.split('\n').collect();
        let mut all_commented = true;
        let mut has_non_empty = false;
        
        for line in &lines {
            let clean = line.trim_end_matches('\r').trim_start();
            if !clean.is_empty() {
                has_non_empty = true;
                if !clean.starts_with(start) || !clean.ends_with(end) {
                    all_commented = false;
                    break;
                }
            }
        }
        
        if has_non_empty && all_commented {
            // Uncomment
            lines
                .iter()
                .map(|line| {
                    let has_cr = line.ends_with('\r');
                    let clean = if has_cr { &line[..line.len() - 1] } else { line };
                    
                    let mut result = String::new();
                    let trimmed = clean.trim_start();
                    let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                    
                    if trimmed.starts_with(&start_prefix) && trimmed.ends_with(&end_suffix) {
                        result.push_str(leading_whitespace);
                        result.push_str(&trimmed[start_prefix.len()..trimmed.len() - end_suffix.len()]);
                    } else if trimmed.starts_with(start) && trimmed.ends_with(end) {
                        result.push_str(leading_whitespace);
                        result.push_str(&trimmed[start.len()..trimmed.len() - end.len()]);
                    } else {
                        result.push_str(clean);
                    }
                    
                    if has_cr { result.push('\r'); }
                    result
                })
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            // Comment
            lines
                .iter()
                .map(|line| {
                    let has_cr = line.ends_with('\r');
                    let clean = if has_cr { &line[..line.len() - 1] } else { line };
                    
                    let mut result = String::new();
                    let trimmed = clean.trim_start();
                    if trimmed.is_empty() {
                        result.push_str(clean);
                    } else {
                        let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                        result.push_str(leading_whitespace);
                        result.push_str(&start_prefix);
                        result.push_str(trimmed);
                        result.push_str(&end_suffix);
                    }
                    
                    if has_cr { result.push('\r'); }
                    result
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
    } else {
        input.to_string()
    }
}

pub fn block_comment(input: &str, extension: &str) -> String {
    let (_, block_symbols) = get_comment_symbols(extension);
    if let Some((start, end)) = block_symbols {
        format!("{} {} {}", start, input, end)
    } else {
        input.to_string()
    }
}

pub fn block_uncomment(input: &str, extension: &str) -> String {
    let (_, block_symbols) = get_comment_symbols(extension);
    if let Some((start, end)) = block_symbols {
        let trimmed = input.trim();
        if trimmed.starts_with(start) && trimmed.ends_with(end) {
            let inside = &trimmed[start.len()..trimmed.len() - end.len()];
            inside.trim().to_string()
        } else {
            input.to_string()
        }
    } else {
        input.to_string()
    }
}

pub fn single_line_comment(input: &str, extension: &str) -> String {
    let (line_symbol, block_symbols) = get_comment_symbols(extension);
    if let Some(symbol) = line_symbol {
        let prefix = format!("{} ", symbol);
        input
            .split('\n')
            .map(|line| {
                let has_cr = line.ends_with('\r');
                let clean = if has_cr { &line[..line.len() - 1] } else { line };
                
                let mut result = String::new();
                let trimmed = clean.trim_start();
                if trimmed.is_empty() {
                    result.push_str(clean);
                } else {
                    let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                    result.push_str(leading_whitespace);
                    result.push_str(&prefix);
                    result.push_str(trimmed);
                }
                
                if has_cr { result.push('\r'); }
                result
            })
            .collect::<Vec<_>>()
            .join("\n")
    } else if let Some((start, end)) = block_symbols {
        let start_prefix = format!("{} ", start);
        let end_suffix = format!(" {}", end);
        input
            .split('\n')
            .map(|line| {
                let has_cr = line.ends_with('\r');
                let clean = if has_cr { &line[..line.len() - 1] } else { line };
                
                let mut result = String::new();
                let trimmed = clean.trim_start();
                if trimmed.is_empty() {
                    result.push_str(clean);
                } else {
                    let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                    result.push_str(leading_whitespace);
                    result.push_str(&start_prefix);
                    result.push_str(trimmed);
                    result.push_str(&end_suffix);
                }
                
                if has_cr { result.push('\r'); }
                result
            })
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        input.to_string()
    }
}

pub fn single_line_uncomment(input: &str, extension: &str) -> String {
    let (line_symbol, block_symbols) = get_comment_symbols(extension);
    if let Some(symbol) = line_symbol {
        let prefix = format!("{} ", symbol);
        input
            .split('\n')
            .map(|line| {
                let has_cr = line.ends_with('\r');
                let clean = if has_cr { &line[..line.len() - 1] } else { line };
                
                let mut result = String::new();
                let trimmed = clean.trim_start();
                let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                
                if trimmed.starts_with(&prefix) {
                    result.push_str(leading_whitespace);
                    result.push_str(&trimmed[prefix.len()..]);
                } else if trimmed.starts_with(symbol) {
                    result.push_str(leading_whitespace);
                    result.push_str(&trimmed[symbol.len()..]);
                } else {
                    result.push_str(clean);
                }
                
                if has_cr { result.push('\r'); }
                result
            })
            .collect::<Vec<_>>()
            .join("\n")
    } else if let Some((start, end)) = block_symbols {
        let start_prefix = format!("{} ", start);
        let end_suffix = format!(" {}", end);
        input
            .split('\n')
            .map(|line| {
                let has_cr = line.ends_with('\r');
                let clean = if has_cr { &line[..line.len() - 1] } else { line };
                
                let mut result = String::new();
                let trimmed = clean.trim_start();
                let leading_whitespace = &clean[..clean.len() - trimmed.len()];
                
                if trimmed.starts_with(&start_prefix) && trimmed.ends_with(&end_suffix) {
                    result.push_str(leading_whitespace);
                    result.push_str(&trimmed[start_prefix.len()..trimmed.len() - end_suffix.len()]);
                } else if trimmed.starts_with(start) && trimmed.ends_with(end) {
                    result.push_str(leading_whitespace);
                    result.push_str(&trimmed[start.len()..trimmed.len() - end.len()]);
                } else {
                    result.push_str(clean);
                }
                
                if has_cr { result.push('\r'); }
                result
            })
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        input.to_string()
    }
}

// ---- Dispatcher -------------------------------------------------------------

#[frb(sync)]
pub fn apply_edit_op(input: String, op_id: String, extension: String, tab_width: usize) -> Result<String, String> {
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
        "edit.comment.toggle_single_line" => Ok(toggle_single_line_comment(&input, &extension)),
        "edit.comment.block_comment" => Ok(block_comment(&input, &extension)),
        "edit.comment.block_uncomment" => Ok(block_uncomment(&input, &extension)),
        "edit.comment.single_line_comment" => Ok(single_line_comment(&input, &extension)),
        "edit.comment.single_line_uncomment" => Ok(single_line_uncomment(&input, &extension)),
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
        assert_eq!(sentence_case("hello. world? yes!", false), "Hello. World? Yes!");
        assert_eq!(sentence_case("he told me: \"i am fine\".", false), "He told me: \"I am fine\".");
        assert_eq!(sentence_case("this is 3.14 value.", false), "This is 3.14 value.");
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
        // Toggle single line comment
        assert_eq!(toggle_single_line_comment("hello", "rs"), "// hello");
        assert_eq!(toggle_single_line_comment("// hello", "rs"), "hello");
        
        // Single line comment
        assert_eq!(single_line_comment("hello\nworld", "rs"), "// hello\n// world");
        
        // Single line uncomment
        assert_eq!(single_line_uncomment("// hello\n// world", "rs"), "hello\nworld");

        // Block comment
        assert_eq!(block_comment("hello", "rs"), "/* hello */");
        assert_eq!(block_uncomment("/* hello */", "rs"), "hello");
    }
}


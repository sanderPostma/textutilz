use flutter_rust_bridge::frb;
#[derive(Debug, Clone)]
pub struct CommandDescriptor {
    pub id: String,
    pub title: String,
    pub category: String,
    pub icon: Option<String>,
    pub shortcut: Option<String>,
    pub toggled: Option<bool>,
    /// The ID of the input panel widget to display, if this command needs one.
    pub panel_id: Option<String>,
    /// The ID of the action to execute, if this command executes immediately.
    pub action_id: Option<String>,
}

pub struct CommandRegistry {
    pub commands: Vec<CommandDescriptor>,
}

impl CommandRegistry {
    pub fn new() -> Self {
        let mut reg = Self { commands: Vec::new() };
        reg.register_defaults();
        reg
    }

    fn register_defaults(&mut self) {
        // File commands
        self.commands.push(CommandDescriptor {
            id: "file.new".to_string(),
            title: "New".to_string(),
            category: "File".to_string(),
            icon: Some("note_add".to_string()),
            shortcut: Some("Ctrl+N".to_string()),
            toggled: None,
            panel_id: Some("new".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "file.open".to_string(),
            title: "Open".to_string(),
            category: "File".to_string(),
            icon: Some("folder_open".to_string()),
            shortcut: Some("Ctrl+O".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("file.open".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "file.save".to_string(),
            title: "Save".to_string(),
            category: "File".to_string(),
            icon: Some("save".to_string()),
            shortcut: Some("Ctrl+S".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("file.save".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "file.close".to_string(),
            title: "Close Tab".to_string(),
            category: "File".to_string(),
            icon: Some("tab_unselected".to_string()),
            shortcut: Some("Ctrl+W".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("file.close".to_string()),
        });

        // Edit commands
        self.commands.push(CommandDescriptor {
            id: "edit.undo".to_string(),
            title: "Undo".to_string(),
            category: "Edit".to_string(),
            icon: Some("undo".to_string()),
            shortcut: Some("Ctrl+Z".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("edit.undo".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "edit.redo".to_string(),
            title: "Redo".to_string(),
            category: "Edit".to_string(),
            icon: Some("redo".to_string()),
            shortcut: Some("Ctrl+Y".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("edit.redo".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "edit.cut".to_string(),
            title: "Cut".to_string(),
            category: "Edit".to_string(),
            icon: Some("content_cut".to_string()),
            shortcut: Some("Ctrl+X".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("edit.cut".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "edit.copy".to_string(),
            title: "Copy".to_string(),
            category: "Edit".to_string(),
            icon: Some("content_copy".to_string()),
            shortcut: Some("Ctrl+C".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("edit.copy".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "edit.paste".to_string(),
            title: "Paste".to_string(),
            category: "Edit".to_string(),
            icon: Some("content_paste".to_string()),
            shortcut: Some("Ctrl+V".to_string()),
            toggled: None,
            panel_id: None,
            action_id: Some("edit.paste".to_string()),
        });

        // Search commands
        self.commands.push(CommandDescriptor {
            id: "search.find".to_string(),
            title: "Find".to_string(),
            category: "Search".to_string(),
            icon: Some("search".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: None,
            action_id: Some("search.find".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "search.replace".to_string(),
            title: "Replace".to_string(),
            category: "Search".to_string(),
            icon: Some("find_replace".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: None,
            action_id: Some("search.replace".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "search.goto".to_string(),
            title: "Go to Line".to_string(),
            category: "Search".to_string(),
            icon: Some("my_location".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: None,
            action_id: Some("search.goto".to_string()),
        });

        // View commands
        self.commands.push(CommandDescriptor {
            id: "view.linenumbers".to_string(),
            title: "Line Numbers".to_string(),
            category: "View".to_string(),
            icon: Some("format_list_numbered".to_string()),
            shortcut: None,
            toggled: Some(false), // Replaced with actual state by caller if needed
            panel_id: None,
            action_id: Some("view.linenumbers".to_string()),
        });
        self.commands.push(CommandDescriptor {
            id: "view.wordwrap".to_string(),
            title: "Word Wrap".to_string(),
            category: "View".to_string(),
            icon: Some("wrap_text".to_string()),
            shortcut: None,
            toggled: Some(false),
            panel_id: None,
            action_id: Some("view.wordwrap".to_string()),
        });

        // Tools
        self.commands.push(CommandDescriptor {
            id: "tools.mime".to_string(),
            title: "MIME tools".to_string(),
            category: "Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime".to_string()),
            action_id: None,
        });

        // Specific MIME Commands
        self.commands.push(CommandDescriptor {
            id: "mime.base64.encode".to_string(),
            title: "Base64 Encode".to_string(),
            category: "MIME Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime.base64.encode".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "mime.base64.decode".to_string(),
            title: "Base64 Decode".to_string(),
            category: "MIME Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime.base64.decode".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "mime.qp.encode".to_string(),
            title: "Quoted-printable Encode".to_string(),
            category: "MIME Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime.qp.encode".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "mime.qp.decode".to_string(),
            title: "Quoted-printable Decode".to_string(),
            category: "MIME Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime.qp.decode".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "mime.url.encode".to_string(),
            title: "URL Encode".to_string(),
            category: "MIME Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime.url.encode".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "mime.url.decode".to_string(),
            title: "URL Decode".to_string(),
            category: "MIME Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime.url.decode".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "mime.saml.decode".to_string(),
            title: "SAML Decode".to_string(),
            category: "MIME Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("mime.saml.decode".to_string()),
            action_id: None,
        });

        // JWT Tools
        self.commands.push(CommandDescriptor {
            id: "tools.jwt".to_string(),
            title: "JWT Tools".to_string(),
            category: "Tools".to_string(),
            icon: Some("transform".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: None,
            action_id: Some("tools.jwt".to_string()),
        });

        // NPP Edit Group Panels
        self.commands.push(CommandDescriptor {
            id: "edit.case".to_string(),
            title: "Convert Case".to_string(),
            category: "Edit".to_string(),
            icon: Some("format_size".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("edit.case".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "edit.eol".to_string(),
            title: "EOL Conversion".to_string(),
            category: "Edit".to_string(),
            icon: Some("keyboard_return".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("edit.eol".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "edit.blank".to_string(),
            title: "Blank Operations".to_string(),
            category: "Edit".to_string(),
            icon: Some("space_bar".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("edit.blank".to_string()),
            action_id: None,
        });
        self.commands.push(CommandDescriptor {
            id: "edit.comment".to_string(),
            title: "Comment / Uncomment".to_string(),
            category: "Edit".to_string(),
            icon: Some("comment".to_string()),
            shortcut: None,
            toggled: None,
            panel_id: Some("edit.comment".to_string()),
            action_id: None,
        });

        // NPP Edit Specific Sub-Commands (for Search)
        let sub_ops = vec![
            ("edit.case.uppercase", "UPPERCASE", "Convert Case", "edit.case"),
            ("edit.case.lowercase", "lowercase", "Convert Case", "edit.case"),
            ("edit.case.proper", "Proper Case", "Convert Case", "edit.case"),
            ("edit.case.proper_blend", "Proper Case (blend)", "Convert Case", "edit.case"),
            ("edit.case.sentence", "Sentence case", "Convert Case", "edit.case"),
            ("edit.case.sentence_blend", "Sentence case (blend)", "Convert Case", "edit.case"),
            ("edit.case.invert", "iNVERT cASE", "Convert Case", "edit.case"),
            ("edit.case.random", "ranDOm CasE", "Convert Case", "edit.case"),

            ("edit.eol.windows", "Windows (CR LF)", "EOL Conversion", "edit.eol"),
            ("edit.eol.unix", "Unix (LF)", "EOL Conversion", "edit.eol"),
            ("edit.eol.mac", "Macintosh (CR)", "EOL Conversion", "edit.eol"),

            ("edit.blank.trim_trailing", "Trim Trailing Space", "Blank Operations", "edit.blank"),
            ("edit.blank.trim_leading", "Trim Leading Space", "Blank Operations", "edit.blank"),
            ("edit.blank.trim_both", "Trim Leading and Trailing Space", "Blank Operations", "edit.blank"),
            ("edit.blank.eol_to_space", "EOL to Space", "Blank Operations", "edit.blank"),
            ("edit.blank.trim_both_and_eol_to_space", "Trim both and EOL to Space", "Blank Operations", "edit.blank"),
            ("edit.blank.tab_to_space", "TAB to Space", "Blank Operations", "edit.blank"),
            ("edit.blank.space_to_tab_all", "Space to TAB (All)", "Blank Operations", "edit.blank"),
            ("edit.blank.space_to_tab_leading", "Space to TAB (Leading)", "Blank Operations", "edit.blank"),

            ("edit.comment.toggle_single_line", "Toggle Single Line Comment", "Comment / Uncomment", "edit.comment"),
            ("edit.comment.block_comment", "Block Comment", "Comment / Uncomment", "edit.comment"),
            ("edit.comment.block_uncomment", "Block Uncomment", "Comment / Uncomment", "edit.comment"),
            ("edit.comment.single_line_comment", "Single Line Comment", "Comment / Uncomment", "edit.comment"),
            ("edit.comment.single_line_uncomment", "Single Line Uncomment", "Comment / Uncomment", "edit.comment"),
        ];

        for (id, title, cat, panel) in sub_ops {
            self.commands.push(CommandDescriptor {
                id: id.to_string(),
                title: title.to_string(),
                category: cat.to_string(),
                icon: Some("transform".to_string()),
                shortcut: None,
                toggled: None,
                panel_id: Some(panel.to_string()),
                action_id: None,
            });
        }
    }

    #[frb(sync)]
    pub fn search(&self, query: String) -> Vec<CommandDescriptor> {
        if query.is_empty() {
            return Vec::new();
        }
        let lower_query = query.to_lowercase();
        self.commands
            .iter()
            .filter(|cmd| {
                cmd.title.to_lowercase().contains(&lower_query)
                    || cmd.category.to_lowercase().contains(&lower_query)
            })
            .cloned()
            .collect()
    }
    
    #[frb(sync)]
    pub fn get_all(&self) -> Vec<CommandDescriptor> {
        self.commands.clone()
    }
}

#[frb(sync)]
pub fn get_command_registry() -> CommandRegistry {
    CommandRegistry::new()
}

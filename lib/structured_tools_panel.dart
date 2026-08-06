import 'package:flutter/material.dart';

import 'markup_styling.dart';
import 'panel_scope_note.dart';
import 'src/rust/api/structured.dart';

/// What a structured-format tool does to the text it is given.
enum StructuredTextAction {
  prettyPrint,
  compact,
  escape,
  unescape,

  /// Checks the document without changing it; the result is a list of
  /// diagnostics rather than replacement text.
  validate,
}

/// A tool invocation: a language and what to do to it.
///
/// [apply] delegates straight to Rust. Nothing about JSON, YAML or XML is
/// decided here — this class only names the operation and reports its outcome.
class StructuredTextOp {
  final StructuredLanguage language;
  final StructuredTextAction action;

  const StructuredTextOp(this.language, this.action);

  String get languageLabel => MarkupStyling.label(language);

  String get label => switch (action) {
    StructuredTextAction.prettyPrint => 'Pretty-print $languageLabel',
    StructuredTextAction.compact => 'Compact $languageLabel',
    StructuredTextAction.escape => 'Escape $languageLabel',
    StructuredTextAction.unescape => 'Unescape $languageLabel',
    StructuredTextAction.validate => 'Validate $languageLabel',
  };

  /// True when this op replaces the text it is given. Validate does not.
  bool get transformsText => action != StructuredTextAction.validate;

  /// Run the operation.
  ///
  /// Throws [StructuredToolException] with the message Rust produced — which
  /// carries a line and column for a parse failure — so the caller can surface
  /// it without inventing wording of its own.
  String apply(String input) {
    try {
      return switch (action) {
        StructuredTextAction.prettyPrint => formatStructured(
          text: input,
          language: language,
          pretty: true,
          indent: '  ',
        ),
        StructuredTextAction.compact => formatStructured(
          text: input,
          language: language,
          pretty: false,
          indent: '  ',
        ),
        StructuredTextAction.escape => escapeStructured(
          text: input,
          language: language,
        ),
        StructuredTextAction.unescape => unescapeStructured(
          text: input,
          language: language,
        ),
        StructuredTextAction.validate => input,
      };
    } catch (error) {
      // The bridge surfaces a `Result<String, String>` failure as the error
      // string itself, but wraps a panic in an exception object. Either way the
      // useful part is the message Rust wrote.
      throw StructuredToolException(
        error is StructuredToolException ? error.message : error.toString(),
      );
    }
  }

  /// Validate without changing anything.
  List<StructuredDiagnostic> validate(String input) =>
      validateStructured(text: input, language: language);
}

/// A tool failed on the text it was given. The message is Rust's, already
/// phrased for a person.
class StructuredToolException implements Exception {
  final String message;

  const StructuredToolException(this.message);

  @override
  String toString() => message;
}

/// The docked bar behind the JSON, YAML and XML Tools entries.
///
/// JSON and JSON5 share one bar with a dialect switch rather than having an
/// entry each: they are the same format with the same operations, and picking
/// between them is a property of the document, not a different tool.
class StructuredToolsPanel extends StatelessWidget {
  /// The bar's base format. For [StructuredLanguage.json] the JSON5 switch is
  /// offered; the other formats have no dialects.
  final StructuredLanguage language;
  final bool enabled;
  final bool hasSelection;

  /// Whether the JSON bar is currently in JSON5 mode.
  final bool useJson5;
  final ValueChanged<bool>? onUseJson5Changed;

  /// Whether the document is revalidated as the user stops typing.
  final bool autoValidate;
  final ValueChanged<bool>? onAutoValidateChanged;

  final ValueChanged<StructuredTextOp> onRun;

  const StructuredToolsPanel({
    super.key,
    required this.language,
    required this.enabled,
    required this.hasSelection,
    required this.onRun,
    this.useJson5 = false,
    this.onUseJson5Changed,
    this.autoValidate = false,
    this.onAutoValidateChanged,
  });

  /// True when this bar's format has dialects to choose between.
  bool get supportsJson5 =>
      language == StructuredLanguage.json || language == StructuredLanguage.json5;

  /// The format operations actually run against, after the dialect switch.
  StructuredLanguage get effectiveLanguage =>
      supportsJson5 && useJson5 ? StructuredLanguage.json5 : language;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = MarkupStyling.label(effectiveLanguage);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // The dialect governs every operation on this bar, so it leads.
        if (supportsJson5)
          _switch(
            context: context,
            keyName: 'structured-json5-switch',
            label: 'JSON5',
            tooltip:
                'Allow comments, unquoted keys, single quotes and trailing commas.',
            value: useJson5,
            onChanged: onUseJson5Changed,
          ),
        _button(
          action: StructuredTextAction.prettyPrint,
          icon: Icons.format_align_left,
          text: 'Pretty-print',
        ),
        _button(
          action: StructuredTextAction.compact,
          icon: Icons.compress,
          text: 'Compact / minify',
        ),
        _button(
          action: StructuredTextAction.escape,
          icon: Icons.code,
          text: 'Escape',
        ),
        _button(
          action: StructuredTextAction.unescape,
          icon: Icons.code_off,
          text: 'Unescape',
        ),
        // The scope note belongs with the transforms it describes: Validate
        // never rewrites anything, and always reads the whole document.
        PanelScopeNote(
          enabled: enabled,
          hasSelection: hasSelection,
          disabledMessage: 'Open a document in Edit mode to transform $label.',
        ),
        const _BarDivider(),
        _button(
          action: StructuredTextAction.validate,
          icon: Icons.fact_check_outlined,
          text: 'Validate',
          enabledOverride: !autoValidate,
          disabledTooltip:
              'Auto-validate is on, so the results are already up to date.',
        ),
        _switch(
          context: context,
          keyName: 'structured-autovalidate-switch',
          label: 'Auto-validate',
          tooltip: 'Recheck the document 2 seconds after you stop typing.',
          value: autoValidate,
          onChanged: onAutoValidateChanged,
        ),
      ],
    );
  }

  Widget _button({
    required StructuredTextAction action,
    required IconData icon,
    required String text,
    bool enabledOverride = true,
    String? disabledTooltip,
  }) {
    final active = enabled && enabledOverride;
    final button = FilledButton.icon(
      key: ValueKey('structured-${action.name}-${language.name}'),
      onPressed: active
          ? () => onRun(StructuredTextOp(effectiveLanguage, action))
          : null,
      icon: Icon(icon, size: 16),
      label: Text(text),
      style: _denseButton,
    );
    if (active || disabledTooltip == null) return button;
    return Tooltip(message: disabledTooltip, child: button);
  }

  /// A compact labelled switch sized to sit in the same row as the buttons.
  Widget _switch({
    required BuildContext context,
    required String keyName,
    required String label,
    required String tooltip,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Scaled down so the switch does not set the bar's row height; the
          // docked bars have a tight vertical budget.
          SizedBox(
            height: 32,
            child: FittedBox(
              fit: BoxFit.contain,
              child: Switch(
                key: ValueKey(keyName),
                value: value,
                onChanged: enabled ? onChanged : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A hairline separating the transform group from the validation group.
class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('structured-bar-divider'),
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

final ButtonStyle _denseButton = FilledButton.styleFrom(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  minimumSize: Size.zero,
);

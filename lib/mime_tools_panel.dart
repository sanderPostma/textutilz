import 'package:flutter/material.dart';

import 'panel_scope_note.dart';
import 'package:textutilz/src/rust/api/mime_tools.dart';

/// The four MIME-tool categories, one per tab.
enum MimeCategory { base64, quotedPrintable, url, saml }

extension MimeCategoryLabel on MimeCategory {
  String get label => switch (this) {
    MimeCategory.base64 => 'Base64',
    MimeCategory.quotedPrintable => 'Quoted-printable',
    MimeCategory.url => 'URL',
    MimeCategory.saml => 'SAML',
  };
}

/// A fully-specified MIME transform: the category plus the selected toggle
/// state. [apply] runs the matching Rust function — the only place the panel's
/// UI state turns into an actual transform. Decode ops throw on invalid input;
/// the caller catches that to show an error.
class MimeOp {
  final MimeCategory category;
  final bool decode;

  // Base64 options.
  final bool b64Padding;
  final bool b64UnixEol;
  final bool b64Strict;

  // URL options.
  final UrlEncodeVariant urlVariant;

  // Shared "operate per line" option (Base64 + URL).
  final bool byLine;

  const MimeOp({
    required this.category,
    required this.decode,
    this.b64Padding = true,
    this.b64UnixEol = false,
    this.b64Strict = false,
    this.urlVariant = UrlEncodeVariant.rfc1738,
    this.byLine = false,
  });

  /// Human-readable name of the operation (drives the GO button + errors).
  String get label {
    switch (category) {
      case MimeCategory.base64:
        return decode ? 'Base64 Decode' : 'Base64 Encode';
      case MimeCategory.quotedPrintable:
        return decode ? 'Quoted-printable Decode' : 'Quoted-printable Encode';
      case MimeCategory.url:
        return decode ? 'URL Decode' : 'URL Encode';
      case MimeCategory.saml:
        return 'SAML Decode';
    }
  }

  String apply(String input) {
    switch (category) {
      case MimeCategory.base64:
        return decode
            ? base64Decode(input: input, strict: b64Strict, byLine: byLine)
            : base64Encode(
                input: input,
                padding: b64Padding,
                unixEol: b64UnixEol,
                byLine: byLine,
              );
      case MimeCategory.quotedPrintable:
        return decode ? qpDecode(input: input) : qpEncode(input: input);
      case MimeCategory.url:
        return decode
            ? urlDecode(input: input)
            : urlEncode(input: input, variant: urlVariant, byLine: byLine);
      case MimeCategory.saml:
        return samlDecode(input: input);
    }
  }
}

/// Material's default 48px tap target makes each wrap run 48px tall on its
/// own, well over the docked bar's height budget (see the ceilings in
/// test/tool_bar_layout_test.dart). shrinkWrap + compact density brings a run
/// to ~32px while keeping the controls comfortably clickable.
final ButtonStyle _denseFilledStyle = FilledButton.styleFrom(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  minimumSize: Size.zero,
);

const ButtonStyle _denseSegmented = ButtonStyle(
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 10, vertical: 4),
  ),
  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
);

/// A checkbox styled to sit inline in a bar's wrap run.
Widget _mimeCheck(String label, bool value, ValueChanged<bool> onChanged) {
  return InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: value,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );
}

/// Encode | Decode segmented control, shared by the categories that have both.
Widget _mimeModeSelector(bool decode, ValueChanged<bool> onChanged) {
  return SegmentedButton<bool>(
    segments: const [
      ButtonSegment(
        value: false,
        label: Text('Encode'),
        icon: Icon(Icons.lock_outline, size: 16),
      ),
      ButtonSegment(
        value: true,
        label: Text('Decode'),
        icon: Icon(Icons.lock_open, size: 16),
      ),
    ],
    selected: {decode},
    showSelectedIcon: false,
    style: _denseSegmented,
    onSelectionChanged: (s) => onChanged(s.first),
  );
}

/// The status text every MIME surface shows: whether a run would hit the
/// selection or the whole document, or why it is disabled.
Widget _mimeStatusText(bool enabled, bool hasSelection, ColorScheme scheme) {
  return PanelScopeNote(
    enabled: enabled,
    hasSelection: hasSelection,
    disabledMessage: 'Open a document in Edit mode to run MIME tools.',
  );
}

/// The MIME tools bar: one docked bar carrying all four categories as tabs,
/// with the selected category's options and Apply on the row below.
///
/// This is the shape the feature was asked for — the tabbed panel, docked —
/// rather than one bar per operation. Per-category option state is held here
/// so switching tabs and coming back does not reset the user's choices.
class MimeToolsPanel extends StatefulWidget {
  final bool enabled;

  /// True when the active editor has a selection: Apply transforms just it.
  final bool hasSelection;
  final ValueChanged<MimeOp> onRun;

  const MimeToolsPanel({
    super.key,
    required this.enabled,
    this.hasSelection = false,
    required this.onRun,
  });

  @override
  State<MimeToolsPanel> createState() => _MimeToolsPanelState();
}

class _MimeToolsPanelState extends State<MimeToolsPanel> {
  MimeCategory _tab = MimeCategory.base64;

  // Per-category state, preserved when switching tabs.
  bool _b64Decode = false;
  bool _b64Padding = true;
  bool _b64UnixEol = false;
  bool _b64Strict = false;
  bool _b64ByLine = false;

  bool _qpDecode = false;

  bool _urlDecode = false;
  UrlEncodeVariant _urlVariant = UrlEncodeVariant.rfc1738;
  bool _urlByLine = false;

  // SAML is decode-only, no state.

  MimeOp get _currentOp {
    switch (_tab) {
      case MimeCategory.base64:
        return MimeOp(
          category: MimeCategory.base64,
          decode: _b64Decode,
          b64Padding: _b64Padding,
          b64UnixEol: _b64UnixEol,
          b64Strict: _b64Strict,
          byLine: _b64ByLine,
        );
      case MimeCategory.quotedPrintable:
        return MimeOp(
          category: MimeCategory.quotedPrintable,
          decode: _qpDecode,
        );
      case MimeCategory.url:
        return MimeOp(
          category: MimeCategory.url,
          decode: _urlDecode,
          urlVariant: _urlVariant,
          byLine: _urlByLine,
        );
      case MimeCategory.saml:
        return const MimeOp(category: MimeCategory.saml, decode: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            for (final c in MimeCategory.values)
              _TabButton(
                label: c.label,
                selected: _tab == c,
                scheme: scheme,
                onTap: () => setState(() => _tab = c),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ..._categoryOptions(scheme),
            _mimeStatusText(widget.enabled, widget.hasSelection, scheme),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 16),
              // Live label: the tabs and the Encode/Decode selector both
              // change which operation this runs, so a constant 'Apply'
              // would lie about what the button does.
              label: Text(
                'Apply · ${_currentOp.label}',
                style: const TextStyle(fontSize: 13),
              ),
              style: _denseFilledStyle,
              onPressed: widget.enabled ? () => widget.onRun(_currentOp) : null,
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _categoryOptions(ColorScheme scheme) {
    switch (_tab) {
      case MimeCategory.base64:
        return [
          _mimeModeSelector(_b64Decode, (v) => setState(() => _b64Decode = v)),
          if (_b64Decode) ...[
            _mimeCheck(
              'Strict',
              _b64Strict,
              (v) => setState(() => _b64Strict = v),
            ),
          ] else ...[
            _mimeCheck(
              'Padding',
              _b64Padding,
              (v) => setState(() => _b64Padding = v),
            ),
            _mimeCheck(
              'Unix EOL',
              _b64UnixEol,
              (v) => setState(() => _b64UnixEol = v),
            ),
          ],
          _mimeCheck(
            'By line',
            _b64ByLine,
            (v) => setState(() => _b64ByLine = v),
          ),
        ];
      case MimeCategory.quotedPrintable:
        return [
          _mimeModeSelector(_qpDecode, (v) => setState(() => _qpDecode = v)),
        ];
      case MimeCategory.url:
        return [
          _mimeModeSelector(_urlDecode, (v) => setState(() => _urlDecode = v)),
          if (!_urlDecode) ...[
            SegmentedButton<UrlEncodeVariant>(
              segments: const [
                ButtonSegment(
                  value: UrlEncodeVariant.rfc1738,
                  label: Text('RFC1738'),
                ),
                ButtonSegment(
                  value: UrlEncodeVariant.extended,
                  label: Text('Extended'),
                ),
                ButtonSegment(
                  value: UrlEncodeVariant.full,
                  label: Text('Full'),
                ),
              ],
              selected: {_urlVariant},
              showSelectedIcon: false,
              style: _denseSegmented,
              onSelectionChanged: (s) => setState(() => _urlVariant = s.first),
            ),
            _mimeCheck(
              'By line',
              _urlByLine,
              (v) => setState(() => _urlByLine = v),
            ),
          ],
        ];
      case MimeCategory.saml:
        return [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          Text(
            'Base64-decode then raw-inflate (HTTP-Redirect binding).',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ];
    }
  }
}

/// A tab-styled button: label with an underline accent when selected.
class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// A panel for a specific MIME tool category (e.g. Base64) without tabs.
/// Can be initialized to a specific decode/encode state.
class SingleMimeToolPanel extends StatefulWidget {
  final bool enabled;
  final bool hasSelection;
  final MimeCategory category;

  /// Whether the bar is on its decode face.
  ///
  /// Controlled by the host rather than held here, because the docked bar's
  /// title has to change with it — a panel that owned this state left the tab
  /// reading "Base64 Encode" while the button underneath said Decode.
  final bool decode;
  final ValueChanged<bool> onDecodeChanged;
  final ValueChanged<MimeOp> onRun;

  const SingleMimeToolPanel({
    super.key,
    required this.enabled,
    this.hasSelection = false,
    required this.category,
    required this.decode,
    required this.onDecodeChanged,
    required this.onRun,
  });

  @override
  State<SingleMimeToolPanel> createState() => _SingleMimeToolPanelState();
}

class _SingleMimeToolPanelState extends State<SingleMimeToolPanel> {
  bool get _decode => widget.decode;

  bool _b64Padding = true;
  bool _b64UnixEol = false;
  bool _b64Strict = false;
  bool _b64ByLine = false;

  UrlEncodeVariant _urlVariant = UrlEncodeVariant.rfc1738;
  bool _urlByLine = false;

  MimeOp get _currentOp {
    switch (widget.category) {
      case MimeCategory.base64:
        return MimeOp(
          category: MimeCategory.base64,
          decode: _decode,
          b64Padding: _b64Padding,
          b64UnixEol: _b64UnixEol,
          b64Strict: _b64Strict,
          byLine: _b64ByLine,
        );
      case MimeCategory.quotedPrintable:
        return MimeOp(category: MimeCategory.quotedPrintable, decode: _decode);
      case MimeCategory.url:
        return MimeOp(
          category: MimeCategory.url,
          decode: _decode,
          urlVariant: _urlVariant,
          byLine: _urlByLine,
        );
      case MimeCategory.saml:
        return const MimeOp(category: MimeCategory.saml, decode: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ..._optionWidgets(scheme),
        PanelScopeNote(
          enabled: widget.enabled,
          hasSelection: widget.hasSelection,
          disabledMessage: 'Open a document in Edit mode to run MIME tools.',
        ),
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow, size: 16),
          // Live label: the Encode/Decode selector above changes which
          // operation this button runs, so a constant 'Apply' would lie.
          label: Text(
            'Apply · ${_currentOp.label}',
            style: const TextStyle(fontSize: 13),
          ),
          style: _denseButtonStyle,
          onPressed: widget.enabled ? () => widget.onRun(_currentOp) : null,
        ),
      ],
    );
  }

  /// Material's default 48px tap target makes each wrap run of this bar 48px
  /// tall on its own, well over the docked bar's height budget (see the
  /// ceilings in test/tool_bar_layout_test.dart). shrinkWrap + compact density
  /// brings a run to ~32px while keeping the controls comfortably clickable.
  static final ButtonStyle _denseButtonStyle = FilledButton.styleFrom(
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    minimumSize: Size.zero,
  );

  static const ButtonStyle _denseSegmentedStyle = ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
  );

  List<Widget> _optionWidgets(ColorScheme scheme) {
    switch (widget.category) {
      case MimeCategory.base64:
        return _base64Options(scheme);
      case MimeCategory.quotedPrintable:
        return _quotedPrintableOptions(scheme);
      case MimeCategory.url:
        return _urlOptions(scheme);
      case MimeCategory.saml:
        return _samlOptions(scheme);
    }
  }

  Widget _modeSelector(bool decode, ValueChanged<bool> onChanged) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('Encode'),
          icon: Icon(Icons.lock_outline, size: 16),
        ),
        ButtonSegment(
          value: true,
          label: Text('Decode'),
          icon: Icon(Icons.lock_open, size: 16),
        ),
      ],
      selected: {decode},
      showSelectedIcon: false,
      style: _denseSegmentedStyle,
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => onChanged(v ?? false),
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }

  List<Widget> _base64Options(ColorScheme scheme) {
    return [
      _modeSelector(_decode, widget.onDecodeChanged),
      if (_decode) ...[
        _check('Strict', _b64Strict, (v) => setState(() => _b64Strict = v)),
        _check('By line', _b64ByLine, (v) => setState(() => _b64ByLine = v)),
      ] else ...[
        _check('Padding', _b64Padding, (v) => setState(() => _b64Padding = v)),
        _check('Unix EOL', _b64UnixEol, (v) => setState(() => _b64UnixEol = v)),
        _check('By line', _b64ByLine, (v) => setState(() => _b64ByLine = v)),
      ],
    ];
  }

  List<Widget> _quotedPrintableOptions(ColorScheme scheme) {
    return [_modeSelector(_decode, widget.onDecodeChanged)];
  }

  List<Widget> _urlOptions(ColorScheme scheme) {
    return [
      _modeSelector(_decode, widget.onDecodeChanged),
      if (!_decode) ...[
        SegmentedButton<UrlEncodeVariant>(
          segments: const [
            ButtonSegment(
              value: UrlEncodeVariant.rfc1738,
              label: Text('RFC1738'),
            ),
            ButtonSegment(
              value: UrlEncodeVariant.extended,
              label: Text('Extended'),
            ),
            ButtonSegment(value: UrlEncodeVariant.full, label: Text('Full')),
          ],
          selected: {_urlVariant},
          showSelectedIcon: false,
          style: _denseSegmentedStyle,
          onSelectionChanged: (s) => setState(() => _urlVariant = s.first),
        ),
        _check('By line', _urlByLine, (v) => setState(() => _urlByLine = v)),
      ],
    ];
  }

  List<Widget> _samlOptions(ColorScheme scheme) {
    return [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Base64-decode then raw-inflate (HTTP-Redirect binding); '
              'plain base64 tokens (POST binding) pass through.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    ];
  }
}

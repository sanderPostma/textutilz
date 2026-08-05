import 'package:flutter/material.dart';
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


/// A panel for a specific MIME tool category (e.g. Base64) without tabs.
/// Can be initialized to a specific decode/encode state.
class SingleMimeToolPanel extends StatefulWidget {
  final bool enabled;
  final bool hasSelection;
  final MimeCategory category;
  final bool initialDecode;
  final ValueChanged<MimeOp> onRun;

  const SingleMimeToolPanel({
    super.key,
    required this.enabled,
    this.hasSelection = false,
    required this.category,
    required this.initialDecode,
    required this.onRun,
  });

  @override
  State<SingleMimeToolPanel> createState() => _SingleMimeToolPanelState();
}

class _SingleMimeToolPanelState extends State<SingleMimeToolPanel> {
  late bool _decode;
  
  bool _b64Padding = true;
  bool _b64UnixEol = false;
  bool _b64Strict = false;
  bool _b64ByLine = false;

  UrlEncodeVariant _urlVariant = UrlEncodeVariant.rfc1738;
  bool _urlByLine = false;

  @override
  void initState() {
    super.initState();
    _decode = widget.initialDecode;
  }

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
        Text(
          widget.enabled
              ? (widget.hasSelection
                  ? 'Transforms the selection.'
                  : '⚠️ Transforms the whole document.')
              : 'Open a document in Edit mode to run MIME tools.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow, size: 16),
          // Live label: the Encode/Decode selector above changes which
          // operation this button runs, so a constant 'Apply' would lie.
          label: Text('Apply · ${_currentOp.label}',
              style: const TextStyle(fontSize: 13)),
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
        ButtonSegment(value: false, label: Text('Encode'), icon: Icon(Icons.lock_outline, size: 16)),
        ButtonSegment(value: true, label: Text('Decode'), icon: Icon(Icons.lock_open, size: 16)),
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
      _modeSelector(_decode, (v) => setState(() => _decode = v)),
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
    return [_modeSelector(_decode, (v) => setState(() => _decode = v))];
  }

  List<Widget> _urlOptions(ColorScheme scheme) {
    return [
      _modeSelector(_decode, (v) => setState(() => _decode = v)),
      if (!_decode) ...[
        SegmentedButton<UrlEncodeVariant>(
          segments: const [
            ButtonSegment(value: UrlEncodeVariant.rfc1738, label: Text('RFC1738')),
            ButtonSegment(value: UrlEncodeVariant.extended, label: Text('Extended')),
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

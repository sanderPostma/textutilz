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

/// The MIME-tools panel body: four tabs of option controls sharing one GO
/// button. GO applies the current [MimeOp] to the active editor via [onRun];
/// it is disabled unless [enabled] (active tab in Edit mode).
class MimeToolsPanel extends StatefulWidget {
  final bool enabled;

  /// True when the active editor has a selection: GO transforms just that span.
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
        return MimeOp(category: MimeCategory.quotedPrintable, decode: _qpDecode);
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
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTabBar(scheme),
            const SizedBox(height: 16),
            // IndexedStack keeps each tab's controls sized to the tallest so
            // the GO button doesn't jump as the user switches categories.
            IndexedStack(
              alignment: Alignment.topLeft,
              index: _tab.index,
              children: [
                _buildBase64(scheme),
                _buildQuotedPrintable(scheme),
                _buildUrl(scheme),
                _buildSaml(scheme),
              ],
            ),
            const SizedBox(height: 20),
            _buildSharedBar(scheme),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ColorScheme scheme) {
    return Wrap(
      spacing: 4,
      children: [
        for (final c in MimeCategory.values)
          _TabButton(
            label: c.label,
            selected: _tab == c,
            scheme: scheme,
            onTap: () => setState(() => _tab = c),
          ),
      ],
    );
  }

  /// Encode | Decode segmented control shared by the categories that have both.
  Widget _modeSelector(bool decode, ValueChanged<bool> onChanged) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, label: Text('Encode'), icon: Icon(Icons.lock_outline, size: 16)),
        ButtonSegment(value: true, label: Text('Decode'), icon: Icon(Icons.lock_open, size: 16)),
      ],
      selected: {decode},
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
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

  Widget _buildBase64(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _modeSelector(_b64Decode, (v) => setState(() => _b64Decode = v)),
        const SizedBox(height: 12),
        Wrap(
          runSpacing: 4,
          children: _b64Decode
              ? [
                  _check('Strict', _b64Strict, (v) => setState(() => _b64Strict = v)),
                  _check('By line', _b64ByLine, (v) => setState(() => _b64ByLine = v)),
                ]
              : [
                  _check('Padding', _b64Padding, (v) => setState(() => _b64Padding = v)),
                  _check('Unix EOL', _b64UnixEol, (v) => setState(() => _b64UnixEol = v)),
                  _check('By line', _b64ByLine, (v) => setState(() => _b64ByLine = v)),
                ],
        ),
      ],
    );
  }

  Widget _buildQuotedPrintable(ColorScheme scheme) {
    return _modeSelector(_qpDecode, (v) => setState(() => _qpDecode = v));
  }

  Widget _buildUrl(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _modeSelector(_urlDecode, (v) => setState(() => _urlDecode = v)),
        if (!_urlDecode) ...[
          const SizedBox(height: 12),
          SegmentedButton<UrlEncodeVariant>(
            segments: const [
              ButtonSegment(value: UrlEncodeVariant.rfc1738, label: Text('RFC1738')),
              ButtonSegment(value: UrlEncodeVariant.extended, label: Text('Extended')),
              ButtonSegment(value: UrlEncodeVariant.full, label: Text('Full')),
            ],
            selected: {_urlVariant},
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            onSelectionChanged: (s) => setState(() => _urlVariant = s.first),
          ),
          const SizedBox(height: 8),
          _check('By line', _urlByLine, (v) => setState(() => _urlByLine = v)),
        ],
      ],
    );
  }

  Widget _buildSaml(ColorScheme scheme) {
    return Row(
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
    );
  }

  Widget _buildSharedBar(ColorScheme scheme) {
    final op = _currentOp;
    return Row(
      children: [
        Expanded(
          child: Text(
            widget.enabled
                ? (widget.hasSelection
                    ? 'Transforms the selection.'
                    : 'Transforms the whole document.')
                : 'Open a document in Edit mode to run MIME tools.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: widget.enabled ? () => widget.onRun(op) : null,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text('GO · ${op.label}'),
        ),
      ],
    );
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
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
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
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow, size: 16),
          label: const Text('Apply'),
          onPressed: widget.enabled ? () => widget.onRun(_currentOp) : null,
        ),
      ],
    );
  }

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
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
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
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/jwt.dart' as rust_jwt;
import 'package:textutilz/src/rust/api/paths.dart' as rust_paths;
import 'dart:async';
import 'editor.dart';

enum JwtMode { encode, decode }

class JwtToolView extends StatefulWidget {
  final String initialEncoded;
  final JwtMode mode;

  const JwtToolView({
    super.key,
    required this.initialEncoded,
    required this.mode,
  });

  @override
  State<JwtToolView> createState() => _JwtToolViewState();
}

class _JwtToolViewState extends State<JwtToolView> {
  final GlobalKey<CustomEditorState> _encodedKey =
      GlobalKey<CustomEditorState>();
  final GlobalKey<CustomEditorState> _headerKey =
      GlobalKey<CustomEditorState>();
  final GlobalKey<CustomEditorState> _payloadKey =
      GlobalKey<CustomEditorState>();

  EditSession? _encodedSession;
  EditSession? _headerSession;
  EditSession? _payloadSession;

  final TextEditingController _secretController = TextEditingController();

  bool _isInitialized = false;
  bool _isValid = false;
  String? _errorMsg;
  Timer? _debounce;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _initSessions();
  }

  Future<void> _initSessions() async {
    try {
      final scratchDir = rust_paths.scratchDir();
      final t = DateTime.now().millisecondsSinceEpoch;

      _encodedSession = EditSession.createScratch(
        path: '$scratchDir/jwt_enc_$t.txt',
        content: widget.initialEncoded,
      );
      _headerSession = EditSession.createScratch(
        path: '$scratchDir/jwt_hdr_$t.json',
        content: '{}',
      );
      _payloadSession = EditSession.createScratch(
        path: '$scratchDir/jwt_pay_$t.json',
        content: '{}',
      );

      if (widget.initialEncoded.isNotEmpty) {
        _syncFromEncoded();
      }

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      debugPrint("Failed to init JWT tool sessions: $e");
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _syncFromEncoded() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final token = _encodedSession!.contentString();
      final secret = _secretController.text;

      final result = rust_jwt.decodeJwt(
        token: token,
        secret: secret.isEmpty ? null : secret,
      );

      String headerText = result.header;
      String payloadText = result.payload;

      // If it's completely malformed, or the base64 decoder fell back to "{}", clear the boxes.
      if (result.error != null && result.error!.contains("format")) {
        headerText = "";
        payloadText = "";
      } else {
        if (headerText == "{}") headerText = "";
        if (payloadText == "{}") payloadText = "";
      }

      if (_headerKey.currentState != null) {
        _headerKey.currentState!.replaceAll(
          headerText,
          requestFocus: false,
          ignoreReadOnly: true,
        );
      } else {
        _headerSession!.replaceAll(text: headerText);
      }

      if (_payloadKey.currentState != null) {
        _payloadKey.currentState!.replaceAll(
          payloadText,
          requestFocus: false,
          ignoreReadOnly: true,
        );
      } else {
        _payloadSession!.replaceAll(text: payloadText);
      }

      setState(() {
        _isValid = result.isValid;
        _errorMsg = result.error;
      });
    } catch (e) {
      setState(() {
        _isValid = false;
        _errorMsg = e.toString();
      });
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _syncFromDecoded() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final header = _headerSession!.contentString();
      final payload = _payloadSession!.contentString();
      final secret = _secretController.text;

      if (secret.isEmpty) {
        setState(() {
          _errorMsg = "Secret required for signing";
          _isValid = false;
        });
        _isSyncing = false;
        return;
      }

      final token = rust_jwt.encodeJwt(
        header: header,
        payload: payload,
        secret: secret,
      );

      if (_encodedKey.currentState != null) {
        _encodedKey.currentState!.replaceAll(
          token,
          requestFocus: false,
          ignoreReadOnly: true,
        );
      } else {
        _encodedSession!.replaceAll(text: token);
      }

      setState(() {
        _isValid = true;
        _errorMsg = null;
      });
    } catch (e) {
      if (_encodedKey.currentState != null) {
        _encodedKey.currentState!.replaceAll(
          "",
          requestFocus: false,
          ignoreReadOnly: true,
        );
      } else {
        _encodedSession!.replaceAll(text: "");
      }

      setState(() {
        _isValid = false;
        _errorMsg = e.toString();
      });
    } finally {
      _isSyncing = false;
    }
  }

  void _onEncodedChanged() {
    if (_isSyncing) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _syncFromEncoded();
    });
  }

  void _onDecodedChanged() {
    if (_isSyncing) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _syncFromDecoded();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final decodedPanel = Expanded(
      flex: 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Decoded", "Edit payload or header to re-sign"),
          Expanded(
            child: Column(
              children: [
                // Header
                Expanded(
                  flex: 1,
                  child: _buildEditorWithHeader(
                    context: context,
                    title: 'HEADER',
                    editorKey: _headerKey,
                    session: _headerSession!,
                    readOnly: widget.mode == JwtMode.decode,
                    onChanged: _onDecodedChanged,
                    borderColor: Colors.red.withOpacity(0.5),
                    showLineNumbers: true,
                  ),
                ),
                // Payload
                Expanded(
                  flex: 2,
                  child: _buildEditorWithHeader(
                    context: context,
                    title: 'PAYLOAD',
                    editorKey: _payloadKey,
                    session: _payloadSession!,
                    readOnly: widget.mode == JwtMode.decode,
                    onChanged: _onDecodedChanged,
                    borderColor: Colors.purple.withOpacity(0.5),
                    showLineNumbers: true,
                  ),
                ),
              ],
            ),
          ),
          // Signature / Verify section
          Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF2C2C2C) : const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isValid
                    ? Colors.green
                    : (secretEmpty() ? scheme.outlineVariant : Colors.red),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      "VERIFY SIGNATURE",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: scheme.primary,
                      ),
                    ),
                    const Spacer(),
                    if (_isValid)
                      const Icon(
                        Icons.check_circle,
                        color: Colors.green,
                        size: 16,
                      )
                    else if (!secretEmpty())
                      const Icon(Icons.error, color: Colors.red, size: 16),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _secretController,
                  maxLines: null,
                  minLines: 1,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  onChanged: (_) => _onDecodedChanged(),
                  decoration: const InputDecoration(
                    labelText: 'Secret / Private Key / Public Key',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_errorMsg != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorMsg!,
                    style: const TextStyle(color: Colors.red, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    final encodedPanel = Expanded(
      flex: 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader("Encoded", "Paste a token here"),
          Expanded(
            child: _buildEditorWithHeader(
              context: context,
              title: 'ENCODED JWT',
              editorKey: _encodedKey,
              session: _encodedSession!,
              readOnly: widget.mode == JwtMode.encode,
              onChanged: _onEncodedChanged,
              borderColor: scheme.outlineVariant,
              showLineNumbers: false,
            ),
          ),
        ],
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.mode == JwtMode.decode) encodedPanel else decodedPanel,
        const VerticalDivider(width: 1),
        if (widget.mode == JwtMode.decode) decodedPanel else encodedPanel,
      ],
    );
  }

  bool secretEmpty() => _secretController.text.isEmpty;

  Widget _buildHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorWithHeader({
    required BuildContext context,
    required String title,
    required GlobalKey<CustomEditorState> editorKey,
    required EditSession session,
    required bool readOnly,
    required VoidCallback? onChanged,
    required Color borderColor,
    required bool showLineNumbers,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerColor = borderColor.withOpacity(isDark ? 0.2 : 0.1);

    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: headerColor,
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    final text = session.contentString();
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Copied $title'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(2.0),
                    child: Icon(Icons.copy, size: 14),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: CustomEditor(
              key: editorKey,
              session: session,
              showLineNumbers: showLineNumbers,
              fontSize: 14.0,
              readOnly: readOnly,
              onContentChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

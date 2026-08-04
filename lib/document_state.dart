import 'package:flutter/widgets.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/hex_session.dart';
import 'package:textutilz/src/rust/api/store.dart';
import 'editor.dart';

/// Days since the Unix epoch for *today's* local date. Used to decide whether an
/// `atMidnight` document has crossed a midnight boundary. Stable for comparison
/// because it is always computed from local midnight.
int currentEpochDay() {
  final now = DateTime.now();
  // 86400000 ms per day; local-midnight instant keeps the value monotonic.
  return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 86400000;
}

/// Cursor / selection stats shown in the status bar.
class EditorStats {
  final int row;
  final int col;
  final int selChars;
  final int selLines;

  const EditorStats({
    this.row = 1,
    this.col = 1,
    this.selChars = 0,
    this.selLines = 0,
  });
}

/// View modes for a document. Kept as plain strings to match the existing
/// SegmentedButton values, with a canonical list here.
class ViewMode {
  static const String read = 'Read';
  static const String tail = 'Tail';
  static const String edit = 'Edit';
  static const String hex = 'Hex';
  static const List<String> all = [read, tail, edit, hex];
}

/// Auto-delete policy for transient (scratch) documents.
enum AutoDelete { off, onAppClose, atMidnight }

extension AutoDeleteLabel on AutoDelete {
  String get label => switch (this) {
        AutoDelete.off => 'Off',
        AutoDelete.onAppClose => 'When closing the app',
        AutoDelete.atMidnight => 'At midnight',
      };
}

/// Serializable per-document metadata. This is the unit we will persist to
/// sqlite; it holds no Flutter/runtime handles. Font sizes are per-view.
class DocumentMeta {
  final String id;
  String displayName;
  String path;
  bool isTransient; // scratch/new file vs a user-opened file
  String contentType;
  String extension;
  AutoDelete autoDelete;
  String viewMode;

  /// Epoch day the document was created. Drives the `atMidnight` purge; 0 for
  /// restored real files (irrelevant there).
  int createdDay;

  /// Font size per view mode (keys: Read/Tail/Edit).
  final Map<String, double> fontSizes;

  DocumentMeta({
    required this.id,
    required this.displayName,
    required this.path,
    this.isTransient = false,
    this.contentType = 'Plain Text',
    this.extension = 'txt',
    this.autoDelete = AutoDelete.off,
    this.viewMode = ViewMode.read,
    int? createdDay,
    Map<String, double>? fontSizes,
  })  : createdDay = createdDay ?? currentEpochDay(),
        fontSizes = fontSizes ??
            {
              ViewMode.read: 14.0,
              ViewMode.tail: 14.0,
              ViewMode.edit: 14.0,
              ViewMode.hex: 14.0,
            };

  double fontSizeFor(String mode) => fontSizes[mode] ?? 14.0;
  void setFontSize(String mode, double size) => fontSizes[mode] = size;

  static int _idCounter = 0;
  static String newId() => 'doc-${_idCounter++}';

  /// Ensure future generated ids never collide with a restored id like `doc-7`.
  static void reserveId(String id) {
    if (id.startsWith('doc-')) {
      final n = int.tryParse(id.substring(4));
      if (n != null && n >= _idCounter) _idCounter = n + 1;
    }
  }

  /// Rebuild metadata from a persisted [DocRecord].
  factory DocumentMeta.fromRecord(DocRecord r) => DocumentMeta(
        id: r.id,
        displayName: r.displayName,
        path: r.path,
        isTransient: r.isTransient,
        contentType: r.contentType,
        extension: r.extension_,
        autoDelete: AutoDelete.values
            .firstWhere((a) => a.name == r.autoDelete, orElse: () => AutoDelete.off),
        viewMode: r.viewMode,
        createdDay: r.createdDay,
        fontSizes: {
          ViewMode.read: r.fontRead,
          ViewMode.tail: r.fontTail,
          ViewMode.edit: r.fontEdit,
        },
      );

}

/// The result of the "New document" panel, handed back to the host to create
/// the tab + backing scratch file.
class NewDocumentRequest {
  final String name;
  final String contentType;
  final String extension;
  final AutoDelete autoDelete;

  const NewDocumentRequest({
    required this.name,
    required this.contentType,
    required this.extension,
    required this.autoDelete,
  });
}

/// A live tab: its persistable [meta] plus the runtime-only handles that never
/// go to the database. The document itself lives in Rust ([session]); this
/// class only carries view state.
class TabRuntime {
  final DocumentMeta meta;

  /// The Rust-owned editable document (mmap base + copy-on-write overlay +
  /// undo/redo). Source of truth for line content, count, and dirtiness.
  final EditSession session;
  final ScrollController scrollController = ScrollController();
  final ValueNotifier<EditorStats> stats = ValueNotifier(const EditorStats());
  final GlobalKey<CustomEditorState> editorKey = GlobalKey<CustomEditorState>();
  DateTime? lastModified;
  bool tailAutoScroll = true;

  /// When non-null, this tab is displaying a specialized tool (e.g., 'jwt.encode')
  /// instead of the standard Read/Tail/Edit viewer.
  String? activeTool;

  /// Byte-oriented editable document for [ViewMode.hex], created lazily the
  /// first time the tab is shown in hex mode. Separate from [session] (the
  /// text/line document); the two carry independent overlays.
  HexSession? _hexSession;

  /// The hex document for this tab, opening it over the same file on first use.
  HexSession get hexSession =>
      _hexSession ??= HexSession.open(path: meta.path);

  TabRuntime({required this.meta, required this.session});

  // Convenience pass-throughs so call sites stay concise.
  String get name => meta.displayName;
  String get path => meta.path;
  String get mode => meta.viewMode;
  set mode(String m) => meta.viewMode = m;
  int get lineCount => session.lineCount().toInt();

  /// Dirtiness is owned by the Rust session (cleared on save). In hex mode the
  /// byte session is the source of truth.
  bool get isDirty => meta.viewMode == ViewMode.hex
      ? (_hexSession?.isDirty() ?? false)
      : session.isDirty();
  double get fontSize => meta.fontSizeFor(meta.viewMode);

  /// Snapshot this tab as a persistable [DocRecord]. Scratch (transient) docs
  /// carry their live content so they can be rehydrated on the next launch;
  /// real files store only their path + view state.
  DocRecord toRecord({required int order, required bool active}) => DocRecord(
        id: meta.id,
        displayName: meta.displayName,
        path: meta.path,
        isTransient: meta.isTransient,
        contentType: meta.contentType,
        extension_: meta.extension,
        autoDelete: meta.autoDelete.name,
        viewMode: meta.viewMode,
        fontRead: meta.fontSizeFor(ViewMode.read),
        fontTail: meta.fontSizeFor(ViewMode.tail),
        fontEdit: meta.fontSizeFor(ViewMode.edit),
        scratchContent: meta.isTransient ? session.contentString() : null,
        createdDay: meta.createdDay,
        tabOrder: order,
        isActive: active,
      );
}

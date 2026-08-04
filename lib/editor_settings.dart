import 'package:flutter/foundation.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/hex_session.dart';

/// App-wide editor preferences, shared by *every* editor — the main text editor
/// and the hex editor alike. This is the single source of truth; a future
/// settings/config panel only has to bind its controls to these notifiers, and
/// all open editors update through the existing propagation in the host.

/// Store-settings key for the undo-coalescing preference.
const String kUndoCoalescingSetting = 'undo_coalescing';

/// Whether consecutive single-character typing merges into one undo step
/// (`true`, the classic word-at-a-time behavior) or each keystroke is its own
/// undo step (`false`).
///
/// Defaults to per-keystroke. Flip this notifier (e.g. from a future settings
/// panel) and the host applies it to every open editor and persists it.
final ValueNotifier<bool> undoCoalescingNotifier = ValueNotifier<bool>(false);

/// Push the current undo-coalescing preference into a text [EditSession].
void applyUndoSettingToText(EditSession s) =>
    s.setCoalesceUndo(on_: undoCoalescingNotifier.value);

/// Push the current undo-coalescing preference into a [HexSession].
void applyUndoSettingToHex(HexSession s) =>
    s.setCoalesceUndo(on_: undoCoalescingNotifier.value);

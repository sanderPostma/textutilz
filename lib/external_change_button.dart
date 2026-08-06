import 'package:flutter/material.dart';

/// Explicit reload affordance for a file that changed outside TextUtilz.
///
/// Amber means reloading is safe; red warns that the current session also has
/// unsaved edits and pressing the button will require confirmation.
class ExternalChangeButton extends StatelessWidget {
  final bool hasUnsavedChanges;
  final VoidCallback onReload;

  const ExternalChangeButton({
    super.key,
    required this.hasUnsavedChanges,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    final background = hasUnsavedChanges
        ? Colors.red.shade700
        : Colors.amber.shade600;
    final foreground = hasUnsavedChanges ? Colors.white : Colors.black;
    final message = hasUnsavedChanges
        ? 'File changed on disk; reload will discard unsaved changes'
        : 'File changed on disk; reload';

    return Tooltip(
      message: message,
      child: FilledButton.icon(
        onPressed: onReload,
        icon: const Icon(Icons.refresh, size: 17),
        label: const Text('Reload'),
        style: FilledButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

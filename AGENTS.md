# Repository Guidelines

## Project Structure & Module Organization

This is a Flutter desktop text editor with a Rust backend. Keep Flutter UI and
application state in `lib/` (`main.dart` is the entry point; `editor.dart`
contains editor behavior). Rust APIs and file-buffering code live in
`rust/src/`, with public bridge APIs under `rust/src/api/`. Generated
Flutter-Rust Bridge bindings are in `lib/src/rust/`; update them through the
bridge generator rather than hand-editing them. `rust_builder/` is generated
native-build glue and should be left alone. Put unit/widget tests in `test/`
and device-backed integration tests in `integration_test/`.

## Build, Test, and Development Commands

- `flutter pub get` — resolve Flutter and native-build dependencies.
- `flutter analyze` — run the configured Dart/Flutter lints.
- `dart format lib test integration_test` — format Dart sources before review.
- `flutter test` — run widget and unit tests.
- `flutter test integration_test` — run the Rust bridge integration test on a
  supported target.
- `cargo test --manifest-path rust/Cargo.toml` and `cargo fmt --manifest-path rust/Cargo.toml` — test and format the Rust crate.
- `flutter run -d linux` — launch the desktop application locally.

## Coding Style & Naming Conventions

Follow `flutter_lints` and use `dart format` output (two-space Dart
indentation). Name Dart files in `snake_case.dart`, types in `PascalCase`, and
members in `camelCase`. Keep widgets small and dispose controllers and focus
nodes. Rust targets edition 2021: run `cargo fmt`, use `snake_case` for
functions/modules and `PascalCase` for types. Preserve the existing
Flutter-Rust Bridge annotations and regenerate bindings after changing exposed
Rust APIs.

## Testing Guidelines

Name tests for the behavior they verify, e.g. `testWidgets('opens selected file', ...)`.
Add widget coverage for UI changes and Rust tests beside the relevant Rust
module for file-buffer behavior. Run analysis plus the relevant Flutter and
Rust tests before submitting; no coverage threshold is configured.

## Commit & Pull Request Guidelines

This checkout contains no Git history, so no repository-specific convention
can be derived. Use concise, imperative subjects such as `Add file reload
action`; keep each commit focused. Pull requests should describe the user
impact, list commands run, link related issues, and include screenshots or a
short recording for visible editor changes. Flag generated binding updates and
platform-specific behavior explicitly.

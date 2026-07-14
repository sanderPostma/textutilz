# textutilz

> 🚧 **Note:** This project is currently under construction and in its early phases of development. Expect rapid changes and potential instabilities.

`textutilz` is a modern desktop text editor built with Flutter and powered by a high-performance Rust backend. It is designed to provide a rich set of text manipulation tools and a responsive editing experience.

## Features

- **Tabbed Editing:** Manage multiple open files concurrently in a clean, tabbed interface.
- **Robust File Operations:** Fast, safe file reading and writing leveraging Rust's `std::fs`.
- **MIME Tools:** Built-in utilities to quickly transform text, including:
  - Base64 Encode/Decode
  - URL Encode/Decode
  - Quoted-Printable Encode/Decode
  - SAML Decode
- **Command Registry:** A unified, searchable command palette allowing quick access to all editor actions and tools.

## Architecture

This project uses [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/) to connect a polished Flutter frontend to a memory-safe, concurrent Rust backend.

- **Frontend (`lib/`):** Manages UI components, theming, and state management in Dart.
- **Backend (`rust/`):** Handles file buffering, encoding, decoding, and command logic.

## Building and Running

### Prerequisites
- Flutter SDK (with Linux desktop support enabled)
- Rust toolchain (`rustup`, `cargo`)
- `flutter_rust_bridge_codegen` (for modifying Rust bindings)

### Quick Start

1. **Resolve dependencies:**
   ```bash
   flutter pub get
   ```

2. **Generate Rust bindings (if making backend changes):**
   ```bash
   flutter_rust_bridge_codegen generate
   ```

3. **Run the application:**
   ```bash
   flutter run -d linux
   ```

### Testing

Run the Flutter widget and unit tests:
```bash
flutter test
```

Test the Rust backend:
```bash
cargo test --manifest-path rust/Cargo.toml
```

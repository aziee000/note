# Secure Notepad (Dart CLI)

End-to-end encrypted note taking in your terminal. Notes and titles are encrypted with AES‑GCM using a key derived from your master password via PBKDF2‑HMAC‑SHA256.

## Setup

```bash
cd /workspace
dart pub get
```

## Usage

```bash
# Initialize (will prompt for master password)
dart run bin/secure_notes.dart --command init

# Add a note (will prompt for password if not provided via env)
dart run bin/secure_notes.dart --command add --title "Bank" --body "Account: 1234"

# List notes
dart run bin/secure_notes.dart --command list

# Show a note by id
dart run bin/secure_notes.dart --command show --id <id>

# Edit a note
dart run bin/secure_notes.dart --command edit --id <id> --title "New title"

# Delete a note
dart run bin/secure_notes.dart --command delete --id <id>

# Full-text search
dart run bin/secure_notes.dart --command search --query secret

# Change master password
dart run bin/secure_notes.dart --command change-password
```

### Options
- `--dir`: custom data directory (default: `$HOME/.secure_notes`)
- `--password-env`: name of env var containing the master password (non-interactive use)

## Security Notes
- AES‑GCM (256-bit) with per-note random nonces.
- Keys derived with PBKDF2‑HMAC‑SHA256 (200k iterations) and a random salt.
- A key confirmation record prevents accidental wrong passwords.
- Files are created under `$HOME/.secure_notes` with restrictive permissions (best-effort `chmod 700`).

Keep your master password safe. Losing it means your data cannot be recovered.
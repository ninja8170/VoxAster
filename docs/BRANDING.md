# VoxAster branding and compatibility

VoxAster is the application: **Local AI Voice Studio for macOS**. OmniVoice is the upstream synthesis technology. Engine names, native markup descriptions and model provenance retain the upstream name.

## Product identity

The build produces `VoxAster.app`, executable `VoxAster` and `VoxAster.icns`. The Swift app entry point is `VoxAsterApp` in `Sources/VoxAster.swift`. Window/menu/About names come from the VoxAster scene and bundle metadata. There is no Xcode project, scheme or Swift package to rename; scripts compile the Swift sources directly. App version remains 3.7.0. Assets contain a waveform icon, not a text wordmark.

## Preserved compatibility identifiers

- Bundle ID `local.omnivoice.native`: keeps the macOS app/preference/permission identity. No new preferences domain or Keychain namespace is introduced.
- `~/Documents/OmniVoice-Mac`: environments, saved audio/references, training engines and Performance productions.
- `~/Library/Application Support/OmniVoice`: projects, history, reference metadata and recoverable drafts.
- `~/Library/Logs/OmniVoice`: the existing backend log location.
- `OMNIVOICE_PYTHON`, `OMNIVOICE_SETUP_PYTHON`, `OMNIVOICE_SETUP_VENV`, `OMNIVOICE_DATA_ROOT`: existing script/environment interfaces.
- Engine IDs such as `OmniVoice Zero-Shot`, the backend `omnivoice` readiness field, Python package/API/CLI symbols, and upstream repository/model IDs remain unchanged. Saved productions and drafts use those engine IDs.
- Build protection and installer process detection still recognize `OmniVoice.app` / the `OmniVoice` process to protect legacy installations and avoid backend conflicts.
- The existing local checkout and unsanitized remote retain a legacy repository name. Public setup instructions deliberately do not point at that remote. Publish sanitized history to a new repository after approval; do not rename the similarly named runtime-data directory.

Installation targets `~/Applications/VoxAster.app`. It does not remove or replace a legacy-named bundle automatically. Only one app/backend may run at a time; both use the existing data. Renaming an app does not migrate or delete recordings, preferences, projects or drafts. The product rename itself changes no dependency, model or tokenizer pins. The separately approved audio-tokenizer licensing migration is documented in [TOKENIZER.md](TOKENIZER.md).

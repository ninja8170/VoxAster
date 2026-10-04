# VoxAster

**Local AI Voice Studio for macOS**

A native macOS app for local voice cloning, voice design and speech production on Apple Silicon. Built with SwiftUI and the [k2-fsa OmniVoice](https://github.com/k2-fsa/OmniVoice) synthesis engine. This is an independent project, not an official k2-fsa app.

**Version 3.7.0 · macOS 14+ · Apple Silicon · source distribution**

The app code and original icons are MIT licensed. **Model weights have separate terms, including non-commercial restrictions.** Free download does not mean unrestricted commercial use. Read [third-party licences](THIRD_PARTY.md) before using or distributing models or outputs.

## Model attribution

Built with Higgs Materials licensed from Boson AI USA, Inc., Copyright Boson AI USA, Inc., All Rights Reserved and Meta Llama 3 licensed under the Meta Llama 3 Community License, Copyright Meta Platforms, Inc., All Right Reserved.

Built with Meta Llama 3; based on Meta Llama 3. Copies of the [Boson agreement](Licenses/BOSON-HIGGS-AUDIO-2.txt), [Meta agreement and acceptable-use policy](Licenses/META-LLAMA-3.txt) and [Notice](Notice) accompany this source and built app. These are restricted community licences, not MIT/Apache or unrestricted open-source terms.

## Features

- Clone a voice from an imported recording or microphone take; save reusable references.
- Design voices using supported speaker attributes, with native vocal-event and pronunciation controls.
- Generate variants, edit Long Form chunks, manage projects and recover editable drafts.
- Performance: exact pauses, ±3 dB segment gain, retained segment retries and deterministic master rebuilds.
- Optional comparison with separately installed F5-TTS and inference from existing saved engines.

Training, dataset token extraction, LoRA/fine-tuning and model improvement are not included in this release.

Performance controls are audio timing/loudness operations, not emotional acting. Unknown bracket tags are rejected. See [script controls](docs/CONTROLS.md).

## Requirements

- Apple Silicon Mac, macOS 14 or newer; Intel/Windows/Linux app builds are not supported.
- Xcode Command Line Tools (`xcode-select --install`), including Swift and the macOS SDK.
- Homebrew Python **3.12**, Git and FFmpeg (`brew install python@3.12 ffmpeg git`).
- Internet for dependency/model downloads; several GB of free space for the model and environments. No minimum RAM guarantee has been established.
- A recording you have permission to use. Microphone access is needed only for recording.

## Installation and build from source

Download the source archive or clone this repository using its GitHub **Code** menu, then enter the extracted/clone directory (named `VoxAster` below). No prebuilt installer or model weights are included.

```sh
cd VoxAster
./setup-runtime.command
./verify-runtime.command
./build.command
open .build/VoxAster.app
```

Setup creates `~/Documents/OmniVoice-Mac/.venv` and downloads the exact model snapshot declared in `Backend/runtime.json`. It refuses to overwrite an existing runtime. It does not install the app, change model pins, or require an API key. If setup is interrupted, inspect the partially created environment before moving it aside and retrying. Existing users should run `./prepare-models.command` once to cache the official, verified audio tokenizer, then `./verify-runtime.command`. This does not install or upgrade Python packages.

The app deliberately uses that per-user runtime path regardless of where the source checkout lives. Build/tests can select a different Python with `OMNIVOICE_PYTHON`; that override does not change the native app runtime location. `OMNIVOICE_SETUP_PYTHON` and `OMNIVOICE_SETUP_VENV` are setup/test overrides.

`requirements.txt` pins OmniVoice to commit `08be0b4ccbac3e13e374e86fbfead4b4cac343e2` (package 0.2.1); `constraints-macos-py312.txt` records the validated dependency environment. The model and text tokenizer use snapshot `c5fdb5ccb189668d56333f77ba2629f4cd7535f4`. The separate audio tokenizer uses official `bosonai/higgs-audio-v2-tokenizer` revision `815a03f1b57dcb5ae918db415f22cd0c8a6f0f54`, verified against pinned SHA-256 hashes. Missing or changed audio assets stop startup; there is no mirror fallback. See [tokenizer provenance](docs/TOKENIZER.md). Build and test commands do not install dependencies.

For an optional per-user application installation, quit every VoxAster instance and any legacy app first and run `./install.command`. It verifies the build, requires port 8011 to be free, stages on the destination filesystem and retains a timestamped backup of any existing app. The destination is `~/Applications/VoxAster.app`; the legacy app bundle is left untouched. Both apps share the same data and cannot run their backends simultaneously. No administrator access is needed. Keep the backup for rollback.

Source builds are ad-hoc signed, **not Developer ID signed or notarized**. Do not disable Gatekeeper globally. Review the source and build locally; public binary distribution needs a separate signing/notarization process.

## First use

1. Wait for **Ready**. Settings shows the exact runtime provenance.
2. Open Voice Clone and choose a short, clean reference recording. A transcript avoids automatic reference transcription and its optional model download.
3. Enter a short script, choose settings and Generate Speech. Export a WAV using the output controls.
4. In Performance, use Pause/Louder/Quieter controls, prepare a production, render segments and rebuild its master. Retrying one segment retains other successful segments.
5. Save references in Library and metadata in Projects. Editable drafts recover separately from audio productions.

Standard macOS editing shortcuts apply. Quit with Command-Q; closing a window is not the same as quitting the app. Only one app backend can use port 8011 at a time.

## Models and engines

Core setup downloads the pinned OmniVoice snapshot automatically; normal app startup loads that cache without downloading the base model. Missing reference transcripts can trigger a separate Whisper download. Optional F5 requires separate setup and may download additional assets. Training is not available. Models and Python runtimes are not bundled into the app. Their terms differ from the app’s MIT licence.

## Privacy, permissions and storage

Synthesis and transcription run locally. The app does not implement audio uploads to external services or analytics. Setup and optional model loading contact package/model hosts; dependencies may perform download checks. This is not an unconditional air-gapped/offline claim. See [PRIVACY.md](PRIVACY.md) for exact storage, network and removal details.

- References, WAVs, existing saved engines and productions: `~/Documents/OmniVoice-Mac/`
- Projects, history, reference metadata and drafts: `~/Library/Application Support/OmniVoice/`
- Backend log: `~/Library/Logs/OmniVoice/native-backend.log`
- Downloaded models: Hugging Face's user cache (normally `~/.cache/huggingface/`).

Legacy storage names and the bundle identifier are deliberately preserved so existing projects, voices, drafts and preferences remain accessible. See [branding and compatibility](docs/BRANDING.md).

No user recordings or model weights are shipped in this repository. The app is not sandboxed; it has your user's filesystem permissions. macOS may request microphone and Documents access.

## Troubleshooting and limitations

- **Runtime setup required:** run setup, or `./verify-runtime.command` if the environment exists.
- **Loading/Backend stopped:** inspect the backend log, verify the exact model is cached, and check `lsof -nP -iTCP:8011 -sTCP:LISTEN`. Quit the app that owns the port; do not kill an unidentified process.
- **Wrong package/model:** restore the verified environment; do not change pins just to bypass the provenance check.
- **Microphone denied:** System Settings → Privacy & Security → Microphone.
- **Literal Markdown or odd speech:** asterisks/Markdown are not acting controls; use plain text and verified tokens.
- Performance supports base OmniVoice reference cloning only. `[deadpan]`, `[sarcastic]`, `[whisper]` and `[shout]` are not inline controls. F5 does not accept OmniVoice markup.
- Output quality, accent and identity continuity require listening checks. Seeds are forwarded; bit-identical synthesis across hardware is not guaranteed.
- Drafts restore editable text/settings, not unsaved output takes. Back up the data directories for durable storage.
- Training is removed from this public release; existing saved engines/data are preserved. See [engine limitations](docs/TRAINING.md). F5 is optional and not provisioned by core setup.
- Higgs materials/outputs must not be used to improve other large language models. Boson requires separate permission above 100,000 annual active users across your/affiliates’ products or services in the preceding calendar year. The incorporated acceptable-use terms also apply; see [third-party obligations](THIRD_PARTY.md).

## Development

```sh
./test.command                   # backend + Swift + signed release/import test
./verify-runtime.command         # dependencies, cached snapshot and provenance
git diff --check
python3 tools/audit-release.py    # working tree/history heuristics and doc links
```

Tests mock synthesis and use temporary output directories. Real model startup and listening acceptance remain separate. No lint configuration is currently provided. Contributions: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md). Release history: [CHANGELOG.md](CHANGELOG.md).

The app source and icons are covered by [MIT](LICENSE). Dependencies/models keep their own licences; see [credits and third-party terms](THIRD_PARTY.md). Use only voices and recordings you are authorized to use.

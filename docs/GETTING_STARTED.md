# Build and use VoxAster 3.8.0

VoxAster's public release is **source-only**. There is no official downloadable `.app` or installer. The original app code/icons are MIT licensed; models and dependencies have their own terms. Start with the [README quick start](../README.md#get-started) and [third-party licences](../THIRD_PARTY.md).

## Choose your source

The README commands check out the immutable `v3.8.0` release tag. Git may describe this as a detached HEAD; that is expected when building a tagged release. Contributors should use a working branch for changes.

Alternatively, download **Source code (zip)** for the [v3.8.0 tag](https://github.com/ninja8170/VoxAster/archive/refs/tags/v3.8.0.zip), extract it and open Terminal in the extracted folder. After installing the documented prerequisites, run:

```sh
./setup-runtime.command
./verify-runtime.command
./build.command
open .build/VoxAster.app
```

No build or test command installs Python dependencies. `setup-runtime.command` is the explicit setup step that does so. Setup requires internet for package/model downloads; neither model weights nor a Python environment are shipped in the source archive.

## Existing runtime

If you have used an earlier OmniVoice/VoxAster build, setup deliberately preserves its environment. From your source directory, run:

```sh
./prepare-models.command
./verify-runtime.command
./build.command
open .build/VoxAster.app
```

`prepare-models.command` caches the approved pinned models, including the official Boson audio tokenizer, and verifies its hashes. It does not upgrade Python packages. If verification reports a different package/model, stop and inspect the runtime; do not change pins to bypass the check. If setup was interrupted, inspect the partially created environment before moving it aside and retrying.

## What setup creates

| Location | Purpose |
|---|---|
| `~/Documents/OmniVoice-Mac/.venv` | Per-user Python runtime used by the native app |
| Hugging Face user cache, normally `~/.cache/huggingface/` | Separately downloaded model assets |
| `.build/VoxAster.app` in the source checkout | Locally built, ad-hoc-signed app |

The legacy runtime/data names are intentional. Existing projects, references, drafts and preferences continue to use the same storage. Do not rename or delete those directories as part of installing VoxAster. See [storage and privacy](../PRIVACY.md) and [branding compatibility](BRANDING.md).

Core setup downloads the exact base model/text tokenizer snapshot and the separately pinned official Boson audio tokenizer declared in [runtime.json](../Backend/runtime.json). Normal base-model startup resolves the local cache. Missing reference transcripts, the Reference Cleaner and Take Doctor use Whisper, which is downloaded separately the first time it is needed.

## First session

1. Wait for **Engine ready** under the window title. **Settings (⌘,) → Engine** lists the app, package and model/tokenizer provenance.
2. Choose a mode in the toolbar. **Voice Design**: pick attributes or a preset in the inspector's Voice tab. **Voice Clone**: drop a short, clean reference (5–20 s) onto the voice plate. For a long clip, press **Find the Best 12 Seconds** in the inspector to trim and transcribe it. Leave **Words in the clip** blank unless you know the exact words.
3. Write the script on the page, or press **Use this example**, then press **⌘G**. Each take appears under the page with its waveform; Take Doctor scores it and underlines any word to check. Set **Takes** to 2–4 in the Render tab to compare variants.
4. For longer material, switch to **Long Form** and edit or retry individual segments. In **Performance**, insert Pause/Louder/Quieter directions, prepare a production, render its speech segments and rebuild the master. A segment retry retains other successful segments; rebuilding uses retained audio without synthesis. For dialogue, use **Cast** and give every `NAME:` a voice.
5. Save references with **Save as Voice…** and browse Takes, Voices and Productions in the sidebar Library. Projects keep their own outputs. Recoverable drafts preserve editable text/settings, not unsaved output takes; Performance productions keep their audio separately.

Quit with **Command-Q**. Closing a window is not the same as quitting the app. Only one VoxAster or legacy app backend can use port 8011 at a time.

## Optional per-user installation

You can use `.build/VoxAster.app` directly. To install your own build after verifying it, quit every VoxAster/legacy instance and run:

```sh
./install.command
```

The script verifies the runtime/build, requires port 8011 to be free, stages on the destination filesystem and retains a timestamped backup if replacing `~/Applications/VoxAster.app`. It leaves a legacy-named app bundle untouched. Both apps share data and must not run their backends simultaneously. Keep the backup for rollback. No administrator access is needed.

Local builds are ad-hoc signed, not Developer ID signed/notarized. Do not disable Gatekeeper globally. A future official binary release would require separate signing/notarization and distribution review.

## Runtime pins and development overrides

| Asset | Validated pin |
|---|---|
| OmniVoice package | `0.2.1`, commit `08be0b4ccbac3e13e374e86fbfead4b4cac343e2` |
| Base model and text tokenizer | `c5fdb5ccb189668d56333f77ba2629f4cd7535f4` |
| Official Boson audio tokenizer | `bosonai/higgs-audio-v2-tokenizer`, revision `815a03f1b57dcb5ae918db415f22cd0c8a6f0f54` |

The audio tokenizer's exact hashes and fail-closed loading behavior are documented in [TOKENIZER.md](TOKENIZER.md). [requirements.txt](../requirements.txt) pins the synthesis package; [constraints-macos-py312.txt](../constraints-macos-py312.txt) records the validated Python dependency set. The native app uses its established per-user runtime regardless of where the source checkout lives.

Build/tests can select a Python executable with `OMNIVOICE_PYTHON`; this does not change the native app's runtime location. `OMNIVOICE_SETUP_PYTHON` and `OMNIVOICE_SETUP_VENV` are setup/test overrides. Contributors can run:

```sh
./test.command
./verify-runtime.command
git diff --check
python3 -B tools/audit-release.py
```

Tests use temporary data and mocked synthesis where appropriate. Real model startup and listening acceptance are separate. Optional F5 inference is not provisioned by core setup; see [engine support](TRAINING.md). Training/fine-tuning is not available.

## Troubleshooting

| Symptom | What to check |
|---|---|
| **Runtime setup required** | Follow the README setup steps, or verify the existing environment rather than overwriting it. |
| **Loading / Backend stopped** | Check `~/Library/Logs/OmniVoice/native-backend.log`, run `./verify-runtime.command`, and check the port with `lsof -nP -iTCP:8011 -sTCP:LISTEN`. Quit the app that owns it; do not kill an unidentified process. |
| **Missing or invalid Boson tokenizer** | Run `./prepare-models.command`, then `./verify-runtime.command`. There is no fallback to an unverified mirror. |
| **Unexpected package/model** | Restore the validated runtime; do not change pins merely to bypass provenance checks. |
| **Microphone access denied** | Check System Settings → Privacy & Security → Microphone. Imported references do not require microphone recording. |
| **Markup is spoken or delivery is odd** | Use plain text and the editor's supported controls. Asterisks/Markdown are not acting direction. See [script controls](CONTROLS.md). |
| **A draft returns without an output take** | Drafts recover editable work, not unsaved takes. Back up user-data directories and retain/export audio you need. |

Performance currently supports base OmniVoice reference cloning; Design/F5/saved-engine Performance routing is not enabled. `[deadpan]`, `[sarcastic]`, `[whisper]` and `[shout]` are not supported inline controls. Whisper is a Voice Design attribute. Speed and Guidance do not represent emotional intensity. Quality, accent and voice continuity require listening checks; a fixed seed is not a promise of identical audio across different hardware.

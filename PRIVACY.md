# Privacy and local storage

## Processing and connections

The native app sends text and reference recordings to its FastAPI backend at `127.0.0.1:8011`. Audio synthesis and optional Whisper transcription run on the Mac. No external speech API, analytics endpoint, application crash-report uploader or cloud-upload code is implemented in this repository. macOS diagnostic reporting is controlled separately by the operating system. The local API rejects browser Origin/fetch-context requests and unexpected Host headers; it is not authenticated against other native programs running on the same Mac. Do not expose it through a tunnel, proxy or network bind.

Setup contacts GitHub, PyPI and Hugging Face to install packages and download the pinned model. The base model uses a local-only cached snapshot on startup. Automatic reference transcription can download `openai/whisper-large-v3-turbo` when first needed. Optional F5 inference can fetch its own assets. Training tokenization and model merging are not available in this release. Remote hosts see ordinary download metadata such as IP addresses and requested model names. User audio is not sent to those hosts by the audited app/model processing paths. Native launches disable Hugging Face telemetry; this is not a guarantee about every possible optional dependency or future upgrade. Offline use requires caching every model for the selected workflow beforehand.

## Retention

| Location | Contents |
|---|---|
| `~/Documents/OmniVoice-Mac/outputs` | Generated WAV files |
| `~/Documents/OmniVoice-Mac/voices` | Saved reference recordings |
| `~/Documents/OmniVoice-Mac/performance` | Frozen scripts, settings, seeds, copied references, prompts, segment takes and masters |
| `~/Documents/OmniVoice-Mac/personal-voice` | Legacy datasets/transcripts, logs, checkpoints and saved engines (preserved; training is removed) |
| `~/Library/Application Support/OmniVoice` | History with scripts/paths, projects, voice metadata/transcripts, editable draft recovery |
| `~/Library/Logs/OmniVoice` | Backend output/errors; may include paths or request details |
| System temporary directory | Microphone takes and transient reference uploads; failures/crashes can leave temporary files |
| Hugging Face user cache | Downloaded model files; normally `~/.cache/huggingface` |
| `~/Library/Application Support/OmniVoice/managed-runtime/v1` | Private runtime generations, verified downloads/models, optional caches, setup logs and installation manifests; repair does not remove projects/voices/drafts |
| Process memory | Auto-play and Keep WAV switches reset to defaults on relaunch; they are not written to a preferences store |

Saved data is not encrypted by this app. Use macOS account protections/FileVault as appropriate. References imported from other locations can remain linked to their original files. Exporting a WAV writes to the destination you choose. A history deletion can retain its WAV depending on the Keep WAV preference. Clearing history does not clear project/draft/Performance/training data.

## Removal

Quit VoxAster and confirm its backend has stopped; independently stop any legacy external training process before removing its data. Back up anything you need, then remove the particular subdirectories/files above in Finder. Removing the whole `~/Documents/OmniVoice-Mac` directory also removes environments and trained engines; do that only for a complete uninstall. Remove `~/Library/Application Support/OmniVoice` to remove projects/history/drafts and `~/Library/Logs/OmniVoice` to remove logs. Deleting the app bundle alone does not remove user data. Other programs may share the Hugging Face cache, so remove only model entries you no longer need. Inspect your chosen export locations and original reference folders separately.

Do not attach real voice recordings, transcripts, private paths, drafts or complete logs to public bug reports. Reproduce with synthetic/non-sensitive inputs and redact locally first.

The unpublished native setup downloads pinned artifacts directly from approved GitHub, PyPI file-host and Hugging Face/CDN hosts. It does not send recordings, scripts or projects to those hosts. Runtime repair replaces only managed generations and retains the previous runtime; it is separate from user-data removal. See [managed setup](docs/RUNTIME_BOOTSTRAP.md).

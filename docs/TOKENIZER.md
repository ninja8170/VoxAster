# Official audio tokenizer and inference boundary

## Inventory before edits

| Class | Original use | Public release disposition |
|---|---|---|
| Runtime / inference | Backend startup, Engine Lab saved-engine loading, legacy saved-model inference; upstream local `audio_tokenizer/` or hardcoded mirror fallback | All three loading routes use `load_inference_model`; official local snapshot only |
| Training / model improvement | Personal Voice dataset/token preparation, LoRA training, merge/save publication; setup and two repair commands; Swift training workspace | Removed; obsolete mutation routes return HTTP 410 without work |
| Documentation / tests / provenance | Runtime manifest, setup/verification, model hashes, training instructions and training-only reliability tests | Replaced with pinned official provenance, inference/removal tests and licence obligations |

The former external source was `eustlb/higgs-audio-v2-tokenizer`. Its card/file list did not provide a usable licence. This is the only intentional current-source mention of that exact old repository: a migration record, not a download instruction. Historical Git revisions still contain retired workflows; they are not supported or licence-cleared for use. The separately installed pinned upstream package still contains its own fallback literal, but the app never invokes that branch (tested against the actual upstream method and real inference).

## Pinned source and independent hashes

Official source: [bosonai/higgs-audio-v2-tokenizer](https://huggingface.co/bosonai/higgs-audio-v2-tokenizer/tree/815a03f1b57dcb5ae918db415f22cd0c8a6f0f54).

Immutable revision: `815a03f1b57dcb5ae918db415f22cd0c8a6f0f54`.

| Artifact | SHA-256 |
|---|---|
| model.safetensors | `fe7c5e8785e0a05833e1bfc3e002ec7f55af21e306b2e7154a448c1f54ccfb0d` |
| config.json | `eefb20806f7104e77c9a5277c9df0f9bb8826b08eb1d4e8ab2b9829b6ef9fac1` |
| preprocessor_config.json | `ae61eea88558608ee2fa86d2aec9fce8d99a5ff75d09cb7651ccce21ae1d9084` |
| LICENSE | `8b2e018eeb3967a4636ccc57528440b33c14dd6e02ad67571fc7759489dde9a0` |

These hashes were computed from downloaded official files, not just copied from repository metadata. All three inference artifact hashes match the existing base model's embedded tokenizer. The official source supplies explicit terms; matching bytes alone is not a licence grant.

The bundled Meta licence/AUP is unmodified from [meta-llama/llama3](https://github.com/meta-llama/llama3/blob/a0940f9cf7065d45bb6675660f80d305c041a754/LICENSE), commit `a0940f9cf7065d45bb6675660f80d305c041a754`, file SHA-256 `4fa551d4f938f68b8c1e6afa9d28befb70e3f33f75d0753248d530364aeea40f`. Its published abuse-reporting contact is intentionally retained in the licence and narrowly allowed by the publication scanner; this does not exempt contributor emails.

## Loading and missing assets

`Backend/provenance.py` resolves the exact official snapshot locally and hashes every required file. `load_inference_model` creates a temporary directory outside the application bundle containing symlinks to the original model files and one `audio_tokenizer` symlink to the verified official directory. It calls the unchanged pinned upstream loader, then removes the temporary view after eager loading. Source model assets, saved engines and installed package files are not rewritten. Existing Performance productions without the new audio-provenance field remain retryable only when their core runtime matches and all three audio hashes match the verified legacy artifacts; different runtimes remain rejected. Training mode is rejected. No remote/model-name fallback is attempted if the official snapshot is absent or invalid.

`prepare-models.command` downloads the pinned base snapshot excluding its repackaged `audio_tokenizer/`, downloads only the required official audio files and verifies them. Local resolution uses matching file filters, so Hub versions that validate partial snapshots do not demand unused artwork/README files. Existing cache assets are not deleted. Normal startup uses local-only snapshot resolution; missing reference transcripts may separately load Whisper, as before.

`runtime.json` remains the pin authority; `/health` and Settings expose official audio source/revision/hash separately from the base model and text tokenizer revision. OmniVoice package 0.2.1, commit `08be0b4ccbac3e13e374e86fbfead4b4cac343e2`, and model/text tokenizer revision `c5fdb5ccb189668d56333f77ba2629f4cd7535f4` are unchanged.

## Release boundary

No weights or environments are distributed. Training, token extraction, LoRA, model merging/publication and their setup/repair scripts are removed from current source. Existing data and saved-engine inference are preserved. Twenty-seven tests exclusively covering the removed training implementation were retired; all inference, Performance and Swift reliability tests remain. New tests cover official source/pin, artifact tampering, missing/partial snapshots, actual upstream fallback avoidance, view cleanup, blocked training APIs and retained saved-model inference.

See [third-party obligations](../THIRD_PARTY.md). This migration does not grant unrestricted commercial/model redistribution rights or clear future model improvement.

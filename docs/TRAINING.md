# Engine support and training removal

VoxAster 3.7.0 does not provide dataset tokenization, OmniVoice/LoRA fine-tuning, training setup/repair, adapter merging or publishing trained engines. The Boson tokenizer agreement restricts using its materials or outputs to improve other large language models. The former workflow is removed from the current source/UI; obsolete mutation API calls return HTTP 410 without executing work.

Existing datasets, environments, recordings, checkpoints and saved-engine metadata are not deleted or migrated. Existing saved engines remain discoverable for inference in Library / Engine Lab; their rights/provenance are not certified by this release. Do not use old historical training scripts as a supported workflow. Re-enabling training requires separate licensing review/permission and validation.

F5 is an optional separate inference engine, not installed by core setup. Existing installations are detected at `~/Documents/OmniVoice-Mac/f5-venv/bin/f5-tts_infer-cli`. The app passes plain text and Speed; OmniVoice-only controls are rejected for mixed comparisons. Check the separate terms in [THIRD_PARTY.md](../THIRD_PARTY.md).

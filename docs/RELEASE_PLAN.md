# First public source release plan

The tokenizer migration and training removal are prepared for the first source release; see the final validation verdict in [RELEASE_READINESS.md](../RELEASE_READINESS.md). This plan is not authorization to create a repository, push or publish.

| Field | Recommendation |
|---|---|
| Repository name | VoxAster |
| Description | Local AI Voice Studio for macOS |
| Topics | macos, apple-silicon, swiftui, text-to-speech, voice-cloning, local-ai, audio-production |
| App licence | MIT; external engines/models retain separate terms |
| Version / tag | 3.7.0 / v3.7.0 |
| Release title | VoxAster 3.7.0 — First public source release |

## Proposed release notes

VoxAster is a native Apple Silicon macOS studio powered by the separate OmniVoice synthesis engine. It provides voice cloning/design, verified native vocal events and pronunciation, editable Long Form chunks, projects and draft recovery. Performance adds exact pauses, segment loudness controls, retained retries and deterministic master rebuilding; it does not add emotional acting. Runtime setup is pinned and local, and signed app bundles remain unchanged during model startup. Models/environments are downloaded separately and carry their own restrictions. This is a source release; the app is not notarized. Training, dataset token extraction and LoRA tooling are removed. The unmodified official Boson audio tokenizer is pinned and hash-verified; Boson/Meta agreements, acceptable-use terms, attribution and Notice accompany source and app. Inference dependencies have separate restrictions, including model non-commercial terms. Optional F5 inference remains separate.

## Safe publication sequence — manual approval required

1. Review [THIRD_PARTY.md](../THIRD_PARTY.md), the full Boson/Meta agreements, the conservative training removal and [tokenizer evidence](TOKENIZER.md). Preserve the credits, agreements and Notice in source/builds. The owner confirmed the Boson 100,000 annual-active-user threshold does not apply; other distributors must assess their own eligibility. Do not distribute new/modified models or re-enable training without separate review.
2. Review the complete prepared working tree, including new source/docs/tests and removed old files. Commit it locally with the configured public-safe Git identity. The current HEAD alone predates the release/rename changes.
3. Re-run publication scanning, tests and diff checks on that final commit. Confirm no private recovery refs or files are present.
4. Prefer a brand-new empty GitHub repository, initially private for a final review. Do not initialize it with an unrelated README/history. Add a new, distinctly named remote only after approval; leave the old unsanitized remote private and do not fetch/pull from it.
5. Publish only the reviewed main branch after approval. Do not publish old tags as supported releases: historical commits retain retired, unsupported training scripts. Deliberately review any historical tag before making it a release. Do not use a mirror push. Review the remote file/history view, enable private vulnerability reporting and available secret scanning, then separately approve public visibility/tag/release creation.
6. Keep the first release source-only. A self-contained binary/model installer requires its own dependency notices, model redistribution clearance and Developer ID/notarization work.

A fresh destination is safer than replacing the existing remote: rewritten branch tips alone do not establish removal of server-side caches, pull-request refs or retained objects. Private recovery material must never accompany the published source.

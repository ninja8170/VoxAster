# Release-readiness audit — 2026-10-04

## Verdict: READY FOR PUBLIC GITHUB RELEASE

Scope: the reviewed **VoxAster 3.7.0 application source**, including required third-party notices, with separately downloaded inference dependencies. This is not approval to redistribute model weights, publish an unrestricted commercial model product, re-enable training, ship a self-contained binary, or skip owner approval for publication.

The previous licence-less tokenizer blocker is resolved by using the official Boson source at an immutable, independently hash-verified revision and removing the training/model-improvement workflow. The owner confirmed the Boson 100,000 annual-active-user threshold does not apply. The licence agreements, acceptable-use restrictions and other eligibility conditions still apply to users and distributors. [THIRD_PARTY.md](THIRD_PARTY.md) distinguishes MIT app code, Apache-2.0 OmniVoice code, non-commercial OmniVoice weights and restricted Boson/Meta community terms.

## Local source and privacy

This document records the preparatory audit against sanitized base `21323109eb3543b035ad1e232c6c7220bef0436e`. The subsequent release checkpoint includes the approved rename, licensing, source and test changes; identify that checkpoint by its Git commit and validate that exact state before publication. No remote access, push, publication, repository creation, new history rewrite or installation occurred during preparation. The old unsanitized remote must remain private.

The prior private-email remediation remains intact. Publication scanning checks working files plus all reachable historical blobs/commit/tag objects; no general email exemption was added. The one narrow allowance is Meta's published licence/AUP reporting contact, retained in the unmodified agreement. Recovery material stays outside the source. Heuristic checks are not an exhaustive secrets or dependency-CVE guarantee.

## Licensing remediation

- Classified runtime inference, training/model improvement and documentation/test/provenance usages before editing. See [TOKENIZER.md](docs/TOKENIZER.md).
- Pinned official Boson audio tokenizer revision `815a03f1b57dcb5ae918db415f22cd0c8a6f0f54`; SHA-256 verifies weights, inference config, preprocessor config and licence. All three inference artifacts match the bytes previously embedded in the pinned base model.
- All three OmniVoice model-loading paths use a temporary local view containing the verified official tokenizer. Missing/changed files fail before upstream loading; its mirror fallback is never used. No installed package rewrite or global monkeypatch is performed.
- Kept package 0.2.1 / commit `08be0b4ccbac3e13e374e86fbfead4b4cac343e2` and base model/text tokenizer `c5fdb5ccb189668d56333f77ba2629f4cd7535f4` unchanged.
- Removed training UI/state/actions, dataset/token preparation, training/LoRA, merging/publication, training safety module and three setup/repair scripts. Obsolete mutation APIs return 410 without work. Existing saved-engine inference and all existing data remain available. Old historical commits contain unsupported retired workflows; do not present old tags as supported releases.
- Preserved existing Performance retries through an explicit compatibility check for this byte-identical migration. Different runtime identities or audio hashes remain rejected.
- Included unmodified Boson/Meta agreements, Meta AUP and required `Notice` in source and built app. README and Settings prominently display required attributions. Training documentation now explains removal rather than teaching the prohibited workflow.

## Validation completed

- **86 backend tests and 320 Swift assertions passed**, covering inference controls/routes, pronunciation, Performance, projects/drafts, reliability, official tokenizer/fallback rejection, blocked training and legacy production retry compatibility.
- Count reconciliation: previous 101 backend tests minus 27 retired training-only tests plus 12 new licensing/inference/privacy compatibility tests = 86. No inference or Swift reliability suite was removed; three Swift assertions were added to 317.
- Clean native compilation, all shell syntax checks, Python syntax/imports, dependency consistency, provenance and bundle resource/licence equality passed. No Swift compiler warnings; non-failing Starlette/HTTPX deprecation advisory remains.
- Actual MPS inference passed with the previously validated fresh Python 3.12 runtime: Design, Clone with dictionary/CMU pronunciation, and a Performance production containing a 500 ms pause and gain direction. Outputs were finite, non-silent 24 kHz WAVs. Master timeline included exactly 12,000 pause samples. Offline mode and a guard on the actual upstream resolver rejected nonlocal/mirror paths; only the intended local model view was resolved.
- Native app launch reached **Ready**, HTTP 200, generation contract 3, version 3.7.0 and exact official audio provenance. Port 8011 belonged to the test bundle's backend. Settings displayed required credits/licences; Voice Training was absent, and Performance with existing drafts/productions remained accessible. No user production was synthesized or edited.
- Normal Command-Q stopped app/backend and released port 8011. Strict ad-hoc signature passed before and after real startup; bundle file hashes were unchanged, with zero `__pycache__` and `.pyc` artifacts.
- Reviewed source/publication scan, documentation links, build references, Git integrity and `git diff --check` complete the local gate. No model weights, generated audio, environments, signing keys or private recovery material are part of source.

## Validation artifacts and limits

Validation app: `/private/tmp/VoxAster-Boson-Validation/release/VoxAster.app`. Test audio and logs remain in temporary validation directories, not in the source or user projects. The installed main app was not replaced.

The existing dependency environment was reused; no package upgrades were made. Official audio files were downloaded and independently hashed. The setup downloader and partial-snapshot behavior were verified, but a second full empty-cache package/model installation was not repeated. F5 and existing saved-model inference routes were exercised with mocks; no real new training was performed or permitted. Real inference checks do not establish subjective voice quality or replace listening acceptance. Other hardware/macOS versions, new microphone permission prompts and installer replacement were not retested.

## Release boundary and next action

Use the repository's public-safe identity for the release checkpoint, and re-run scanning and release validation on that exact committed state before tagging or publication. Follow [RELEASE_PLAN.md](docs/RELEASE_PLAN.md) for a separately approved new public destination. Do not reuse/publish the old unsanitized remote or mirror-push private refs. No models/environments are bundled. Source builds are ad-hoc signed, not Developer ID signed or notarized. Future binaries, derived models/software, commercial uses and training require their own terms/distribution review.

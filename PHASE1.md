# OmniVoice 3.5.1: authoritative generation pipeline

Phase 1 maintenance release based on the installed Native 3.5 Reference Auto Tune distribution. The 3.5 Swift and backend changes were additive to the checkout's 3.4.5 files. Existing project/history/playback/training functionality is retained. No upstream package or weights were upgraded.

## Version provenance

`Backend/runtime.json` is the build manifest. The build generates the bundle version from it. Startup resolves the already-cached model revision with `local_files_only=True`, reads installed package metadata and its direct Git commit, and refuses an unverified package. It loads that explicit snapshot path, not a floating model ID. `/health` exposes package version/commit, model and text/audio tokenizer revisions, tokenizer JSON SHA-256, and audio tokenizer configuration SHA-256. Settings displays the native bundle version and backend provenance. A generation-contract check prevents the new UI silently connecting to an old backend.

Pinned existing runtime: omnivoice 0.2.1, commit `08be0b4ccbac3e13e374e86fbfead4b4cac343e2`; model and bundled tokenizers revision `c5fdb5ccb189668d56333f77ba2629f4cd7535f4`. Provenance shown in Settings describes the base runtime; selected personal models remain separate local checkpoints.

## Shared request and capability boundaries

`Sources/GenerationRequest.swift` serializes the existing UI settings. `Backend/generation.py` validates multipart requests for Clone, Design, Long Form, Variants and Engine Lab, and constructs the OmniVoice model arguments. Speed, Steps, Guidance, Seed and Denoise are shared. Language selections are resolved to native language IDs; unknown selections fail validation.

Clone and Variants use the Clone pronunciation dictionary and language. Engine Lab's OmniVoice engines use those same selections. Long Form uses its own Pronunciation Notes. Design has no pronunciation UI and does not inherit Clone rules or language; its API can accept explicit pronunciation rules. Reference transcripts are never rewritten. Replacement rules protect existing bracket markup and pinyin tone forms, including native markup inserted by earlier rules. Empty replacement rules remain ignored for compatibility. Ordinary prose replacement semantics remain case-sensitive substrings.

Engine Lab returns capabilities for each available engine. F5 receives only plain speech/reference text, reference/output paths and Speed. OmniVoice Steps, Guidance, Seed and Denoise do not reach F5. Any bracket markup, internal token delimiters or uppercase pinyin tone forms in target/reference text, or nonempty pronunciation/language/Design controls, reject an F5 comparison before either engine synthesizes. This deliberately does not strip/translate unsupported syntax. The UI explains the comparison boundary.

## Long Form source and retry

The explicit production-segment array is authoritative, even if a client also supplies stale master text. The backend never re-splits explicit segments. Editing a segment updates the master text and invalidates the old master audio. Editing master text invalidates stale segment previews. Preparing/refreshing rebuilds previews from current text.

Full generation synthesizes the exact segment array and retains the existing 180 ms master join. Individual segment output paths are returned. Retry sends the current edited array plus the selected index and synthesizes only that segment; its result is stored on that segment. Retry does not assemble a new master. The UI tells the user to generate the master again; this currently regenerates all segments. Responses for an edited/replaced source are discarded rather than attached to the wrong source.

A nonzero seed is `base + segmentIndex` for Long Form/retries and `base + takeIndex` for Variants. Engine Lab's OmniVoice engines receive the same base seed. Zero does not reseed. This enables stable segment retries but is not a cross-device determinism guarantee. Denoise is forwarded on all OmniVoice routes; upstream's denoise conditioning still only applies when reference audio is present.

Analyzer recommendations survive the preset onChange callback; selecting a named preset intentionally replaces its associated settings.

## Build and tests

- `./test.command [artifact-directory]`: backend HTTP/model-boundary tests, Swift tests invoking actual AppModel generation actions through an injected ephemeral URLSession, shell syntax checks, complete release app compilation, signing and bundle verification.
- `./build.command [artifact-directory]`: builds and signs the app without installation, launches or dependency changes.
- `./install.command`: explicit installation only, after a successful build; verifies existing imports and does not run pip. Keeps the prior application as a timestamped backup.

Tests use fake synthesis results and temporary storage; they do not load model weights or run speech generation. The cached provenance check is read-only. No pre-existing automated tests/build suite existed in the checkout.

## Deferred Phase 2

No new expression UX, expanded advanced-control UX, Performance Direction parser, invented emotion tags, exact-pause system or new audio assembly workflow is included. Later work may expose remaining verified native events/parameters, improve pronunciation authoring, and design a separately validated performance layer. None is authorized by this phase.

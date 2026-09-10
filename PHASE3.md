# OmniVoice Mac 3.7.0 — deterministic performance timing and assembly

Phase 2 was verified and checkpointed as `c584525` (`feat: expose complete native OmniVoice controls`) and pushed to `origin/main` before Phase 3 began. This phase changes the app/backend version to 3.7.0 and generation contract to 3. The existing synthesis package, model and tokenizer pins are unchanged. No app installation, upstream upgrade or model inference is part of the verification described here.

## Scope and native capability boundary

A dedicated **Performance** workspace adds app-level timing, gain and retained-segment production using the existing **OmniVoice Zero-Shot reference-cloning** engine. It uses the selected reference recording/transcript and global generation controls; its dictionary is separate. F5, Design, trained-engine routing and native fixed duration are deliberately not enabled on the Performance route. `/performance/capabilities` declares this boundary. Native Events and Performance Directions have distinct controls and explanations.

Other generation routes keep their existing behavior and reject app-level directions with an instruction to use Performance. Unknown/malformed bracket controls now block everywhere, including reference transcripts. This intentionally supersedes Phase 2's permissive warning for otherwise unknown brackets. Valid native event/CMU markup remains supported; reference transcripts are validated without being rewritten. Markdown emphasis still warns without silently deleting prose, although Markdown links containing unverified brackets now fail bracket validation.

Existing whole-generation Voice Design whisper remains a native Design capability; inline `[whisper]` is not supported. No new native emotional acting is claimed or implemented.

## Parser and immutable plan

`Backend/performance_script.py` supplies immutable lexical nodes with original source spans and exact raw text. Node kinds distinguish text, native vocal events, CMU pronunciation, pinyin, pauses and gain. Unclosed/nested brackets, wrong case, unknown tokens and malformed controls produce line/column errors. The exact 13 native event tokens and CMU symbol definitions are shared with ordinary speech validation.

The compiler flushes speech at each application direction. It never splits a native event or phoneme span. Dictionary replacement runs only within speech text; protected bracket/pinyin spans remain intact, and direction nodes are never passed to replacement code. A replacement cannot introduce a performance direction or unknown bracket token. The preview uses the installed model's native whitespace normalization, showing speech text separately from app-inserted pauses. It does not expose internal prompt delimiters or send app directions to the model.

Preparing a production validates everything before copying the reference and writing a manifest under `~/Documents/OmniVoice-Mac/performance/<id>/`. It freezes:

- Original script and dictionary/matching mode; lexical source spans and compiled segments.
- Actual reference bytes, original filename, transcript, engine identity and SHA-256.
- Package/model/tokenizer manifest and engine capabilities.
- Per-speech-segment processed text, complete validated generation request, gain and seed.

A positive seed is `base + speech-segment ordinal`; pause nodes do not consume seed offsets. Seed 0 chooses one positive random base **once at Prepare** and persists it. Retrying uses the saved seed/settings/reference, not mutable global UI values. This guarantees seed forwarding and assembly determinism; it does not promise cross-device bit-identical neural synthesis.

Script bounds: 100,000 characters, at most 256 compiled segments, at most 120 seconds total explicit pauses. An oversized base seed is rejected if its segment offsets would exceed the existing seed bound.

## Supported directions

| App direction | Behavior |
|---|---|
| `[pause Nms]` | Integer 1–10000 ms, exact lowercase, no leading zeroes. Splits speech and inserts `N × 24` zero samples at 24 kHz after segment post-processing. |
| `[louder]` | +3 dB applied to the following speech segment. Ends at the next performance direction. |
| `[quieter]` | −3 dB applied to the following speech segment. Ends at the next performance direction. |

A gain direction needs speech before the next performance direction/end of script; dangling or consecutive gain directives fail with a precise error. Initial speech and speech after a pause have 0 dB instruction unless directed again. A direction at a cursor splits a segment; it does not change emotional expression. There is no implicit stacking of gain.

Examples:

```text
A conversational setup. [pause 500ms] The punchline.
Normal volume. [louder] A raised-volume line. [pause 250ms] Back to normal volume.
[quieter] A softer line. [pause 500ms] Normal volume again.
```

Pause/Louder/Quieter chips use the same Unicode-safe cursor/selection insertion path as native events. The Pause field validates the exact integer range. Native events remain available in the same editor under their separate label.

## Exact assembly behavior

`Backend/performance_audio.py` operates on mono 24 kHz samples:

1. Receive the native output **after** the existing OmniVoice post-processing.
2. Remove leading/trailing samples at or below absolute amplitude `1e-4` (−80 dBFS). Reject empty, non-finite, non-mono, entirely silent or shorter-than-10-ms speech renders instead of retaining unmeasured silence.
3. If input peak exceeds 1, attenuate that segment to peak 1. Apply common −4 dB headroom, then its −3/0/+3 dB instruction. Peak remains at or below −1 dBFS, including +3 dB segments. There is no independent loudness normalization that cancels the quieter instruction.
4. Apply 5 ms / 120-sample linear edge fades within the retained speech samples. Endpoints are nonzero ramps so the fades do not append exact-zero padding.
5. Save the post-processed segment as 24 kHz mono **float WAV**. No PCM quantization is used to turn quiet fade samples into added zero padding.
6. Concatenate retained speech and exact zero-valued pause arrays. Fades smooth speech boundaries; there is **no overlapping crossfade** that changes segment/pause sample positions.
7. Write the float WAV master. **No trimming, normalization or synthesis runs after pause insertion.**

`[pause 500ms]` contributes exactly **12,000 zero samples**. Leading, trailing and consecutive pauses also survive. The master manifest records each segment's start/end sample positions. Rebuilding from the same retained files produces identical WAV bytes and timeline.

This is a sample-count timing guarantee, not a perceptual-silence detector: retained nonzero ambience and phonetic release affect the perceived gap. The threshold can remove exceptionally quiet edges, and the 5 ms fades are inside the speech duration. Trimming counts, gain, input scaling and fade length are recorded for each rendered segment. No hidden 180 ms Long Form join is used in this pipeline; the pre-existing Long Form route is unchanged.

## Production workflow and recovery

1. Enter the script and select a reference/settings. **Prepare new production** freezes the plan.
2. **Render missing / failed** issues one request per speech segment without audio. Pause nodes never invoke synthesis. Successful segments remain even if a later one fails.
3. Inspect each segment's processed text, gain, seed, frozen settings and audio preview. **Retry only this segment** invokes only that segment's saved request.
4. A successful retry writes a new immutable take and invalidates the master. It does not overwrite any other segment. A failed retry retains the previous successful take/master, if present, and records its error.
5. **Rebuild master** reads retained audio only. It rejects missing/corrupted audio or wrong sample rates and never calls the model.
6. Saved productions can be loaded after changing workspaces or restarting the backend. Interrupted rendering is recoverable; the reference and seeds remain frozen. The first render creates and saves the native `VoiceClonePrompt` (using upstream’s existing save/load API); subsequent segments and restarts reuse its audio tokens, RMS and resolved transcript. Blank transcripts retain the normal Clone auto-transcription behavior, resolved only once. The resolved transcript is validated for unknown markup before use and shown in the production view. A changed reference or cached-prompt hash blocks retry. Retained audio hashes protect rebuilds from accidentally changed files.

Changing the draft or global settings does not mutate a frozen production; prepare a new production to use those changes. The UI explicitly shows draft/source differences. Existing productions and prior takes remain on disk; automatic cleanup and editing a frozen segment are not included. Per-segment retries intentionally keep their seed rather than silently creating a different random take.

## Verification

Run `./test.command [artifact-directory]` for backend HTTP/parser/audio tests, Swift editor/AppModel/request assertions, release compilation, shell syntax, bundle provenance/resources and code-signature verification. Run `git diff --check` separately. All tests use temporary storage, mocked synthesis and synthetic audio fixtures; the installed model's duration-precedence test remains non-inference preprocessing only.

Coverage includes native/parser losslessness, precise unknown-tag errors, rule protection/injection rejection, gain scoping, range bounds, exact silence samples before/after float-WAV export, fade continuity, headroom/clipping, stable positive/random-base seeds, retained retry isolation/failures/restart recovery, tamper detection, master byte determinism, API/UI request routing and original generation regressions.

Interactive desktop acceptance and real voice listening remain pending. Timing and DSP tests do not establish naturalness across independent synthesis boundaries; users should review fades, quiet phoneme edges and overall continuity on their recordings. This phase does not add emotional acting.

## Verified results

Verified on 2026-09-10 from the actual project checkout:

- **65 backend tests passed**, including all original Phase 1 regressions and updated Phase 2 strict-bracket expectations.
- **235 Swift editor/UI/request assertions passed** across Clone, Design, Variants, Long Form, Retry, Engine Lab and Performance.
- Native release compilation, shell syntax, bundle provenance/resources, and code-signature verification passed.
- `git diff --check` passed; the working tree contains exactly the 19 intended Phase 3 files below.
- All five files of the installed OmniVoice 3.5 application matched their pre-change SHA-256 fingerprints. No installation or application launch occurred.
- Package/model/tokenizer pins remained unchanged. Tests used mocked synthesis, native clone-prompt serialization of small fixture tensors, and synthetic PCM fixtures; no model weights were loaded and no speech inference ran.
- Built artifact: `/private/tmp/omnivoice-phase3-verification/release/OmniVoice.app`.
- Phase 3 remains uncommitted for review; Phase 2 checkpoint `c584525` is pushed and synchronized.

## Exact files changed

- `Backend/backend.py`
- `Backend/generation.py`
- `Backend/performance.py`
- `Backend/performance_audio.py`
- `Backend/performance_script.py`
- `Backend/runtime.json`
- `Backend/speech_text.py`
- `PHASE3.md`
- `README.md`
- `Sources/NativeAdvancedControls.swift`
- `Sources/OmniVoice.swift`
- `Sources/PerformanceWorkspace.swift`
- `Sources/SpeechEditor.swift`
- `Tests/GenerationTests.swift`
- `Tests/PerformanceTests.swift`
- `Tests/test_generation.py`
- `Tests/test_native_controls.py`
- `Tests/test_performance.py`
- `test.command`

## Proposed Phase 4 boundary — not implemented

Any acting-oriented work needs a separately approved design and evidence for each supported mapping. Possible future work includes explicit per-segment plan editing/new-take seed choices, a reviewed retention/cleanup policy, additional engine adapters and better boundary listening tools. Emotion recipes, invented native emotional tags, reference-based acting and model changes remain excluded unless explicitly authorized. Installation and Phase 4 require approval.

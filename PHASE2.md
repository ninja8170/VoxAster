# OmniVoice Mac 3.6.0 — native controls (Phase 2)

Phase 1 was checkpointed and pushed as `353c5de` (`feat: establish OmniVoice 3.5.1 generation foundation`). Phase 2 is a native app/backend change only. The installed app is not replaced, and the synthesis package, model, tokenizers and their pins are unchanged. The native version is 3.6.0; the generation wire contract is 2 so this UI cannot silently use a Phase 1 backend.

This document supersedes Phase 1's pronunciation/UI descriptions; PHASE1.md remains the checkpoint record.

## Native vocal events

Clone (including its A/B Variants), Design, Long Form master/production editors and OmniVoice-only Engine Lab comparisons use a plain AppKit speech editor. Buttons insert at the retained cursor or replace the selected text, including Unicode text. Native pronunciation insertion uses the same selection. Question and Surprise have grouped menus; menu labels/help expose the exact token.

| Control | Native token(s) |
|---|---|
| Laugh | `[laughter]` |
| Sigh | `[sigh]` |
| Confirm | `[confirmation-en]` |
| Question → En, Ah, Oh, Ei, Yi | `[question-en]`, `[question-ah]`, `[question-oh]`, `[question-ei]`, `[question-yi]` |
| Surprise → Ah, Oh, Wa, Yo | `[surprise-ah]`, `[surprise-oh]`, `[surprise-wa]`, `[surprise-yo]` |
| Hmm | `[dissatisfaction-hnn]` |

These are vocal events, not persistent emotional states. Exact lowercase manual entry remains supported. `[sniff]` is excluded. Existing Design attributes, including whole-generation whisper style, remain available; an inline `[whisper]` tag is not a supported substitute.

## Pronunciation and preview

- Each relevant editor has a pronunciation dictionary. Clone and Variants share rules, and OmniVoice Engine Lab uses those same rules. Design now has its own dictionary and replacement mode. Long Form retains its own rules. Reference transcripts are never rewritten.
- Rules use `original=replacement`, one per line, in order. Matching is case-sensitive and defaults to whole ASCII Latin words/phrases; Chinese phrases match directly. An explicit “Match inside words” toggle restores legacy substring matching. This is a deliberate safer default for existing dictionaries: review their preview, especially when reusing old projects.
- Existing bracket spans and uppercase pinyin tones are protected, as is markup introduced by earlier replacements. Invalid/empty rules are reported as errors rather than silently ignored. Empty replacements do not delete text.
- Native CMU authoring accepts uppercase symbols such as `B EY1 S` and inserts `[B EY1 S]`. Vowels require pronunciation stress 0, 1 or 2; these digits do not specify acting emphasis. Invalid authoring input disables insertion. Manually entered valid CMU markup remains unchanged.
- Pinyin authoring accepts uppercase syllables with tone 1–5, such as `ZHE2` or `NI3 HAO3`. It checks syntax, not linguistic correctness. There is no automatic word-to-phoneme conversion.
- “What OmniVoice receives” calls `/preview-speech` after a short debounce. It shows target text after the same replacement logic and installed native `_combine_text` whitespace processing. It preserves event/phoneme notation and does not show reference conditioning or internal prompt delimiters. It does not predict audio or timing. A missing backend produces “Preview unavailable”; generation still validates server-side.
- Line breaks are removed by upstream preprocessing, not converted into timed pauses. The preview warns about this. Script editors disable automatic smart quotes, dash substitution and text replacement.

## Generation parameters and boundaries

Existing Speed, Steps, Guidance, Denoise and Seed remain. Advanced adds:

| UI label | Native parameter | Default | App authoring range | Meaning |
|---|---|---:|---|---|
| Target duration | `duration` | unset | >0–600 seconds | Overrides Speed-based length estimation for this passage/take. Native trimming may shorten the result. |
| Time shift | `t_shift` | 0.1 | 0.001–1 | Changes the iterative decoding schedule, not spoken pauses. |
| Position temperature | `position_temperature` | 5 | 0–20 | Randomness in choosing audio-token positions to fill. |
| Token temperature | `class_temperature` | 0 | 0–20 | Randomness in token choice; zero uses greedy selection. |
| Codebook layer penalty | `layer_penalty_factor` | 5 | 0–20 | Encourages earlier audio codebook layers to be filled first. |

These are app validation/slider bounds, not claims of upstream hard limits or recommended quality across the entire range. All values must be finite. Reset restores Speed 1, Steps 32, Guidance 2, Seed 0, Denoise on, automatic duration and the native advanced defaults above. Guidance is conditioning strength, not emotion intensity; Speed controls overall pacing, not emotional energy. Denoise's cleaner-speech conditioning applies when reference audio is present.

Clone, Design, Variants and OmniVoice-only Engine Lab expose all five additions. Long Form and Retry expose the four decoding controls; fixed duration is deliberately not exposed there, and explicit API duration requests are rejected. Distributing a total duration across editable sections needs a future policy. The capability declaration identifies duration-enabled routes.

F5 comparisons expose no native event, pronunciation or advanced authoring controls. Hidden native advanced selections are replaced by defaults for the mixed request while preserving the user's OmniVoice selections in memory. Nondefault native advanced values submitted directly to an F5 comparison are rejected before either engine runs. The F5 adapter still receives only plain text, reference/output paths and Speed. Existing Clone rules must be cleared and language set to Auto detect for F5 comparisons; the UI explains this. Native Steps/Guidance/Seed/Denoise never enter the F5 adapter.

Settings columns scroll independently so expanded controls remain reachable. Existing Phase 1 authoritative production edits, selected-section retry, seed offsets, Denoise/language forwarding and analyzer preset handling remain intact.

## Text safety

The backend validates authoritative speech segments before reference processing or synthesis. This applies to all generation routes, independent of whether the UI preview has loaded.

Blocked with an explanation: wrong-case/padded native tags, malformed/nested/unbalanced bracket syntax, recognizable malformed CMU overrides, internal model delimiters, malformed dictionary rules and the listed unsupported directions (`[deadpan]`, `[sarcastic]`, `[angry]`, `[amused]`, `[irritated]`, `[excited]`, `[sad]`, `[serious]`, `[whisper]`, `[shout]`, `[louder]`, `[quieter]`, `[pause]`, `[pause 500ms]`, `[laugh]`, `[chuckle]`, `[breath]`, `[gasp]`, `[sniff]`). They are not translated or silently deleted.

Warnings preserve text and allow explicit generation: `*stage direction*`, `**emphasis**`, Markdown headings/lists/links/code fences, likely parenthetical directions, possible malformed pinyin tones and other unverified bracketed text. These constructs are not advertised as native controls and may be spoken literally. Detection cannot identify every possible prose stage direction.

## Verification

Run `./test.command [artifact-directory]` for all backend tests, Swift editor/AppModel/request assertions, native release compilation, shell syntax, bundled source/provenance checks and code-signature verification. Tests use temporary storage and mocked audio outputs; they do not load weights or run synthesis. The duration precedence test invokes the actual installed model preprocessing method with a fake duration estimator/audio-tokenizer configuration.

The suite covers the 19 Phase 1 backend tests and original 66 Swift assertions plus native events/case/grouping, cursor/selection/Unicode insertion, text validation/protection/preview, native authoring helpers, advanced forwarding, native duration precedence, F5 boundaries, reset and authoritative Long Form retry. Run `git diff --check` separately before review. No dependencies are installed by testing/building. Audible quality and interactive desktop acceptance still require user review; automated forwarding tests do not establish acting quality.

Verified from the actual project checkout on 2026-09-10:

- 39 backend tests passed (19 Phase 1 regression tests plus 20 Phase 2 tests).
- 196 Swift assertions passed (including all original 66 assertions).
- Native release compilation, shell syntax, release bundle provenance/resources and code-signature verification passed.
- `git diff --check` passed; Phase 2 remains uncommitted for review.
- Release artifact: `/private/tmp/omnivoice-phase2-verification/release/OmniVoice.app`.
- All five files in the installed OmniVoice 3.5 app matched their pre-application SHA-256 fingerprints. No app was installed or launched, and no synthesis was run.

## Files changed in Phase 2

- Backend/backend.py
- Backend/generation.py
- Backend/runtime.json
- Backend/speech_text.py (new)
- Sources/GenerationRequest.swift
- Sources/OmniVoice.swift
- Sources/SpeechEditor.swift (new)
- Sources/NativeAdvancedControls.swift (new)
- Tests/GenerationTests.swift
- Tests/test_generation.py
- Tests/test_native_controls.py (new)
- test.command
- README.md
- PHASE2.md (new)

## Exact Phase 3 boundary

No app-level performance-direction execution, emotional tag translation, performance segmentation, pause insertion, gain processing, reference-based acting recipes or new audio assembly has been implemented. Existing Long Form joining is unchanged.

A future, separately authorized phase could design a typed performance-direction language and validate it before synthesis, define which directives map to supported request settings versus explicit audio processing, and specify authoritative per-span state, previews, rejection behavior and tests. Unsupported directions must never fall through to spoken text. That architecture requires approval; it is not part of Phase 2. Phase 3 and installation remain pending explicit authorization.

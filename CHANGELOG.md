# Changelog

## 3.8.0 — studio redesign and studio tools

- Fixed generation freezing: long reference clips (over 20 s) are always trimmed, even when a transcript is saved, and synthesis runs off the server's event loop so the app stays responsive. Quitting no longer hangs on a stuck backend.
- New single-window studio: Voice Clone, Voice Design, Long Form, Performance and Cast modes in the toolbar; voice plate, ruled script page with worked examples, takes roll; Library tables; Engine Lab window; standard Settings window. Follows the macOS light/dark appearance.
- Reference Cleaner: finds the cleanest 6–15 s of one speaker in a long clip, transcribes it, and can save it as a voice.
- Take Doctor: transcribes each take locally with Whisper, scores it against the script, flags wrong or missing words, picks the best variant, and can re-render a single sentence and splice it into the take.
- Cast: `NAME:` scripts rendered with a voice per character and joined into one scene; designed characters keep their voice from their first line.
- Performance productions made with 3.7.0 remain renderable.
- Managed runtimes installed for 3.7.0 need one **Set Up or Repair Runtime** after updating, because the runtime lock records the app version. Existing Python-environment setups are unaffected.
- README, Getting Started and Privacy updated for the new studio and tools.

## 3.7.0 — first public source release

- Product renamed to VoxAster — Local AI Voice Studio for macOS; existing data and runtime identities are preserved.
- Publication checks cover historical commit/tag identities; documentation distinguishes external model terms and local processing limits.
- Native macOS voice cloning, design, pronunciation, variants and generation controls.
- Performance production workspace with exact pauses, segment gain, retained retries and deterministic master assembly.
- Authoritative Long Form edits, reference identity checks, project/draft recovery and safe exports.
- Python bytecode disabled in signed bundles, with post-import signature checks.
- Pinned runtime setup and verification, explicit third-party/privacy documentation, browser-request protection and backend shutdown on application quit.

Optional F5 inference remains separate. Personal Voice training, dataset token extraction and LoRA tooling are removed for the public release. Inference now resolves the official Boson audio tokenizer at an immutable, hash-verified revision with required notices. The OmniVoice package, base model and text tokenizer pins remain unchanged. No native emotional acting capability is claimed.

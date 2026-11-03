# Changelog

## 3.8.2 — QA fixes, Rebuild Master and kept takes

- **Long Form Rebuild Master:** after re-rendering a segment, join the existing segments into a new master (new `/long/join` route, VoxAster outputs only) instead of rendering every segment again.
- **Long Form splitting:** segments now end at `.`, `!`, `?` or `…` (closing quotes stay with their sentence); a sentence longer than 420 characters is broken at a comma, or else a space. Previously only `. ` split, so question-heavy scripts became one segment. Every Long Form failure now shows **Failed** instead of leaving "Generating sections…".
- **Takes:** every take from a 2–4 take generation is recorded in Takes and the open project; the comparison lanes show them without listing them twice.
- **Scene Editor:** dragging the ruler scrubs the playhead, and ⇧-drag sets a loop (a plain drag used to create a loop that could only be cleared from a hidden menu). A loop clears with its ✕ on the ruler, the loop button, **L**, the ruler's menu or **Esc**. Esc clears the loop, then the selection, then closes the editor. A loop repeats only when playback reaches its end, and stops just short of the end of the mix so it always repeats. The playhead keeps its place across the remix after an edit; clicking empty track space while paused moves it. Track volume drags are one undo step; nudge buttons respect the overlap guard; the trim cursor no longer sticks; repeated markers at one spot are ignored.
- **Cast:** the gap slider re-spaces a rendered scene (keeping edits, passage timing, interruptions and talk-overs; one undo step and one remix). Re-rendering a line keeps its fades. **New Scene** and **Open Scene** ask before discarding an unsaved scene.
- **Safer deletes:** voices and scenes move to the Trash; **Clear All Takes** asks for confirmation.
- **Script editor:** Clear Script, Replace with Clipboard (was Paste Script), examples and inserted tokens are undoable with ⌘Z.
- **Errors:** invalid settings name the setting and its allowed range, and empty Long Form segments are named by number.
- **Playback:** play/pause buttons and menu items in the Library and Studio reflect what is playing; starting one player pauses the other; the Record menu items read **Stop Recording** while recording. File durations are cached, so long take lists no longer re-open every file during playback, and the Scenes list no longer checks the disk on every redraw.
- **Repository:** a documentation index in `docs/README.md`; the 3.7.0 release audit and screenshots moved under `docs/`; `docs/TRAINING.md` is now `docs/ENGINES.md`.
- No model, tokenizer or package changed. Managed runtimes need **Set Up or Repair Runtime** once; 3.8.1 Performance productions remain renderable.

## 3.8.1 — Cast scenes, the Scene Editor and the Together engine

- **Scene Editor:** a full-window, Audacity-style multitrack timeline for Cast. One track per character with Mute, Solo and volume; every line is a clip you can move, trim, fade, re-level or re-render. Clips snap to each other and the playhead (hold ⌘ to turn off) and never stack on one track; re-rendering a line shifts later clips by its change in length. Undo/redo, keyboard editing, markers, loop playback, a Pace slider (70–140 % of every gap) and a playhead that pages along. The master is remixed shortly after each edit.
- **Interruptions:** a line ending `--` is cut off (the next speaker overlaps its last 0.25 s and it fades out); a line starting `>>` talks over the previous one (0.8 s early, previous line 8 dB quieter). Both can be toggled per clip.
- **Room** (Dry, Booth, Small room, Large room): matches speech levels (up to ±9 dB) and places every voice in one synthetic room with room tone at or below −70 dBFS. Louder tone under a reverb tail made Whisper hear words in the gaps.
- **Together engine (optional):** MOSS-TTSD performs passages of up to six lines in one pass so voices react to each other. It runs in its own Python 3.13 / MLX worker installed by `setup-moss.command` (about 10 GB, pinned in `Backend/moss.json`), and every voice is first sampled cleanly by OmniVoice because MOSS needs clean speech to clone.
- **Line checks:** every rendered line is transcribed with Whisper; misheard words are marked on the clip and listed in the selection bar. Double-click a clip to change its words; the script is updated and the line re-renders in place. **Check Lines** covers older scenes.
- **Exports:** mix at original level or −16 / −14 / −23 LUFS (BS.1770 with a −1 dBFS limiter), one dry stem per character, and SRT or WebVTT subtitles labelled by speaker.
- **Scenes in the Library:** save a scene with its script, voices, room, timeline and rendered lines in its own folder, so deleting takes never breaks it. Rendered lines survive relaunch.
- **Reliability:** a failed line is retried once and the rest of the scene still renders; **Retry Failed** finishes it, and a failed re-render keeps the previous take. Autoplay plays the master the panel shows.
- **Fix:** opening Cast could abort VoxAster ("more Update Constraints in Window passes than there are views") when the inspector's four-segment Room picker was wider than the inspector column. Room is now a menu, and the Scene Editor no longer imposes a minimum width.
- Managed runtimes need **Set Up or Repair Runtime** once after updating; repair reuses the verified downloads. 3.8.0 Performance productions remain renderable.

## 3.8.0 — studio redesign and studio tools

- Fixed generation freezing: long reference clips (over 20 s) are always trimmed, even when a transcript is saved, and synthesis runs off the server's event loop so the app stays responsive. Quitting no longer hangs on a stuck backend.
- New single-window studio: Voice Clone, Voice Design, Long Form, Performance and Cast modes in the toolbar; voice plate, ruled script page with worked examples, takes roll; Library tables; Engine Lab window; standard Settings window. Follows the macOS light/dark appearance.
- Reference Cleaner: finds the cleanest 6–15 s of one speaker in a long clip, transcribes it, and can save it as a voice.
- Take Doctor: transcribes each take locally with Whisper, scores it against the script, flags wrong or missing words, picks the best variant, and can re-render a single sentence and splice it into the take.
- Cast: `NAME:` scripts rendered with a voice per character and joined into one scene; designed characters keep their voice from their first line.
- Performance productions made with 3.7.0 remain renderable.
- Managed runtimes installed for 3.7.0 need one **Set Up or Repair Runtime** after updating, because the runtime lock records the app version. Existing Python-environment setups are unaffected.
- An engine left running after an app crash or force-quit now shuts itself down, so the next launch does not fail with "The backend exited".
- README, Getting Started and Privacy updated for the new studio and tools, with new screenshots from a demo profile of synthetic voices.

## 3.7.0 — first public source release

- Product renamed to VoxAster — Local AI Voice Studio for macOS; existing data and runtime identities are preserved.
- Publication checks cover historical commit/tag identities; documentation distinguishes external model terms and local processing limits.
- Native macOS voice cloning, design, pronunciation, variants and generation controls.
- Performance production workspace with exact pauses, segment gain, retained retries and deterministic master assembly.
- Authoritative Long Form edits, reference identity checks, project/draft recovery and safe exports.
- Python bytecode disabled in signed bundles, with post-import signature checks.
- Pinned runtime setup and verification, explicit third-party/privacy documentation, browser-request protection and backend shutdown on application quit.

Optional F5 inference remains separate. Personal Voice training, dataset token extraction and LoRA tooling are removed for the public release. Inference now resolves the official Boson audio tokenizer at an immutable, hash-verified revision with required notices. The OmniVoice package, base model and text tokenizer pins remain unchanged. No native emotional acting capability is claimed.

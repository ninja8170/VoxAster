# Script controls in 3.8.2

Native events (exact lowercase): `[laughter]`, `[sigh]`, `[confirmation-en]`, `[question-en]`, `[question-ah]`, `[question-oh]`, `[question-ei]`, `[question-yi]`, `[surprise-ah]`, `[surprise-oh]`, `[surprise-wa]`, `[surprise-yo]`, `[dissatisfaction-hnn]`.

CMU override: `[B EY1 S]`; uppercase phonemes with vowel stress 0–2. Pinyin overrides use uppercase syllables and tones 1–5, e.g. `NI3 HAO3`. Dictionary entries are `original=replacement`, one per line. Native markup and reference transcripts are protected from dictionary replacement.

Only in Performance: `[pause 500ms]` inserts 12,000 zero samples at 24 kHz after speech processing. Durations 1–10,000 ms are accepted. `[louder]` and `[quieter]` apply +3/-3 dB to the following speech segment until another direction; they do not mean shouting/whispering. Retained segments have frozen references, settings and seeds. Rebuild does no synthesis. Edge trimming/fades affect rendered speech boundaries; exact inserted silence is not a promise of an identical perceived linguistic pause.

Only in Cast: write each line as `NAME: line`; unlabelled lines continue the previous speaker. A line ending `--` (or an em dash) is cut off by the next speaker: they come in 0.25 s before it ends and it fades out. A line starting `>>` talks over the previous line: it starts 0.8 s before that line ends, which continues 8 dB quieter. The marks are removed before synthesis; a cut-off line is sent to the voice engine ending in a dash, so it sounds unfinished. Both can be changed per clip in the Scene Editor.

Unknown/malformed bracket controls block generation. Markdown, asterisks, parentheses, capitals and punctuation are not verified acting controls and may be spoken literally. Use plain text and the editor's buttons. Model preprocessing removes line breaks; blank lines do not guarantee pauses. Whisper is a Voice Design attribute, not a Clone inline tag.

Speed changes pace; Guidance changes conditioning; neither is emotional intensity. Seed is forwarded to the runtime, not a cross-hardware determinism guarantee. Duration overrides Speed estimation on individual generations; Long Form does not expose total duration. F5 accepts only its supported plain-text settings, not OmniVoice markup.

Implementation: `Backend/performance_script.py`, `performance_audio.py`, `performance.py`, `generation.py` and `Sources/PerformanceWorkspace.swift`; Cast marks in `CastStore.cue` (`Sources/StudioTools.swift`) and `studio_tools.shape_clip`.

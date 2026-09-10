# OmniVoice 3.7.0 — bounded P0 reliability pass

This pass builds on the uncommitted Phase 3 work. It does not install the app,
commit/checkpoint Phase 3, change runtime/package/model/tokenizer pins, run speech
inference, or begin Phase 4. The version remains 3.7.0 so existing Phase 3
production runtime checks remain compatible.

## P0.1 Export

`SafeFiles.export` canonicalizes symlinks/paths and checks device/inode identity
(including hard links). Same-file exports fail with an actionable message and do
not change either file. A unique temporary sibling is copied and checked against
the source SHA-256 before publication; the source is checked again for changes.
The copy is synchronized before a POSIX rename replaces the destination atomically.
The previous destination is never explicitly deleted. Copy, verification or rename
failure preserves it and cleans staging. Destination symlinks intentionally export
to their resolved target. This is filesystem atomicity, not a power-loss backup
or protection against another process maliciously racing filesystem operations.

## P0.2 References

Every selection has a new selection UUID and an audio SHA-256. Manual transcripts
bind to that identity. Import, drag/drop, Library, Engine Lab, Project restoration
and completed recordings follow the same selection policy. Import/drop validate a
regular decodable nonempty audio file; an invalid replacement keeps the old reference.
Completed recordings are retained under Application Support before becoming the
reference, rather than relying on the lifetime of an OS temporary take.

Replacing audio clears unrelated transcript, metrics and recommendations. Analyzer
requests carry the selection identity, transcript and request UUID; callbacks and
Apply Recommended Settings recheck all of them plus the current audio fingerprint.
Changing transcript also invalidates analysis. Reference-conditioned generation
rejects a changed/missing reference fingerprint; Design remains independent.

SavedVoice and VoiceProject gain an optional referenceSHA256 field. Existing JSON
still decodes. A fingerprint-matched saved transcript can be restored. Legacy or
mismatched transcripts are not silently trusted: the original record remains and
the Reference card offers explicit review/acceptance of the saved transcript.
Analysis is deliberately invalidated rather than migrated/cached across selection.
No reference-library redesign or model-conditioning cache has been added.

## P0.3 Editable draft safeguard

A versioned `editable-drafts.json` sidecar under Application Support/OmniVoice
stores editable scripts for Clone, Design, Long Form, Engine Lab and Performance,
pronunciation rules/modes, current generation/design settings and seeds, reference
path/fingerprint/transcript, and authoritative Long Form segment text. It does NOT
claim to save selected takes, audio history, assembled masters, or a complete
production/session graph. Performance productions keep their existing separate store.

Each editable change writes a recovery snapshot atomically. This intentionally
uses immediate writes rather than a debounce that could lose the latest edits on
quit. The active draft is restored on restart. Project switching/New Project first
save the outgoing draft and are blocked on failure or an active generation/recording.
Unsaved drafts are retained under unique IDs and accessible in Projects → Recoverable
drafts. New/legacy projects start with isolated blank scripts/default settings and
clear unrelated output UI. Existing projects.json fields remain backward compatible.
The preset pickers apply presets only on deliberate user selection, so restoring a
saved preset label cannot overwrite the restored numeric settings through onChange.

Project metadata writes propagate errors and never claim Saved on failure. UI status
explicitly distinguishes project records/recoverable drafts from full productions.
Unreadable draft/project JSON is preserved, not overwritten with an empty store.
Quitting retries draft persistence; a failure offers Cancel Quit or an explicit
Quit Without Saving. Referenced files moved/deleted externally require reselection;
this pass is not a general asset-migration/backup system.

## P0.4 Training/dataset/model transactions

Source existence and source/destination overlap are checked before preparation.
Prepared audio, diagnostics and manifests are written only inside a private staging
sibling. The final manifests refer to the final dataset paths. Both splits and their
24 kHz finite mono audio are validated before publication. Processing, validation
or publication failure leaves the old dataset intact. Ordinary quality rejections
are reported; operational exceptions abort the transaction.

Merged models are built in staging. Configuration, text tokenizer and audio tokenizer
files must exist; JSON/tokenizer and safetensors headers are checked without loading
model weights. Existing merged-model directories are replaced by macOS atomic
RENAME_SWAP (Linux renameat2 exchange where available). Unsupported filesystem
exchange fails closed; no delete-then-copy fallback exists. Old staging assets are
cleaned only after successful publication. This is not full acoustic/model acceptance.

Saved engines have stable UUID identities and unique immutable revision paths, rather
than sanitized-name directories. Distinct names that sanitize identically cannot
collide. Updating a named engine retains its identity and old directory. The atomic
registry update selects the new revision; registry failure preserves the old registry
and engine. Legacy entries receive an ID when explicitly republished; no bulk migration
or old-engine deletion occurs. Unreadable registries, duplicate names, unsafe external
paths and overlapping destinations fail before publication.

A filesystem lock serializes preparation, merges, engine publication and app-launched
training. The training shell inherits the lock descriptor, so it remains held if the
backend parent exits. The old in-memory process guard remains, and a process-table
check catches known older/manual training commands for this data root that did not
inherit the lock. If active-process inspection cannot run, destructive actions fail
closed with an explanation. Arbitrary external filesystem mutation/manual tools that
bypass these guards are outside this transaction contract.

No action is permanently disabled. Publication is intentionally unavailable while
training is active, process inspection is unavailable, staging is invalid, paths are
unsafe, or the filesystem cannot perform atomic exchange.

## Tests and acceptance

Tests use temporary directories, synthetic WAVs, tiny tokenizer/tensor fixtures,
mocked inference/merge output and injected I/O failures. They include same-path,
canonical/symlink/hard-link export rejection; copy/verification/rename failure;
reference/transcript/analysis races; invalid drops; known/legacy reference selection;
recording retention; restart/switch/save-failure draft recovery; legacy and corrupt
JSON; invalid/empty/overlapping datasets; write/validation/publish failures; engine
identity/name collisions; registry failures; actual directory exchange; and a real
short-lived child process retaining the publication lock.

Run `./test.command [temporary-artifact-directory]` for backend tests, Swift assertions,
release compilation, all shell syntax, bundle resource/provenance comparisons and
signature verification. `git diff --check` is separate. No synthesis is needed.

Interactive checks still required: export dialogs, reference replacement and transcript
review, draft recovery/project switching, quit failure handling, and Phase 3 listening
acceptance. No Phase 4 functionality is included.

## Final verification — 2026-09-11

From the actual project checkout:

- 92 backend tests passed (65 existing + 27 P0 regressions).
- 308 Swift assertions passed (235 existing + 73 P0 assertions).
- Native release build, bundle provenance/resource equality and strict signature
  verification passed. Every shell script was also syntax-checked individually;
  test.command now loops over all six files instead of treating later filenames
  as arguments to the first script.
- git diff --check passed.
- All five installed-app file SHA-256 fingerprints matched the baseline; runtime.json
  remained byte-identical to the pre-P0 manifest.
- Artifact: /private/tmp/omnivoice-p0-checkout-verification/release/OmniVoice.app
- Log: /private/tmp/omnivoice-p0-checkout-verification.log

The initial sandboxed release attempt could not package icons. The complete native
verification succeeded with macOS packaging permissions. A subsequent resource
comparison correctly caught a training-safety edit made after bundle copying; the
final full run used consistent source and passed. No failing check remains.

No installation, commit, push, model inference, dependency change or Phase 4 work
was performed. No permanent feature disablement was necessary. The installation
recommendation is to complete the outstanding interactive/listening acceptance,
then install after explicit authorization. No known unresolved defect remains
within these four P0 scopes; the documented filesystem/external-process limits and
P1 production/session work remain outside this pass.

### Files changed by the P0 pass (in addition to existing Phase 3 changes)

- Backend/backend.py
- Backend/training_safety.py (new)
- Sources/OmniVoice.swift
- Sources/Reliability.swift (new)
- Sources/DraftRecovery.swift (new)
- Tests/GenerationTests.swift
- Tests/ReliabilityTests.swift (new)
- Tests/test_reliability.py (new)
- test.command
- P0_RELIABILITY.md (new)

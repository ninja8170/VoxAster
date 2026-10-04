# Binary distribution preparation

This records the earlier packaging-audit snapshot. The subsequent local [managed first-run phase](RUNTIME_BOOTSTRAP.md) resolves the manual runtime/bootstrap blocker and expands the resource inventory. Its validation was explicitly unsigned; Developer ID, notarization and clean-Mac acceptance remain separate gates.

**Verdict: NOT READY — BLOCKERS REMAIN.** Local audit on 2026-10-04, based on source `2fc51a153f78d806cf05f68ed21b1d7120651d9a` plus uncommitted packaging preparation. No official app/DMG download is available. This does not change the source-only `v3.7.0` release or authorize notarization/publication.

## Release gates

| Gate | Finding |
|---|---|
| Exact embedded payload | Native-only payload inspected; no runtime packages or weights included |
| First-run experience | **Blocked:** app needs a pre-existing external Python environment and prepared model cache; no in-app setup |
| Developer ID | **Blocked:** read-only Keychain inspection found zero valid code-signing identities |
| Hardened Runtime | Enabled in local build; only audio-input entitlement |
| Deployment target | Fixed: compiler previously produced macOS 27 minimum while plist said 14; now both say 14 |
| Minimum-OS acceptance | **Pending:** actual macOS 14 hardware/VM test, including external runtime wheels; setting a deployment target is not that test |
| Gatekeeper / notarization | **Blocked:** ad-hoc candidate is rejected by Gatekeeper, has no secure timestamp or notarization ticket |
| Microphone / identity migration | **Pending:** test recording consent and preferences with the future Developer-ID identity; ad-hoc-to-Team-ID signing can affect consent identity |

## Exact native-only payload

`tools/audit-bundle.py` fails closed on any extra file, directory, symlink, external dylib or unintended entitlement. It verifies copied resources against source, the actual Mach-O deployment target, architecture, branded usage strings, absence of a test launch environment and strict signing. `--inventory` writes every file's path, byte count, SHA-256 and classification outside the app.

All paths below are relative to `VoxAster.app/Contents/`:

| File | Classification / redistribution boundary |
|---|---|
| `MacOS/VoxAster` | Compiled original Swift application; MIT, plus compiler-inserted Swift support under its runtime exception |
| `Info.plist` | Generated original application metadata |
| `_CodeSignature/CodeResources` | Generated signing metadata |
| `Resources/VoxAster.icns` | Original owner-authorized icon, generated from existing assets |
| `Resources/backend.py` | Original API/inference adapter; MIT |
| `Resources/generation.py` | Original request/capability adapter; MIT |
| `Resources/speech_text.py` | Original pronunciation/text processing; MIT |
| `Resources/performance.py` | Original production storage/render adapter; MIT |
| `Resources/performance_audio.py` | Original assembly implementation; MIT |
| `Resources/performance_script.py` | Original parser; MIT |
| `Resources/provenance.py` | Original asset provenance/loading adapter; MIT |
| `Resources/runtime.json` | Original external-asset pin manifest; contains identifiers/hashes, not weights |
| `Resources/LICENSE` | Original MIT notice; retain |
| `Resources/THIRD_PARTY.md` | Component distinctions and attribution; retain |
| `Resources/PRIVACY.md` | Original privacy/storage documentation |
| `Resources/Notice` | Boson/Meta required attribution; retain |
| `Resources/Licenses/BOSON-HIGGS-AUDIO-2.txt` | Unmodified Boson agreement; retain |
| `Resources/Licenses/META-LLAMA-3.txt` | Unmodified incorporated Meta agreement/AUP; retain |

There are no embedded frameworks, dylibs, interpreter, virtual environment, Python wheels, FFmpeg, fonts or Swift package dependencies. System frameworks and Swift libraries resolve under `/System/Library` and `/usr/lib`; they are not copied. Swift's [runtime-library exception](https://github.com/swiftlang/swift/blob/main/LICENSE.txt) permits redistribution of compiler-inserted portions without the otherwise-required Apache attribution. This does not cover arbitrary vendoring of toolchain libraries.

The original-code/icon owner approved MIT redistribution. No unknown third-party implementation file was found in this payload. The included third-party documents preserve, rather than override, their terms. See [THIRD_PARTY.md](../THIRD_PARTY.md) for the exact binary boundary. Clearance of these embedded files does not clear an external runtime installer, its downloaded wheels/native libraries or model redistribution. Any change to that boundary requires a fresh inventory and licence review.

The strict file allowlist excludes OmniVoice/Boson/Qwen weights, Hugging Face caches, reference audio, generated voices/WAVs, projects, databases, preferences, logs, bytecode, local caches and signing credentials. Only model identifiers/hashes occur in the manifest; no standalone Qwen assets are shipped.

## What first run actually does

`AppModel.startBackend` in `Sources/VoxAster.swift` looks for `~/Documents/OmniVoice-Mac/.venv/bin/python` and the bundled `Resources/backend.py`. If Python is absent, it reports **Runtime setup required**, with an error directing the user to `setup-runtime.command` in a source checkout. That script is not in the app. There is no automatic interpreter/runtime installer and no resumable setup UI.

A recipient of this current binary would still have to obtain the source scripts, install Homebrew, Python 3.12, Git and FFmpeg, and run `setup-runtime.command` followed by `verify-runtime.command`. Git may require Apple's Command Line Tools. They could skip native compilation, but they would still be recreating a development-style inference environment in Terminal. This is not an acceptable claim of a standalone download-and-run app.

- Setup defaults to Homebrew Python at `/opt/homebrew/bin/python3.12`. It creates the legacy per-user virtual environment and installs the pinned OmniVoice Git commit and constrained dependencies. The app's PATH explicitly includes Homebrew locations for tools such as FFmpeg. WAV decoding does not always need FFmpeg, but other supported media paths can.
- Dependencies go in the user's `.venv`. Base model/text tokenizer and official audio tokenizer downloads use the user's Hugging Face cache (normally `~/.cache/huggingface/hub`, overridable by Hub environment variables).
- `Backend/provenance.py` pins base/text revision `c5fdb5ccb189668d56333f77ba2629f4cd7535f4`; official Boson audio revision is `815a03f1b57dcb5ae918db415f22cd0c8a6f0f54`. Package stays `0.2.1` / `08be0b4ccbac3e13e374e86fbfead4b4cac343e2`.
- All four required Boson artifacts have independent expected SHA-256 checks. Base model/text assets use a pinned Hub snapshot, but no equivalent app-maintained per-file digest manifest. Python dependency versions are constrained, but installation does not use a complete `--require-hashes` lock (including build dependencies).
- Normal model startup is **local-cache only**; it does not fetch missing base assets. Missing/invalid models stop backend startup. The UI offers the log path/runtime verification advice; detailed errors remain in the log. It cannot repair the problem for a binary-only user.
- Optional reference transcription can download `openai/whisper-large-v3-turbo` on demand. The pinned upstream package selects a model name without an explicit immutable Whisper revision here. Supplying the reference transcript avoids that path. Optional F5 remains separately provisioned.
- Hub downloads can reuse cached data on another invocation; this is not transactional whole-app setup. Setup refuses an existing environment, including one left by a failed install. There is no automatic rollback/resume of that environment or integrated disk-space/download progress UI.
- Measured cached core assets: base/text 2,461,786,031 logical bytes, official audio tokenizer 805,677,537 bytes (about 3.04 GiB combined). The validated Python environment occupies about 1.2 GiB on this machine. These are observations, not a guaranteed download/disk requirement; temporary downloads, package caches and optional Whisper/F5 need additional space.

Recommended bounded next architecture decision: a managed, versioned external runtime installed by a guided setup flow, with atomic staging, integrity verification, progress/retry, clear model terms and recoverable errors. Keep mutable assets outside the signed app and preserve legacy user data. Decide separately whether the interpreter/wheels are bundled or fetched; audit the exact artifacts before adopting either option. No bootstrap or dependency changes are implemented in this preparation pass.

## Signing and permissions

`build.command` now explicitly compiles `-O -target arm64-apple-macosx14.0`. The compatibility bundle identifier remains `local.omnivoice.native`. No version, package or model pin changes are made.

`Resources/VoxAster.entitlements` contains only `com.apple.security.device.audio-input=true`, required for microphone recording with Hardened Runtime. The app has branded microphone and Documents usage descriptions. Documents access is used for the existing runtime/reference/output storage; it is not a new broad filesystem entitlement. Imported files and exports use native open/save panels. No automatic Downloads/Desktop access, camera, contacts or Apple Events access is requested.

The app is not sandboxed: App Sandbox network client/server and inheritance entitlements are not required. Native networking and `Process` launch do not justify disabling Hardened Runtime protections. Python/PyTorch/MPS run in a separate external interpreter, not inside the Swift process. No evidence justifies native `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`, `get-task-allow` or DYLD environment exceptions. If a future embedded interpreter needs exceptions, audit and test that executable specifically; do not copy broad exceptions onto the native app.

There is one Mach-O and no nested code. Signing targets the app directly; `--deep` is used only for verification. Adding embedded executables/frameworks would require inside-out individual signing and a revised bundle audit. Default builds remain explicitly ad-hoc. Setting `VOXASTER_SIGN_IDENTITY` requires a `Developer ID Application: ...` identity, adds a secure timestamp and preserves Hardened Runtime/entitlements. No certificate/key was created, exported or modified.

References: [Apple distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime), [audio input](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input), [Documents purpose string](https://developer.apple.com/documentation/bundleresources/information-property-list/nsdocumentsfolderusagedescription), [App Sandbox networking](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client).

## Local verification and limitations

Completed verification: **86 backend tests and 320 Swift UI/request assertions passed**, together with optimized release compilation, shell syntax, resource/provenance equality, Python no-bytecode imports and strict signing through `test.command`. The new bundle audit passed. Three separate negative probes correctly rejected an injected cache directory, an altered backend resource and a signature missing the approved microphone entitlement.

The isolated-home native launch tests produced these results:

1. No runtime: branded app launched, displayed **Runtime setup required**, and directed the user to source setup scripts. No user recordings/projects were loaded.
2. Existing validated runtime linked into the isolated home, empty model cache and offline mode: backend failed with `LocalEntryNotFoundError`; the UI reported backend exit and a log path. This confirms absent models are not downloaded/repaired on startup.
3. Same isolated home/runtime with existing cached models, still offline: app visibly reached **Ready**, HTTP `/health` returned **200 / ok true**, generation contract **3**, app **3.7.0**, package **0.2.1** and the expected package/model/tokenizer pins. The listener was the backend inside the temporary audit app. Normal quit stopped app/backend and released port 8011. All 18 bundle file hashes remained unchanged, strict signing passed afterward, and no `__pycache__` or `.pyc` appeared. No synthesis was performed.

For isolation, only the launch-test copy had a temporary `LSEnvironment` and was re-signed with the same Hardened Runtime/entitlements; it is not distributed. Candidate/archives have no `LSEnvironment`. Test copy code matches the candidate; its bundled attribution text predates this audit's appended documentation paragraph. The warm-cache result proves prepared-runtime startup, not clean-Mac provisioning. Existing models were read, not installed or upgraded; real user data and installed apps were left untouched.

The candidate's ad-hoc signature verifies strictly, but `spctl --assess --type execute` rejects it and `stapler validate` reports no ticket. Signed, notarized and stapled are separate states. No Gatekeeper or quarantine protection was weakened. A private temporary home is not a clean macOS installation: the host still has current system frameworks/toolchains, and it cannot establish macOS 14 behavior, fresh TCC consent or Developer-ID migration.

Normal bundle writes are prevented by production Python `-B` plus `PYTHONDONTWRITEBYTECODE=1`; backend subprocesses preserve that setting. Outputs, productions and saved engines remain under Documents; manifests/drafts/history under `~/Library/Application Support/OmniVoice`; logs under `~/Library/Logs/OmniVoice`; model/package caches and temporary inference views remain external. Python `.py` files in Resources are sealed data, imported by the external interpreter, not unsigned Mach-O executables.

Relocation inspection: backend code is located via `Bundle.main.resourcePath`, not a source checkout. Native dylibs are system-resolved. Launch outside Applications and drag-copy to `/Applications` do not solve the missing-runtime dependency. Compatibility paths/bundle ID stay fixed, preserving projects/references/drafts across replacements. Quit both old/new app and port 8011 owner before replacement. Back up the previous app, replace only the bundle, and retain all user/runtime data. Actual `/Applications` installation and existing-user upgrade are not performed in this audit.

## Distribution recommendation and prototype

**DMG** is recommended for the eventual native drag-to-Applications experience. ZIP is a useful simpler alternative, but gives less installation guidance. Neither format fixes first-run or signing blockers.

The local prototype contains only `VoxAster.app` and an `Applications -> /Applications` symlink, with no decorative artwork or user data. It is an unsigned/unnotarized **prototype**, not an install recommendation. Packaging uses a fresh staging directory, exact approved app contents and normalized staging timestamps. HFS+ volume UUIDs/image metadata mean `hdiutil` output is not promised to be byte-for-byte reproducible; determinism here means the validated payload/layout. Record the resulting archive hashes and verify mounted contents against the inventory.

After building locally, a maintainer can stage a fresh directory and use:

```sh
# Substitute explicit temporary paths; never stage over an installed app.
ditto "$CANDIDATE_APP" "$STAGING/VoxAster.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname VoxAster -srcfolder "$STAGING" -fs HFS+ -format UDZO "$PROTOTYPE_DMG"
ditto -c -k --sequesterRsrc --keepParent "$CANDIDATE_APP" "$PROTOTYPE_ZIP"
hdiutil verify "$PROTOTYPE_DMG"
```

A candidate must be re-inventoried and checked for signature/resource immutability after runtime, ZIP extraction and read-only DMG mounting. Exclude development launch-environment copies from all packages.

The earlier local DMG/ZIP prototypes passed mounted/extracted resource equality and signature checks. Ephemeral artifact paths, archive hashes and local file inventories are intentionally excluded from the source checkpoint. Rebuild and record a fresh inventory for the eventual authorized distribution.

## Future signing/notarization sequence — not executed

First resolve the runtime/bootstrap architecture and binary licences, complete minimum-OS/recording/upgrade acceptance, and obtain a valid Developer ID Application certificate with private key through the owner's Apple Developer account. Keep credentials in the owner's secure tooling; do not put them in source or command logs.

With the chosen signing identity and final output directory supplied as shell variables:

```sh
VOXASTER_SIGN_IDENTITY="$SIGNING_IDENTITY" ./build.command "$RELEASE_DIR"
python3 -B tools/audit-bundle.py "$RELEASE_DIR/VoxAster.app" --inventory "$RELEASE_DIR/inventory.json"
codesign --verify --deep --strict --verbose=2 "$RELEASE_DIR/VoxAster.app"
codesign -dvvv --entitlements - --xml "$RELEASE_DIR/VoxAster.app"
```

Confirm Developer ID authority, TeamIdentifier, secure timestamp, Hardened Runtime and approved entitlements; an ad-hoc build is not eligible. For the future DMG workflow, sign the finished DMG with the same Developer ID and timestamp. Apple notarizes ZIP/DMG submissions; ZIP itself cannot be stapled. A complete DMG flow after separate explicit authorization is:

```sh
codesign --sign "$SIGNING_IDENTITY" --timestamp "$FINAL_DMG"
xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
# Only after Accepted; on any other result, obtain/review the submission log.
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$FINAL_DMG"
```

The owner must separately configure the Keychain profile using Apple's documented process; no credentials/profile are requested or created now. Preserve the accepted submission ID/log. Validate the quarantined downloaded DMG and copied app on a clean compatible Mac, including offline ticket behavior, before release. If shipping ZIP as well, submit/staple the app through an appropriate ZIP notarization flow, then recreate the ZIP from that stapled app. Do not advertise ZIP notarization based only on an unrelated DMG's ticket.

See [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) and [common failures](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

No notarization submission, credential setup, installation, Git commit/push, tag change or GitHub Release edit is part of this pass. The next approval should cover first-run runtime architecture, not external notarization of this incomplete candidate.

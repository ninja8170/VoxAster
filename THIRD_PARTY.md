# Third-party software, models and assets

The MIT licence in this repository covers the original VoxAster app, backend adapter, documentation and icons. The owner confirmed code/icon redistribution rights on 2026-10-04. No third-party recordings, datasets, model weights, fonts, private signing material or Python environments are distributed here. Apple system fonts/SF Symbols are used through system APIs, not bundled as font/icon packages.

## Separate dependencies (downloaded by the user)

| Component | Terms / evidence | Use |
|---|---|---|
| k2-fsa OmniVoice code, commit `08be0b4ccbac3e13e374e86fbfead4b4cac343e2` | [Apache-2.0](https://github.com/k2-fsa/OmniVoice/blob/08be0b4ccbac3e13e374e86fbfead4b4cac343e2/LICENSE), Xiaomi Corp. | Synthesis dependency; original notices retained in installed package |
| OmniVoice weights, snapshot `c5fdb5ccb189668d56333f77ba2629f4cd7535f4` | [Pinned model card](https://huggingface.co/k2-fsa/OmniVoice/blob/c5fdb5ccb189668d56333f77ba2629f4cd7535f4/README.md) states CC-BY-NC (does not specify a version there) | Separately downloaded; non-commercial restriction must not be represented as MIT/Apache |
| Higgs Audio 2 audio tokenizer, official Boson revision `815a03f1b57dcb5ae918db415f22cd0c8a6f0f54` | [Boson Higgs Audio 2 Community License](Licenses/BOSON-HIGGS-AUDIO-2.txt), incorporating [Meta Llama 3 licence/AUP](Licenses/META-LLAMA-3.txt) | Unmodified inference only; user downloads pinned, hash-verified artifacts; no weights bundled |
| F5-TTS (optional) | [Code MIT; pretrained weights CC-BY-NC](https://github.com/SWivid/F5-TTS#license) | Separate environment; not installed by core setup |
| Whisper large-v3-turbo | [MIT model card](https://huggingface.co/openai/whisper-large-v3-turbo) | Local optional transcription |
| PyTorch / torchaudio | [PyTorch BSD-style](https://github.com/pytorch/pytorch/blob/main/LICENSE), [torchaudio BSD-2-Clause](https://github.com/pytorch/audio/blob/main/LICENSE) | Local tensor/audio runtime |
| Transformers, Accelerate, Hugging Face Hub | Apache-2.0 (installed distribution licence metadata) | Model loading/inference |
| FastAPI, Uvicorn, Starlette, HTTPX | MIT or BSD-3-Clause per installed distribution | Local API/client/testing |
| python-multipart | Apache-2.0 (installed distribution metadata) | Multipart uploads |
| NumPy, SciPy, librosa, SoundFile | BSD-family/ISC package licences; libsndfile has separate LGPL terms | Audio processing |
| FFmpeg | [LGPL/GPL depending on build](https://ffmpeg.org/legal.html) | Separate Homebrew executable; not redistributed by the app |
| SwiftUI, AppKit, AVFoundation, SF Symbols | Apple SDK/platform terms | System frameworks/resources; not relicensed by this project |

`constraints-macos-py312.txt` records the validated Python package set; [the complete metadata inventory](docs/DEPENDENCIES.md) also identifies transitive licences, including soxr LGPL, certifi MPL and bundled-wheel notices. Transitive dependencies retain their installed licence notices. This source release does not vendor those packages; anyone bundling them into a binary/installer must audit that concrete dependency distribution and carry its required notices. A MIT app licence does not override model, training-data, voice-consent or output-use restrictions.

## Boson / Meta obligations

Built with Higgs Materials licensed from Boson AI USA, Inc., Copyright Boson AI USA, Inc., All Rights Reserved and Meta Llama 3 licensed under the Meta Llama 3 Community License, Copyright Meta Platforms, Inc., All Right Reserved.

Built with Meta Llama 3; based on Meta Llama 3.

- The full unmodified agreements and Meta acceptable-use policy are in `Licenses/`; `Notice` carries both required copyright attributions. Build copies them into the app. README and Settings prominently display the required credits. These materials are not covered by the app's MIT licence.
- Comply with applicable laws, trade restrictions and the incorporated acceptable-use policy. No implied trademark rights or endorsement. Warranty, liability, termination and dispute terms are in the supplied agreements.
- Do not use Higgs materials or outputs to improve other large language models. The public app removes dataset extraction, training, LoRA, merging/publication and their UI/scripts. Inference does not train or change weights. Existing locally saved engines are not deleted; their separate provenance/rights are the user's responsibility and are not certified by this release.
- Boson requires an expanded licence if your or your affiliates' products/services exceeded 100,000 annual active users in the preceding calendar year. The release owner confirmed on 2026-10-04 that this threshold does not apply. Other users/distributors must assess their own eligibility. Meta's incorporated additional commercial terms also remain in the full agreement.
- Section 1.b.i also imposes naming requirements for AI models or similar software created, modified or improved using Higgs materials. This release does not create/distribute a new or modified model and does not enable model improvement. Do not assume this integration clears a future derived model or software release; reassess those terms before adding training or distributing derivatives.

## Distribution scope

This is an MIT **application source** release with separately licensed inference dependencies, not an unrestricted model release. No third-party weights/environments are bundled. The pinned OmniVoice card declares CC-BY-NC without an explicit version; do not redistribute weights without establishing full applicable terms. Anyone later vendoring packages or models must audit that concrete distribution and carry all notices. Free download alone does not clear commercial use.

The tokenizer's source, exact artefact hashes, adapter and training removal are documented in [tokenizer provenance](docs/TOKENIZER.md).

## Credits

OmniVoice synthesis is by the k2-fsa contributors (Han Zhu and collaborators; Xiaomi copyright in code). Optional F5-TTS is by SWivid/Yushen Chen and collaborators. Whisper is by OpenAI. The macOS application is independent of these projects. No endorsement is implied.

## Native-only binary inventory boundary (local preparation)

The local binary audit inspects the built files, independently of package declarations. The current build contains one compiled original Swift executable, the original Python backend adapters, original icon, runtime configuration and the licence/privacy/notice documents. It contains no Python interpreter, Python packages, FFmpeg, native third-party libraries, model/tokenizer weights or fonts. SwiftUI/AppKit/AVFoundation and Swift runtime libraries are resolved from macOS system locations, not copied into the app. Compiler-inserted Swift support is covered by Swift's [Apache-2.0 runtime-library exception](https://github.com/swiftlang/swift/blob/main/LICENSE.txt); this is not clearance to redistribute an arbitrary toolchain.

For this exact native-only payload, original code/icons may be redistributed under MIT with the included notice. The supplied Boson/Meta agreements and attribution remain included because they govern the separately obtained inference system. This finding does not clear bundling the external runtime, its native wheels, FFmpeg or weights, and does not remove any model-use restrictions above. A future runtime bootstrap or embedded-runtime design requires another concrete artifact/licence inventory before distribution.

No official binary download exists yet. The signing, first-run and minimum-OS acceptance blockers are recorded in [binary distribution preparation](docs/BINARY_DISTRIBUTION.md). Source release `v3.7.0` remains unchanged.

## Managed first-run installation (local, unpublished)

The new first-run flow downloads the reviewed standalone interpreter, pinned wheels, FFmpeg executable and model files directly from their upstream distributors into private Application Support storage. No such binary/weight is bundled in the app. The [managed runtime catalogue](docs/RUNTIME_BOOTSTRAP.md) records every artifact, size, licence boundary and source; the bundled lock carries every SHA-256. In particular, imageio-ffmpeg's BSD wrapper does not change its included FFmpeg 7.1 executable's GPL-2.0-or-later licence. Existing model restrictions remain unchanged. This flow is not clearance to mirror or bundle the downloaded runtime.

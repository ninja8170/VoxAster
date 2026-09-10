# 🎙 OmniVoice Mac

**A native macOS studio for local voice cloning, voice design, speech generation, model comparison and personal voice training.**

OmniVoice Mac turns the open-source [k2-fsa OmniVoice](https://github.com/k2-fsa/OmniVoice) model into a polished native macOS application built around local, private voice workflows.

Instead of operating OmniVoice through scripts or a browser interface, OmniVoice Mac provides a complete SwiftUI studio for creating voices, generating speech, managing projects, benchmarking engines and training personalised LoRA voice models directly on Apple Silicon.

> **Current version:** v3.4.5  
> **Platform:** macOS / Apple Silicon  
> **Status:** Active development

---

## ✨ What is OmniVoice Mac?

OmniVoice Mac started as an experiment:

> *Can OmniVoice be turned into a genuinely useful native Mac application?*

It has since grown into a local voice-production environment with multiple workflows built around the OmniVoice engine.

Everything from voice references and generated audio to trained voice models can remain on your Mac.

---

## 🎤 Voice Clone

Clone a voice from a short reference recording and generate new speech locally.

### Features

- Import WAV, MP3 and M4A references
- Record directly from the Mac microphone
- Save reusable reference voices
- Reference transcript support
- Cross-language voice cloning workflow
- Expression controls
- Pronunciation dictionary
- Adjustable generation speed
- Diffusion-step controls
- Guidance controls
- Multiple generation presets
- Local WAV output
- Integrated waveform and playback

### Expression controls

Supported expressive speech controls are exposed directly in the UI, including:

- Laughter
- Sigh
- Confirmation
- Question
- Surprise
- Dissatisfaction / hesitation

No need to manually remember expression tokens.

---

## 🎨 Voice Design

Create entirely new voices without supplying a reference recording.

Voice Design exposes OmniVoice's controllable speaker characteristics through a native visual interface.

### Voice controls

- Gender
- Age
- Pitch
- Delivery style
- English accent
- Chinese dialect
- Automatic voice generation

### Creator presets

Quickly configure voices for common use cases:

- 📖 Audiobook
- 📰 News Anchor
- 🎮 NPC
- 🎙 Podcast
- 📚 Language Tutor
- 🎧 Customer Support
- 🌙 Whisper

Each preset configures the underlying voice characteristics while remaining editable.

---

## 🧠 Voice Training

OmniVoice Mac can train a personalised **LoRA voice model locally on Apple Silicon**.

The complete pipeline runs on the Mac:

```text
Recordings
    ↓
Dataset Analysis
    ↓
Transcription
    ↓
Audio Normalisation
    ↓
Train / Dev Split
    ↓
Audio Token Extraction
    ↓
LoRA Training
    ↓
Checkpoint
    ↓
Merged OmniVoice Model
    ↓
Saved Trained Voice
```

### Dataset preparation

Voice Training can:

- analyse recording folders
- reject unusable clips
- normalise accepted audio
- convert audio to 24 kHz mono WAV
- use existing transcripts
- transcribe missing transcripts with local Whisper
- create training manifests
- extract OmniVoice audio tokens

### Apple Silicon training

The training pipeline includes macOS-specific compatibility work for:

- PyTorch MPS
- single-process DataLoaders
- macOS multiprocessing behaviour
- DataLoader prefetch handling
- SDPA
- MPS-safe precision
- Homebrew / FFmpeg discovery

Training progress is displayed directly inside the application.

### Trained Voice Library

Completed models can be named and saved:

```text
Dwayne Studio v1
Dwayne Studio v2
Narration Voice
Podcast Test
```

Each saved model becomes an independent engine that can be used in **Engine Lab**.

---

## 🧪 Engine Lab

Engine Lab provides randomized blind A/B testing between installed speech engines.

Select:

```text
Engine 1
        vs
Engine 2
```

Both receive:

- the same reference voice
- the same script
- the same speed
- the same generation settings

The outputs are then randomized as **Take A** and **Take B**.

Listen first.

Choose the better result.

Then reveal which engine generated each take.

### Supported engines

Depending on the local installation:

- **OmniVoice Zero-Shot**
- **Saved OmniVoice trained voices**
- **F5-TTS**

This makes it possible to objectively compare:

```text
OmniVoice Zero-Shot
        vs
Dwayne Studio v1
```

or:

```text
OmniVoice
   vs
F5-TTS
```

without knowing which result is which beforehand.

---

## 📚 Library

OmniVoice Mac maintains a local asset library for:

### Reference Voices

Reusable source voices for cloning and benchmarking.

### Trained Voices

Named OmniVoice models produced through Voice Training.

### Generated Audio

Previous speech generations with playback and file access.

---

## 📜 History

Successful generations are recorded locally.

History provides access to:

- generation type
- generation time
- script preview
- playback
- export
- Finder location
- deletion

Generation types include:

```text
Voice Clone
Voice Design
Auto Voice
Long Form
```

---

## 📄 Long Form

Long Form is designed for larger speech-production jobs such as:

- narration
- audiobooks
- documentaries
- podcasts
- presentations
- long scripts

It includes:

- dedicated reference-voice selection
- pronunciation rules
- chunked generation
- production progress
- combined final output

---

## 🗂 Projects

Projects separate production work from global application history.

Each project maintains its own:

- project name
- reference voice
- pronunciation rules
- generated outputs

Projects can be created, saved, reopened and deleted.

Outputs generated while a project is active are associated with that project without removing them from the global History.

---

## ⚙️ Generation Controls

OmniVoice Mac exposes the important inference controls while providing simpler presets for everyday use.

### Presets

| Preset | Purpose |
|---|---|
| Fast Preview | Faster iteration |
| Natural | Balanced default |
| Maximum Quality | Higher generation quality |
| Narration | Long-form speech |

### Advanced controls

- Speed
- Diffusion steps
- Guidance

---

## 🖥 Native macOS Interface

OmniVoice Mac is not an Electron wrapper or browser window.

The application UI is built using **SwiftUI** and integrates with native macOS functionality including:

- microphone permissions
- native file selection
- Finder
- local audio playback
- drag and drop
- native application storage
- Apple Silicon acceleration

The speech backend runs locally and communicates with the native application through a localhost API.

---

## 🏗 Architecture

```text
┌───────────────────────────────────────┐
│            OmniVoice Mac              │
│               SwiftUI                 │
├───────────────────────────────────────┤
│                                       │
│ Voice Clone        Voice Design       │
│ Long Form          Voice Training     │
│ Library            Projects           │
│ History            Engine Lab         │
│                                       │
└──────────────────┬────────────────────┘
                   │
             localhost API
                   │
┌──────────────────▼────────────────────┐
│             FastAPI Backend           │
├───────────────────────────────────────┤
│                                       │
│ OmniVoice                            │
│ F5-TTS                               │
│ Whisper                              │
│ PyTorch / MPS                        │
│ FFmpeg                               │
│ LoRA Training                        │
│                                       │
└──────────────────┬────────────────────┘
                   │
                   ▼
             Apple Silicon
```

---

## 🔒 Local-first

OmniVoice Mac is designed around local workflows.

Application data is stored under locations such as:

```text
~/Documents/OmniVoice-Mac/
```

This can include:

```text
outputs/
voices/
personal-voice/
personal-voice/engines/
```

Application metadata is stored in macOS Application Support.

Large models, recordings, generated audio, training datasets and personal voice checkpoints should **not** be committed to Git.

---

## 📦 Repository Structure

```text
OmniVoice-Mac/
│
├── Assets/
│   └── App icon assets
│
├── Backend/
│   └── backend.py
│
├── Sources/
│   └── OmniVoice.swift
│
├── install.command
├── setup-personal-training.command
├── repair-mac-training.command
├── repair-training-config.command
│
├── .gitignore
└── README.md
```

---

## 🚀 Installation

### Requirements

- Apple Silicon Mac
- macOS
- Python 3
- Xcode Command Line Tools
- Homebrew
- FFmpeg
- OmniVoice Python environment

The current application expects the OmniVoice environment at:

```text
~/Documents/OmniVoice-Mac/.venv
```

Install the native application with:

```bash
chmod +x install.command
./install.command
```

The application is installed to:

```text
~/Applications/OmniVoice.app
```

---

## 🧠 Voice Training Setup

Voice Training uses a separate training environment.

Run:

```bash
chmod +x setup-personal-training.command
./setup-personal-training.command
```

Training data and checkpoints are intentionally kept outside the Git repository.

---

## 🛠 Technology

### Native application

- Swift
- SwiftUI
- AppKit
- AVFoundation

### Backend

- Python
- FastAPI
- Uvicorn

### AI / Audio

- k2-fsa OmniVoice
- PyTorch
- Apple Metal Performance Shaders (MPS)
- Whisper
- F5-TTS
- FFmpeg
- LoRA

---

## 🧭 Current Development Direction

The core local studio is now functional.

Current areas of development include:

- further UI refinement
- project workflow improvements
- larger Personal Voice training datasets
- trained-model quality evaluation
- additional engine benchmarking
- improved long-form production
- better model lifecycle management
- performance optimisation on Apple Silicon

---

## 🧪 Experimental Status

OmniVoice Mac is currently an experimental personal project.

Some functionality—particularly local LoRA training and third-party model integration—may require specific dependency versions and may change as the underlying models evolve.

It is not currently intended as a production-supported distribution.

---

## 🙏 Credits

OmniVoice Mac is built around the open-source **OmniVoice** project from **k2-fsa**.

- [k2-fsa/OmniVoice](https://github.com/k2-fsa/OmniVoice)
- [k2-fsa](https://github.com/k2-fsa)

Additional local experimentation includes F5-TTS and Whisper.

OmniVoice Mac is an independent native macOS project and is not an official k2-fsa application.

---

## 📄 License

This repository currently does not declare an independent license.

Usage of OmniVoice and other included or integrated models remains subject to their respective licenses and terms.

---

<p align="center">
  <strong>OmniVoice Mac</strong><br>
  Local voice creation on Apple Silicon.
</p>

# Product screenshots

## VoxAster 3.8 (`3.8/`)

These images show the real native VoxAster 3.8 interface and are the ones used in the README. All except the Scene Editor were captured from 3.8.0.

| Image | What it shows |
|---|---|
| [3.8/hero.png](3.8/hero.png) | README banner (see composition note below) |
| [3.8/voice-clone.png](3.8/voice-clone.png) | Voice Clone with voice plate, ruled script, Take Doctor line and takes roll (dark) |
| [3.8/take-doctor.png](3.8/take-doctor.png) | Three variant takes scored by Take Doctor, best marked (dark) |
| [3.8/voice-design.png](3.8/voice-design.png) | Voice Design with the Audiobook preset and a designed voice's drawn signature (dark) |
| [3.8/long-form.png](3.8/long-form.png) | Long Form master and three rendered segments (light) |
| [3.8/performance.png](3.8/performance.png) | A prepared and rendered Performance production with an 800 ms pause (dark) |
| [3.8/cast.png](3.8/cast.png) | A three-character Cast scene rendered and joined (dark) |
| [3.8/library.png](3.8/library.png) | The Takes table in the Library (dark) |
| [3.8/scene-editor.png](3.8/scene-editor.png) | 3.8.1 Scene Editor: three tracks, a cut-off line, a talk-over, a marker and a fade-out (dark) |

### Capture and privacy

Captured from the 3.8.0 build launched with an isolated demo home (`CFFIXED_USER_HOME`) and data root, so the personal Library, History, voices, projects and drafts were never read. All four demo voices (Harbour Narrator, Mara, Tom, Studio Host) were invented with Voice Design using fixed seeds; none is a person's recording. Every take, Long Form master, Performance production and Cast scene shown was generated for real through the app from those voices. The scripts were written for these screenshots.

Each window was captured on its own at 1440 × 900 without a shadow and saved as an optimized PNG. No UI was fabricated or retouched.

The Scene Editor image (3.8.1) is the app's real `SceneEditor` view rendered offscreen at 1440 × 900 from the 3.8.1 source with an isolated, temporary scene. Its six lines were generated for real by the OmniVoice engine with Voice Design from invented descriptors (no reference recording) for three fictional characters, Narrator, Mara and Tom, and laid out by the app's own timeline code; the marker and fade were set through the same code paths the editor uses. Window chrome is not shown because the view was rendered without a window frame. Nothing was drawn or retouched.

The banner composes, on a ruled-paper background, the unmodified light-mode Voice Clone window and the actual waveform of the synthetic "Mara" voice drawn as an ink line with a seconds ruler and a red stylus. It adds no text.

## VoxAster 3.7.0 (archived)

These images show the real native VoxAster 3.7.0 interface from validated source commit `7af18b8c3297c3bd0728f26aa912b65e1c2ec948`.

| Image | Workspace |
|---|---|
| [voice-design.png](voice-design.png) | Supported speaker attributes and script editor |
| [voice-clone.png](voice-clone.png) | Synthetic reference, transcript and generation controls |
| [long-form.png](long-form.png) | Editable production chunks before generation |
| [performance.png](performance.png) | Prepared segments, app-level directions and exact pause sample count |

## Capture and privacy

Captured from a temporary copy of the validated local build. Application code and backend resources were unchanged; only the copy's launch environment and ad-hoc signature were adjusted to use an isolated demo home. The installed app and personal Library, History, references, projects and drafts were not used.

The scripts were written for these screenshots. The reference is synthetic Voice Design output from release validation, not a person's recording. The Performance production was prepared through the actual UI; its pending state is real. No generated output or audio files are included here.

Images were captured at 2960 × 1840, cropped by 66 pixels at the top to exclude system capture chrome, then downsampled to 1480 × 887 and saved as optimized sRGB PNGs without ancillary metadata. No UI was fabricated, composited or retouched. All four images together are approximately 1.52 MiB.

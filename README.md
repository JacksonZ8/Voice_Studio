# Voice Studio

Voice Studio is a local macOS app for building and testing custom TTS voices. It guides a voice project from raw audio/video import to vocal separation, slice labeling, GPT-SoVITS training, and text-to-speech playback in one desktop workflow.

The app is designed for local experimentation: your audio, generated samples, trained weights, and runtime caches stay on your machine and are not included in this repository.

## What It Does

- Import local audio or video sources.
- Analyze basic audio quality, including duration, sample rate, channel count, peak, RMS, and silence ratio.
- Separate vocals and background audio through a local UVR/BS-RoFormer or Demucs-compatible backend.
- Slice vocal audio into short clips for training.
- Generate ASR draft labels and let the user review/edit each transcript before training.
- Run a GPT-SoVITS training workflow from confirmed slices and labels.
- Import local voice packages and switch between them.
- Type text, generate WAV output with the selected trained voice, and play it inside the app.
- Keep generated TTS files bounded with simple output caching and cleanup.

RVC is intentionally left as a future optional module. The first version focuses on making the GPT-SoVITS voice-training and TTS loop usable.

## App Flow

```text
Import source
  -> Quality check
  -> Vocal/BGM separation
  -> Slice audio
  -> ASR draft labels
  -> Human label review
  -> GPT-SoVITS training
  -> TTS generation and playback
```

Voice Studio opens directly into the working interface. There is no landing page or web server to start.

## Requirements

- macOS
- Swift toolchain, for rebuilding the app
- Python environments for the local audio/ML tools you want to enable
- A local GPT-SoVITS checkout/runtime for real training and inference
- Optional UVR/BS-RoFormer or Demucs-compatible separation weights/tools
- Optional faster-whisper environment for ASR draft labeling

The repository does not ship model weights, voice data, generated audio, or full GPT-SoVITS dependencies.

## Run The App

If you already have a built app bundle:

```text
Voice Studio.app
```

On first launch, macOS may warn that the app is unsigned. Right-click `Voice Studio.app`, choose **Open**, then confirm.

To rebuild the app from source:

```bash
./build_app.sh
```

This creates or updates:

```text
Voice Studio.app/Contents/MacOS/VoiceStudio
```

## Project Layout

```text
Voice_train/
  native_app/Sources/             # SwiftUI app source
  scripts/                        # Local pipeline helpers
  configs/                        # Example runtime config
  docs/                           # Packaging and setup notes
  training_voice_assets/          # Generic voice package metadata template
  gpt_sovits_runtime/             # Local runtime directory, ignored where needed
  voice_projects/                 # Local project data, ignored by Git
```

Each local voice project uses:

```text
voice_projects/{voice_id}/
  project.json
  sources/
  dataset/
  inference/
  exports/
  separated/
  asr/
  gpt_sovits/
```

## Configure GPT-SoVITS

The app includes a runtime setup panel. Open Voice Studio, click **运行环境** in the sidebar, then:

1. Select your local GPT-SoVITS root directory.
2. Click **生成配置并检测**. If no Python is selected, Voice Studio creates `.venv-voice-studio` inside the GPT-SoVITS directory and uses its `bin/python`.
3. Optionally select the Python executable used for ASR.

Voice Studio will write `gpt_sovits_runtime/engine_config.json` and check the core runtime files. The generated venv gives the app a dedicated Python executable; GPT-SoVITS Python package dependencies still need to match the GPT-SoVITS project requirements.

For manual setup, create a local runtime config from the template:

```bash
cp configs/engine_config.example.json gpt_sovits_runtime/engine_config.json
```

Then edit `gpt_sovits_runtime/engine_config.json`:

```json
{
  "python": "/path/to/GPT-SoVITS/.venv-voice-studio/bin/python",
  "runtime_root": "/path/to/GPT-SoVITS",
  "inference_cli": "GPT_SoVITS/inference_cli.py",
  "asr_python": "/path/to/faster-whisper-venv/bin/python"
}
```

`runtime_root` should point to your local GPT-SoVITS root directory. The app can create `.venv-voice-studio` there when generating the config.

## Voice Package Format

Voice Studio can import a local voice package directory that contains:

```text
voice_package/
  configs/*.json
  weights/*.ckpt
  weights/*.pth
  reference/reference.wav
  reference/ref_text.txt
  samples/*.wav
```

The repository includes `training_voice_assets/` as a generic metadata template. It does not include real voice weights, reference audio, or generated samples.

## Current Status

Implemented:

- Native macOS SwiftUI app.
- Project creation and project directory management.
- Local source import through macOS file picker.
- WAV quality analysis and actionable quality notes.
- Step-by-step workflow for import, separation, ASR labeling, training, and TTS.
- Real separation script wrapper with UVR/BS-RoFormer first and Demucs fallback.
- ASR draft labeling script using faster-whisper when available.
- GPT-SoVITS training scripts for local projects.
- GPT-SoVITS CLI inference hook for real TTS generation.
- Voice package import and TTS output playback.
- Bounded TTS output cache behavior.
- App shutdown handling for child training/inference processes.

Still limited or optional:

- Video files are registered first; full video audio extraction depends on local ffmpeg/runtime setup.
- ASR labels are drafts and should be manually reviewed before training.
- Training presets are still oriented toward local smoke/short-run validation.
- Full RVC training and combined GPT-SoVITS + RVC inference are not part of the first version.

## What Is Not Committed

The GitHub repository intentionally excludes:

- Built app bundles: `Voice Studio.app/`
- Local projects: `voice_projects/`
- Runtime config: `gpt_sovits_runtime/engine_config.json`
- Runtime caches, logs, temporary files, and generated weights
- Model weights and generated voice samples
- Local test media
- Original handoff materials and private planning notes

See `docs/GITHUB_PACKAGING.md` for the packaging boundary.

## Development Checks

Useful local checks:

```bash
./build_app.sh
python3 -m py_compile scripts/run_app_training_smoke.py scripts/run_asr.py scripts/run_separation.py scripts/run_slicing.py scripts/run_training.py
```

Before publishing, also check that no local data or model files are staged:

```bash
git status --ignored
git diff --cached --name-status
```

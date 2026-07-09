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

### Option A: Download release (recommended)

Download `Voice_Studio-v*.zip` from the [latest release](https://github.com/JacksonZ8/Voice_Studio/releases), unzip, then:

```bash
# REQUIRED: remove macOS quarantine (otherwise auto-detection cannot write config)
xattr -dr com.apple.quarantine "Voice Studio.app"
```

Then right-click `Voice Studio.app` → **Open** (first-launch Gatekeeper bypass).

#### First-time setup (new users — no existing GPT-SoVITS install)

1. Open the app. The 运行环境 panel shows three buttons.
2. Click **下载 GPT-SoVITS 模型 (~5.7GB)** — downloads source code + pretrained weights + G2P + UVR5
3. Click **安装 Python 依赖** — creates `.venv` in `external/GPT-SoVITS/` and installs torch + requirements
4. Click **安装 ASR 环境** — creates `.venv-asr` in `external/asr/` with faster-whisper
5. After all three show green checkmarks, click **生成配置并检测** — writes `engine_config.json`

You're now ready to train and generate TTS.

#### Users with existing GPT-SoVITS install

The app auto-detects GPT-SoVITS in common locations (Desktop, home, sibling directories). Green checkmarks will already show for what's detected. Use the buttons only for missing pieces.

### Option B: Build from source

```bash
./build_app.sh
```

This compiles the Swift source into `Voice Studio.app`. No quarantine applies to local builds.

This creates or updates:

```text
Voice Studio.app/Contents/MacOS/VoiceStudio
```

## Project Layout

```text
Voice_Studio/
  native_app/Sources/             # SwiftUI app source
  scripts/                        # Local pipeline helpers (training, ASR, slicing, separation)
  configs/                        # Example runtime config
  docs/                           # Packaging and setup notes
  training_voice_assets/          # Generic voice package metadata template
  gpt_sovits_runtime/             # Local runtime directory (config, smoke overrides, cache)
  voice_projects/                 # Local project data, ignored by Git
```

The app is self-contained: the built `Voice Studio.app` reads `scripts/` and `gpt_sovits_runtime/` relative to its own bundle location. Clone this repo anywhere — no hardcoded paths required.

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

**Auto-detection (recommended).** Voice Studio scans common locations on launch — sibling directories, `~/GPT-SoVITS`, `~/Desktop`, and any subdirectory containing `external/GPT-SoVITS` or `GPT-SoVITS`. If it finds the GPT-SoVITS root, the matching Python venv (`.venv-gpt-sovits`, `.venv`, etc.), the ASR Python, and ffmpeg, it writes `gpt_sovits_runtime/engine_config.json` automatically. No manual setup needed.

Open **运行环境** in the sidebar to review the detected items. If anything is missing, you can override it manually:

1. Select your local GPT-SoVITS root directory (the folder that contains `GPT_SoVITS/inference_cli.py`).
2. Click **生成配置并检测**. The app auto-guesses Python and ASR Python relative to the chosen root.
3. Optionally select a different Python for ASR draft labeling.

For manual setup, copy the template and edit it:

```bash
cp configs/engine_config.example.json gpt_sovits_runtime/engine_config.json
```

```json
{
  "python": "/path/to/GPT-SoVITS/.venv/bin/python",
  "gpt_sovits_root": "/path/to/GPT-SoVITS",
  "runtime_root": "/path/to/project/gpt_sovits_runtime",
  "inference_cli": "GPT_SoVITS/inference_cli.py",
  "asr_python": "/path/to/asr/.venv-asr/bin/python"
}
```

- `gpt_sovits_root` — your local GPT-SoVITS installation root.
- `runtime_root` — the `gpt_sovits_runtime/` working directory inside this project.
- `python` — the Python executable for training and TTS inference (must have `torch` and GPT-SoVITS dependencies installed).
- `asr_python` — optional; Python with `faster-whisper` installed for ASR draft labeling.

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
- GPT-SoVITS training scripts with real-time streaming output and ffmpeg auto-detection.
- GPT-SoVITS CLI inference hook for real TTS generation.
- Voice package import and TTS output playback.
- Bounded TTS output cache behavior.
- App shutdown handling for child training/inference processes.
- **Auto-detection** of GPT-SoVITS root, Python venv, ASR Python, and ffmpeg on launch.
- **Portable layout** — no hardcoded paths; clone anywhere and build.

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

Build the app:

```bash
./build_app.sh
```

Verify Python scripts parse correctly:

```bash
python3 -m py_compile scripts/run_training.py scripts/run_asr.py scripts/run_separation.py scripts/run_slicing.py
```

Test auto-detection from a clean state (remove any existing config first):

```bash
rm -f gpt_sovits_runtime/engine_config.json
rm -rf gpt_sovits_runtime/cache
# Then launch the app — it should auto-detect and write engine_config.json
```

Before publishing, check that no local data or model files are staged:

```bash
git status --ignored
git diff --cached --name-status
```

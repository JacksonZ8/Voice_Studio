# GitHub Packaging Plan

This repository contains the Voice Studio application source and reproducible setup files only. Runtime data, model weights, generated audio, caches, and trained voice projects stay local or are downloaded at runtime.

## Commit To Git

- `native_app/` — SwiftUI app source
- `scripts/` — Python training/ASR/slicing/separation scripts + bash setup scripts
  - `download_models.sh` — one-click model + source download
  - `setup_environment.sh` — Python venv + dependencies
  - `setup_asr.sh` — faster-whisper ASR environment
  - `run_training.py`, `run_separation.py`, `run_asr.py`, `run_slicing.py`
- `gpt_sovits_runtime/smoke_overrides/` — training override modules
- `configs/engine_config.example.json` — config template for auto-detection seed
- `docs/` — packaging and integration notes
- `training_voice_assets/` — voice package metadata (README, configs/, docs/)
- `external/` — empty placeholder (models downloaded at runtime)
- `README.md`, `build_app.sh`, `.gitignore`

## Keep Out Of Git

- `Voice Studio.app/` — built app binary
- `voice_projects/` — local project data
- `external/GPT-SoVITS/` — downloaded source + models (~5.7GB)
- `gpt_sovits_runtime/engine_config.json` — local config with absolute paths
- `gpt_sovits_runtime/{cache,logs,TEMP,GPT_weights_v2,SoVITS_weights_v2}/`
- `gpt_sovits_runtime/{GPT_SoVITS,tools,configs,config.py,feature_extractor,text}` — symlinks
- `training_voice_assets/{reference,samples,weights}/`
- `Voice_Studio-v*.zip` — release artifacts
- Legacy planning docs and local test media

## After Cloning

1. Build the app:

   ```bash
   ./build_app.sh
   ```

2. Open `Voice Studio.app` — the app auto-detects GPT-SoVITS, writes `engine_config.json` on launch.

3. New users: open 运行环境, click the three buttons to download models, install dependencies, and set up ASR.

4. Existing GPT-SoVITS users: auto-detection finds your installation. Use the runtime panel to override paths if needed.

## Release Flow

```bash
./build_app.sh --release          # builds app + creates Voice_Studio-vX.Y.Z.zip
gh release create vX.Y.Z --title "..." --notes "..." Voice_Studio-vX.Y.Z.zip
```

The release zip includes the app bundle + all scripts + smoke_overrides + config template + empty external/ directory. Users extract, remove quarantine (`xattr -dr`), and launch.

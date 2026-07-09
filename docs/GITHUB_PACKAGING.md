# GitHub Packaging Plan

This repository should contain the Voice Studio application source and reproducible setup files only. Runtime data, model weights, generated audio, caches, and trained voice projects should stay local or be distributed separately.

## Commit To Git

- `native_app/`
- `scripts/`
- `configs/engine_config.example.json`
- `docs/`
- `README.md`
- `build_app.sh`
- `.gitignore`
- `sandrone_tts_assets/README.md`
- `sandrone_tts_assets/configs/`
- `sandrone_tts_assets/docs/`

## Keep Out Of Git

- `Voice Studio.app/`
- `voice_projects/`
- `gpt_sovits_runtime/engine_config.json`
- `gpt_sovits_runtime/cache/`
- `gpt_sovits_runtime/logs/`
- `gpt_sovits_runtime/TEMP/`
- `gpt_sovits_runtime/GPT_weights_v2/`
- `gpt_sovits_runtime/SoVITS_weights_v2/`
- `gpt_sovits_runtime/tools/uvr5/uvr5_weights/*.pth`
- `sandrone_tts_assets/reference/`
- `sandrone_tts_assets/samples/`
- `sandrone_tts_assets/weights/`
- `ONE_CLICK_TTS_TRAINER_PLAN.md`
- `agent_handoff/`
- local test media such as `测试语音.mp3`

## After Cloning

1. Build the macOS app:

   ```bash
   ./build_app.sh
   ```

2. Create a local GPT-SoVITS runtime config:

   ```bash
   cp configs/engine_config.example.json gpt_sovits_runtime/engine_config.json
   ```

3. Edit `gpt_sovits_runtime/engine_config.json` so it points to the local GPT-SoVITS Python environment and runtime directory.

4. Put local model weights and voice packages back into the ignored runtime/data directories as needed.

## Recommended GitHub Flow

1. Start with a private repository.
2. Push only the source commit.
3. Check GitHub's file list before making the repository public.
4. If a downloadable app is needed, upload `Voice Studio.app.zip` as a GitHub Release asset instead of committing the `.app` bundle.

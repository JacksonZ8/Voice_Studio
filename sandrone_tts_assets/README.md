# Sandrone TTS Assets For Agent Development

This directory contains the portable GPT-SoVITS assets needed to add Sandrone voice output to a future Sandrone agent project.

## Contents

- `weights/sandrone_v1-e8.ckpt`: GPT semantic model.
- `weights/sandrone_v1_e12_s2028.pth`: SoVITS acoustic/vocoder model.
- `reference/reference.wav`: reference voice prompt audio.
- `reference/ref_text.txt`: reference transcript.
- `samples/*.wav`: validated sample outputs.
- `configs/sandrone_tts_config.json`: machine-readable asset manifest for an agent project.

## Recommended Agent Flow

```text
User message -> LLM reply text -> TTS service -> Sandrone wav -> frontend playback
```

## CLI Integration

The current workspace can synthesize audio with:

```bash
cd /path/to/GPT-SoVITS
MPLCONFIGDIR=/tmp/voice-studio-matplotlib-cache \
PYTHONPATH=/path/to/GPT-SoVITS:/path/to/GPT-SoVITS/GPT_SoVITS \
/path/to/GPT-SoVITS/.venv/bin/python GPT_SoVITS/inference_cli.py \
  --gpt_model /path/to/weights/sandrone_v1-e8.ckpt \
  --sovits_model /path/to/weights/sandrone_v1_e12_s2028.pth \
  --ref_audio /path/to/reference/reference.wav \
  --ref_text /path/to/reference/ref_text.txt \
  --ref_language 中文 \
  --target_text /path/to/target.txt \
  --target_language 中文 \
  --output_path /path/to/output_dir
```

`inference_cli.py` writes `output.wav`; rename it after generation if the agent needs stable filenames.

## API Integration

For a future agent, prefer wrapping GPT-SoVITS behind a local TTS service. The service should:

- Load `configs/sandrone_tts_config.json`.
- Accept text.
- Generate or fetch cached wav.
- Return an audio URL/path.
- Record TTS call count and latency for the API usage panel.

## Important Notes

- These files are intended for local, personal, non-commercial use.
- Do not publish the model or serve it publicly unless rights and platform terms are confirmed.
- The current GPT-SoVITS source tree has two local compatibility patches:
  - explicit Chinese inference bypasses automatic language detection;
  - reference WAV loading uses `soundfile` to avoid missing `torchcodec`.

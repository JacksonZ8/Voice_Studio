# Training Voice Assets For Local Development

This directory describes the optional built-in GPT-SoVITS voice package used by Voice Studio during local development.

The GitHub repository keeps only portable metadata and integration notes. Model weights, reference audio, and generated samples should stay local unless you have confirmed the rights to distribute them.

## Expected Local Contents

- `weights/gpt.ckpt`: GPT semantic model.
- `weights/sovits.pth`: SoVITS acoustic/vocoder model.
- `reference/reference.wav`: reference voice prompt audio.
- `reference/ref_text.txt`: reference transcript.
- `samples/*.wav`: validated sample outputs.
- `configs/training_voice_config.json`: machine-readable asset manifest.

## Recommended Flow

```text
Input text -> GPT-SoVITS inference -> trained voice wav -> local playback
```

## CLI Integration

```bash
cd /path/to/GPT-SoVITS
MPLCONFIGDIR=/tmp/voice-studio-matplotlib-cache \
PYTHONPATH=/path/to/GPT-SoVITS:/path/to/GPT-SoVITS/GPT_SoVITS \
/path/to/GPT-SoVITS/.venv/bin/python GPT_SoVITS/inference_cli.py \
  --gpt_model /path/to/weights/gpt.ckpt \
  --sovits_model /path/to/weights/sovits.pth \
  --ref_audio /path/to/reference/reference.wav \
  --ref_text /path/to/reference/ref_text.txt \
  --ref_language 中文 \
  --target_text /path/to/target.txt \
  --target_language 中文 \
  --output_path /path/to/output_dir
```

`inference_cli.py` writes `output.wav`; rename it after generation if the app needs stable filenames.

## Important Notes

- Keep voice data and weights out of Git.
- Treat this package as a local development example, not as a public model distribution.
- Replace the config paths with your own trained voice package files before sharing a build.

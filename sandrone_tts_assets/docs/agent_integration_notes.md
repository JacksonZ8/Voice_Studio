# Agent Integration Notes

## Minimal TTS Service Contract

```http
POST /api/tts
Content-Type: application/json

{
  "text": "你好，我是你的智能助手桑多涅。",
  "voice_id": "sandrone_v1_e12_e8"
}
```

Response:

```json
{
  "audio_path": "/data/audio_cache/xxx.wav",
  "voice_id": "sandrone_v1_e12_e8",
  "duration_sec": 2.74,
  "cached": false
}
```

## Suggested Backend Wrapper

1. Write target text to a temporary `.txt` file.
2. Run GPT-SoVITS `inference_cli.py`.
3. Move `output.wav` into `data/audio_cache/`.
4. Return the cache path to the frontend.
5. Store one `api_calls` row with provider `local-gpt-sovits`.

## Suggested UI Controls

- Voice toggle: on/off.
- Autoplay toggle: on/off.
- Regenerate voice button.
- TTS status: idle/generating/failed.
- API usage page entry:
  - name: Sandrone GPT-SoVITS
  - type: local TTS
  - endpoint: CLI or `127.0.0.1:9880`
  - model files: GPT + SoVITS
  - calls today
  - average latency
  - last error

## Memory-First Development Order

Do not block basic chat and memory on TTS. The first usable agent should work as text-only, then add TTS as a playback layer.

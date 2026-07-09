#!/usr/bin/env bash
# Create ASR Python venv with faster-whisper.
# The model itself (~500MB) is auto-downloaded on first ASR run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASR_DIR="$ROOT/external/asr"
VENV="$ASR_DIR/.venv-asr"
PIP="$VENV/bin/pip"
PYTHON="$VENV/bin/python"

echo "SETUP_PROGRESS=0.0"
echo "[asr] Setting up ASR environment..."

# ── Find system Python 3 ──
SYSTEM_PYTHON=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -x "$candidate" ]; then
    SYSTEM_PYTHON="$candidate"
    break
  fi
done

if [ -z "$SYSTEM_PYTHON" ]; then
  echo "SETUP_ERROR=未找到系统 python3"
  exit 1
fi

echo "[asr] Using system Python: $SYSTEM_PYTHON"

# ── Create venv ──
if [ -f "$PYTHON" ]; then
  echo "[asr] venv already exists"
else
  mkdir -p "$ASR_DIR"
  "$SYSTEM_PYTHON" -m venv "$VENV"
  echo "[asr] venv created"
fi
echo "SETUP_PROGRESS=0.15"

# ── Install faster-whisper ──
echo "[asr] Installing faster-whisper..."
"$PIP" install --upgrade pip --quiet 2>&1 | tail -1
"$PIP" install faster-whisper --quiet 2>&1 | tail -3
echo "SETUP_PROGRESS=0.9"

# ── Verify ──
echo "[asr] Verifying..."
"$PYTHON" -c "from faster_whisper import WhisperModel; print('  faster-whisper: OK')"
echo "SETUP_PROGRESS=1.0"
echo "SETUP_OK=1"
echo "[asr] ASR environment ready: $PYTHON"

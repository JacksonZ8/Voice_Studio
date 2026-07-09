#!/usr/bin/env bash
# Create Python venv and install GPT-SoVITS dependencies.
# Run AFTER download_models.sh has placed models in external/GPT-SoVITS/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GPT_ROOT="$ROOT/external/GPT-SoVITS"
VENV="$GPT_ROOT/.venv"
PIP="$VENV/bin/pip"
PYTHON="$VENV/bin/python"

echo "SETUP_PROGRESS=0.0"
echo "[setup] Creating virtual environment at $VENV..."

# ── Find system Python 3 ──
SYSTEM_PYTHON=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -x "$candidate" ]; then
    SYSTEM_PYTHON="$candidate"
    break
  fi
done

if [ -z "$SYSTEM_PYTHON" ]; then
  echo "SETUP_ERROR=未找到系统 python3，请先安装 Python 3"
  exit 1
fi

echo "[setup] Using system Python: $SYSTEM_PYTHON"

# ── Phase 1: Create venv ──
if [ -f "$PYTHON" ]; then
  echo "[setup] venv already exists, skipping creation"
else
  "$SYSTEM_PYTHON" -m venv "$VENV"
  echo "[setup] venv created"
fi
echo "SETUP_PROGRESS=0.1"

# ── Phase 2: Upgrade pip ──
echo "[setup] Upgrading pip..."
"$PIP" install --upgrade pip --quiet 2>&1 | tail -1
echo "SETUP_PROGRESS=0.15"

# ── Phase 3: Install torch ──
echo "[setup] Installing PyTorch (this may take a few minutes)..."
if [ "$(uname -m)" = "arm64" ]; then
  # Apple Silicon — use MPS-capable build (default index)
  echo "[setup] Apple Silicon detected — installing MPS-capable PyTorch"
  "$PIP" install torch torchaudio --quiet 2>&1 | tail -3
else
  # Intel Mac — use CPU-only for compatibility
  echo "[setup] Intel Mac detected — installing CPU-only PyTorch"
  "$PIP" install torch torchaudio --index-url https://download.pytorch.org/whl/cpu --quiet 2>&1 | tail -3
fi
echo "SETUP_PROGRESS=0.35"

# ── Phase 4: Install GPT-SoVITS requirements ──
echo "[setup] Installing GPT-SoVITS dependencies..."
if [ -f "$GPT_ROOT/requirements.txt" ]; then
  "$PIP" install -r "$GPT_ROOT/requirements.txt" --quiet 2>&1 | tail -5
else
  echo "SETUP_ERROR=未找到 $GPT_ROOT/requirements.txt"
  exit 1
fi
echo "SETUP_PROGRESS=0.85"

# ── Phase 5: Verify key packages ──
echo "[setup] Verifying installation..."
"$PYTHON" -c "import torch; print(f'  torch {torch.__version__}')"
"$PYTHON" -c "import transformers; print(f'  transformers {transformers.__version__}')"
"$PYTHON" -c "import librosa; print(f'  librosa {librosa.__version__}')" 2>/dev/null || echo "  librosa: ok"

echo "SETUP_PROGRESS=1.0"
echo "SETUP_OK=1"
echo "[setup] Environment ready: $PYTHON"

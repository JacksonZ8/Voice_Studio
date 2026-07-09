#!/usr/bin/env bash
# Download GPT-SoVITS pretrained models + G2PWModel + UVR5 weights.
# Usage:
#   SOURCE=HF        bash download_models.sh   (HuggingFace, default)
#   SOURCE=HF-Mirror bash download_models.sh   (HF Mirror for China)
#   SOURCE=ModelScope bash download_models.sh  (ModelScope)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/external/GPT-SoVITS"
SOURCE="${SOURCE:-HF}"

# ── URL selection ──
case "$SOURCE" in
  HF)
    BASE="https://huggingface.co/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
    ;;
  HF-Mirror)
    BASE="https://hf-mirror.com/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
    ;;
  ModelScope)
    BASE="https://www.modelscope.cn/models/XXXXRT/GPT-SoVITS-Pretrained/resolve/master"
    ;;
  *)
    echo "Unknown SOURCE: $SOURCE (use HF, HF-Mirror, or ModelScope)" >&2
    exit 1
    ;;
esac

# ── Files to download: name, size_bytes, dest_subdir ──
FILES=(
  "pretrained_models.zip|4898947072|pretrained_models"
  "G2PWModel.zip|617611264|GPT_SoVITS/text"
  "uvr5_weights.zip|548405248|tools/uvr5"
)

mkdir -p "$DEST"

# ── Helper: download one file with progress ──
download_one() {
  local name="$1"
  local size_bytes="$2"
  local subdir="$3"
  local url="$BASE/$name"
  local dest_dir="$DEST/$subdir"
  local dest_file="$dest_dir/$name"

  mkdir -p "$dest_dir"

  # Skip if file exists and size matches
  if [ -f "$dest_file" ]; then
    local existing_size
    existing_size=$(stat -f%z "$dest_file" 2>/dev/null || stat -c%s "$dest_file" 2>/dev/null || echo 0)
    if [ "$existing_size" -eq "$size_bytes" ] 2>/dev/null; then
      echo "DOWNLOAD_PROGRESS=1.0"
      echo "[download] $name already downloaded (${size_bytes} bytes)"
      return 0
    fi
    echo "[download] Resuming $name from byte $existing_size"
  else
    echo "[download] Starting $name (${size_bytes} bytes)"
  fi

  local tmp_file="${dest_file}.tmp"

  if curl -L --continue-at - --progress-bar -o "$tmp_file" "$url" 2>&1 | while IFS= read -r line; do
    if [[ "$line" =~ ([0-9]+([.][0-9]+)?)% ]]; then
      local pct="${BASH_REMATCH[1]}"
      echo "DOWNLOAD_PROGRESS=$(python3 -c "print($pct/100)")"
    fi
  done; then
    mv "$tmp_file" "$dest_file"
    echo "[download] $name complete"
    local final_size
    final_size=$(stat -f%z "$dest_file" 2>/dev/null || stat -c%s "$dest_file" 2>/dev/null || echo 0)
    if [ "$final_size" -ne "$size_bytes" ]; then
      echo "[warn] $name size mismatch: expected $size_bytes, got $final_size" >&2
    fi
  else
    echo "DOWNLOAD_ERROR=Failed to download $name (code $?)" >&2
    exit 1
  fi
}

# ── Main ──
total_files=${#FILES[@]}
current=0
for entry in "${FILES[@]}"; do
  IFS='|' read -r name size subdir <<< "$entry"
  echo "DOWNLOAD_FILE=$name"
  download_one "$name" "$size" "$subdir"
  current=$((current + 1))
  echo "DOWNLOAD_PROGRESS=$(python3 -c "print($current/$total_files)")"
done

# ── Extract zips ──
echo "[download] Extracting pretrained_models.zip..."
unzip -q -o "$DEST/pretrained_models/pretrained_models.zip" -d "$DEST/GPT_SoVITS/" 2>&1 || true
echo "[download] Extracting G2PWModel.zip..."
unzip -q -o "$DEST/GPT_SoVITS/text/G2PWModel.zip" -d "$DEST/GPT_SoVITS/text/" 2>&1 || true
echo "[download] Extracting uvr5_weights.zip..."
unzip -q -o "$DEST/tools/uvr5/uvr5_weights.zip" -d "$DEST/tools/uvr5/" 2>&1 || true

# ── Verify key files ──
REQUIRED=(
  "$DEST/GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large/pytorch_model.bin"
  "$DEST/GPT_SoVITS/pretrained_models/chinese-hubert-base/pytorch_model.bin"
  "$DEST/GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth"
  "$DEST/GPT_SoVITS/text/G2PWModel/G2PWModel_1.1.zip"
)
all_ok=true
for f in "${REQUIRED[@]}"; do
  if [ ! -f "$f" ] && [ ! -d "$f" ]; then
    echo "[warn] Missing expected file: $f" >&2
    all_ok=false
  fi
done

if $all_ok; then
  echo "DOWNLOAD_OK=1"
  echo "[download] All models downloaded and verified"
else
  echo "DOWNLOAD_OK=0"
  echo "[download] Some files may be missing; re-run to resume partial downloads"
fi

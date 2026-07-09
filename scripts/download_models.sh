#!/usr/bin/env bash
# Download GPT-SoVITS source code + pretrained models + G2PWModel + UVR5 weights.
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
    HF_BASE="https://huggingface.co/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
    GH_SOURCE="https://github.com/lj1995/GPT-SoVITS/archive/refs/heads/main.zip"
    ;;
  HF-Mirror)
    HF_BASE="https://hf-mirror.com/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
    GH_SOURCE="https://github.com/lj1995/GPT-SoVITS/archive/refs/heads/main.zip"
    ;;
  ModelScope)
    HF_BASE="https://www.modelscope.cn/models/XXXXRT/GPT-SoVITS-Pretrained/resolve/master"
    GH_SOURCE="https://github.com/lj1995/GPT-SoVITS/archive/refs/heads/main.zip"
    ;;
  *)
    echo "Unknown SOURCE: $SOURCE (use HF, HF-Mirror, or ModelScope)" >&2
    exit 1
    ;;
esac

mkdir -p "$DEST"

# ── Files to download: name, size_bytes, dest_subdir, source (HF/GH) ──
# Sorted by priority: source code first (smaller, needed before models)
FILES=(
  # source_code.zip from GitHub (~50MB when compressed)
  "GPT-SoVITS-source.zip|52428800|.|gh"
  # Pretrained model weights from HuggingFace
  "pretrained_models.zip|4898947072|pretrained_models|hf"
  "G2PWModel.zip|617611264|GPT_SoVITS/text|hf"
  "uvr5_weights.zip|548405248|tools/uvr5|hf"
)

# ── Compute total size for weighted progress ──
TOTAL_SIZE=0
for entry in "${FILES[@]}"; do
  IFS='|' read -r name size subdir src <<< "$entry"
  TOTAL_SIZE=$((TOTAL_SIZE + size))
done

# ── Helper: download one file with accurate progress ──
download_one() {
  local name="$1"
  local size_bytes="$2"
  local subdir="$3"
  local src_type="$4"
  local dest_dir="$DEST/$subdir"
  local dest_file="$dest_dir/$name"
  local download_start_bytes=0

  mkdir -p "$dest_dir"

  # Determine URL
  local url
  if [ "$src_type" = "gh" ]; then
    url="$GH_SOURCE"
  else
    url="$HF_BASE/$name"
  fi

  # Check if file already exists with correct size
  if [ -f "$dest_file" ]; then
    local existing_size
    existing_size=$(stat -f%z "$dest_file" 2>/dev/null || stat -c%s "$dest_file" 2>/dev/null || echo 0)
    if [ "$existing_size" -eq "$size_bytes" ] 2>/dev/null; then
      echo "[download] $name already downloaded (${size_bytes} bytes)"
      return 0
    fi
    echo "[download] Resuming $name from byte $existing_size (expected: ${size_bytes})"
    download_start_bytes=$existing_size
  else
    echo "[download] Starting $name ($(numfmt --to=iec 2>/dev/null <<< "$size_bytes" || echo "${size_bytes} bytes"))"
  fi

  local tmp_file="${dest_file}.tmp"

  # If we have a partial download, copy it to tmp for resume
  if [ "$download_start_bytes" -gt 0 ] && [ -f "$dest_file" ]; then
    cp "$dest_file" "$tmp_file"
  fi

  # Use curl -# for machine-parseable progress (one # per 2% by default)
  # curl -# writes progress to stderr; we capture and convert \r to \n for line-based parsing
  local curl_exit=0
  curl -L --continue-at - -# -o "$tmp_file" "$url" 2>&1 >/dev/null | while IFS= read -r -d $'\r' chunk; do
    # chunk looks like: "##########                                                 25.0%"
    if [[ "$chunk" =~ ([0-9]+([.][0-9]+)?)% ]]; then
      local file_pct="${BASH_REMATCH[1]}"
      echo "DOWNLOAD_FILE_PCT=$file_pct"
    fi
  done || curl_exit=$?

  # Check if curl succeeded
  if [ "${PIPESTATUS[0]}" -ne 0 ] 2>/dev/null || [ "$curl_exit" -ne 0 ]; then
    echo "DOWNLOAD_ERROR=Failed to download $name" >&2
    # Keep partial file for resume
    if [ -f "$tmp_file" ]; then
      mv "$tmp_file" "$dest_file" 2>/dev/null || true
    fi
    exit 1
  fi

  # Move tmp to final
  if [ -f "$tmp_file" ]; then
    mv "$tmp_file" "$dest_file"
  fi

  echo "[download] $name complete"

  # Verify size
  local final_size
  final_size=$(stat -f%z "$dest_file" 2>/dev/null || stat -c%s "$dest_file" 2>/dev/null || echo 0)
  if [ "$final_size" -lt "$((size_bytes - 1024))" ]; then
    echo "[warn] $name: expected ${size_bytes} bytes, got ${final_size} bytes. File may be incomplete." >&2
  fi
}

# ── Count downloaded bytes so far (for weighted progress) ──
downloaded_sofar=0

# ── Main download loop ──
for entry in "${FILES[@]}"; do
  IFS='|' read -r name size subdir src <<< "$entry"
  echo "DOWNLOAD_FILE=$name"

  # Check if already fully downloaded (skip progress if done)
  local dest_file="$DEST/$subdir/$name"
  local skip=false
  if [ -f "$dest_file" ]; then
    local existing_size
    existing_size=$(stat -f%z "$dest_file" 2>/dev/null || stat -c%s "$dest_file" 2>/dev/null || echo 0)
    if [ "$existing_size" -eq "$size" ] 2>/dev/null; then
      skip=true
    fi
  fi

  if $skip; then
    downloaded_sofar=$((downloaded_sofar + size))
    echo "DOWNLOAD_PROGRESS=$(python3 -c "print(min(1.0, $downloaded_sofar / $TOTAL_SIZE))")"
    echo "[download] $name already complete — skipping"
    continue
  fi

  download_one "$name" "$size" "$subdir" "$src"
  downloaded_sofar=$((downloaded_sofar + size))
  echo "DOWNLOAD_PROGRESS=$(python3 -c "print(min(1.0, $downloaded_sofar / $TOTAL_SIZE))")"
done

# ── Extract source code zip ──
echo "[download] Extracting GPT-SoVITS source code..."
SOURCE_ZIP="$DEST/GPT-SoVITS-source.zip"
if [ -f "$SOURCE_ZIP" ]; then
  # Extract to temp dir first, then move contents up one level
  TEMP_EXTRACT="$DEST/.source_extract_tmp"
  rm -rf "$TEMP_EXTRACT"
  mkdir -p "$TEMP_EXTRACT"
  if ! unzip -q -o "$SOURCE_ZIP" -d "$TEMP_EXTRACT"; then
    echo "[warn] Failed to extract GPT-SoVITS source code" >&2
  else
    # GitHub zip creates GPT-SoVITS-main/ directory; move contents to DEST
    # Also handle other possible structures
    for subdir in "$TEMP_EXTRACT"/*/; do
      if [ -d "$subdir" ]; then
        # Copy contents without overwriting existing (preserve downloaded models)
        cp -rn "$subdir"* "$DEST/" 2>/dev/null || true
        # Also copy dotfiles like .gitignore, requirements.txt
        cp -rn "$subdir".* "$DEST/" 2>/dev/null || true
      fi
    done
    rm -rf "$TEMP_EXTRACT"
    echo "[download] GPT-SoVITS source extracted"
  fi
else
  echo "[warn] GPT-SoVITS source zip not found at $SOURCE_ZIP" >&2
fi

# ── Extract model zips ──
if [ -f "$DEST/pretrained_models/pretrained_models.zip" ]; then
  echo "[download] Extracting pretrained_models.zip..."
  if ! unzip -q -o "$DEST/pretrained_models/pretrained_models.zip" -d "$DEST/GPT_SoVITS/"; then
    echo "[warn] Failed to extract pretrained_models.zip" >&2
  fi
fi

if [ -f "$DEST/GPT_SoVITS/text/G2PWModel.zip" ]; then
  echo "[download] Extracting G2PWModel.zip..."
  if ! unzip -q -o "$DEST/GPT_SoVITS/text/G2PWModel.zip" -d "$DEST/GPT_SoVITS/text/"; then
    echo "[warn] Failed to extract G2PWModel.zip" >&2
  fi
fi

if [ -f "$DEST/tools/uvr5/uvr5_weights.zip" ]; then
  echo "[download] Extracting uvr5_weights.zip..."
  if ! unzip -q -o "$DEST/tools/uvr5/uvr5_weights.zip" -d "$DEST/tools/uvr5/"; then
    echo "[warn] Failed to extract uvr5_weights.zip" >&2
  fi
fi

# ── Verify critical files ──
REQUIRED=(
  # Source code
  "$DEST/GPT_SoVITS/inference_cli.py"
  "$DEST/requirements.txt"
  # Pretrained models
  "$DEST/GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large/pytorch_model.bin"
  "$DEST/GPT_SoVITS/pretrained_models/chinese-hubert-base/pytorch_model.bin"
  "$DEST/GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth"
  # G2P
  "$DEST/GPT_SoVITS/text/G2PWModel/G2PWModel_1.1.zip"
)

all_ok=true
for f in "${REQUIRED[@]}"; do
  if [ ! -f "$f" ] && [ ! -d "$f" ]; then
    echo "[warn] Missing: $f" >&2
    all_ok=false
  fi
done

if $all_ok; then
  echo "DOWNLOAD_OK=1"
  echo "[download] All models and source code downloaded and verified"
else
  echo "DOWNLOAD_OK=0"
  echo "[download] Some files may be missing; re-run to resume partial downloads"
fi

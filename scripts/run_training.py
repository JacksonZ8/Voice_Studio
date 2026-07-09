#!/usr/bin/env python3
"""
Production GPT-SoVITS training script for Voice Studio.
Replaces the smoke-test script with real multi-slice, multi-epoch training.

Reads from a voice project:
  voice_projects/{voice_id}/
    dataset/slices/*.wav
    asr/asr_drafts.json          # ASR annotations (with user corrections)
    project.json

Outputs a voice package:
  voice_projects/{voice_id}/exports/{exp_name}/
    configs/*.json
    weights/*.ckpt / *.pth
    reference/

Usage:
  python run_training.py --project voice_projects/sandrone_native --exp-name sandrone_v2 \
      --sovits-epochs 12 --gpt-epochs 8
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "gpt_sovits_runtime"
ENGINE_CONFIG = RUNTIME / "engine_config.json"

# Three built-in presets
PRESETS = {
    "fast": {"sovits_epochs": 3, "gpt_epochs": 2, "batch_size": 4, "description": "快速验证 (10-15分钟素材)"},
    "standard": {"sovits_epochs": 12, "gpt_epochs": 8, "batch_size": 2, "description": "标准训练 (20-40分钟素材)"},
    "fine": {"sovits_epochs": 20, "gpt_epochs": 15, "batch_size": 2, "description": "精修训练 (40分钟以上干净素材)"},
}

# ── helpers ──────────────────────────────────────────────────


def run(cmd: list[str], cwd: Path, env: dict[str, str]) -> None:
    """Stream subprocess output line-by-line so the Swift app sees real-time progress.

    Training scripts (s2_train.py, s1_train.py) write progress bars and log messages
    to stderr, so we merge stderr into stdout to ensure everything reaches the app."""
    joined = " ".join(str(x) for x in cmd)
    print(f"[run] {joined}", flush=True)
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,  # Merge stderr → stdout so app sees tqdm + logging
    )
    # Stream line by line for real-time progress in the Swift app
    for line in proc.stdout:
        print(line, end="", flush=True)
    proc.wait()
    if proc.returncode != 0:
        print(f"TRAINING_ERROR=Step failed with exit code {proc.returncode}", flush=True)
        raise SystemExit(proc.returncode)


def require_nonempty(path: Path, label: str) -> None:
    """Verify a directory exists and contains at least one file."""
    if not path.exists():
        raise SystemExit(f"Stage output missing: {label} ({path})")
    if path.is_dir():
        contents = list(path.iterdir())
        if not contents:
            raise SystemExit(f"Stage output empty: {label} ({path}) — no files produced")
        print(f"[verify] {label}: {len(contents)} file(s) ok", flush=True)


def require(path: Path, label: str) -> None:
    if not path.exists():
        raise SystemExit(f"Missing {label}: {path}")


def load_json(path: Path) -> dict:
    require(path, str(path))
    return json.loads(path.read_text(encoding="utf-8"))


def newest(pattern: Path) -> Path | None:
    files = list(pattern.parent.glob(pattern.name))
    if not files:
        return None
    return max(files, key=lambda item: item.stat().st_mtime)


# ── runtime setup ────────────────────────────────────────────


def load_engine() -> dict:
    require(ENGINE_CONFIG, "engine config")
    return json.loads(ENGINE_CONFIG.read_text(encoding="utf-8"))


def prepare_runtime_links(external_root: Path) -> None:
    RUNTIME.mkdir(parents=True, exist_ok=True)
    links = {
        "GPT_SoVITS": external_root / "GPT_SoVITS",
        "tools": external_root / "tools",
        "configs": external_root / "GPT_SoVITS" / "configs",
        "config.py": external_root / "config.py",
        "feature_extractor": external_root / "GPT_SoVITS" / "feature_extractor",
        "text": external_root / "GPT_SoVITS" / "text",
    }
    for name, target in links.items():
        link = RUNTIME / name
        # Remove broken symlinks so they get recreated correctly
        if link.is_symlink() and not link.exists():
            link.unlink()
        if link.exists() or link.is_symlink():
            continue
        link.symlink_to(target, target_is_directory=target.is_dir())
        link.symlink_to(target, target_is_directory=target.is_dir())


def write_training_configs(
    exp_name: str, exp_dir: Path, sovits_epochs: int, gpt_epochs: int, sovits_batch_size: int, gpt_batch_size: int
) -> tuple[Path, Path]:
    """Write s2.json (SoVITS) and s1.yaml (GPT) configs with the given params."""
    temp_dir = RUNTIME / "TEMP"
    temp_dir.mkdir(parents=True, exist_ok=True)
    (RUNTIME / "SoVITS_weights_v2").mkdir(exist_ok=True)
    (RUNTIME / "GPT_weights_v2").mkdir(exist_ok=True)

    # ── SoVITS config (s2.json) ──
    s2 = json.loads((RUNTIME / "GPT_SoVITS/configs/s2.json").read_text(encoding="utf-8"))
    s2["train"]["fp16_run"] = False
    s2["train"]["batch_size"] = sovits_batch_size
    s2["train"]["epochs"] = sovits_epochs
    s2["train"]["save_every_epoch"] = max(1, sovits_epochs // 3)
    s2["train"]["if_save_latest"] = True
    s2["train"]["if_save_every_weights"] = True
    s2["train"]["pretrained_s2G"] = "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth"
    s2["train"]["pretrained_s2D"] = "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2D2333k.pth"
    s2["train"]["gpu_numbers"] = "0"
    s2["train"]["grad_ckpt"] = False
    s2["data"]["exp_dir"] = str(exp_dir)
    s2["s2_ckpt_dir"] = str(exp_dir)
    s2["save_weight_dir"] = "SoVITS_weights_v2"
    s2["name"] = exp_name
    s2["version"] = "v2"
    s2["model"]["version"] = "v2"
    s2_path = temp_dir / f"{exp_name}_s2.json"
    s2_path.write_text(json.dumps(s2, ensure_ascii=False, indent=2), encoding="utf-8")

    # ── GPT config (s1.yaml) ──
    s1 = yaml.safe_load((RUNTIME / "GPT_SoVITS/configs/s1longer-v2.yaml").read_text(encoding="utf-8"))
    s1["train"]["precision"] = "32"
    s1["train"]["batch_size"] = gpt_batch_size
    s1["train"]["epochs"] = gpt_epochs
    s1["train"]["save_every_n_epoch"] = max(1, gpt_epochs // 3)
    s1["train"]["if_save_every_weights"] = True
    s1["train"]["if_save_latest"] = True
    s1["train"]["half_weights_save_dir"] = "GPT_weights_v2"
    s1["train"]["exp_name"] = exp_name
    s1["pretrained_s1"] = "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s1bert25hz-5kh-longer-epoch=12-step=369668.ckpt"
    s1["train_semantic_path"] = str(exp_dir / "6-name2semantic.tsv")
    s1["train_phoneme_path"] = str(exp_dir / "2-name2text.txt")
    s1["output_dir"] = str(exp_dir / "logs_s1_v2")
    s1_path = temp_dir / f"{exp_name}_s1.yaml"
    s1_path.write_text(yaml.safe_dump(s1, allow_unicode=True, sort_keys=False), encoding="utf-8")

    return s2_path, s1_path


# ── data assembly ────────────────────────────────────────────


def build_train_list(project_dir: Path) -> tuple[Path, list[dict]]:
    """
    Read confirmed train list or fall back to slices + ASR drafts.
    Priority: lists/train.confirmed.list (from App GUI confirmations)
           → slices + asr_drafts.json matching (filter out [需手动输入])
    Returns (train_list_path, entries used).
    """
    lists_dir = project_dir / "lists"
    lists_dir.mkdir(parents=True, exist_ok=True)

    # Priority 1: Read confirmed list written by the Swift app
    confirmed_list_path = lists_dir / "train.confirmed.list"
    if confirmed_list_path.exists():
        entries: list[dict] = []
        for line in confirmed_list_path.read_text(encoding="utf-8").strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            parts = line.split("|")
            if len(parts) >= 4:
                entries.append({"path": parts[0], "text": parts[3], "filename": Path(parts[0]).name})
        if entries:
            train_list = lists_dir / "train.list"
            train_list.write_text(confirmed_list_path.read_text(encoding="utf-8"), encoding="utf-8")
            (lists_dir / "train.abs.list").write_text(train_list.read_text(encoding="utf-8"), encoding="utf-8")
            print(f"[train] Loaded {len(entries)} confirmed entries from {confirmed_list_path}", flush=True)
            return train_list, entries

    # Priority 2: Fall back to slices + ASR drafts matching
    slices_dir = project_dir / "dataset/slices"
    asr_json = project_dir / "asr/asr_drafts.json"

    text_by_filename: dict[str, str] = {}
    if asr_json.exists():
        asr_data = json.loads(asr_json.read_text(encoding="utf-8"))
        for item in asr_data:
            fname = item.get("fileName", "")
            text = (item.get("text") or "").strip()
            if text and text != "[需手动输入]":
                text_by_filename[fname] = text

    wavs = sorted(slices_dir.glob("*.wav")) if slices_dir.exists() else []
    entries = []
    for wav in wavs:
        text = text_by_filename.get(wav.name, "[需手动输入]")
        entries.append({"path": str(wav), "text": text, "filename": wav.name})

    if not entries:
        raise SystemExit(f"No WAV slices found in {slices_dir}")

    confirmed = [e for e in entries if e["text"] != "[需手动输入]"]
    print(f"[train] {len(entries)} slices total, {len(confirmed)} with confirmed text", flush=True)

    use = confirmed if confirmed else entries
    if not confirmed:
        print("[train] WARNING: No slices have confirmed ASR text. Training with placeholder texts.", flush=True)

    train_list = lists_dir / "train.list"
    lines = [f"{e['path']}|voice_train|zh|{e['text']}" for e in use]
    train_list.write_text("\n".join(lines) + "\n", encoding="utf-8")
    (lists_dir / "train.abs.list").write_text(train_list.read_text(encoding="utf-8"), encoding="utf-8")

    print(f"[train] Wrote {len(use)} entries to {train_list}", flush=True)
    return train_list, use


# ── export ───────────────────────────────────────────────────


def export_voice_package(
    exp_name: str,
    project_dir: Path,
    ref_wav: Path,
    ref_text: str,
    gpt_weight: Path,
    sovits_weight: Path,
) -> Path:
    """Package trained weights + config into a voice package."""
    export_dir = project_dir / "exports" / exp_name
    weights_dir = export_dir / "weights"
    reference_dir = export_dir / "reference"
    configs_dir = export_dir / "configs"
    for path in [weights_dir, reference_dir, configs_dir]:
        path.mkdir(parents=True, exist_ok=True)

    shutil.copy2(gpt_weight, weights_dir / gpt_weight.name)
    shutil.copy2(sovits_weight, weights_dir / sovits_weight.name)
    shutil.copy2(ref_wav, reference_dir / "reference.wav")
    (reference_dir / "ref_text.txt").write_text(ref_text, encoding="utf-8")

    config = {
        "voice_id": exp_name,
        "engine": "GPT-SoVITS",
        "version": "v2",
        "language": "zh",
        "usage": "text_to_speech",
        "weights": {"gpt": f"weights/{gpt_weight.name}", "sovits": f"weights/{sovits_weight.name}"},
        "reference": {"audio": "reference/reference.wav", "text": ref_text, "language": "中文"},
        "inference": {
            "default_target_language": "中文",
            "default_ref_language": "中文",
            "recommended_device": "cpu",
            "full_precision": True,
            "output_sample_rate": 32000,
        },
        "validated_samples": [],
        "notes": [f"Voice package generated by Voice Studio training. Experiment: {exp_name}"],
    }
    (configs_dir / f"{exp_name}_tts_config.json").write_text(
        json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return export_dir


# ── main ─────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="GPT-SoVITS training for Voice Studio")
    parser.add_argument("--project", required=True, help="Path to voice project directory")
    parser.add_argument("--exp-name", default="voice_studio_train", help="Experiment name")
    parser.add_argument("--preset", choices=["fast", "standard", "fine"], default="standard",
                        help="Training preset (overrides individual epoch/batch args)")
    parser.add_argument("--sovits-epochs", type=int, default=None, help="SoVITS epochs (overrides preset)")
    parser.add_argument("--gpt-epochs", type=int, default=None, help="GPT epochs (overrides preset)")
    parser.add_argument("--batch-size", type=int, default=None, help="Batch size (overrides preset)")
    args = parser.parse_args()

    # Resolve preset
    preset = PRESETS.get(args.preset, PRESETS["standard"])
    sovits_epochs = args.sovits_epochs if args.sovits_epochs is not None else preset["sovits_epochs"]
    gpt_epochs = args.gpt_epochs if args.gpt_epochs is not None else preset["gpt_epochs"]
    batch_size = args.batch_size if args.batch_size is not None else preset["batch_size"]
    print(f"[train] Preset: {args.preset} — {preset['description']}", flush=True)
    print(f"[train] SoVITS epochs={sovits_epochs}, GPT epochs={gpt_epochs}, batch_size={batch_size}", flush=True)

    project_dir = Path(args.project).expanduser().resolve()
    require(project_dir / "project.json", "project.json")

    # Load engine
    engine = load_engine()
    python = Path(engine["python"])
    external_root = python.parents[2]  # .venv/bin/python → GPT-SoVITS root
    prepare_runtime_links(external_root)

    # Project structure
    exp_name = args.exp_name
    dataset_dir = project_dir / "dataset"
    lists_dir = project_dir / "lists"
    cache_dir = project_dir / "cache"
    for path in [lists_dir, cache_dir]:
        path.mkdir(parents=True, exist_ok=True)

    # 1. Build train list from slices + ASR
    train_list, entries = build_train_list(project_dir)

    # Pick reference audio (first slice with confirmed text) and reference text
    ref_entry = next((e for e in entries if e["text"] != "[需手动输入]"), entries[0])
    ref_wav = Path(ref_entry["path"])
    ref_text = ref_entry["text"]
    require(ref_wav, f"reference WAV: {ref_wav}")

    # 2. Environment
    env = os.environ.copy()

    # Ensure ffmpeg is findable – the GUI app has a minimal PATH that may not
    # include Homebrew.  Step 2 (CN-HuBERT) and VAD slicing both need ffmpeg.
    _ffmpeg = shutil.which("ffmpeg")
    if _ffmpeg is None:
        for _candidate in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
            if Path(_candidate).exists():
                _ffmpeg = _candidate
                break
    if _ffmpeg:
        _ffmpeg_dir = str(Path(_ffmpeg).parent)
        env["PATH"] = f"{_ffmpeg_dir}:{env.get('PATH', '/usr/bin:/bin')}"
    else:
        print("[warn] ffmpeg not found – audio loading in step 2 may fail", flush=True)

    env["PYTHONPATH"] = f"{RUNTIME / 'smoke_overrides'}:{RUNTIME}:{RUNTIME / 'GPT_SoVITS'}"
    env["MPLCONFIGDIR"] = str(cache_dir)
    env["NUMBA_CACHE_DIR"] = str(cache_dir)
    env["XDG_CACHE_HOME"] = str(cache_dir)
    env["TOKENIZERS_PARALLELISM"] = "false"

    abs_list = lists_dir / "train.abs.list"

    # 3. Prepare exp_dir
    exp_dir = RUNTIME / "logs" / exp_name
    for sub in [exp_dir, exp_dir / "logs_s2_v2", exp_dir / "logs_s1_v2"]:
        sub.mkdir(parents=True, exist_ok=True)

    # ── Step 1/6: Text/BERT features ──
    print("\n[1/6] Extracting text/BERT features...", flush=True)
    print("TRAINING_PROGRESS=0.02", flush=True)
    env.update({
        "inp_text": str(abs_list),
        "inp_wav_dir": "",
        "exp_name": exp_name,
        "i_part": "0",
        "all_parts": "1",
        "opt_dir": str(exp_dir),
        "bert_pretrained_dir": "GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large",
        "is_half": "False",
        "version": "v2",
    })
    run([str(python), "-s", "GPT_SoVITS/prepare_datasets/1-get-text.py"], cwd=RUNTIME, env=env)
    part_text = exp_dir / "2-name2text-0.txt"
    target_text = exp_dir / "2-name2text.txt"
    if part_text.exists():
        part_text.replace(target_text)
    require(target_text, "2-name2text.txt")
    require_nonempty(exp_dir / "3-bert", "3-bert features")
    print("TRAINING_PROGRESS=0.05", flush=True)

    # ── Step 2/6: CN-HuBERT / 32k wav ──
    print("\n[2/6] Extracting CN-HuBERT features & 32k wavs...", flush=True)
    env.update({
        "cnhubert_base_dir": "GPT_SoVITS/pretrained_models/chinese-hubert-base",
        "is_half": "False",
    })
    run([str(python), "-s", "GPT_SoVITS/prepare_datasets/2-get-hubert-wav32k.py"], cwd=RUNTIME, env=env)
    require_nonempty(exp_dir / "4-cnhubert", "4-cnhubert features")
    require_nonempty(exp_dir / "5-wav32k", "5-wav32k files")
    print("TRAINING_PROGRESS=0.10", flush=True)

    # ── Step 3/6: Semantic tokens ──
    print("\n[3/6] Extracting semantic tokens...", flush=True)
    # Remove stale output from a previous failed run (script skips if file exists)
    stale_sem = exp_dir / f"6-name2semantic-{0}.tsv"
    stale_sem.unlink(missing_ok=True)
    env.update({
        "pretrained_s2G": "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth",
        "s2config_path": "GPT_SoVITS/configs/s2.json",
    })
    run([str(python), "-s", "GPT_SoVITS/prepare_datasets/3-get-semantic.py"], cwd=RUNTIME, env=env)
    sem0 = exp_dir / "6-name2semantic-0.tsv"
    sem = exp_dir / "6-name2semantic.tsv"
    require(sem0, "6-name2semantic-0.tsv")
    sem_content = sem0.read_text(encoding="utf-8").strip()
    if not sem_content or len(sem_content.split("\n")) < 2:
        raise SystemExit(f"Semantic token output is empty or has no data rows: {sem0}")
    sem.write_text("item_name\tsemantic_audio\n", encoding="utf-8")
    sem.write_text(sem.read_text(encoding="utf-8") + sem0.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"[verify] 6-name2semantic: {len(sem_content.split(chr(10)))} rows ok", flush=True)
    print("TRAINING_PROGRESS=0.13", flush=True)

    # ── Step 4/6: Write training configs ──
    print("\n[4/6] Writing training configs...", flush=True)
    s2_cfg, s1_cfg = write_training_configs(exp_name, exp_dir, sovits_epochs, gpt_epochs, batch_size, batch_size)
    print("TRAINING_PROGRESS=0.15", flush=True)

    # ── Step 5/6: Train SoVITS ──
    print(f"\n[5/6] Training SoVITS ({sovits_epochs} epochs)...", flush=True)
    run([str(python), "-s", "smoke_overrides/s2_train.py", "--config", str(s2_cfg)], cwd=RUNTIME, env=env)
    print("TRAINING_PROGRESS=0.60", flush=True)

    # ── Step 6/6: Train GPT ──
    print(f"\n[6/6] Training GPT ({gpt_epochs} epochs)...", flush=True)
    env["_CUDA_VISIBLE_DEVICES"] = "0"
    env["hz"] = "25hz"
    run([str(python), "-s", "smoke_overrides/s1_train.py", "--config_file", str(s1_cfg)], cwd=RUNTIME, env=env)
    print("TRAINING_PROGRESS=0.97", flush=True)

    # ── Find outputs ──
    gpt_weight = newest(RUNTIME / f"GPT_weights_v2/{exp_name}*.ckpt")
    sovits_weight = newest(RUNTIME / f"SoVITS_weights_v2/{exp_name}*.pth")
    if not gpt_weight or not sovits_weight:
        raise SystemExit("Training completed but weights were not found.")

    # ── Export voice package ──
    print("\n[export] Packaging voice...", flush=True)
    export_dir = export_voice_package(exp_name, project_dir, ref_wav, ref_text, gpt_weight, sovits_weight)

    print(f"\nTRAINING_EXPORT={export_dir}", flush=True)
    print(f"TRAINING_GPT_WEIGHT={export_dir / 'weights' / gpt_weight.name}", flush=True)
    print(f"TRAINING_SOVITS_WEIGHT={export_dir / 'weights' / sovits_weight.name}", flush=True)
    print(f"TRAINING_EXP_NAME={exp_name}", flush=True)
    print(f"TRAINING_TOTAL_SLICES={len(entries)}", flush=True)
    print("TRAINING_OK=1", flush=True)


if __name__ == "__main__":
    main()

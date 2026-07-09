#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import signal
import shutil
import subprocess
import sys
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "测试语音.mp3"
RUNTIME = ROOT / "gpt_sovits_runtime"
ENGINE_CONFIG = RUNTIME / "engine_config.json"
CURRENT_PROCESS: subprocess.Popen | None = None


def terminate_child(signum, _frame) -> None:
    if CURRENT_PROCESS and CURRENT_PROCESS.poll() is None:
        CURRENT_PROCESS.terminate()
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, terminate_child)
signal.signal(signal.SIGINT, terminate_child)


def run(cmd: list[str], cwd: Path, env: dict[str, str]) -> None:
    global CURRENT_PROCESS
    print("[run]", " ".join(cmd), flush=True)
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, text=True)
    CURRENT_PROCESS = proc
    proc.wait()
    CURRENT_PROCESS = None
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


def require(path: Path, label: str) -> None:
    if not path.exists():
        raise SystemExit(f"Missing {label}: {path}")


def load_engine() -> dict:
    require(ENGINE_CONFIG, "engine config")
    return json.loads(ENGINE_CONFIG.read_text(encoding="utf-8"))


def prepare_runtime_links(external_root: Path) -> None:
    RUNTIME.mkdir(parents=True, exist_ok=True)
    links = {
        "GPT_SoVITS": external_root / "GPT_SoVITS",
        "tools": external_root / "tools",
        "configs": external_root / "configs",
        "config.py": external_root / "config.py",
        "feature_extractor": external_root / "feature_extractor",
        "text": external_root / "text",
    }
    for name, target in links.items():
        link = RUNTIME / name
        if link.exists() or link.is_symlink():
            continue
        link.symlink_to(target, target_is_directory=target.is_dir())


def write_configs(exp_name: str, exp_dir: Path, sovits_batch_size: int, gpt_batch_size: int) -> tuple[Path, Path]:
    temp_dir = RUNTIME / "TEMP"
    temp_dir.mkdir(parents=True, exist_ok=True)
    (RUNTIME / "SoVITS_weights_v2").mkdir(exist_ok=True)
    (RUNTIME / "GPT_weights_v2").mkdir(exist_ok=True)

    s2 = json.loads((RUNTIME / "GPT_SoVITS/configs/s2.json").read_text(encoding="utf-8"))
    s2["train"]["fp16_run"] = False
    s2["train"]["batch_size"] = sovits_batch_size
    s2["train"]["epochs"] = 1
    s2["train"]["save_every_epoch"] = 1
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

    s1 = yaml.safe_load((RUNTIME / "GPT_SoVITS/configs/s1longer-v2.yaml").read_text(encoding="utf-8"))
    s1["train"]["precision"] = "32"
    s1["train"]["batch_size"] = gpt_batch_size
    s1["train"]["epochs"] = 1
    s1["train"]["save_every_n_epoch"] = 1
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


def newest(pattern: str) -> Path | None:
    files = list(RUNTIME.glob(pattern))
    if not files:
        return None
    return max(files, key=lambda item: item.stat().st_mtime)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default=str(DEFAULT_SOURCE))
    parser.add_argument("--transcript", default="这是用于训练测试的语音素材。")
    parser.add_argument("--seconds", type=int, default=8)
    parser.add_argument("--exp-name", default="voice_studio_smoke")
    parser.add_argument("--sovits-batch-size", type=int, default=10)
    parser.add_argument("--gpt-batch-size", type=int, default=10)
    parser.add_argument("--smoke-min-num", type=int, default=10)
    args = parser.parse_args()

    source = Path(args.source).expanduser().resolve()
    require(source, "source audio")
    engine = load_engine()
    python = Path(engine["python"])
    external_root = python.parents[1]
    prepare_runtime_links(external_root)

    exp_name = args.exp_name
    project_dir = ROOT / "voice_projects" / "app_training_smoke"
    dataset_dir = project_dir / "dataset"
    lists_dir = project_dir / "lists"
    export_dir = project_dir / "exports" / exp_name
    cache_dir = project_dir / "cache"
    for path in [dataset_dir, lists_dir, export_dir, cache_dir]:
        path.mkdir(parents=True, exist_ok=True)

    wav = dataset_dir / "test_slice.wav"
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    run(
        [
            ffmpeg,
            "-y",
            "-i",
            str(source),
            "-t",
            str(args.seconds),
            "-ac",
            "1",
            "-ar",
            "44100",
            str(wav),
        ],
        cwd=ROOT,
        env=os.environ.copy(),
    )

    train_list = lists_dir / "train.list"
    train_list.write_text(f"{wav}|test_voice|zh|{args.transcript}\n", encoding="utf-8")
    abs_list = lists_dir / "train.abs.list"
    abs_list.write_text(train_list.read_text(encoding="utf-8"), encoding="utf-8")

    env = os.environ.copy()
    env["PYTHONPATH"] = f"{RUNTIME / 'smoke_overrides'}:{RUNTIME}:{RUNTIME / 'GPT_SoVITS'}"
    env["MPLCONFIGDIR"] = str(cache_dir)
    env["NUMBA_CACHE_DIR"] = str(cache_dir)
    env["XDG_CACHE_HOME"] = str(cache_dir)
    env["TOKENIZERS_PARALLELISM"] = "false"
    env["VOICE_STUDIO_SMOKE_MIN_NUM"] = str(args.smoke_min_num)

    exp_dir = RUNTIME / "logs" / exp_name
    exp_dir.mkdir(parents=True, exist_ok=True)
    (exp_dir / "logs_s2_v2").mkdir(parents=True, exist_ok=True)
    (exp_dir / "logs_s1_v2").mkdir(parents=True, exist_ok=True)

    print("[1/6] text/BERT features", flush=True)
    env.update(
        {
            "inp_text": str(abs_list),
            "inp_wav_dir": "",
            "exp_name": exp_name,
            "i_part": "0",
            "all_parts": "1",
            "opt_dir": str(exp_dir),
            "bert_pretrained_dir": "GPT_SoVITS/pretrained_models/chinese-roberta-wwm-ext-large",
            "is_half": "False",
            "version": "v2",
        }
    )
    run([str(python), "-s", "GPT_SoVITS/prepare_datasets/1-get-text.py"], cwd=RUNTIME, env=env)
    part_text = exp_dir / "2-name2text-0.txt"
    if part_text.exists():
        part_text.replace(exp_dir / "2-name2text.txt")

    print("[2/6] CN-HuBERT/32k wav", flush=True)
    env.update(
        {
            "cnhubert_base_dir": "GPT_SoVITS/pretrained_models/chinese-hubert-base",
            "is_half": "False",
        }
    )
    run([str(python), "-s", "GPT_SoVITS/prepare_datasets/2-get-hubert-wav32k.py"], cwd=RUNTIME, env=env)

    print("[3/6] semantic tokens", flush=True)
    env.update(
        {
            "pretrained_s2G": "GPT_SoVITS/pretrained_models/gsv-v2final-pretrained/s2G2333k.pth",
            "s2config_path": "GPT_SoVITS/configs/s2.json",
        }
    )
    run([str(python), "-s", "GPT_SoVITS/prepare_datasets/3-get-semantic.py"], cwd=RUNTIME, env=env)
    semantic = exp_dir / "6-name2semantic.tsv"
    semantic.write_text("item_name\tsemantic_audio\n", encoding="utf-8")
    semantic.write_text(semantic.read_text(encoding="utf-8") + (exp_dir / "6-name2semantic-0.tsv").read_text(encoding="utf-8"), encoding="utf-8")

    print("[4/6] train configs", flush=True)
    s2_path, s1_path = write_configs(args.exp_name, exp_dir, args.sovits_batch_size, args.gpt_batch_size)

    print("[5/6] train SoVITS smoke", flush=True)
    run([str(python), "-s", "smoke_overrides/s2_train.py", "--config", str(s2_path)], cwd=RUNTIME, env=env)

    print("[6/6] train GPT smoke", flush=True)
    env["_CUDA_VISIBLE_DEVICES"] = "0"
    env["hz"] = "25hz"
    run([str(python), "-s", "smoke_overrides/s1_train.py", "--config_file", str(s1_path)], cwd=RUNTIME, env=env)

    gpt_weight = newest(f"GPT_weights_v2/{exp_name}*.ckpt")
    sovits_weight = newest(f"SoVITS_weights_v2/{exp_name}*.pth")
    if not gpt_weight or not sovits_weight:
        raise SystemExit("Training finished but weights were not found")

    weights_dir = export_dir / "weights"
    reference_dir = export_dir / "reference"
    configs_dir = export_dir / "configs"
    for path in [weights_dir, reference_dir, configs_dir]:
        path.mkdir(parents=True, exist_ok=True)
    shutil.copy2(gpt_weight, weights_dir / gpt_weight.name)
    shutil.copy2(sovits_weight, weights_dir / sovits_weight.name)
    shutil.copy2(wav, reference_dir / "reference.wav")
    (reference_dir / "ref_text.txt").write_text(args.transcript, encoding="utf-8")

    config = {
        "voice_id": exp_name,
        "engine": "GPT-SoVITS",
        "version": "v2",
        "language": "zh",
        "usage": "text_to_speech",
        "weights": {"gpt": f"weights/{gpt_weight.name}", "sovits": f"weights/{sovits_weight.name}"},
        "reference": {"audio": "reference/reference.wav", "text": args.transcript, "language": "中文"},
        "inference": {
            "default_target_language": "中文",
            "default_ref_language": "中文",
            "recommended_device": "cpu",
            "full_precision": True,
            "output_sample_rate": 32000,
        },
        "validated_samples": [],
        "notes": ["Smoke-test voice package generated by Voice Studio app training test."],
    }
    (configs_dir / "voice_studio_smoke_tts_config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"SMOKE_TRAIN_EXPORT={export_dir}", flush=True)
    print(f"SMOKE_GPT_WEIGHT={weights_dir / gpt_weight.name}", flush=True)
    print(f"SMOKE_SOVITS_WEIGHT={weights_dir / sovits_weight.name}", flush=True)


if __name__ == "__main__":
    main()

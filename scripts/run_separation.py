#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "gpt_sovits_runtime"
CACHE = RUNTIME / "cache"

CACHE.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("MPLCONFIGDIR", str(CACHE))
os.environ.setdefault("NUMBA_CACHE_DIR", str(CACHE))
os.environ.setdefault("XDG_CACHE_HOME", str(CACHE))
os.environ.setdefault("TEMP", str(CACHE))


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("[run]", " ".join(cmd), flush=True)
    proc = subprocess.run(cmd, cwd=str(cwd) if cwd else None, text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


def find_uvr_weight(weight_dir: Path) -> Path | None:
    preferred = os.environ.get("VOICE_STUDIO_UVR_MODEL", "").strip()
    if preferred:
        candidate = weight_dir / preferred
        if candidate.exists():
            return candidate
        for suffix in [".ckpt", ".pth"]:
            candidate = weight_dir / f"{preferred}{suffix}"
            if candidate.exists():
                return candidate
    for pattern in ["*roformer*.ckpt", "*roformer*.pth", "*.pth", "*.ckpt"]:
        found = sorted(weight_dir.glob(pattern))
        if found:
            return found[0]
    return None


def copy_first_wav(source_dir: Path, target: Path) -> None:
    wavs = sorted(source_dir.glob("*.wav"))
    if not wavs:
        raise SystemExit(f"No wav output found in {source_dir}")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(wavs[0], target)


def separate_with_uvr(source: Path, out_dir: Path, weight: Path) -> dict:
    tools_dir = RUNTIME / "tools/uvr5"
    if not tools_dir.exists():
        raise SystemExit(f"Missing UVR tools: {tools_dir}")

    sys.path.insert(0, str(tools_dir))
    from bsroformer import Roformer_Loader
    from vr import AudioPre, AudioPreDeEcho

    vocals_dir = out_dir / "uvr_vocals"
    bgm_dir = out_dir / "uvr_bgm"
    vocals_dir.mkdir(parents=True, exist_ok=True)
    bgm_dir.mkdir(parents=True, exist_ok=True)

    device = "cpu"
    model_name = weight.stem
    if "roformer" in model_name.lower():
        runner = Roformer_Loader(
            model_path=str(weight),
            config_path=str(weight.with_suffix(".yaml")),
            device=device,
            is_half=False,
        )
    else:
        runner_cls = AudioPre if "DeEcho" not in model_name else AudioPreDeEcho
        runner = runner_cls(agg=0, model_path=str(weight), device=device, is_half=False)

    runner._path_audio_(str(source), str(bgm_dir), str(vocals_dir), "wav", "HP3" in model_name)
    vocals = out_dir / "vocals.wav"
    bgm = out_dir / "bgm.wav"
    copy_first_wav(vocals_dir, vocals)
    copy_first_wav(bgm_dir, bgm)
    return {"backend": f"uvr5:{model_name}", "vocals": str(vocals), "bgm": str(bgm)}


def separate_with_demucs(source: Path, out_dir: Path) -> dict:
    demucs = shutil.which("demucs")
    if not demucs:
        raise SystemExit("Demucs is not installed")
    demucs_out = out_dir / "demucs"
    run([demucs, "--two-stems", "vocals", "-o", str(demucs_out), str(source)])
    wavs = sorted(demucs_out.glob(f"**/{source.stem}/vocals.wav"))
    bgms = sorted(demucs_out.glob(f"**/{source.stem}/no_vocals.wav"))
    if not wavs or not bgms:
        raise SystemExit(f"Demucs finished but outputs were not found in {demucs_out}")
    vocals = out_dir / "vocals.wav"
    bgm = out_dir / "bgm.wav"
    shutil.copy2(wavs[0], vocals)
    shutil.copy2(bgms[0], bgm)
    return {"backend": "demucs", "vocals": str(vocals), "bgm": str(bgm)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    source = Path(args.source).expanduser().resolve()
    out_dir = Path(args.output_dir).expanduser().resolve()
    if not source.exists():
        raise SystemExit(f"Missing source: {source}")
    out_dir.mkdir(parents=True, exist_ok=True)

    weight_dir = RUNTIME / "tools/uvr5/uvr5_weights"
    weight = find_uvr_weight(weight_dir)
    try:
        if weight:
            print("SEPARATION_PROGRESS=0.20", flush=True)
            result = separate_with_uvr(source, out_dir, weight)
        else:
            print("SEPARATION_PROGRESS=0.20", flush=True)
            result = separate_with_demucs(source, out_dir)
    except SystemExit as exc:
        message = str(exc)
        if not weight:
            message = (
                "缺少真实分离模型：未找到 Demucs，也未在 "
                f"{weight_dir} 放置 UVR/BS-RoFormer .pth/.ckpt 权重。"
            )
        print(json.dumps({"ok": False, "error": message}, ensure_ascii=False), flush=True)
        raise

    print(json.dumps({"ok": True, **result}, ensure_ascii=False), flush=True)
    print(f"SEPARATION_VOCALS={result['vocals']}", flush=True)
    print(f"SEPARATION_BGM={result['bgm']}", flush=True)


if __name__ == "__main__":
    main()

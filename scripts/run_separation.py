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
ENGINE_CONFIG = RUNTIME / "engine_config.json"
CACHE = RUNTIME / "cache"

CACHE.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("MPLCONFIGDIR", str(CACHE))
os.environ.setdefault("NUMBA_CACHE_DIR", str(CACHE))
os.environ.setdefault("XDG_CACHE_HOME", str(CACHE))
os.environ.setdefault("TEMP", str(CACHE))


def ensure_runtime_symlinks() -> Path:
    """Create/repair runtime symlinks so that gpt_sovits_runtime/tools points
    to the actual GPT-SoVITS tools directory. Returns the real path to the
    GPT-SoVITS root (resolved through engine config)."""
    if ENGINE_CONFIG.exists():
        cfg = json.loads(ENGINE_CONFIG.read_text(encoding="utf-8"))
        external_root = Path(cfg.get("gpt_sovits_root") or cfg.get("runtime_root") or "")
    else:
        external_root = None

    # Fallback: scan engine config's PYTHONPATH or common sibling directories
    if not external_root or not external_root.exists():
        # Try to find GPT-SoVITS by scanning parent dirs (same logic as Swift auto-detect)
        candidates = [
            ROOT / "external" / "GPT-SoVITS",
            ROOT.parent / "external" / "GPT-SoVITS",
            ROOT.parent / "GPT-SoVITS",
        ]
        external_root = next((c for c in candidates if (c / "GPT_SoVITS" / "inference_cli.py").exists()), None)

    if not external_root or not external_root.exists():
        print("[warn] Cannot resolve GPT-SoVITS root — UVR separation may fail", flush=True)
        return None

    RUNTIME.mkdir(parents=True, exist_ok=True)

    # Create/repair symlinks (same as run_training.py prepare_runtime_links)
    links = {
        "GPT_SoVITS": external_root / "GPT_SoVITS",
        "tools": external_root / "tools",
        "configs": external_root / "GPT_SoVITS" / "configs",
        "config.py": external_root / "config.py",
    }
    for name, target in links.items():
        link = RUNTIME / name
        if not target.exists():
            continue  # Skip if target doesn't exist (e.g. configs might not be a dir)
        # Remove broken symlinks
        if link.is_symlink() and not link.exists():
            link.unlink()
        if link.exists() or link.is_symlink():
            continue
        link.symlink_to(target, target_is_directory=target.is_dir())

    print(f"[setup] Runtime symlinks ready → GPT-SoVITS root: {external_root}", flush=True)
    return external_root


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


def separate_with_uvr(source: Path, out_dir: Path, weight: Path, gpt_root: Path | None = None) -> dict:
    # Try real gpt_root first, then RUNTIME symlink, then direct path
    if gpt_root:
        tools_dir = gpt_root / "tools" / "uvr5"
    else:
        tools_dir = RUNTIME / "tools" / "uvr5"
    if not tools_dir.exists():
        # Last resort: check download destination directly
        tools_dir = ROOT / "external" / "GPT-SoVITS" / "tools" / "uvr5"
    if not tools_dir.exists():
        raise SystemExit(f"Missing UVR tools directory (tried several paths). "
                         f"Please ensure GPT-SoVITS source code is installed.")

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

    # Ensure runtime symlinks exist so UVR weights/tools are reachable.
    # Without this, gpt_sovits_runtime/tools/ may not point to the actual
    # GPT-SoVITS installation (symlinks are normally created during training).
    gpt_root = ensure_runtime_symlinks()

    # Look for UVR weights: try the real gpt_root first, then RUNTIME symlink
    if gpt_root:
        weight_dir = gpt_root / "tools" / "uvr5" / "uvr5_weights"
    else:
        weight_dir = RUNTIME / "tools" / "uvr5" / "uvr5_weights"
    weight = find_uvr_weight(weight_dir)
    if not weight:
        # Also try direct download path (external/GPT-SoVITS/tools/uvr5/uvr5_weights)
        fallback_dir = ROOT / "external" / "GPT-SoVITS" / "tools" / "uvr5" / "uvr5_weights"
        if fallback_dir != weight_dir:
            print(f"[warn] No UVR weight found at {weight_dir}, trying {fallback_dir}", flush=True)
            weight = find_uvr_weight(fallback_dir)
    try:
        if weight:
            print("SEPARATION_PROGRESS=0.20", flush=True)
            result = separate_with_uvr(source, out_dir, weight, gpt_root)
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

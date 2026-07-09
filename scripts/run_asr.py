#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import wave
from pathlib import Path

from faster_whisper import WhisperModel


def resolve_model(model: str) -> str:
    if model != "small":
        return model
    cache_root = Path.home() / ".cache/huggingface/hub/models--Systran--faster-whisper-small/snapshots"
    if cache_root.exists():
        snapshots = sorted(cache_root.iterdir())
        if snapshots:
            return str(snapshots[-1])
    return model


def duration(path: Path) -> float:
    with wave.open(str(path), "rb") as source:
        return source.getnframes() / float(source.getframerate())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--model", default="small")
    parser.add_argument("--language", default="zh")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_json = Path(args.output_json)
    wavs = sorted(input_dir.glob("*.wav"))
    if args.limit:
        wavs = wavs[: args.limit]
    if not wavs:
        raise SystemExit(f"No wav slices found in {input_dir}")

    model_name = resolve_model(args.model)
    model = WhisperModel(model_name, device=args.device, compute_type=args.compute_type)
    rows = []
    for wav in wavs:
        segments, info = model.transcribe(
            str(wav),
            language=args.language,
            beam_size=5,
            vad_filter=True,
            condition_on_previous_text=False,
        )
        text = "".join(segment.text.strip() for segment in segments).strip()
        if not text:
            text = "[需手动输入]"
        rows.append(
            {
                "fileName": wav.name,
                "path": str(wav),
                "text": text,
                "duration": duration(wav),
                "asrEngine": f"faster-whisper:{model_name}",
                "language": info.language,
                "languageProbability": info.language_probability,
            }
        )
        print(f"{wav.name}\t{text}", flush=True)

    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"ASR_OUTPUT_JSON={output_json}", flush=True)


if __name__ == "__main__":
    main()

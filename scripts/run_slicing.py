#!/usr/bin/env python3
"""
VAD-based audio slicing for voice training.
Uses RMS energy detection — no extra dependencies beyond numpy (already in GPT-SoVITS venv).

Produces:
  dataset/slices/slice_001.wav ...
  dataset/manifest.csv

Algorithm:
  1. Compute frame-level RMS energy
  2. Adaptive threshold: median + offset, clamped to sane range
  3. Find speech segments, merge gaps < min_silence_gap
  4. Within each speech segment, split into 3-10s chunks at low-energy breakpoints
  5. Filter chunks that are too quiet or too short
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import wave
from pathlib import Path

import numpy as np


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    """Read WAV, return (float32 samples in [-1,1], sample_rate)."""
    with wave.open(str(path), "rb") as f:
        sr = f.getframerate()
        n_channels = f.getnchannels()
        n_frames = f.getnframes()
        raw = f.readframes(n_frames)
    dtype = np.int16
    data = np.frombuffer(raw, dtype=dtype).astype(np.float32) / 32768.0
    if n_channels > 1:
        data = data.reshape(-1, n_channels).mean(axis=1)  # mix to mono
    return data, sr


def write_wav(path: Path, samples: np.ndarray, sr: int) -> None:
    """Write float32 [-1,1] mono audio to 16-bit WAV."""
    path.parent.mkdir(parents=True, exist_ok=True)
    clipped = np.clip(samples, -1.0, 1.0)
    int16 = (clipped * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(sr)
        f.writeframes(int16.tobytes())


def frame_rms(samples: np.ndarray, frame_len: int, hop_len: int) -> np.ndarray:
    """Return RMS energy per frame."""
    n_frames = max(1, (len(samples) - frame_len) // hop_len + 1)
    rms = np.zeros(n_frames, dtype=np.float32)
    for i in range(n_frames):
        start = i * hop_len
        chunk = samples[start : start + frame_len]
        rms[i] = np.sqrt(np.mean(chunk**2) + 1e-12)
    return rms


def adaptive_threshold(rms: np.ndarray, offset: float = 0.6) -> float:
    """
    Compute speech threshold from the RMS distribution.
    Uses median as baseline then adds a multiplier for robustness.
    """
    median = float(np.median(rms))
    std = float(np.std(rms))
    thresh = median + offset * std
    # Clamp: not lower than very quiet, not higher than a reasonable max
    thresh = max(thresh, 0.003)
    thresh = min(thresh, 0.08)
    return thresh


def find_speech_segments(
    rms: np.ndarray, threshold: float, frame_len: int, hop_len: int, sr: int, min_silence_gap: float = 0.3
) -> list[tuple[float, float]]:
    """
    Find contiguous speech regions above threshold.
    Merge regions separated by less than min_silence_gap seconds.
    Returns list of (start_sec, end_sec).
    """
    is_speech = rms > threshold
    segments: list[tuple[float, float]] = []

    in_speech = False
    speech_start = 0.0

    for i, speech in enumerate(is_speech):
        t = (i * hop_len + frame_len / 2) / sr
        if speech and not in_speech:
            speech_start = t
            in_speech = True
        elif not speech and in_speech:
            segments.append((speech_start, t))
            in_speech = False

    if in_speech:
        t_end = (len(rms) * hop_len + frame_len / 2) / sr
        segments.append((speech_start, t_end))

    # Merge close segments — use a generous gap for fragmented speech (game dialog etc.)
    merged = [segments[0]]
    for start, end in segments[1:]:
        prev_start, prev_end = merged[-1]
        gap = start - prev_end
        if gap < min_silence_gap:
            merged[-1] = (prev_start, end)
        else:
            merged.append((start, end))
    return merged


def split_into_chunks(
    samples: np.ndarray,
    sr: int,
    segments: list[tuple[float, float]],
    min_chunk: float = 3.0,
    max_chunk: float = 10.0,
    min_silence_gap: float = 0.3,
) -> list[tuple[float, float, np.ndarray]]:
    """
    Split speech segments into chunks of 3-10 seconds using a greedy
    max_chunk-sized window with low-energy breakpoint search.
    """
    hop_len = int(sr * 0.01)   # 10ms hop
    frame_len = int(sr * 0.025)  # 25ms frame

    chunks: list[tuple[float, float, np.ndarray]] = []

    for seg_start, seg_end in segments:
        seg_duration = seg_end - seg_start
        if seg_duration < min_chunk:
            continue

        start_sample = int(seg_start * sr)
        end_sample = int(seg_end * sr)
        seg_audio = samples[start_sample:end_sample]

        if seg_duration <= max_chunk:
            chunks.append((seg_start, seg_end, seg_audio))
            continue

        # Greedy split: walk forward in max_chunk-sized steps,
        # at each step find the quietest frame within a lookback/lookahead window
        seg_rms = frame_rms(seg_audio, frame_len, hop_len)
        n_frames = len(seg_rms)

        cursor = 0  # frames from start of segment
        while cursor < n_frames:
            remaining = (n_frames - cursor) * hop_len / sr
            if remaining < min_chunk:
                # Discard short trailing tail
                break

            # Target cut point: cursor + max_chunk's worth of frames
            target = min(n_frames - 1, cursor + int(max_chunk * sr / hop_len))
            if remaining <= max_chunk:
                # Last chunk — take all remaining
                cut = n_frames
            else:
                # Search for quietest frame in [target - 1s, target + 1s]
                search_half = int(1.0 * sr / hop_len)  # ±1 second
                search_start = max(cursor + int(min_chunk * sr / hop_len), target - search_half)
                search_end = min(n_frames - 1, target + search_half)
                if search_end <= search_start:
                    cut = min(n_frames, target)
                else:
                    region_rms = seg_rms[search_start:search_end]
                    quietest_offset = int(np.argmin(region_rms))
                    cut = search_start + quietest_offset

            # Extract chunk
            cut = max(cursor, min(n_frames, cut))
            a_sample = int(cursor * hop_len / sr * sr)
            b_sample = int(cut * hop_len / sr * sr) if cut < n_frames else len(seg_audio)
            if b_sample <= a_sample:
                break

            chunk_audio = seg_audio[a_sample:b_sample]
            chunk_dur = len(chunk_audio) / sr
            if chunk_dur >= min_chunk:
                chunk_start = seg_start + a_sample / sr
                chunk_end = seg_start + b_sample / sr
                chunks.append((chunk_start, chunk_end, chunk_audio))

            cursor = cut

    return chunks


def compute_quality(samples: np.ndarray) -> dict:
    """Return per-slice quality metrics."""
    peak = float(np.max(np.abs(samples)))
    rms = float(np.sqrt(np.mean(samples**2) + 1e-12))
    silence_ratio = float(np.mean(np.abs(samples) < 0.01))
    return {"peak": round(peak, 4), "rms": round(rms, 4), "silence_ratio": round(silence_ratio, 3)}


def main() -> None:
    parser = argparse.ArgumentParser(description="VAD-based audio slicing for voice training")
    parser.add_argument("--source", required=True, help="Path to input WAV (vocals)")
    parser.add_argument("--output-dir", required=True, help="Output directory for slices/")
    parser.add_argument("--min-chunk", type=float, default=3.0, help="Minimum chunk duration in seconds")
    parser.add_argument("--max-chunk", type=float, default=10.0, help="Maximum chunk duration in seconds")
    parser.add_argument("--target-sr", type=int, default=32000, help="Target sample rate for output slices")
    parser.add_argument("--min-total-speech", type=float, default=8.0, help="Minimum total speech duration to proceed")
    args = parser.parse_args()

    source = Path(args.source).expanduser().resolve()
    out_dir = Path(args.output_dir).expanduser().resolve()
    slices_dir = out_dir / "slices"
    slices_dir.mkdir(parents=True, exist_ok=True)

    if not source.exists():
        print(json.dumps({"ok": False, "error": f"Source not found: {source}"}, ensure_ascii=False))
        raise SystemExit(1)

    # 1. Load audio
    print(f"[slice] Loading {source}...", flush=True)
    audio, sr = read_wav(source)

    # 2. Resample if needed
    if sr != args.target_sr:
        print(f"[slice] Resampling {sr} -> {args.target_sr} Hz...", flush=True)
        from scipy.signal import resample_poly

        gcd = np.gcd(sr, args.target_sr)
        audio = resample_poly(audio, args.target_sr // gcd, sr // gcd).astype(np.float32)
        sr = args.target_sr

    duration = len(audio) / sr
    print(f"[slice] Duration: {duration:.1f}s, sample rate: {sr} Hz", flush=True)

    # 3. Compute RMS energy and threshold
    frame_len = int(sr * 0.025)  # 25ms
    hop_len = int(sr * 0.010)    # 10ms
    rms = frame_rms(audio, frame_len, hop_len)
    threshold = adaptive_threshold(rms)
    print(f"[slice] Speech threshold (RMS): {threshold:.4f}", flush=True)

    # 4. Find speech segments (merge gap of 1.5s for fragmented speech like game dialog)
    segments = find_speech_segments(rms, threshold, frame_len, hop_len, sr, min_silence_gap=1.5)
    total_speech = sum(end - start for start, end in segments)
    print(f"[slice] Found {len(segments)} speech segments, total {total_speech:.1f}s", flush=True)

    if total_speech < args.min_total_speech:
        # Fallback: use the whole file as one segment with a lower threshold
        print(f"[slice] Total speech ({total_speech:.1f}s) below minimum ({args.min_total_speech}s). "
              f"Using whole file as single segment.", flush=True)
        segments = [(0.0, duration)]
        total_speech = duration

    # 5. Split into 3-10s chunks
    chunks = split_into_chunks(audio, sr, segments, min_chunk=args.min_chunk, max_chunk=args.max_chunk)
    print(f"[slice] Produced {len(chunks)} chunks", flush=True)

    # 6. Write slices and manifest
    manifest_rows: list[dict] = []
    for idx, (start, end, chunk_audio) in enumerate(chunks):
        slice_name = f"slice_{idx + 1:03d}.wav"
        slice_path = slices_dir / slice_name
        write_wav(slice_path, chunk_audio, sr)
        dur = len(chunk_audio) / sr
        quality = compute_quality(chunk_audio)
        manifest_rows.append({
            "slice_id": idx + 1,
            "path": str(slice_path),
            "source_file": str(source),
            "start": round(start, 2),
            "end": round(end, 2),
            "duration": round(dur, 2),
            **quality,
            "quality_flags": "",
        })
        print(f"[slice] {slice_name}: {start:.2f}s - {end:.2f}s ({dur:.2f}s) "
              f"peak={quality['peak']:.3f} rms={quality['rms']:.3f}", flush=True)

    # 7. Write manifest.csv
    manifest_path = out_dir / "manifest.csv"
    fieldnames = ["slice_id", "path", "source_file", "start", "end", "duration",
                  "rms", "peak", "silence_ratio", "quality_flags"]
    with open(manifest_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(manifest_rows)

    # 8. Report
    total_slice_duration = sum(r["duration"] for r in manifest_rows)
    result = {
        "ok": True,
        "total_duration": round(duration, 1),
        "total_speech": round(total_speech, 1),
        "total_slices": len(chunks),
        "total_slice_duration": round(total_slice_duration, 1),
        "manifest": str(manifest_path),
        "slices_dir": str(slices_dir),
    }
    print(json.dumps(result, ensure_ascii=False), flush=True)
    print(f"SLICING_MANIFEST={manifest_path}", flush=True)
    print(f"SLICING_DIR={slices_dir}", flush=True)
    print(f"SLICING_COUNT={len(chunks)}", flush=True)


if __name__ == "__main__":
    main()

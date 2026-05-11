"""Speaker diarization via pyannote-audio.

Runs `pyannote/speaker-diarization-3.1` (HuggingFace) to split a WAV into
speaker-attributed time intervals. Returns anonymous labels (Speaker A, B, C...)
in order of first appearance — identification is out of scope (PR5).

Requires a HuggingFace access token in `HF_TOKEN` (loaded by `src/config.py`
from .env). On Apple Silicon the pipeline runs on the MPS backend if available.

Heavy imports (torch / pyannote) are deferred until `diarize()` is called so
the CLI stays snappy.
"""

import os
import sys


def _label_for_index(i: int) -> str:
    # A, B, ..., Z, AA, AB, ...
    s = ""
    i += 1
    while i > 0:
        i, rem = divmod(i - 1, 26)
        s = chr(ord("A") + rem) + s
    return s


def diarize(
    wav_path: str,
    min_speakers: int | None = None,
    max_speakers: int | None = None,
) -> list[dict]:
    """Diarize a WAV file. Returns sorted list of dicts:
        {"start": float, "end": float, "speaker": "A"|"B"|...}

    Returns [] if HF_TOKEN missing, pipeline fails, or pyannote not installed.
    """
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
    if not token:
        print(
            "[diarizer] HF_TOKEN missing from env / .env — skipping diarization. "
            "Set HF_TOKEN to a HuggingFace token with access to "
            "pyannote/speaker-diarization-3.1 to enable speaker labels.",
            file=sys.stderr,
        )
        return []

    # Heavy imports — deferred so CLI startup stays fast.
    try:
        import torch  # noqa: F401
        from pyannote.audio import Pipeline
    except Exception as e:
        print(
            f"[diarizer] pyannote-audio / torch not available ({e}). "
            "Run `pip install pyannote.audio torch` in the chikki env.",
            file=sys.stderr,
        )
        return []

    print(
        f"[diarizer] Loading pyannote/speaker-diarization-3.1 (this can take a moment)…",
        file=sys.stderr,
    )

    try:
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            use_auth_token=token,
        )
    except Exception as e:
        print(
            f"[diarizer] Failed to load pyannote pipeline ({e}). "
            "Common causes: invalid HF_TOKEN, or model EULA not accepted at "
            "https://huggingface.co/pyannote/speaker-diarization-3.1",
            file=sys.stderr,
        )
        return []

    # Prefer MPS on Apple Silicon when available, else CPU.
    try:
        import torch

        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
            print("[diarizer] Using MPS backend.", file=sys.stderr)
        else:
            print("[diarizer] Using CPU backend.", file=sys.stderr)
    except Exception as e:
        print(f"[diarizer] Could not set device ({e}); falling back to default.", file=sys.stderr)

    kwargs = {}
    if min_speakers is not None:
        kwargs["min_speakers"] = int(min_speakers)
    if max_speakers is not None:
        kwargs["max_speakers"] = int(max_speakers)

    try:
        diarization = pipeline(wav_path, **kwargs)
    except Exception as e:
        print(f"[diarizer] Diarization failed: {e}", file=sys.stderr)
        return []

    # Map raw labels (SPEAKER_00, SPEAKER_01, ...) → anonymous letters in
    # order of first appearance on the timeline.
    label_map: dict[str, str] = {}
    out: list[dict] = []
    for turn, _, raw_label in diarization.itertracks(yield_label=True):
        if raw_label not in label_map:
            label_map[raw_label] = _label_for_index(len(label_map))
        out.append(
            {
                "start": float(turn.start),
                "end": float(turn.end),
                "speaker": label_map[raw_label],
            }
        )

    out.sort(key=lambda d: (d["start"], d["end"]))
    print(
        f"[diarizer] Done. {len(out)} turns, {len(label_map)} speakers: "
        f"{', '.join(sorted(label_map.values()))}",
        file=sys.stderr,
    )
    return out


def align_segments(segments: list[dict], turns: list[dict]) -> list[dict]:
    """Attach a `speaker` key to each transcript segment via interval overlap.

    Both inputs must be sorted by start time. Uses a two-pointer sweep, so the
    total work is O(n + m + K) where K is the number of (segment, turn)
    overlap pairs — bounded by O(n + m) when turns don't overlap each other
    (typical for pyannote output).

    The chosen speaker for each segment is the diarizer turn with the largest
    overlap duration. Segments with no overlapping turn get `speaker = None`.
    """
    if not segments or not turns:
        for s in segments:
            s.setdefault("speaker", None)
        return segments

    # Ensure sorted.
    segs = sorted(segments, key=lambda s: (s.get("start", 0.0), s.get("end", 0.0)))
    trs = sorted(turns, key=lambda t: (t["start"], t["end"]))

    j_start = 0
    for seg in segs:
        s_start = float(seg.get("start", 0.0))
        s_end = float(seg.get("end", s_start))

        # Advance j_start past turns that end before this segment begins.
        while j_start < len(trs) and trs[j_start]["end"] <= s_start:
            j_start += 1

        best_overlap = 0.0
        best_speaker = None
        j = j_start
        while j < len(trs) and trs[j]["start"] < s_end:
            ov = min(s_end, trs[j]["end"]) - max(s_start, trs[j]["start"])
            if ov > best_overlap:
                best_overlap = ov
                best_speaker = trs[j]["speaker"]
            j += 1

        seg["speaker"] = best_speaker

    return segs

"""Speaker diarization via pyannote-audio.

Runs `pyannote/speaker-diarization-3.1` (HuggingFace) to split a WAV into
speaker-attributed time intervals. Returns anonymous labels (Speaker A, B, C...)
in order of first appearance.

When `config.diarization.identify` is true AND the speaker registry is
non-empty, cluster centroids are matched against enrolled speaker embeddings and
anonymous labels are replaced with real names (PR5).

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
    identify: bool | None = None,
    match_threshold: float | None = None,
) -> list[dict]:
    """Diarize a WAV file. Returns sorted list of dicts:
        {"start": float, "end": float, "speaker": "A"|"B"|...}

    When `identify` is True (or unset and config.diarization.identify is True)
    AND the speaker registry is non-empty, cluster centroids are matched against
    enrolled embeddings and anonymous labels are replaced with real names.

    Returns [] if HF_TOKEN missing, pipeline fails, or pyannote not installed.
    """
    # Resolve identify / match_threshold from config when not explicitly passed.
    from .config import CONFIG as _CONFIG
    _diar_cfg = _CONFIG.get("diarization", {})
    if identify is None:
        identify = bool(_diar_cfg.get("identify", True))
    if match_threshold is None:
        match_threshold = float(_diar_cfg.get("match_threshold", 0.7))

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

    # ------------------------------------------------------------------
    # Speaker identification: replace anonymous labels with enrolled names.
    # ------------------------------------------------------------------
    if identify:
        out = _identify_speakers(
            wav_path=wav_path,
            pipeline=pipeline,
            diarization=diarization,
            label_map=label_map,
            out=out,
            token=token,
            match_threshold=match_threshold,
        )

    out.sort(key=lambda d: (d["start"], d["end"]))
    print(
        f"[diarizer] Done. {len(out)} turns, {len(label_map)} speakers: "
        f"{', '.join(sorted(set(d['speaker'] for d in out)))}",
        file=sys.stderr,
    )
    return out


def _identify_speakers(
    wav_path: str,
    pipeline,
    diarization,
    label_map: dict,
    out: list[dict],
    token: str,
    match_threshold: float,
) -> list[dict]:
    """Match cluster centroid embeddings against the enrolled speaker registry.

    Returns a (possibly updated) copy of `out` with anonymous labels replaced
    by matched names where the cosine similarity >= match_threshold.

    If two clusters match the same enrolled name, the higher-similarity cluster
    wins; the lower-similarity one reverts to its anonymous label.
    """
    # Lazy import to keep startup fast.
    try:
        from . import speaker_db
        import numpy as np
    except Exception as e:
        print(f"[diarizer] Could not import speaker_db / numpy ({e}); skipping identification.", file=sys.stderr)
        return out

    enrolled = speaker_db.list_speakers()
    if not enrolled:
        print("[diarizer] No enrolled speakers — skipping identification.", file=sys.stderr)
        return out

    print(
        f"[diarizer] Attempting speaker identification against {len(enrolled)} enrolled speaker(s) "
        f"(threshold={match_threshold}) …",
        file=sys.stderr,
    )

    # Compute centroid embedding for each raw label cluster using pyannote's
    # SpeakerEmbedding model.
    try:
        from pyannote.audio import Model, Inference
    except Exception as e:
        print(f"[diarizer] pyannote embedding model unavailable ({e}); skipping identification.", file=sys.stderr)
        return out

    try:
        import torch
        emb_model = Model.from_pretrained("pyannote/embedding", use_auth_token=token)
        if torch.backends.mps.is_available():
            emb_model = emb_model.to(torch.device("mps"))
    except Exception as e:
        print(f"[diarizer] Could not load embedding model ({e}); skipping identification.", file=sys.stderr)
        return out

    inference = Inference(emb_model, window="whole")

    # Build per-raw-label audio segments from the diarization output.
    try:
        import soundfile as sf
        audio_data, sr = sf.read(wav_path, always_2d=False)
    except Exception as e:
        print(f"[diarizer] Could not read audio for identification ({e}); skipping.", file=sys.stderr)
        return out

    # Collect embeddings per raw label by averaging segment embeddings.
    from pyannote.core import Segment
    raw_label_embeddings: dict[str, list] = {}
    for turn, _, raw_label in diarization.itertracks(yield_label=True):
        try:
            emb = inference.crop(wav_path, Segment(turn.start, turn.end))
            raw_label_embeddings.setdefault(raw_label, []).append(np.array(emb, dtype=np.float32).flatten())
        except Exception as e:
            print(f"[diarizer] Embedding failed for segment {turn} ({e}); skipping segment.", file=sys.stderr)

    if not raw_label_embeddings:
        print("[diarizer] No embeddings computed; skipping identification.", file=sys.stderr)
        return out

    # Compute centroid per raw label.
    centroids: dict[str, np.ndarray] = {}
    for raw_label, embs in raw_label_embeddings.items():
        centroids[raw_label] = np.mean(np.stack(embs, axis=0), axis=0)

    # Match each centroid against the registry, track best match per raw label.
    raw_to_name: dict[str, str | None] = {}
    raw_to_sim: dict[str, float] = {}
    for raw_label, centroid in centroids.items():
        name = speaker_db.match(centroid, threshold=match_threshold)
        raw_to_name[raw_label] = name
        # Re-compute best similarity for tie-breaking (match() already logs it).
        if name is not None:
            # Fetch the similarity we just computed.
            best_sim = _cosine_sim_against_registry(centroid, name)
            raw_to_sim[raw_label] = best_sim
        else:
            raw_to_sim[raw_label] = -1.0

    # Resolve conflicts: if two raw labels matched the same name, keep only
    # the one with higher similarity; the other reverts to anonymous.
    name_to_best_raw: dict[str, str] = {}
    for raw_label, name in raw_to_name.items():
        if name is None:
            continue
        existing = name_to_best_raw.get(name)
        if existing is None or raw_to_sim[raw_label] > raw_to_sim[existing]:
            if existing is not None:
                print(
                    f"[diarizer] Conflict: both {raw_label} and {existing} matched '{name}'; "
                    f"keeping {raw_label} (sim={raw_to_sim[raw_label]:.3f} vs {raw_to_sim[existing]:.3f}).",
                    file=sys.stderr,
                )
                raw_to_name[existing] = None  # Revert loser.
            name_to_best_raw[name] = raw_label

    # Build reverse: anonymous letter → resolved name.
    anon_to_name: dict[str, str] = {}
    for raw_label, anon in label_map.items():
        name = raw_to_name.get(raw_label)
        if name:
            anon_to_name[anon] = name
            print(f"[diarizer] {anon} → '{name}'", file=sys.stderr)

    if not anon_to_name:
        print("[diarizer] No speakers matched; keeping anonymous labels.", file=sys.stderr)
        return out

    # Apply name substitutions to out.
    updated = []
    for segment in out:
        s = dict(segment)
        s["speaker"] = anon_to_name.get(s["speaker"], s["speaker"])
        updated.append(s)

    return updated


def _cosine_sim_against_registry(embedding, name: str) -> float:
    """Return cosine similarity of `embedding` against the registered embedding for `name`."""
    try:
        import numpy as np
        from . import speaker_db

        emb = np.array(embedding, dtype=np.float32).flatten()
        norm_emb = np.linalg.norm(emb)
        if norm_emb == 0.0:
            return -1.0

        registry = speaker_db._load_registry()
        for entry in registry["speakers"]:
            if entry["name"].lower() == name.lower():
                import os
                emb_path = os.path.join(speaker_db._SPEAKERS_DIR, entry["embedding_path"])
                if not os.path.exists(emb_path):
                    return -1.0
                ref = np.load(emb_path).astype(np.float32).flatten()
                norm_ref = np.linalg.norm(ref)
                if norm_ref == 0.0:
                    return -1.0
                return float(np.dot(emb, ref) / (norm_emb * norm_ref))
    except Exception:
        pass
    return -1.0


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

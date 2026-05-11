"""Speaker registry for Chikki — enrollment and identification.

Manages a persistent registry of known speakers at `speakers/registry.json`.
Each enrolled speaker has a 192-dim (or similar) mean embedding stored as a
`.npy` file alongside the registry.

Schema of `speakers/registry.json`:
    {
        "speakers": [
            {
                "name": "Kshitij",
                "embedding_path": "kshitij.npy",
                "created_at": "2026-05-11T12:00:00"
            },
            ...
        ]
    }

All paths resolve relative to the repo root (same pattern as `src/config.py`).
Heavy deps (pyannote, torch) are lazy-imported inside functions so the CLI
stays snappy.
"""

import json
import os
import sys
from datetime import datetime, timezone

import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SPEAKERS_DIR = os.path.join(_BASE_DIR, "speakers")
_REGISTRY_PATH = os.path.join(_SPEAKERS_DIR, "registry.json")


# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------


def _ensure_dir() -> None:
    os.makedirs(_SPEAKERS_DIR, exist_ok=True)


def _load_registry() -> dict:
    """Load registry from disk. Returns empty registry if file is missing."""
    if not os.path.exists(_REGISTRY_PATH):
        return {"speakers": []}
    try:
        with open(_REGISTRY_PATH, encoding="utf-8") as f:
            data = json.load(f)
        if "speakers" not in data:
            data["speakers"] = []
        return data
    except Exception as e:
        print(f"[speaker_db] Could not read registry ({e}); treating as empty.", file=sys.stderr)
        return {"speakers": []}


def _save_registry(registry: dict) -> None:
    _ensure_dir()
    with open(_REGISTRY_PATH, "w", encoding="utf-8") as f:
        json.dump(registry, f, indent=2)


def _embedding_filename(name: str) -> str:
    """Sanitise speaker name to a safe filename stem."""
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in name.lower())
    return f"{safe}.npy"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def enroll(name: str, audio_path: str) -> None:
    """Enroll a speaker from a WAV file.

    Runs pyannote's SpeakerEmbedding model on the audio, computes the mean
    embedding, saves it as a `.npy` file, and updates the registry.

    Raises RuntimeError if pyannote is unavailable or enrollment fails.
    """
    print(f"[speaker_db] Enrolling '{name}' from {audio_path} …", file=sys.stderr)

    try:
        import torch
        from pyannote.audio import Model, Inference
    except Exception as e:
        raise RuntimeError(
            f"pyannote-audio / torch not available ({e}). "
            "Run `pip install pyannote.audio torch` in the chikki env."
        ) from e

    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
    if not token:
        raise RuntimeError(
            "HF_TOKEN missing from env / .env — required to load the embedding model. "
            "Add `HF_TOKEN=hf_…` to .env and accept the EULA at "
            "https://huggingface.co/pyannote/embedding"
        )

    print("[speaker_db] Loading pyannote/embedding model …", file=sys.stderr)
    try:
        model = Model.from_pretrained("pyannote/embedding", use_auth_token=token)
    except Exception as e:
        raise RuntimeError(
            f"Failed to load embedding model ({e}). "
            "Make sure you have accepted the EULA at "
            "https://huggingface.co/pyannote/embedding"
        ) from e

    # Prefer MPS on Apple Silicon.
    try:
        if torch.backends.mps.is_available():
            model = model.to(torch.device("mps"))
            print("[speaker_db] Using MPS backend.", file=sys.stderr)
        else:
            print("[speaker_db] Using CPU backend.", file=sys.stderr)
    except Exception as e:
        print(f"[speaker_db] Could not set device ({e}); using default.", file=sys.stderr)

    inference = Inference(model, window="whole")

    try:
        embedding = inference(audio_path)
    except Exception as e:
        raise RuntimeError(f"Embedding inference failed: {e}") from e

    # `embedding` is a numpy array (shape: [dim]) when window="whole".
    emb_array = np.array(embedding, dtype=np.float32).flatten()
    print(f"[speaker_db] Embedding shape: {emb_array.shape}", file=sys.stderr)

    _ensure_dir()
    filename = _embedding_filename(name)
    emb_path = os.path.join(_SPEAKERS_DIR, filename)
    np.save(emb_path, emb_array)

    registry = _load_registry()
    # Remove existing entry for same name (re-enroll).
    registry["speakers"] = [s for s in registry["speakers"] if s["name"].lower() != name.lower()]
    registry["speakers"].append(
        {
            "name": name,
            "embedding_path": filename,
            "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"),
        }
    )
    _save_registry(registry)
    print(f"[speaker_db] Enrolled '{name}' — embedding saved to {emb_path}", file=sys.stderr)


def match(embedding: np.ndarray, threshold: float = 0.7) -> "str | None":
    """Match an embedding against the registry.

    Returns the name of the best match above `threshold`, or None if no
    enrolled speaker exceeds the threshold.

    Uses cosine similarity: (a·b) / (||a|| * ||b||).
    """
    registry = _load_registry()
    if not registry["speakers"]:
        return None

    emb = np.array(embedding, dtype=np.float32).flatten()
    norm_emb = np.linalg.norm(emb)
    if norm_emb == 0.0:
        return None

    best_name: "str | None" = None
    best_sim: float = -1.0

    for entry in registry["speakers"]:
        emb_path = os.path.join(_SPEAKERS_DIR, entry["embedding_path"])
        if not os.path.exists(emb_path):
            print(
                f"[speaker_db] Missing embedding file for '{entry['name']}': {emb_path}",
                file=sys.stderr,
            )
            continue
        try:
            ref = np.load(emb_path).astype(np.float32).flatten()
        except Exception as e:
            print(f"[speaker_db] Could not load embedding for '{entry['name']}': {e}", file=sys.stderr)
            continue

        norm_ref = np.linalg.norm(ref)
        if norm_ref == 0.0:
            continue

        sim = float(np.dot(emb, ref) / (norm_emb * norm_ref))
        if sim > best_sim:
            best_sim = sim
            best_name = entry["name"]

    if best_sim >= threshold:
        print(f"[speaker_db] Best match: '{best_name}' (sim={best_sim:.3f})", file=sys.stderr)
        return best_name

    print(f"[speaker_db] No match above threshold {threshold} (best sim={best_sim:.3f})", file=sys.stderr)
    return None


def list_speakers() -> list:
    """Return list of enrolled speaker dicts from the registry."""
    return _load_registry()["speakers"]


def delete(name: str) -> bool:
    """Remove a speaker from the registry and delete their .npy file.

    Returns True if the speaker was found and removed, False otherwise.
    """
    registry = _load_registry()
    before = len(registry["speakers"])
    to_remove = [s for s in registry["speakers"] if s["name"].lower() == name.lower()]
    registry["speakers"] = [s for s in registry["speakers"] if s["name"].lower() != name.lower()]

    if len(registry["speakers"]) == before:
        return False  # Not found.

    for entry in to_remove:
        emb_path = os.path.join(_SPEAKERS_DIR, entry["embedding_path"])
        if os.path.exists(emb_path):
            try:
                os.remove(emb_path)
                print(f"[speaker_db] Deleted embedding file: {emb_path}", file=sys.stderr)
            except Exception as e:
                print(f"[speaker_db] Could not delete {emb_path}: {e}", file=sys.stderr)

    _save_registry(registry)
    print(f"[speaker_db] Removed '{name}' from registry.", file=sys.stderr)
    return True

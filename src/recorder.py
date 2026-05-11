"""Audio recorder using sounddevice. Records from default mic to WAV files.

Writes audio incrementally to disk so data is never lost on crash/force-kill.

When `recording.system_audio` is true, also spawns the `chikki-syscap` Swift
helper (ScreenCaptureKit) to capture system audio in parallel. On stop, the
mic and system tracks are combined:
  - mono mix (sum + normalize peak) -> <timestamp>.wav (used for transcription)
  - stereo archive (L=mic, R=system) -> <timestamp>_stereo.wav
If the helper is missing or fails, falls back silently to mic-only.
"""

import atexit
import os
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime

import numpy as np
import sounddevice as sd
import soundfile as sf

from .config import CONFIG


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _locate_syscap_binary():
    """Locate the chikki-syscap helper binary.

    Search order:
      1. $CHIKKI_SYSCAP
      2. <repo>/menubar/.build/release/chikki-syscap
      3. <repo>/menubar/.build/debug/chikki-syscap
      4. chikki-syscap on PATH
    """
    env = os.environ.get("CHIKKI_SYSCAP")
    if env and os.path.exists(env) and os.access(env, os.X_OK):
        return env

    for build in ("release", "debug"):
        path = os.path.join(_REPO_ROOT, "menubar", ".build", build, "chikki-syscap")
        if os.path.exists(path) and os.access(path, os.X_OK):
            return path

    found = shutil.which("chikki-syscap")
    if found:
        return found

    return None


class Recorder:
    def __init__(self):
        self._cfg = CONFIG["recording"]
        self._sample_rate = self._cfg["sample_rate"]
        self._channels = self._cfg["channels"]
        self._max_duration = self._cfg["max_duration_minutes"] * 60
        self._recordings_dir = self._cfg["recordings_dir"]
        self._system_audio_enabled = bool(self._cfg.get("system_audio", False))
        self._mix_mode = self._cfg.get("mix_mode", "mono")
        os.makedirs(self._recordings_dir, exist_ok=True)

        self._stream = None
        self._recording = False
        self._start_time = None
        self._lock = threading.Lock()
        self._file = None
        self._filepath = None

        # System audio helper state
        self._sys_proc = None
        self._sys_filepath = None

    @property
    def is_recording(self):
        return self._recording

    @property
    def elapsed(self):
        if self._start_time and self._recording:
            return time.time() - self._start_time
        return 0.0

    @property
    def filepath(self):
        return self._filepath

    def _callback(self, indata, frames, time_info, status):
        if status:
            print(f"[recorder] {status}", file=sys.stderr)
        if self._file is not None:
            self._file.write(indata.copy())

    def _start_system_audio(self, timestamp):
        """Spawn the chikki-syscap helper. On failure, log to stderr and continue mic-only."""
        binary = _locate_syscap_binary()
        if not binary:
            print(
                "[recorder] system_audio enabled but chikki-syscap helper not found; "
                "falling back to mic-only. Build it with: "
                "cd menubar && swift build -c release --product chikki-syscap",
                file=sys.stderr,
            )
            return

        sys_filename = f"system_{timestamp}.wav"
        sys_filepath = os.path.join(self._recordings_dir, sys_filename)

        try:
            proc = subprocess.Popen(
                [
                    binary, sys_filepath,
                    "--sample-rate", str(self._sample_rate),
                    "--channels", str(self._channels),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=sys.stderr,
            )
        except (OSError, PermissionError) as e:
            print(f"[recorder] failed to launch chikki-syscap: {e}; falling back to mic-only.", file=sys.stderr)
            return

        # Give the helper a moment to fail fast (e.g. permission denied).
        time.sleep(0.2)
        if proc.poll() is not None:
            print(
                f"[recorder] chikki-syscap exited immediately (code {proc.returncode}); "
                "likely missing Screen Recording permission. Falling back to mic-only.",
                file=sys.stderr,
            )
            return

        self._sys_proc = proc
        self._sys_filepath = sys_filepath

    def _stop_system_audio(self):
        """Send 'stop' to the helper, wait for graceful exit. Returns path or None."""
        proc = self._sys_proc
        path = self._sys_filepath
        self._sys_proc = None
        self._sys_filepath = None
        if proc is None:
            return None

        try:
            if proc.stdin is not None and not proc.stdin.closed:
                try:
                    proc.stdin.write(b"stop\n")
                    proc.stdin.flush()
                    proc.stdin.close()
                except (BrokenPipeError, OSError):
                    pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                print("[recorder] chikki-syscap did not stop within 5s; terminating.", file=sys.stderr)
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        except Exception as e:
            print(f"[recorder] error stopping chikki-syscap: {e}", file=sys.stderr)

        if path and os.path.exists(path) and os.path.getsize(path) > 44:
            return path
        if path and os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass
        return None

    def start(self):
        with self._lock:
            if self._recording:
                return None

            # Open WAV file for incremental writing
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"recording_{timestamp}.wav"
            self._filepath = os.path.join(self._recordings_dir, filename)
            self._file = sf.SoundFile(
                self._filepath,
                mode="w",
                samplerate=self._sample_rate,
                channels=self._channels,
                format="WAV",
                subtype="FLOAT",
            )

            self._stream = sd.InputStream(
                samplerate=self._sample_rate,
                channels=self._channels,
                dtype="float32",
                callback=self._callback,
            )
            self._stream.start()
            self._recording = True
            self._start_time = time.time()
            self._timestamp = timestamp

            # Optional system audio capture (parallel process)
            if self._system_audio_enabled:
                self._start_system_audio(timestamp)

            # Ensure we save on unexpected exit
            atexit.register(self._emergency_save)

        return True

    def stop(self):
        with self._lock:
            if not self._recording:
                return None
            self._recording = False
            self._stream.stop()
            self._stream.close()
            self._stream = None

            filepath = self._filepath
            duration = time.time() - self._start_time if self._start_time else 0
            self._start_time = None

            if self._file is not None:
                self._file.close()
                self._file = None

            try:
                atexit.unregister(self._emergency_save)
            except Exception:
                pass

        # Stop system-audio helper (outside the lock; it may take a moment).
        sys_path = self._stop_system_audio()

        if not (filepath and os.path.exists(filepath) and os.path.getsize(filepath) > 44):
            if filepath and os.path.exists(filepath):
                os.remove(filepath)
            return None

        # If we have a system-audio track, mix mic+system.
        if sys_path:
            try:
                final = _mix_mic_and_system(
                    mic_path=filepath,
                    sys_path=sys_path,
                    timestamp=self._timestamp,
                    recordings_dir=self._recordings_dir,
                    sample_rate=self._sample_rate,
                )
                if final:
                    filepath = final
            except Exception as e:
                print(f"[recorder] mixing failed: {e}; using mic-only file.", file=sys.stderr)

        print(f"[recorder] Saved: {filepath} ({duration:.1f}s)", file=sys.stderr)
        return filepath

    def _emergency_save(self):
        """Called by atexit — close the file so whatever was written is valid."""
        try:
            if self._stream is not None:
                self._stream.stop()
                self._stream.close()
            if self._file is not None:
                self._file.close()
                self._file = None
                print(f"\n[recorder] Emergency save: {self._filepath}", file=sys.stderr)
            # Try to stop the helper too.
            if self._sys_proc is not None:
                try:
                    if self._sys_proc.stdin is not None and not self._sys_proc.stdin.closed:
                        self._sys_proc.stdin.write(b"stop\n")
                        self._sys_proc.stdin.flush()
                        self._sys_proc.stdin.close()
                    self._sys_proc.wait(timeout=3)
                except Exception:
                    try:
                        self._sys_proc.terminate()
                    except Exception:
                        pass
        except Exception:
            pass

    def toggle(self):
        """Toggle recording on/off. Returns filepath when stopping, True when starting."""
        if self._recording:
            return self.stop()
        else:
            return self.start()


def _mix_mic_and_system(mic_path, sys_path, timestamp, recordings_dir, sample_rate):
    """Combine mic + system audio. Writes a mono mix (returned, used for transcription)
    and a stereo archive (L=mic, R=system) alongside.

    Returns the path to the mono mix, or None on failure.
    """
    mic, mic_sr = sf.read(mic_path, dtype="float32", always_2d=True)
    sysd, sys_sr = sf.read(sys_path, dtype="float32", always_2d=True)

    # Resample system audio if necessary (helper should already match, but be safe).
    if sys_sr != mic_sr:
        sysd = _resample_linear(sysd, sys_sr, mic_sr)

    # Reduce multi-channel to mono per track.
    mic_mono = mic.mean(axis=1) if mic.shape[1] > 1 else mic[:, 0]
    sys_mono = sysd.mean(axis=1) if sysd.shape[1] > 1 else sysd[:, 0]

    # Pad shorter to longer with zeros.
    n = max(len(mic_mono), len(sys_mono))
    if len(mic_mono) < n:
        mic_mono = np.pad(mic_mono, (0, n - len(mic_mono)))
    if len(sys_mono) < n:
        sys_mono = np.pad(sys_mono, (0, n - len(sys_mono)))

    # Stereo archive: L=mic, R=system
    stereo = np.stack([mic_mono, sys_mono], axis=1)
    stereo_path = os.path.join(recordings_dir, f"recording_{timestamp}_stereo.wav")
    sf.write(stereo_path, stereo, mic_sr, subtype="FLOAT")

    # Mono mix: sum + normalize peak to ~0.99 if clipping would occur
    mono = mic_mono + sys_mono
    peak = float(np.max(np.abs(mono))) if mono.size else 0.0
    if peak > 0.99:
        mono = mono * (0.99 / peak)

    # Overwrite the mic-named file with the mono mix; this stays the canonical
    # transcription target so the rest of the pipeline is unchanged.
    mix_path = os.path.join(recordings_dir, f"recording_{timestamp}.wav")
    sf.write(mix_path, mono, mic_sr, subtype="FLOAT")

    # Mic path may be the same path (recording_<ts>.wav already). Clean up the
    # raw system file — its content is preserved in the stereo archive.
    try:
        if os.path.abspath(sys_path) != os.path.abspath(mix_path):
            os.remove(sys_path)
    except OSError:
        pass

    print(
        f"[recorder] system audio mixed: mono -> {os.path.basename(mix_path)}, "
        f"stereo archive -> {os.path.basename(stereo_path)}",
        file=sys.stderr,
    )
    return mix_path


def _resample_linear(x, src_sr, dst_sr):
    """Cheap linear resampler for fallback when helper-provided SR mismatches.
    Not high quality, but only used in the rare mismatch case."""
    if src_sr == dst_sr or len(x) == 0:
        return x
    src_n = x.shape[0]
    dst_n = int(round(src_n * dst_sr / src_sr))
    if dst_n <= 0:
        return x[:0]
    src_idx = np.linspace(0, src_n - 1, dst_n)
    out = np.empty((dst_n, x.shape[1]), dtype=np.float32)
    lo = np.floor(src_idx).astype(np.int64)
    hi = np.minimum(lo + 1, src_n - 1)
    frac = (src_idx - lo).astype(np.float32)
    for c in range(x.shape[1]):
        out[:, c] = x[lo, c] * (1 - frac) + x[hi, c] * frac
    return out

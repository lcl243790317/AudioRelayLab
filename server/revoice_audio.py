# SPDX-License-Identifier: GPL-3.0-only
"""Shared waveform safety checks; no timing alignment or voice processing."""
import hashlib
import io
from revoice_contract import validate_output_duration

MAX_NEW_TOKENS = 2300


def validated_samples(waveform, rate, codec_frames):
    import numpy as np
    if not codec_frames or any(count >= MAX_NEW_TOKENS for count in codec_frames):
        raise RuntimeError('Generation reached the token limit; refusing an incomplete sentence')
    if not isinstance(rate, int) or rate <= 0:
        raise RuntimeError('Invalid output sample rate')
    samples = np.asarray(waveform, dtype=np.float32).reshape(-1)
    validate_output_duration(len(samples)/rate)
    if not np.isfinite(samples).all() or np.max(np.abs(samples)) < .0001:
        raise RuntimeError('Model returned invalid or silent audio')
    peak = float(np.max(np.abs(samples)))
    if peak > .98:
        samples = samples * (.98/peak)
    return samples


def wav_bytes(samples, rate):
    import soundfile as sf
    buffer = io.BytesIO()
    sf.write(buffer, samples, rate, format='WAV', subtype='PCM_16')
    data = buffer.getvalue()
    return data, hashlib.sha256(data).hexdigest()

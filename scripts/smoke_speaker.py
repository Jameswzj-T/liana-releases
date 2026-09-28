#!/usr/bin/env python3
"""Offline voiceprint capability check: synthetic waveform and temporary enrollment only.

Use --brain-root with the candidate bundle's Resources/brain and its own Python.
Before packaging, --model explicitly supplies the missing, hash-verified model.
The report identifies both inputs; it does not claim microphone/speaker accuracy.
"""
import sys
sys.dont_write_bytecode = True
if sys.flags.optimize:
    raise RuntimeError('Run voiceprint checks without Python optimization (-O).')

import argparse
import hashlib
import json
from pathlib import Path
import tempfile


def check(brain, model=None):
    attempts = []
    def deny(event, arguments):
        if event in {'socket.connect', 'socket.getaddrinfo'}:
            attempts.append(event)
            raise RuntimeError('Network disabled during voiceprint check')
    sys.addaudithook(deny)
    sys.path.insert(0, str(brain))
    from core import speaker
    import numpy as np
    if not Path(speaker.__file__).resolve().is_relative_to(brain):
        raise ValueError('Voiceprint source did not come from the requested brain')
    actual_model = model or Path(speaker._model_path())
    manifest = json.loads((brain / 'model-manifest.json').read_text())
    entry = next(item for item in manifest['groups']['first_release']['files']
                 if item['path'] == 'models/speaker/campplus.onnx')
    digest = hashlib.sha256(actual_model.read_bytes()).hexdigest()
    if digest != entry['sha256']:
        raise ValueError('Voiceprint model differs from the release manifest')
    # In-memory test routing only. Never read, write or clear the real enrollment.
    speaker._model_path = lambda: str(actual_model)
    with tempfile.TemporaryDirectory(prefix='liana-synthetic-speaker-') as directory:
        enrollment = Path(directory) / 'synthetic-enrollment.npy'
        speaker._enroll_file = lambda: str(enrollment)
        assert not speaker.is_enrolled()
        assert speaker.available()
        rng = np.random.default_rng(17)
        t = np.arange(48000, dtype=np.float32) / 16000
        samples = (0.2 * np.sin(2 * np.pi * 180 * t)
                   + 0.1 * np.sin(2 * np.pi * 410 * t)
                   + 0.02 * rng.standard_normal(t.size)).astype('float32')
        embedding = speaker.compute_embedding(samples)
        assert embedding.shape == (192,) and np.isfinite(embedding).all()
        assert abs(float(np.linalg.norm(embedding)) - 1.0) < 1e-5
        assert speaker.enroll(samples) and speaker.is_enrolled()
        saved = speaker.read_enrollment()
        assert saved.shape == (192,) and np.allclose(saved, embedding)
        score = speaker.similarity(samples, enrolled=saved)
        assert score > 0.99 and not attempts
    return {'passed': True, 'brain_root': str(brain), 'model_input': str(actual_model),
            'model_sha256': digest, 'runtime': str(Path(sys.executable).resolve()),
            'bundled_model': model is None, 'embedding_dimension': 192,
            'temporary_enrollment_roundtrip': True, 'same_signal_similarity': score,
            'network_attempts': attempts, 'user_enrollment_accessed': False,
            'microphone_tested': False, 'real_speaker_accuracy_tested': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--brain-root', type=Path, required=True)
    parser.add_argument('--model', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = args.report.resolve()
    if report.exists() or not report.parent.is_dir() or any(part.endswith('.app') for part in report.parts):
        raise ValueError('Use a new report outside every App, in an existing directory')
    result = check(args.brain_root.resolve(), args.model.resolve() if args.model else None)
    with report.open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()

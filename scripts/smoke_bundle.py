#!/usr/bin/env python3
"""Offline inference with explicitly supplied synthetic audio, without UI launch."""
import sys
sys.dont_write_bytecode = True

import argparse
import importlib
import json
import os
from pathlib import Path
import tempfile
import time

if sys.flags.optimize:
    raise RuntimeError('Run release checks without Python optimization (-O).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--audio', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = args.report.resolve()
    if report.exists() or any(part.endswith('.app') for part in report.parts):
        raise ValueError('Use a new report path outside every application bundle.')
    if not report.parent.is_dir():
        raise ValueError('The report parent directory must already exist.')
    brain = args.app.resolve() / 'Contents/Resources/brain'
    if not Path(sys.executable).resolve().is_relative_to(brain / '.venv'):
        raise ValueError('Run this check with the candidate bundle Python.')
    for name in ('ASR_API_KEY', 'ASR_CLOUD_KEY', 'LLM_API_KEY'):
        os.environ.pop(name, None)
    # Isolate the product's input files, without changing the real HOME.
    # This Python fixture is not a clean macOS installation.
    fixture = Path(tempfile.mkdtemp(prefix='liana-offline-inputs-', dir=report.parent))
    os.environ.update(ASR_PROVIDER='local', ASR_ENGINE='qwen3_06', ASR_CLOUD='0', ASR_E2E='0',
                      POLISH_DISABLE='1', TEXT_ENHANCEMENT_ENABLED='0', HF_HUB_OFFLINE='1',
                      TRANSFORMERS_OFFLINE='1', ASR_QWEN3_06_MODEL=str(brain / 'models/Qwen3-ASR-0.6B-8bit'))
    attempts = []
    private_data = Path(os.path.expanduser('~/Library/Application Support/VoiceFlow'))
    def deny(event, arguments):
        if event in {'socket.connect', 'socket.getaddrinfo'}:
            attempts.append(event)
            raise RuntimeError('Network disabled during bundle test')
        if event in {'open', 'os.listdir', 'os.scandir'} and arguments:
            path = arguments[0]
            if isinstance(path, (str, bytes, os.PathLike)):
                absolute = Path(os.path.abspath(os.fsdecode(path)))
                if absolute == private_data or private_data in absolute.parents:
                    raise RuntimeError('Private product data disabled during bundle test')
    sys.addaudithook(deny)
    sys.path.insert(0, str(brain))
    started = time.monotonic()
    manifest = json.loads((brain / 'runtime-manifest.json').read_text())
    modules = []
    for relative in manifest['brain_sources']:
        name = relative.removeprefix('brain/').removesuffix('.py').replace('/', '.')
        name = name.removesuffix('.__init__')
        module = importlib.import_module(name)
        assert Path(module.__file__).resolve().is_relative_to(brain)
        modules.append(name)
    from core import asr, polish, speaker
    polish._vocab_file = lambda: str(fixture / 'vocab.txt')
    polish._corrections_file = lambda: str(fixture / 'corrections.txt')
    polish._domain_profile_file = lambda: str(fixture / 'domain_profile.txt')
    speaker._enroll_file = lambda: str(fixture / 'speaker_enroll.npy')
    from core.config import Config
    from core.text_enhancement import smart_dictation_prompt_identity
    import numpy as np
    vad = asr.new_vad()
    for _ in range(32):
        vad.accept_waveform(np.zeros(512, dtype='float32'))
    vad.flush()
    assert vad.empty()
    config = Config(asr_engine='qwen3_06', polish_disabled=True, asr_cloud=False, asr_e2e=False,
                    vocab_context_enabled=False, corrections_hard_enabled=False, speaker_verify=False)
    text = asr.transcribe(str(args.audio.resolve()), config)
    assert isinstance(text, str) and text.strip(), 'Synthetic speech produced no text'
    assert not attempts
    prompt, prompt_hash = smart_dictation_prompt_identity()
    result = {'passed': True, 'modules': len(modules), 'vad': True, 'inference_nonempty': True,
              'synthetic_output': text, 'seconds': round(time.monotonic() - started, 2),
              'prompt': prompt, 'prompt_sha256': prompt_hash, 'network_attempts': attempts,
              'microphone_tested': False, 'UI_started': False, 'system_permissions_tested': False}
    with report.open('x') as stream:
        stream.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()

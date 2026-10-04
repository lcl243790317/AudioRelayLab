# SPDX-License-Identifier: GPL-3.0-only
"""One resident Qwen model per GPU, reusing the local text-only inference contract."""
import gc
import importlib.metadata
import json
import os
from pathlib import Path
import time
import uuid
from revoice_audio import MAX_NEW_TOKENS, validated_samples, wav_bytes
from revoice_contract import synthesis_arguments, custom_task, SPEAKERS
from revoice_registry import PresetRegistry, digest

def verify_models(registry, model_root, variants=None):
    for variant in variants or registry.required_variants():
        for item in registry.lock['models'][variant]['files']:
            path = Path(model_root)/variant/item['path']
            if not path.is_file() or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
                raise RuntimeError('Pinned model asset verification failed')


class QwenEngine:
    def __init__(self, model_root, reference_root, *, require_l4=True):
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['TRANSFORMERS_OFFLINE'] = '1'
        import torch
        from qwen_tts import Qwen3TTSModel
        self.torch, self.model_class = torch, Qwen3TTSModel
        self.registry = PresetRegistry()
        if not torch.cuda.is_available():
            raise RuntimeError('CUDA GPU is required')
        self.gpu_name = torch.cuda.get_device_name(0)
        self.total_memory = torch.cuda.get_device_properties(0).total_memory
        if require_l4 and 'L4' != self.gpu_name.removeprefix('NVIDIA ').strip():
            raise RuntimeError('The assigned GPU is not NVIDIA L4')
        if require_l4 and self.total_memory < 22_000_000_000:
            raise RuntimeError('The assigned L4 does not provide the expected 24 GB VRAM')
        if not torch.cuda.is_bf16_supported():
            raise RuntimeError('BF16 is required')
        lock = self.registry.lock
        for name, expected in dict(torch=lock['inheritedRuntime']['torch'], numpy=lock['inheritedRuntime']['numpy'],
                                   **{n:lock['extraDependencies'][n] for n in ('qwen-tts','transformers','accelerate','huggingface-hub','tokenizers','sox')}).items():
            if importlib.metadata.version(name) != expected:
                raise RuntimeError('Inference dependency differs from its lock')
        self.model_root, self.reference_root = Path(model_root), Path(reference_root)
        verify_models(self.registry, self.model_root)
        self.references = {p.id:self.registry.verify_reference(p.reference_id, self.reference_root)
                           for p in self.registry.presets.values() if p.enabled and p.variant=='base'}
        self.model, self.variant, self.prompts = None, None, {}
        self.observed = []
        self.session_id = uuid.uuid4().hex
        self.generations = 0
        self.startup_verified = True
        self.snapshot_marker = None
        self.initialization_peak = 0
        self.load_peak_bytes = 0

    def reset_session(self):
        self.session_id = uuid.uuid4().hex
        self.generations = 0
        self.observed.clear()
        if self.torch.cuda.get_device_name(0).removeprefix('NVIDIA ').strip() != self.gpu_name.removeprefix('NVIDIA ').strip():
            raise RuntimeError('GPU identity changed during restore')
        for p in self.registry.presets.values():
            if p.enabled and p.variant == 'base':
                self.registry.verify_reference(p.reference_id, self.reference_root)

    def prepare_snapshot(self):
        # Only fixed accepted target references participate; never caller audio/text.
        self._load('base')
        self.initialization_peak = self.load_peak_bytes
        self._load('custom')  # moves the cached Base prompts to CPU and releases Base
        self.initialization_peak = max(self.initialization_peak, self.load_peak_bytes)
        self.synthesize_custom('Serena', '你好，我们开始吧。', '', 'snapshot-warmup')
        self.initialization_peak = max(self.initialization_peak, self.torch.cuda.max_memory_allocated())
        self.torch.cuda.synchronize()
        self.snapshot_marker = uuid.uuid4().hex
        self.reset_session()

    def _move_prompts(self, device):
        for prompt in self.prompts.values():
            for item in prompt:
                if item.ref_code is not None:
                    item.ref_code = item.ref_code.to(device)
                item.ref_spk_embedding = item.ref_spk_embedding.to(device)

    def unload(self):
        self._move_prompts('cpu')
        self.model, self.variant = None, None
        gc.collect()
        self.torch.cuda.empty_cache()

    def _load(self, variant):
        if self.variant == variant:
            return 0.0
        self.unload()
        started = time.perf_counter()
        # A Volume mutation does not invalidate Modal snapshots. Validate each newly loaded variant.
        if hasattr(self, 'registry'):
            verify_models(self.registry, self.model_root, [variant])
        self.torch.cuda.reset_peak_memory_stats()
        self.model = self.model_class.from_pretrained(str(self.model_root/variant), device_map='cuda:0',
                                                     dtype=self.torch.bfloat16, attn_implementation='sdpa',
                                                     local_files_only=True)
        self.variant = variant
        if variant == 'custom' and hasattr(self.model, 'get_supported_speakers'):
            if set(self.model.get_supported_speakers()) != {s.lower() for s in SPEAKERS}:
                raise RuntimeError('Pinned speaker inventory differs from the whitelist')
        original = self.model.model.generate
        def observe(*values, **options):
            result = original(*values, **options)
            self.observed[:] = [int(code.shape[0]) for code in result[0]]
            return result
        self.model.model.generate = observe
        if variant == 'base':
            self._move_prompts('cuda:0')
            with self.torch.inference_mode():
                for name, (audio, text) in self.references.items():
                    if name not in self.prompts:
                        self.prompts[name] = self.model.create_voice_clone_prompt(ref_audio=str(audio), ref_text=text)
        self.load_peak_bytes = self.torch.cuda.max_memory_allocated()
        return time.perf_counter()-started

    def synthesize(self, preset_id, text, request_id):
        preset = self.registry.get(preset_id, cloud=True)
        task = preset.task(text)
        return self._generate(preset.id, preset.variant, task, request_id, preset.reference_id, 'preset')

    def synthesize_custom(self, speaker, text, instruction, request_id):
        return self._generate('custom', 'custom', custom_task(speaker, text, instruction), request_id, None, 'custom')

    def _generate(self, voice, variant, task, request_id, reference_id, mode):
        load_seconds = self._load(variant)
        self.torch.manual_seed(task['seed'])
        self.torch.cuda.reset_peak_memory_stats()
        arguments = synthesis_arguments(variant, task, self.prompts.get(voice))
        self.observed.clear()
        started = time.perf_counter()
        method = self.model.generate_custom_voice if variant=='custom' else self.model.generate_voice_clone
        with self.torch.inference_mode():
            waves, rate = method(**arguments, max_new_tokens=MAX_NEW_TOKENS)
        elapsed = time.perf_counter()-started
        samples = validated_samples(waves[0], int(rate), self.observed)
        data, sha256 = wav_bytes(samples, int(rate))
        self.generations += 1
        model = self.registry.lock['models'][variant]
        reference_hash = self.registry.references[reference_id]['audioSHA256'] if variant=='base' else None
        metadata = dict(requestID=request_id, voice=voice, variant=variant, speaker=task.get('speaker'), generationMode=mode,
                        modelRepository=model['repository'], modelRevision=model['revision'],
                        modelSHA256=next(f['sha256'] for f in model['files'] if f['path']=='model.safetensors'),
                        seed=task['seed'], sampleRate=int(rate), outputDuration=len(samples)/rate,
                        generationSeconds=elapsed, modelLoadSeconds=load_seconds,
                        sha256=sha256, targetReferenceSHA256=reference_hash,
                        gpuName=self.gpu_name, cudaPeakAllocatedBytes=self.torch.cuda.max_memory_allocated(),
                        cudaTotalMemoryBytes=self.total_memory,
                        dtype='torch.bfloat16', attention='sdpa', codecFrames=self.observed[0],
                        sessionID=self.session_id, generationNumber=self.generations,
                        residentModelCount=1, offlineAssetsVerified=self.startup_verified,
                        modelLoadPeakAllocatedBytes=self.load_peak_bytes, initializationPeakAllocatedBytes=self.initialization_peak,
                        snapshotMarker=self.snapshot_marker,
                        sourceAudioProvidedToSynthesis=False, sourceTimingProvided=False)
        # Private Modal logs carry audit metadata, never user text or reference content.
        print(json.dumps(dict(event='qwen_generation', **metadata)), flush=True)
        return dict(audio=data, metadata=metadata)

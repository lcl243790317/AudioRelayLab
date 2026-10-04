# SPDX-License-Identifier: GPL-3.0-only
"""Shared identity registry for local auditions and the optional Modal backend."""
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from revoice_contract import text_for_synthesis

ROOT = Path(__file__).resolve().parent


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


@dataclass(frozen=True)
class Preset:
    id: str
    display_name: str
    variant: str
    speaker: str | None
    instruction: str
    decision: str
    reference_id: str | None = None

    @property
    def enabled(self):
        return self.decision == 'keep'

    def task(self, text):
        task = dict(text=text_for_synthesis(text), seed=20261003)
        if self.variant == 'custom':
            task.update(speaker=self.speaker, instruction=self.instruction)
        return task

    def public(self):
        return dict(id=self.id, displayName=self.display_name, variant=self.variant,
                    speaker=self.speaker, instruction=self.instruction, fixedReferenceID=self.reference_id)


class PresetRegistry:
    def __init__(self, root=ROOT):
        root = Path(root)
        palette, cases = read_json(root/'revoice-palette.json'), read_json(root/'revoice-audition-cases.json')
        decisions = read_json(root/'revoice-review.json')['decisions']
        self.references = read_json(root/'revoice-references.json')['references']
        self.lock = read_json(root/'revoice-lock.json')
        self.presets = {}
        for item in palette['profiles']:
            name = item['id']
            if not re.fullmatch('[a-z0-9-]+', name) or name in self.presets:
                raise ValueError('Invalid or duplicate preset ID')
            decision = decisions[name]
            if decision not in ('keep', 'adjust', 'unreviewed', 'reject'):
                raise ValueError('Invalid review state')
            if item['kind'] == 'accepted':
                speaker = {'serena': 'Serena', 'vivian': 'Vivian'}[item['sourcePrefix']]
                preset = Preset(name, item['label'], 'custom', speaker, cases['customInstruction'], decision)
            elif item['kind'] == 'custom':
                preset = Preset(name, item['label'], 'custom', item['speaker'], item['instruction'], decision)
            elif item['kind'] == 'designed':
                if name not in self.references:
                    raise ValueError('Missing fixed identity reference')
                preset = Preset(name, item['label'], 'base', None, '', decision, name)
            else:
                raise ValueError('Unsupported preset kind')
            if preset.variant == 'custom' and preset.speaker not in ('Serena', 'Vivian', 'Dylan', 'Uncle_Fu'):
                raise ValueError('Unsupported fixed speaker')
            self.presets[name] = preset
        if set(decisions) != set(self.presets):
            raise ValueError('Review states must cover the current palette exactly')

    def get(self, name, *, cloud=False):
        if not isinstance(name, str) or name not in self.presets:
            raise ValueError('Unknown voice preset')
        preset = self.presets[name]
        if cloud and not preset.enabled:
            raise ValueError('Voice preset is awaiting acceptance')
        return preset

    def public_voices(self):
        return [p.public() for p in self.presets.values() if p.enabled]

    def required_variants(self):
        return sorted({p.variant for p in self.presets.values() if p.enabled})

    def verify_reference(self, name, asset_root):
        expected = self.references[name]
        # Filenames are server-owned registry data, never request parameters.
        for field in ('audioFile', 'metadataFile'):
            if Path(expected[field]).name != expected[field] or '/' in expected[field] or '\\' in expected[field]:
                raise ValueError('Reference assets must be plain filenames')
        audio = Path(asset_root)/expected['audioFile']
        metadata_path = Path(asset_root)/expected['metadataFile']
        if digest(audio) != expected['audioSHA256'] or digest(metadata_path) != expected['metadataSHA256']:
            raise ValueError('Fixed reference has changed')
        metadata = read_json(metadata_path)
        if metadata['variant'] != 'design' or metadata['sha256'] != expected['audioSHA256']:
            raise ValueError('Reference identity metadata mismatch')
        text = text_for_synthesis(metadata['text'])
        if hashlib.sha256(text.encode()).hexdigest() != expected['textSHA256']:
            raise ValueError('Reference transcript mismatch')
        model = self.lock['models']['design']
        model_hash = next(f['sha256'] for f in model['files'] if f['path'] == 'model.safetensors')
        if (metadata['modelRepository'], metadata['modelRevision'], metadata['modelSHA256']) != (model['repository'], model['revision'], model_hash):
            raise ValueError('Reference design model differs from the lock')
        return audio, text

    def inventory(self):
        return [dict(**p.public(), review=p.decision, cloudEnabled=p.enabled,
                     needsCustomVoice=p.variant=='custom', needsBase=p.variant=='base',
                     needsVoiceDesignRuntime=False) for p in self.presets.values()]

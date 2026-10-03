# SPDX-License-Identifier: GPL-3.0-only
"""Generate the expanded, text-only local auditions without changing the App or service."""
import argparse
import json
import shutil
from pathlib import Path
from evaluate_revoice import run_worker
from revoice_worker import digest

ROOT = Path(__file__).resolve().parent


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def verify_clip(path, text, reference=None):
    report = json.loads(path.with_suffix('.json').read_text(encoding='utf-8'))
    if digest(path) != report['sha256'] or report['text'] != text:
        raise ValueError('Audio hash or synthesis text mismatch: ' + path.name)
    if report['sourceAudioProvidedToSynthesis'] or report['sourceTimingProvided']:
        raise ValueError('Source voice features must never enter revoicing')
    if reference is not None and report['targetReferenceSHA256'] != digest(reference):
        raise ValueError('Designed voice must reuse its fixed target reference')
    return report


def generate(output, baseline):
    output, baseline = Path(output).resolve(), Path(baseline).resolve()
    palette = json.loads((ROOT / 'revoice-palette.json').read_text(encoding='utf-8-sig'))
    cases = json.loads((ROOT / 'revoice-audition-cases.json').read_text(encoding='utf-8-sig'))['cases']
    # Verify the accepted recordings before creating any new results.
    for profile in palette['profiles']:
        if profile['kind'] == 'accepted':
            for case in cases:
                verify_clip(baseline / (profile['sourcePrefix'] + '-' + case['id'] + '.wav'), case['text'])
    if output.exists():
        raise ValueError('Choose a new output directory; accepted recordings are never overwritten')
    output.mkdir(parents=True)
    custom, designs = [], []
    for profile in palette['profiles']:
        samples = []
        for case in cases:
            name = (profile.get('sourcePrefix') if profile['kind'] == 'accepted' else profile['id']) + '-' + case['id']
            samples.append(dict(id=name, scene=case['id'], text=case['text']))
            if profile['kind'] == 'accepted':
                for suffix in ('.wav', '.json'):
                    shutil.copy2(baseline / (name + suffix), output / (name + suffix))
        if profile['kind'] != 'accepted':
            samples.append(dict(id=profile['id'] + '-role', scene='role', text=profile['roleText']))
        profile['samples'] = samples
        if profile['kind'] == 'custom':
            custom.extend(dict(id=s['id'], text=s['text'], speaker=profile['speaker'],
                               instruction=profile['instruction']) for s in samples)
        elif profile['kind'] == 'designed':
            profile['referenceID'] = profile['id'] + '-reference'
            designs.append(dict(id=profile['referenceID'], text=palette['referenceText'],
                                instruction=profile['designInstruction']))

    write_json(output / 'custom-tasks.json', custom)
    print('Generating fixed-speaker performances: ' + str(len(custom)), flush=True)
    run_worker(['tts', '--variant', 'custom', '--tasks', str(output / 'custom-tasks.json'),
                '--output', str(output)], output / 'custom.log')
    write_json(output / 'design-tasks.json', designs)
    print('Generating new fixed target references: ' + str(len(designs)), flush=True)
    run_worker(['tts', '--variant', 'design', '--tasks', str(output / 'design-tasks.json'),
                '--output', str(output)], output / 'design.log')

    for profile in palette['profiles']:
        reference = None
        if profile['kind'] == 'designed':
            reference = output / (profile['referenceID'] + '.wav')
            verify_clip(reference, palette['referenceText'])
            tasks = [dict(id=s['id'], text=s['text']) for s in profile['samples']]
            task_file = output / (profile['id'] + '-tasks.json')
            write_json(task_file, tasks)
            print('Reusing fixed reference: ' + profile['label'], flush=True)
            run_worker(['tts', '--variant', 'base', '--tasks', str(task_file), '--output', str(output),
                        '--reference', str(reference), '--reference-text', palette['referenceText']],
                       output / (profile['id'] + '.log'))
        for sample in profile['samples']:
            verify_clip(output / (sample['id'] + '.wav'), sample['text'], reference)

    palette['cases'] = cases
    palette['baselineReusedWithoutModification'] = True
    write_json(output / 'audition-manifest.json', palette)
    print('Verified all ' + str(sum(len(p['samples']) for p in palette['profiles'])) +
          ' utterances and ' + str(len(designs)) + ' fixed references.', flush=True)
    from build_revoice_palette_page import make_page
    make_page(output, output / '声线扩展试听.html')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--baseline-dir', default=str(ROOT.parent / 'dist/revoice'))
    args = parser.parse_args()
    generate(args.output_dir, args.baseline_dir)


if __name__ == '__main__':
    main()

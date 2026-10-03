"""Generate bundled test audio and short codec fixtures using our own signal (no user files)."""
import array
import json
import math
import shutil
import subprocess
import wave
from pathlib import Path

root = Path(__file__).resolve().parents[1]
resource = root / 'AudioRelayLab/Resources'
resource.mkdir(parents=True, exist_ok=True)
samples = array.array('h')
for _ in range(3):
    for frequency in [440, 660, 880]:
        for index in range(57330):
            time = index / 44100
            fade = max(0, min(1, time / .01, (1 - time) / .01))
            samples.append(round(32767 * .28 * fade * math.sin(2 * math.pi * frequency * time)) if time < 1 else 0)
with wave.open(str(resource / 'BundledTest.wav'), 'wb') as file:
    file.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
    file.writeframes(samples.tobytes())
folder = root / 'AudioRelayLabTests/Fixtures/generated'
folder.mkdir(parents=True, exist_ok=True)
formats = [('wav', 'pcm_s16le', 'wav'), ('mp3', 'libmp3lame', 'mp3'), ('m4a', 'aac', 'ipod'),
           ('aac', 'aac', 'adts'), ('aiff', 'pcm_s16be', 'aiff'), ('aifc', 'pcm_s16le', 'aiff'),
           ('caf', 'pcm_f32le', 'caf'), ('flac', 'flac', 'flac')]
if not shutil.which('ffmpeg'):
    raise SystemExit('BundledTest.wav generated; ffmpeg is required for codec acceptance fixtures.')
for extension, codec, container in formats:
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(resource / 'BundledTest.wav'),
                    '-t', '1.3', '-c:a', codec, '-f', container, str(folder / ('fixture.' + extension))], check=True)
(folder / 'formats.json').write_text(json.dumps([item[0] for item in formats]), encoding='utf-8')
print('Generated BundledTest.wav (11.7 seconds) and 8 codec fixtures: WAV MP3 M4A AAC AIFF AIFC CAF FLAC')

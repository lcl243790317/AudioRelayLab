# SPDX-License-Identifier: GPL-3.0-only
"""Pure contracts for the audition pipeline: synthesis never receives source audio."""
import math

MAX_INPUT_SECONDS = 60
MAX_OUTPUT_SECONDS = 180
MAX_TEXT_CHARACTERS = 1000
MAX_INSTRUCTION_CHARACTERS = 500
SPEAKERS = {
    'Serena': 'Serena · 温柔女声', 'Vivian': 'Vivian · 明亮女声',
    'Dylan': 'Dylan · 北京青年男声', 'Uncle_Fu': 'Uncle_Fu · 醇厚男声',
    'Eric': 'Eric · 成都男声', 'Ryan': 'Ryan · 活力英语男声',
    'Aiden': 'Aiden · 清朗英语男声', 'Ono_Anna': 'Ono_Anna · 轻巧日语女声',
    'Sohee': 'Sohee · 温暖韩语女声',
}

def safe_unicode(text):
    text.encode('utf-8')
    if any(ord(c) < 32 and c not in '\r\n\t' for c in text):
        raise ValueError('Invalid control characters')
    return text

def custom_task(speaker, text, instruction=''):
    if not isinstance(speaker, str) or speaker not in SPEAKERS:
        raise ValueError('Unsupported speaker')
    if not isinstance(instruction, str) or len(instruction) > MAX_INSTRUCTION_CHARACTERS:
        raise ValueError('Instruction must be at most 500 characters')
    return dict(speaker=speaker, text=text_for_synthesis(text),
                instruction=safe_unicode(instruction), language='Auto', seed=20261003)

def public_speakers():
    return [dict(id=name, displayName=label) for name, label in SPEAKERS.items()]

def text_for_synthesis(text):
    if not isinstance(text, str) or not text.strip():
        raise ValueError('没有可配音的文字，请检查识别结果')
    text = text.strip()
    if len(text) > MAX_TEXT_CHARACTERS:
        raise ValueError('配音文字不能超过 1000 字符')
    return safe_unicode(text)

def synthesis_arguments(variant, task, reference_prompt=None):
    result = dict(text=text_for_synthesis(task['text']), language=task.get('language', 'Chinese'), non_streaming_mode=True)
    if variant == 'custom':
        if task.get('speaker') not in SPEAKERS:
            raise ValueError('Unsupported audition speaker')
        result.update(speaker=task['speaker'], instruct=task.get('instruction',''))
    elif variant == 'design':
        if not task.get('instruction'): raise ValueError('Voice design requires a description')
        result['instruct'] = task['instruction']
    elif variant == 'base':
        if reference_prompt is None: raise ValueError('A fixed target reference prompt is required')
        result['voice_clone_prompt'] = reference_prompt
    else:
        raise ValueError('Unsupported synthesis model')
    return result

def validate_input_duration(seconds):
    if not math.isfinite(seconds) or not .3 <= seconds <= MAX_INPUT_SECONDS:
        raise ValueError('识别输入须为 0.3–60 秒')

def validate_output_duration(seconds):
    if not math.isfinite(seconds) or not 0 < seconds <= MAX_OUTPUT_SECONDS:
        raise ValueError('配音输出长度异常或超过 180 秒；不截断成品')

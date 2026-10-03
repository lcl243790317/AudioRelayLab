# SPDX-License-Identifier: GPL-3.0-only
"""Pure contracts for the audition pipeline: synthesis never receives source audio."""
import math

MAX_INPUT_SECONDS = 60
MAX_OUTPUT_SECONDS = 180
MAX_TEXT_CHARACTERS = 1000

def text_for_synthesis(text):
    if not isinstance(text, str) or not text.strip():
        raise ValueError('没有可配音的文字，请检查识别结果')
    text = text.strip()
    if len(text) > MAX_TEXT_CHARACTERS:
        raise ValueError('配音文字不能超过 1000 字符')
    return text

def synthesis_arguments(variant, task, reference_prompt=None):
    result = dict(text=text_for_synthesis(task['text']), language='Chinese', non_streaming_mode=True)
    if variant == 'custom':
        if task.get('speaker') not in ('Serena','Vivian'):
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

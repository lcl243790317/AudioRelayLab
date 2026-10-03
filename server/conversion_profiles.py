# SPDX-License-Identifier: GPL-3.0-only
"""Named, bounded profiles based on the official Seed-VC V1/V2 interfaces."""
import math

MODES = ("naturalSpeech", "preserveProsody", "balancedV2", "timbrePriority")
DEFAULTS = {
    "naturalSpeech": dict(steps=36, intelligibility=0.7, similarity=0.65, topP=0.7, temperature=0.7, repetitionPenalty=1.2, pitchShift=0),
    "preserveProsody": dict(steps=40, intelligibility=0.7, similarity=0.65, topP=0.7, temperature=0.7, repetitionPenalty=1.2, pitchShift=0),
    "balancedV2": dict(steps=36, intelligibility=0.9, similarity=0.65, topP=0.7, temperature=0.7, repetitionPenalty=1.2, pitchShift=0),
    "timbrePriority": dict(steps=50, intelligibility=1.0, similarity=0.75, topP=0.7, temperature=0.7, repetitionPenalty=1.2, pitchShift=0),
}

def conversion_settings(profile, mode="preserveProsody", overrides=None):
    if mode not in MODES:
        raise ValueError("不支持此转换方式，请更新 App 或重新连接")
    settings = dict(DEFAULTS[mode])
    # Only a specific mode's settings override the shipped recommendation.
    settings.update(profile.get("modes", {}).get(mode, {}))
    overrides = overrides or {}
    allowed = {"steps"}
    if mode in ("balancedV2", "timbrePriority"):
        allowed |= {"intelligibility", "similarity"}
    if mode == "preserveProsody":
        allowed.add("pitchShift")
    if set(overrides)-allowed:
        raise ValueError("当前转换方式不支持此微调参数")
    settings.update(overrides)
    ranges = dict(steps=(20,80),intelligibility=(0,1),similarity=(0,1),topP=(0.5,1),
                  temperature=(0.7,1.2),repetitionPenalty=(1,1.5),pitchShift=(-6,6))
    if set(settings) != set(ranges):
        raise ValueError("电脑音色配置包含未知参数")
    for name,(low,high) in ranges.items():
        try: value = float(settings[name])
        except (TypeError,ValueError): raise ValueError("AI 参数需要有限数字")
        if not math.isfinite(value) or not low <= value <= high:
            raise ValueError("AI 参数超出支持范围：" + name)
        if name == "steps" and value != int(value):
            raise ValueError("生成步数需要整数")
        settings[name] = int(value) if name == "steps" else value
    settings["mode"] = mode
    return settings

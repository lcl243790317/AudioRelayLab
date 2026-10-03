# 自然重新配音：首轮实现与试听

2026-10-03。用户已明确：保留原话，让年轻成年女声以自然、轻妩媚的方式重新说；接受更长处理时间和自由输出时长。自动生成后可改字重做。**当前完成的是试听阶段，声线未验收；尚未接入 App、改变正式音色或发布 1.6.0。**

## 已实现

- 原录音仅进入 faster-whisper large-v3 CPU INT8 识别进程；配音子进程只接受文字、指定声线和固定目标参考。配音参数通过白名单构造，没有原声音高、节奏或录音路径。
- Qwen3-TTS 1.7B CustomVoice 的 Serena、Vivian；1.7B VoiceDesign 生成的年轻成年女性参考，通过 1.7B Base 复用到三个不同句子。三条路径均在本机 RTX 4070 Laptop CUDA / BF16 / SDPA 实际运行，没有降成 0.6B。
- 录音重配音与直接文字配音的独立命令。修改文字入口跳过识别；输入 0.3–60 秒，配音文字最多 1000 字符，输出独立限制最长 180 秒。原话不做语言模型改写或清理重复。
- 成品仅在生成、长度、非静音及文件哈希检查通过后发布；采用不会覆盖已有文件的原子发布。子进程失败、超时或 Ctrl+C 时不会把正在生成的内部文件发布为成品。
- 模型版本和 38 个配置/权重文件哈希见 `server/revoice-lock.json`。独立环境额外依赖单独安装，仅通过只读路径复用原 Seed-VC 环境的 PyTorch 等；原环境未升级。源码仓库引用与实际安装的 PyPI qwen-tts 0.1.1 分别记录。

## 可复查证据

`dist/revoice/自然重新配音试听.html` 内嵌 20 段音频，包含三个候选的同文试听、真人原声与重新配音、不同原节奏、影视对白错字、短句、长段落、60 秒输入和修改文字。

- 17 个真实生成 WAV 的 SHA-256 逐一验证；完整参数、目标参考哈希、实际时长、耗时和显存信息保存在同名 JSON。
- 原声 24.35 秒与加速后 20.29 秒，经识别得到完全相同文字；两次独立配音都是 17.36 秒，**文件 SHA-256 完全相同**。这验证了本轮配音不沿用源音频节奏与声纹的输入路径。
- 60 秒真人素材拼接输入经过完整流程，输出 41.20 秒，总耗时 110.62 秒；仅用作时长边界验证，不评价该拼接内容的自然度。
- 459 字长段落输出 94.64 秒，模型生成耗时 197.72 秒；未对齐原声、未截断至 60 秒。
- 修改文字测试输出 8.48 秒，总耗时 24.08 秒，metadata 的 recognition 为 null；没有再次识别原声。
- 39 项 Python 回归测试通过，含原声特征隔离、独立时长、原话/重复保留的文字边界、改字跳过识别、失败不发布，以及其他写入者文件保护。
- 离线页通过独立无头 Edge：播放器元数据、不同声线时长、切换从头开始、反馈持久化与下载、1040px/390px 布局、无横向溢出和无 JavaScript 错误。桌面/手机截图已实际检查。

本轮配音峰值 CUDA 分配显存约 4.65 GiB，实际按模型串行运行。实验前暂时停止本项目闲置的旧 GPU 服务，每个阶段在 finally 中恢复；当前原服务认证接口和原六个正式音色均可访问，模型等待下一任务加载。没有运行新的 iOS 构建；原 1.5.1 安装包和上一轮构建证据保持原版本。

| 样本 | 输出时长 | 模型生成耗时 | 路径 |
|---|---:|---:|---|
| corrected-text | 8.48s | 16.61s | custom |
| designed-chat | 5.52s | 10.72s | base |
| designed-mixed | 11.52s | 21.90s | base |
| designed-reference | 8.88s | 17.39s | design |
| designed-soft | 9.20s | 17.80s | base |
| pipeline-60s | 41.20s | 77.59s | custom |
| pipeline-dialogue | 16.80s | 32.31s | custom |
| pipeline-male-fast | 17.36s | 41.03s | custom |
| pipeline-male | 17.36s | 45.64s | custom |
| serena-chat | 7.20s | 14.96s | custom |
| serena-long | 94.64s | 197.72s | custom |
| serena-mixed | 14.80s | 29.32s | custom |
| serena-short | 1.52s | 2.91s | custom |
| serena-soft | 9.76s | 19.73s | custom |
| vivian-chat | 11.92s | 23.02s | custom |
| vivian-mixed | 14.56s | 27.58s | custom |
| vivian-soft | 15.12s | 28.85s | custom |

模型生成耗时不含每次进程启动和 CPU 识别；完整流程耗时以 JSON 的 pipelineSeconds 为准。

## 实际发现与验收要求

影视对白 ASR 对“雍军/庸君”“党政/党争”和人物名字存在疑点；本轮保留原始识别文字，没有悄悄修正。辅助 ASR 还把包含“嗯，嗯”的短句识别成“好的”，改字样本的“嗯”也未被识别出来，不能据此断定是模型漏读还是 ASR 过滤，请回听短句。长段落辅助识别没有发现整句遗漏，唯一文字差异为同音的“它/他”。这些检查均不能代替声音自然度和逐字回听。

三种候选尚未判定为自然、完美或用户认可；设计指令描述年龄和气质，不保证实际听感。真人输入仍采用固定 Seed-VC 版本的公开解说/影视对白示例，最终需要用户本人正常说话的适配测试。权重和示例音频保留本地，不上传 GitHub。

验收后才实施手机“停止录音后自动生成”、识别文字编辑、局域网接口、队列取消/恢复、长成品保存/混音、旧服务兼容及 1.6.0 构建。三个候选都不满意时继续筛选，不发布新音色。

## 本机复现

在项目根目录 PowerShell 中使用已有 Seed-VC Python 安装锁定环境：

```powershell
.\server\.venv\Scripts\python.exe -X utf8 server/setup_revoice_audition.py
```

整套试听可生成到一个新目录。运行前确保原电脑 AI 没有任务，临时释放其 GPU；结束或失败都恢复它：

```powershell
try {
    .\server\run.ps1 -Stop
    .\server\.runtime\revoice\venv\Scripts\python.exe -X utf8 server/run_revoice_auditions.py --output-dir dist/revoice-rerun
} finally {
    .\server\run.ps1
}
```

单独测试本人录音，或修改文字重做，输出须为新的 WAV 路径：

```powershell
.\server\.runtime\revoice\venv\Scripts\python.exe -X utf8 server/evaluate_revoice.py --input '我的原声.wav' --voice Serena --output dist/revoice/my-voice.wav
.\server\.runtime\revoice\venv\Scripts\python.exe -X utf8 server/evaluate_revoice.py --text '修改后的原话。' --voice Serena --output dist/revoice/my-corrected.wav
```

声线可选 Serena、Vivian、Designed。Designed 需要本轮 `dist/revoice/designed-reference.wav` 及同名 metadata；两者哈希不匹配会拒绝执行。

官方来源：[Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)、[faster-whisper](https://github.com/SYSTRAN/faster-whisper)。模型具体仓库、版本和哈希以锁文件为准。

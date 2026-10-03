# AudioRelayLab 1.3：电脑 AI 与声音工坊

本轮在原仓库增量开发。自然度优先的路径是 **录原声 → 电脑 Seed-VC v2 转换 → 手机回听、混音、延迟播放**。这是录音后转换，手机实时路径仍使用 Signalsmith DSP。

## 这台电脑现在怎么用

1. 本机依赖已经安装到 `server/.venv`，官方模型已经实际下载并运行。`server/run.ps1` 启动的服务监听 7867 端口。
2. 打开 `server/CONNECTION-ZH.txt`，复制电脑地址和连接密钥。手机与电脑接同一 Wi-Fi，在 App 的「变声 → 电脑 AI → 连接我的电脑」填入这两项。
3. 点击「录制原声」，在安静环境正常说话，然后「停止并保留原声」。每段 0.3–25 秒，24 秒自动保存；原声不会预先经过变调，也不会现场监听。
4. 选择「自然女声」，点击「生成 AI 声音」。首次等待可能包含模型加载；页面显示真实的排队、加载、转换状态。完成后可以回听、应用到音频页，或选择背景音乐保存混音。
5. 其他纯人声音频可先在音频页导入，再在变声页点击「使用当前音频」。长文件可在音频页应用起点并在高级设置限制源时长。只有主动点击生成，才发送选中的录音到配置的电脑。

若手机连接失败，确认电脑地址对应当前 Wi-Fi，而不是 VPN/虚拟网卡；在 Windows 提示中允许本项目 Python 在专用网络接收连接。程序不自动修改防火墙。停止本项目服务：`powershell -File server/run.ps1 -Stop`；再次启动：`powershell -File server/run.ps1`。

## 音色来源与参数

| 音色 | 实际参考 | 用途 |
|---|---|---|
| 自然女声 | QwenAudio / CosyVoice 官方 `asset/zero_shot_prompt.wav`，中文，3.48 秒；仅转换 float WAV 为 PCM16 | 首选实际参考音色 |
| 清亮女声（未启用） | 此 Windows 的 Microsoft Yaoyao 中文合成语音 | 检查出现重复词，已移出默认列表 |
| 温柔女声（未启用） | 此 Windows 的 Microsoft Huihui Desktop 中文合成语音，语速 -1 | 检查出现重复词，已移出默认列表 |

官方示例来源、固定提交、原文件 SHA-256 见 `server/reference-lock.json`，仓库 Apache-2.0 文本见 `server/COSYVOICE-LICENSE.txt`。后两个参考在本机生成，未放入 Git 或 IPA。它们并非中国收费调音师的私有音色。

AI 使用 30 diffusion steps、intelligibility CFG 0.7、similarity CFG 0.7、top-p 0.9、temperature 0.85、repetition penalty 1.0、convert_style=True。它们是固定模型的推理参数，不是手机 DSP 的 pitch/formant 参数。App 每个结果保存实际引擎、模型源码版本、参考来源、参数、处理时间与 WAV 哈希。

实际样本用本地 Whisper-small 做了中文识别对比。自然女声保留主要语句，但专有名称有识别误差；合成参考的两种结果出现明显重复词或漏词，因此只启用一个默认女声。识别结果、基频和幅度见 `dist/ai-samples/actual-audio-analysis.json`；识别正确不等价于听感自然。

可在 `server/.private/references` 放置有使用权限的清晰参考，再在 `.private/voices.json` 增加/替换对应项，重启服务并让 App 重新读取音色。应选纯人声、无背景音乐、无明显混响的短参考；避免把 Windows 合成参考的自然度当作真人目标。

## 已完成的实际验证

本机 NVIDIA GeForce RTX 4070 Laptop GPU，PyTorch 2.5.1+cu124；模型源码固定为 `51383efd921027683c89e5348211d93ff12ac2a8`。

- 同一段本地 Microsoft Kangkang 中文男声输入，分别生成三种 WAV；自然女声 13.15 秒 / 10.17 秒计算，清亮女声 15.62 秒 / 12.25 秒计算，温柔女声 16.07 秒 / 12.55 秒计算。加载模型 8.41 秒。AR 风格转换会改变停顿与长度。
- 实际带认证 HTTP 服务完成上传 → CUDA 模型 → 下载 → SHA-256 一致，含加载总等待 20.19 秒；这不是测试替身的结果。
- 可回听文件在 `dist/ai-samples`：`male-source.wav`、三个 `female-*.wav`、`phone-api-result.wav`。机器与参数证据为 `actual-inference.json` 和 `actual-api.json`，日志在 `server/.logs`。
- API 的认证、非法/截断 WAV、长度、音色白名单、参考路径、取消、下载哈希有独立契约测试；这些测试使用显式测试替身，与上面的真实 GPU 证据分开。

目前输入验证使用合成男声，尚未验证你的真人原声与手机 Wi-Fi 连接。自然度、性别听感和是否暴露原声需要用实际原声回听，不能由编译成功或频率数值证明。「完美」「所有男声都听不出来」不作为未经验证的承诺。

## 手机本地模式与 UI

手机实时模式保留 15 个预设和实时混音。女声起始 pitch 调整为 5–11 半音，同时控制共振峰、低中频与去齿音；可测量已有原声的基频，对不同低男声计算不同移调量。可独立微调音高与共振峰，本地 DSP 仍会保留部分原说话人特征。

UI 改为「音频 / 变声 / 资料」三个入口。Mixer 开关位于手机实时模式，AI 人声另有保存背景音乐混音功能；历史、录音库、日志统一进入资料。纸张色、衬线标题、灰色方形按钮、细线和轻阴影参考用户图片，高级设置折叠保留。

## 另一台 Windows 电脑安装

需要 Python 3.12、较新的 NVIDIA 驱动，以及足够的磁盘和显存；本轮实际验证为 8 GB 显卡。运行 `powershell -File server/setup.ps1 -Python C:\实际路径\python.exe`。安装只使用项目私有虚拟环境。若没有上述中文 SAPI 音色，可手动提供参考文件和配置，不需重新建立 iOS 项目。

Seed-VC 服务为独立 GPL-3.0 进程，其固定源码与协议实现均可获得，许可证见 `server/LICENSE-GPL-3.0.txt`；iOS App 通过 HTTP 交换 WAV。服务不回退到假结果，模型加载、推理或文件校验失败会报告实际错误。

研究来源：[RVC 中文项目](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI)、[Seed-VC 中文说明](https://github.com/Plachtaa/seed-vc/blob/main/README-ZH.md)、[CosyVoice 官方转换示例](https://github.com/QwenAudio/CosyVoice/blob/main/example.py)。Seed-VC 仓库已归档，使用固定版本。iOS 局域网配置遵循 [Apple NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)，没有启用全局任意 HTTP 放行。

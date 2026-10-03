# AudioRelayLab 1.4.0：本机 AI 对比记录

## 输入与环境

本轮输入为 Microsoft Kangkang / Windows 本地合成中文男声，13.81925 秒，不是用户的真人录音。GPU 为 RTX 4070 Laptop 8 GB，PyTorch 2.5.1+cu124。引擎来源固定为 Seed-VC 51383efd921027683c89e5348211d93ff12ac2a8。六个独立参考的来源及原文件 SHA-256 在 server/reference-lock.json。

实际运行了 13 次最终模式推理（覆盖四种模式、六个独立参考、切回已使用模型），另有两次淘汰路径对比。最终四种模式均关闭 AR 表达重写，参数写在每份实际推理 metadata 中。二进制样本和完整 JSON 证据保存在本机 dist/voice-1.4，未提交到仓库或嵌入 IPA。

## 中文识别与音高走势

用本机 Whisper-small 识别及 librosa pyin 分析；去标点后按原始字符计算编辑差异。简繁体、同音字和专名差异仍会计入，所以这个数不能直接当作漏字率，也不能当作自然度评分。音高相关性是对齐的有声帧 log F0 相关性，不代表情绪、发音或说话人相似度。

| 实际样本 | 原始识别字符差异 | F0 中位数 Hz | 与原声 F0 走势相关性 |
|---|---:|---:|---:|
| 1-naturalSpeech-female-natural | 0 | 308.3 | 0.935 |
| 2-naturalSpeech-female-cn | 0 | 255.5 | 0.800 |
| 7-preserveProsody-female-natural | 0 | 279.5 | 0.994 |
| 8-preserveProsody-female-cn | 0 | 215.5 | 0.989 |
| 9-balancedV2-female-natural | 0 | 283.5 | 0.854 |
| 10-balancedV2-female-cn | 2 | 255.5 | 0.547 |
| 14-timbrePriority-female-natural | 2 | 303.9 | 0.852 |
| 15-timbrePriority-female-cn | 20 | 249.7 | 0.708 |

自然说话模式下的四个女声参考，以及中性 OpenVoice 参考，本段识别文本与原声去标点后相同。F0 模式两种中文参考的走势相关性约 0.994 和 0.989。V2 与音色优先部分样本出现“接力/介立”“平常/屏长”等识别差异，保留这些结果，未宣称逐字完美。最后一行的 20 处原始差异包含 16 处简繁转换和 4 处同音/近音识别差异。

AR 表达重写在清雅参考上把输出拉长至约 28.57 秒，并出现明显重复和内容丢失，因此没有作为可选功能发布。这也是第四项改为“音色优先 · 调校”而关闭重写的原因。

## 实际认证 HTTP 连续验证

更新后的真实服务（protocolVersion 3）连续处理五个任务，每次先重新读取健康状态。覆盖四种模式、V2 自定义参数、不同长度以及回到 Speech 模型。五次任务全部完成；输出 WAV 的 SHA-256、单声道 PCM16、22.05/44.1 kHz、源/输出时长差与 metadata 参数全部校验通过。五次重连使用同一工作进程，最后状态 ready / CUDA。

| 模式 | 参考 ID | 总等待秒 | 输出秒 | 生成步数 |
|---|---|---:|---:|---:|
| naturalSpeech | female-natural | 13.59 | 13.819 | 36 |
| preserveProsody | female-cn | 12.00 | 13.819 | 40 |
| balancedV2 | female-natural | 11.50 | 13.819 | 40 |
| timbrePriority | female-cn | 9.35 | 13.819 | 50 |
| naturalSpeech | female-neutral | 6.75 | 5.500 | 36 |

这里的等待包含本机模型加载/切换与推理，不能代表另一台电脑的速度。完整任务编号、SHA-256 和参数保存在 http-api-evidence.json。

## 真人仍需试听

先使用“自然女声 · 中文 / 清雅女声 · 中文 + 自然说话”，用同一段你自己的录音比较四种模式。若原口气最重要，用“严格保留语调”；V2 可用于比较音色和咬字。不会因为识别文字相同或基频升高，就保证听起来是自然女生。手机 DSP 另有真实信号回归，但现场延迟和真人自然度仍须 iPhone 实测。

来源：[Seed-VC 中文说明](https://github.com/Plachtaa/seed-vc/blob/51383efd921027683c89e5348211d93ff12ac2a8/README-ZH.md)、[V1 推理](https://github.com/Plachtaa/seed-vc/blob/51383efd921027683c89e5348211d93ff12ac2a8/inference.py)、[V2 推理](https://github.com/Plachtaa/seed-vc/blob/51383efd921027683c89e5348211d93ff12ac2a8/inference_v2.py)。

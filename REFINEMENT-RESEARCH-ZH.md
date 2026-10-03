# 社区女声 refinement 首轮评估

后续反馈：用户已拒绝本轮 A、B，方向改为文字驱动的自然重新配音。本文件保留为 RVC 实验记录；当前进展见 [重新配音评估](REVOICE-RESEARCH-ZH.md)。

2026-10-03。目标为自然女声附加成熟妩媚气质，保留原话、停顿与语调。**当前结论：已完成真实 GPU 候选试听，没有任何声线被判为完美或加入正式服务。** 清冷/可爱是后续筛选方向，本轮先验收成熟妩媚。

## 当前可交付

- App 1.5.1/build 9 的两个库倒序、直接选库、独立试听和简单/高级入口已经通过真实构建：162 XCTest、30 Python，Swift 警告 0。
- 离线试听页：`dist/refinement/试听对比.html`。包含 10 段原声/转换；同位置切换、7/3 个选项、听感持久化、手机宽度和 JavaScript 错误检查已通过独立无头 Edge；桌面/手机截图已检查。电脑操作插件因 Windows 沙箱启动故障未能打开页面，界面验证使用独立测试浏览器，不操作用户浏览器。
- RVC 共 7 次成功推理：两种声线各自低男声 +8/+10、较高音域对白 +2，以及雅琳 60 秒长度验证。另有 2 次现有服务的认证 Seed-VC 基线转换，下载 SHA-256 已核对。

## 具体候选与来源

候选 A：[chaye741/RVC-Voice-Models](https://huggingface.co/chaye741/RVC-Voice-Models/tree/acfd9f836ca1fc862a594bc303cfccee8d565e94)，女声-雅琳御姐，48 kHz RVC v2，配有 768 维、64098 个向量的真实索引。

候选 B：[lowo/RVC-weights](https://huggingface.co/lowo/RVC-weights/tree/8ff8d75d1cb5bf96116ac2eb63ebe8ff62d98f7c)，`!!For_yaorao 御姐.zip` 内的原版 `yaoraoFor.pth`，40 kHz RVC v2。压缩包另有 01–04 融合版本，没有附带索引；本轮使用原版和 0 索引，不自行给它配别的音色索引。仓库标注 AGPL-3.0，不据此推断原训练录音获得任意使用授权。

推理实现：[官方 RVC](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI/tree/81eed5e8f68b6bed1789f682fe78cdd324495afc)，固定源码版本。HuBERT 与 RMVPE 来自官方文档指向的 `lj1995/VoiceConversionWebUI`，也固定版本和哈希；见 `server/refinement-lock.json`。

两组输入来自固定版本 Seed-VC 的 `examples/source/source_s3.wav`（24.35 秒解说男声）和 `source_s4.wav`（22.26 秒对白男声）。它们是真人公开示例，不是本机合成男声；解说和影视对白不等于普通日常对话。示例的原演出者授权及候选训练数据授权尚未独立确认，因此只保留本地评估文件，不把权重、参考或这些音频上传到仓库/随 App 分发。

## 运行证据

| 样本 | 输入 / 输出秒数 | 本机总耗时 | 参数 |
|---|---:|---:|---|
| duration-yalin-60s | 60.000 / 59.980 | 8.91s | +8 半音，索引 0.65 |
| yalin-dialogue-p2 | 22.257 / 22.240 | 7.93s | +2 半音，索引 0.65 |
| yalin-p10 | 24.349 / 24.340 | 7.97s | +10 半音，索引 0.65 |
| yalin-p8 | 24.349 / 24.340 | 8.09s | +8 半音，索引 0.65 |
| yaorao-dialogue-p2 | 22.257 / 22.240 | 6.55s | +2 半音，索引 0 |
| yaorao-p10 | 24.349 / 24.340 | 6.52s | +10 半音，索引 0 |
| yaorao-p8 | 24.349 / 24.340 | 6.53s | +8 半音，索引 0 |

上述耗时包含独立 CLI 启动与模型加载，设备为 RTX 4070 Laptop 8 GB。本机现有 Seed-VC 服务一直在运行，没有重启或改正式音色配置。60 秒输入是重复拼接的公开真人素材，只用于长度验证，不作为自然度评价；输出 59.98 秒，末尾约 20 ms 差异仍需试听留意。

Seed-VC 基线使用当前 `female-natural`：自然说话约 4.19 秒，保留语调约 13.31 秒。RVC 接收原公开 WAV，Seed 基线按现有协议重采样为 22.05 kHz PCM16；没有 TTS 重写或二次神经转换。原声、转换及实际参数均保存在 `dist/refinement`，各 RVC 样本 JSON 包含模型/索引/输入/输出哈希，Seed JSON 为实际任务 metadata。

Whisper-small 与基频分析记录见 `dist/refinement/analysis.json`。RVC 解说候选测得中位基频约 189–217 Hz，现有 Seed 结果约 284–297 Hz；不同采样/识别路径对原声的估计也有差异，数字不能替代女性自然度或妩媚气质试听。ASR 在原声中也误识别电影名和人名，不以文字完全相同打分。雅琳部分末句出现识别疑点，妖娆也有词形差异；重点人工比较原声末句、s/sh/t 辅音、气口和对白轻重音，不能宣称咬字完全一致。

## 已处理的环境问题

Windows FAISS/OpenMP 与 PyTorch 在同一进程发生真实运行库冲突。使用 `server/rvc_isolation` 将索引读取、重构和检索放入仅加载 FAISS 的子进程，RVC 仍执行真实 FAISS 搜索；没有使用允许重复 OpenMP 运行库的环境开关。检索维度、重构形状及向量自身零距离检查通过。权重使用 `weights_only=True` 检查，推理子进程也强制安全加载。

安装环境位于 Git 忽略的 `.runtime/refinement/venv`，额外包独立安装，通过只读 .pth 复用现有 PyTorch 等依赖。可复现安装入口为 `server/setup_rvc_audition.py`，逐个核对源码 ZIP、权重、索引、基础模型和压缩包哈希；重复执行已验证。

## 接入门槛

先在试听页选择喜欢的候选，或者明确这些都不满意。只有用户认可且素材使用条件核实后的声线才进入正式音色列表；然后接入现有单队列电脑服务、按音色提供推荐配置，并验证 60 秒、短音频、模型切换、取消及失败恢复。当前没有额外手机协议字段，也没有未经验收的气质滑块。最终还需要用户本人正常说话的适配试听。

## 代码与功能简化检查

现有复杂度主要集中在协调器和音频会话/引擎、AI 请求恢复，以及手机 DSP；不能仅按文件大小删除这些状态保护。本轮把 AI 生成/混音页面从实时调音页面分离，复用现有音频库作为输入选择，统一库排序；回听与使用分开，去掉默认双步准备，技术模式和细调参数收进高级入口。现有播放器、混音和实验记录保留；没有引入大范围架构重写或新通话能力承诺。

## 本机复现命令

在项目根目录的 PowerShell 中执行，安装器要求已有的 Seed-VC Python 环境：

```powershell
.\server\.venv\Scripts\python.exe -X utf8 server/setup_rvc_audition.py
```

生成新的雅琳试听，输入须为 0.3–60 秒音频，输出路径不能已存在。根据原声音域调整半音值；以下 +8 仅为本轮低男声参数：

```powershell
$auditionRoot = Join-Path $PWD 'server/.runtime/refinement'
$auditionRevision = '81eed5e8f68b6bed1789f682fe78cdd324495afc'
& "$auditionRoot/venv/Scripts/python.exe" -X utf8 server/evaluate_rvc.py --upstream "$auditionRoot/Retrieval-based-Voice-Conversion-WebUI-$auditionRevision" --revision $auditionRevision --model "$auditionRoot/yalin.pth" --index "$auditionRoot/yalin.index" --input '你的原声.wav' --output 'dist/refinement/我的新试听.wav' --pitch 8
```

转换妖娆时把模型改为 `yaorao.pth` 并去掉 `--index` 参数。完整哈希、版本和下载地址在锁文件中；这些命令仅生成本地文件，不注册正式音色。

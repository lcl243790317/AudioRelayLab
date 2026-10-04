# AudioRelayLab 1.6.0：GPU snapshot 对照与云端验收

**最终启用 GPU snapshot**。CustomVoice 与 Base 的冷启动中位数均降低至少 30%；恢复、切换与输出校验通过。保持一个 L4、min=0/max=1/buffer=0、生成并发 1，GPU/CPU 空闲窗口均为 120 秒。

## 串行 A/B

同一 App 与固定短句“你好，今天过得怎么样？”，先关闭 snapshot，后开启；模型仍是固定 Qwen3-TTS 1.7B BF16/SDPA，未修改依赖或推理算法。每次等待无 runner/input/backlog/headroom，并根据新 session 与 generationNumber=1 判定冷启动。

| 模型 | 关闭 snapshot 两次（秒） | 已确认恢复三次（秒） | 中位数（秒） | 降低 |
|---|---|---|---|---|
| CustomVoice / Serena | 45.28, 89.28 | 25.81, 24.71, 24.60 | 67.28 → 24.71 | 63.3% |
| Base / 清润书生 | 70.71, 65.78 | 33.00, 35.39, 35.19 | 68.24 → 35.19 | 48.4% |

首次捕获在平台日志中耗时 **204.10 秒**（Creating GPU memory snapshot → Snapshot created，含捕获前初始化与预热）；首次包含捕获的完整请求 **227.18 秒**，单独记录，不计入恢复中位数。原始时间戳和恢复消息见 [平台捕获与恢复时间戳](validation/revoice-1.6.0/platform-snapshot-timestamps.json)。后续使用相同 snapshotMarker、新 session、计数归零及实际 CUDA 输出确认恢复；平台也记录 Restoring Function from memory snapshot。

共 **13 次冷启动测试请求**，包含两个排除样本，低于 16 次上限。一次控制面显示零 runner 但仍有 headroom，实际复用旧 session，作为热请求排除；随后补齐真正 Base 冷启动。一次首次部署的模式未传入远端模块，已修复 image 环境并重部署；失败样本与修复原因保留，没有作为有效 snapshot 样本。

A/B 结束后继续在同一热 session 补测声线，延长了活动时间，旧监控器以 A/B 完成时刻计时的最终 idle 等待因此到期。该失败原报告完整保留为 [原监控报告](validation/revoice-1.6.0/snapshot-original-monitor-report.json)。补测结束后另行确认缩零，之后十个 HTTP 负向请求与独立新查询仍为零；冷启动样本、中位数、恢复证据没有重新生成或替换。最终复核详情见报告的 `finalIdleMonitor`。

所有对照 WAV 完整验证采样率、单声道 PCM16、非静音、真实正时长和 SHA256；相同模型/文字的 A/B 输出 SHA 与基线一致。Base 缓存两组固定参考 prompt，CustomVoice/Base 互切时只保留一个 GPU 模型，重新加载核验文件哈希。

## 真实 L4 与费用

空闲 110 秒后仍复用同一 session、modelLoadSeconds=0。停止请求后确认 runner、running input、backlog、headroom 全部为零。实际终止延迟见原始 scaleToZero 列表；120 秒不是精确关机时刻。

初始化/捕获峰值 **4.075 GiB**；模型加载/参考构建峰值 **4.075 GiB**；生成峰值 **4.292 GiB**。这些是 PyTorch CUDA allocated 峰值，不含全部驱动/context 占用；L4 型号、固定 revision、离线资产与单模型驻留均有真实日志证据。

工作区 metered cost 从上一轮结束的 $0.13108351 到本轮结束的 **$1.04108801**，差值约 **$0.91000450**；抵扣后当前 billed cost 为 **$0.00**。账单可能滞后且为整个工作区。L4 实际 rate 仍约 $0.80/GPU 小时；未购买 credits、升级套餐或增加常驻 GPU。

六个预设由 A/B 两个声线与补充四个 smoke 覆盖；九个 speaker 均通过 `/v1/tts/custom` 实际生成。十个 HTTP 负向请求覆盖双层认证、白名单、空文字、长度、原音频字段、预设覆盖与 body 大小；前后 GPU 仍为零。详情见 [真实声线与 HTTP 验证记录](validation/revoice-1.6.0/gpu-smoke-report.json)；测试只证明接口/模型/输出完整性，不代替自然度试听。

## iOS 构建与交付

构建提交 `8d80b9b6ffc8f5556a1902206b3059f3af5c471b`，分支 `feature/revoice-ios-1.6.0`。由于浏览器工具不可用、本机没有 GitHub CLI 登录，使用[草稿 PR](https://github.com/lcl243790317/AudioRelayLab/pull/1)的现有 CI 触发；checkout 显式选择 feature head，构建证据使用实际源码 SHA，main 未合并。[实际构建](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37171526393)通过 **179 XCTest / 72 Python**、Simulator Debug 与 iPhoneOS Release，Swift 编译警告 0。预设与自定义页面的实际截图已检查。

无签名 IPA：`dist/AudioRelayLab-1.6.0-unsigned.ipa`，1.6.0/build 10，1211400 字节。SHA256：`0dfbd163cb66b766ad46b363a8050096aed530f785e9f0b2e92ce51599f3a4cf`。重新检查 arm64 iPhoneOS、最低 iOS 17、无签名、后台音频、麦克风/语音识别用途描述；逐值扫描真实凭据均未命中，包内无模型权重。

识别拒绝/不可用、改字不再次识别、更换录音不串用文字、只提交文字/目标参数、失败后手动重试、同源303与跨域拒绝、停止等待丢弃迟到结果、90秒完整保存与混音、181秒拒绝保存及旧元数据兼容，都有自动测试。真实 iPhone 的识别准确度、重签权限和自然度由用户验收；没有将模拟器替代真机。安装与私有连接 JSON 导入见 [REVOICE-1.6-ZH.md](REVOICE-1.6-ZH.md)。

原始[A/B 及最终复核报告](validation/revoice-1.6.0/snapshot-report.json)、[云端隐私与资产审计](validation/revoice-1.6.0/cloud-audit.json)、[IPA 审计](validation/revoice-1.6.0/ipa-audit.json)随本分支保存；不包含凭据、权重或私有参考 WAV。

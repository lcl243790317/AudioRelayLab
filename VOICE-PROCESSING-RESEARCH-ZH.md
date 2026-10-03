# 1.3.0 自然度优先增量

本轮采用电脑 Seed-VC v2 + 官方中文参考录音，已在本机显卡生成实际 WAV 并通过真实 HTTP 服务下载验证。完整来源、参数、样本、局限与安装见 [AI-VOICE-GUIDE-ZH.md](AI-VOICE-GUIDE-ZH.md)。以下为已有 DSP 研究历史，其参数不等价于神经模型。

# Voice Lab 技术研究与实现

本轮实现边界：iOS 17.0 deployment；正式功能仅使用 iOS 18.1.1 已有公开 API。DSP 在设备本地运行，不上传音频。自然度和实际延迟仍需真机回听，本文件中的预设是调校起点。

## 研究与选择

基频主要影响音高；共振峰和频谱包络影响元音与声道听感。直接整体移频容易同时改变两者。Apple 的 [AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch) 提供 pitch/rate/overlap，适合普通音乐倍速；公开参数没有独立 formant 调节。本项目据此将普通播放与人声处理分开。

[Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) 的官方 API 支持 pitch、formant、延迟查询及分摊频谱计算。选用固定版本源码，独立设置 pitch/formant 并启用 pitch compensation。它的包络修正也有局限，不能当作精准的人声身份转换。

本项目实际固定的头文件在 `setFormantBase(0)` 时自动估计基频；这个行为由固定源码确认，不能仅凭网页示例推断所有版本。没有使用神经网络、云端 voice cloning 或额外模型。

辅助处理由本项目 C++ 实现：高通清除低频、低中频清理、presence/air 整形、包络压缩、软噪声门与高频能量去齿音。它们是轻量近似滤波，不是精密多段母带处理。机器人预设另加 45 Hz 环形调制，允许明显人工效果。

Apple 的 [AVAudioSourceNode](https://developer.apple.com/documentation/avfaudio/avaudiosourcenode) 用于输出处理后的 PCM；[AVAudioUnitEffect](https://developer.apple.com/documentation/avfaudio/avaudiouniteffect/init(audiocomponentdescription:)) 包装公开 DynamicsProcessor。输出设置 -3 dB 阈值、0.1 dB headroom、1 ms attack、50 ms release。DSP 自身限制 ±0.98；音乐与人声相加后由动态处理器保护，不宣称零瞬态峰值保证。

## 实际 graph 与线程

```text
inputNode tap → 下混单声道 → 高通 → Signalsmith pitch/formant
 → EQ → 压缩/软门/去齿音 → 可选环形调制 → 对齐的 dry/wet → gain
 → SPSC PCM ring → AVAudioSourceNode → Voice Mixer ─┐
音乐 AVAudioPlayerNode → TimePitch → Music volume ──┤
                    mainMixer / Master → DynamicsProcessor
                      ├→ recording tap → SPSC ring → 后台 CAF writer
                      └→ Monitor Mixer → outputNode
```

输入、输出及录音回调只做 PCM / DSP / ring 操作。主线程管理会话、图和界面；专用队列写文件。原子参数、ring 索引要求无锁，编译期检查。配置、缓冲预分配和 DSP 预热在启动前完成；每块最多 512 帧。pitch/formant/EQ/dynamics/wet/gain 等约 40 ms 平滑；原生 mixer 音量及音乐 seek 不保证无可闻跳变，需回听。

频谱块选不小于采样率 × 40 ms 的 2 次幂、hop 为块长 / 4，启用 split computation。界面显示库报告的 DSP 延迟，以及 session input/output latency；总端到端延迟还含 ring、IO 和动态处理器，必须测量，不能直接把三个显示值相加称为实测值。频域方法可能有瞬态涂抹、齿音或低音失真；极端预设应逐人调弱。

实时监听默认需耳机；扬声器需主动启用并从低 Master 开始。录制默认静音现场监听，保存处理后 PCM。后台开关开启时允许真实音频继续，关闭则切后台时停止并保存录音；中断、路由、图配置、媒体服务变化仍安全结束并丢弃未完整录音，提示手动重启。新启动重新验证硬件格式，不复用旧图。

## 15 个预设

Pitch / formant 单位为半音；三项 EQ 为 dB。完整动态、去齿音、wet/gain/robot 参数集中在 `VoicePreset.swift`，录制时参数变化另存事件时间线。

| 预设 | Pitch | Formant | 高通 Hz | Low-mid / Presence / Air |
|---|---:|---:|---:|---|
| 原声 | 0 | 0 | 20 | 0 / 0 / 0，wet=0 |
| 自然女声 | 3 | 1.8 | 100 | -2.5 / 1.5 / 1 |
| 少女声 | 4.5 | 2.5 | 110 | -3 / 2 / 1.5 |
| 萝莉音 | 6 | 3.2 | 130 | -4 / 2 / 1 |
| 甜美女声 | 2.5 | 2.2 | 80 | -1.5 / 1 / 2 |
| 成熟女声 | 1 | 0.8 | 70 | 0 / 1 / 0.5 |
| 正太音 | 3.5 | 1.4 | 100 | -1 / 1.5 / 0.5 |
| 自然男声 | -2.5 | -1.5 | 65 | 1 / 1 / 0 |
| 青年男声 | -1 | -0.8 | 75 | -1 / 2 / 0 |
| 磁性男声 | -3 | -1.8 | 55 | 2 / 0.5 / 0 |
| 低沉男声 | -4.5 | -2.5 | 50 | 2.5 / -1 / 0 |
| 清晰人声 | 0 | 0 | 100 | -3 / 3 / 1 |
| 广播人声 | -0.5 | -0.3 | 70 | 1.5 / 2 / 0 |
| 电话音 | 0 | 0 | 300 | -6 / -6 / -12 |
| 机器人 | -1 | -0.5 | 120 | 0 / 1 / 0，ring modulation=0.9 |

自然预设采用适度 pitch 与较小的 formant 位移，加少量频谱和动态整形。该参数依据是工程设计与听感目标，尚非用户原声的校准结果。效果强度同时缩放 pitch、formant、robot 与 wet；0% 为对齐的 dry，但保留预设输出 gain。原声有同等对齐延迟，便于比较。预设名称描述方向，不能保证年龄、性别或身份效果。

## 依赖、许可证和复现

| 依赖 | 固定版本 | 许可证 |
|---|---|---|
| Signalsmith Stretch | 1.3.2；a670068d9aeb64913331d5cc29337b19a457a7df | MIT |
| [Signalsmith Linear](https://github.com/Signalsmith-Audio/linear) | de55e6a50ffcf6f8f43f649692d94691c7025151 | MIT |

Vendor 目录保留源码版权和完整许可证；PATCHES.md 记录唯一 seeded-constructor 显式转换补丁，seed 1234 不变。`DEPENDENCIES.json` 记录固定提交；App resource 的 `THIRD-PARTY-NOTICES.txt` 携带两份许可证。C++17，DSP 编译 -O3；使用库的内置 FFT，未启用需要另行链接的 xsimd / IPP / PFFFT，也没有声称当前实现使用 Accelerate 加速。Vendor 的其他平台实现不加入编译 target。

音频导入使用 Apple 的 [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator) 与 [安全作用域 URL](https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource())，在 picker completion 获得临时访问权限、协调读取并复制至沙盒，后续只读本地文件。权限释放由 lease 生命周期管理。格式最终通过 AVAudioFile 的真实 PCM 读取判断。

当前编译、合成 PCM 的实际 DSP 测试和 CAF 写入证据见 BUILD-STATUS-ZH.txt；iOS 18.1.1 真人音色、监听质量、声学反馈、HFP 和微信收录结果必须按 VOICE-LAB-TEST-PROTOCOL-ZH.md 填写。

1.2.1 事件处理依据：Apple [categoryChange](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason/categorychange) 表示会话类别变化，不自动代表输入输出失效；[Engine configuration notification](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification) 可能因硬件采样率/声道变化停止并反初始化图，节点仍保留连接。实现必须核对实际路由/格式、转交普通线程后处理，不能把每条通知无条件失败或在内部通知回调直接销毁图。

# AudioRelayLab 1.6.0 / build 10 签名测试版

默认“声音工坊 → AI 重新配音”：录音只在手机转成文字，Modal Qwen3-TTS 1.7B 根据文字与目标声线重新说话。云端不接收原录音、音高、声纹、气口或节奏；成品不对齐原录音时长。原话、重复和口头词保留，只允许识别器整理标点，不增加自动润色。

## 使用

1. 使用自己的证书重新签名 `AudioRelayLab-1.6.0-unsigned.ipa`，安装后打开“声音工坊”。
2. 首次使用导入电脑 `server/.private/modal-client.json`，或粘贴完整 JSON。配置包含 endpoint、proxyTokenID、proxyTokenSecret、apiKey，保存在本机 Keychain；不要上传到 GitHub、公开分享或放进 IPA。重新签名、更换 Bundle ID、重装后若钥匙串不可用，再次导入；存储失败仍可在当前启动期间使用。
3. “预设声线”：选择 Serena 原版、Vivian 原版、古风温润小生、清润书生、清脆动漫可爱声或清冷淡然 Serena。预设沿用已认可 instruction 和两组固定参考。录音停止后自动识别并生成；从库选录音后点击“识别并生成配音”。识别文字可以修改，再次生成只使用修改后的文字。
4. “自定义配音”：选择 Serena、Vivian、Dylan、Uncle_Fu、Eric、Ryan、Aiden、Ono_Anna 或 Sohee。默认 Serena、instruction 空白。键盘输入，或录音/从库识别后先校对文字，再点击“生成配音”。instruction 原样交给 CustomVoice，不添加任何预设指令。此入口不覆盖固定参考预设。
5. 成品可以回听、分享、用于延迟播放，或与背景音乐混合保存。混音使用完整成品时长，音乐默认 4%。两个音频库继续按新增时间最新在前。

手机识别使用 `SFSpeechRecognizer(zh-CN)`，先请求语音识别权限，检查设备端支持，强制 `requiresOnDeviceRecognition=true`；仅接受最终结果。权限拒绝、设备不支持或识别失败时保留原录音并提示手动输入。不能识别时不会自动上传录音做云端识别。手机中英混读和识别准确度须由用户在真机确认。

输入录音 0.3–60 秒；文字最多 1,000 个 Unicode 字符；instruction 最多 500 个。超限明确报错，不截断。成品时长独立允许大于 0 至 180 秒。选择新录音会取消旧识别并清空对应文字；改文字、speaker 或 instruction 不会重新识别。

高级入口保留旧电脑变声及本地模型；“手机实时”保留原来的实时处理和混音。旧电脑服务可以继续在高级入口使用。旧云端服务没有 customTTS 能力时仍可使用其预设，自定义入口提示更新服务。

## 等待、取消与文件校验

页面显示录音中、识别中、配音中、保存中。GPU 和常规 CPU API 空闲窗口均为 120 秒，准备模型任务保持短窗口；120 秒是缩零调度的窗口，实际容器终止还可能有控制面延迟。

长请求只跟随同源 HTTPS 303 结果跳转，总等待最多 900 秒；连接失败不自动重复提交。点击“停止等待”会取消本机等待并丢弃迟到结果，已进入云端的生成可能继续完成。等待结束后可手动重试。保存前核验 WAV/PCM、SHA256、24 kHz 采样率、目标身份、模型 revision 与实际时长；失败不保存半成品。

元数据可选记录识别文字、实际配音文字、预设或自定义、speaker/instruction、模型与输出哈希；旧记录仍可读取。分享音频文件不附带私有连接配置。

## 测试与构建证据

源码分支为 `feature/revoice-ios-1.6.0`。本轮只交付无签名测试 IPA，main 合并与正式发布等待用户签名验收。构建使用 Python 3.12、锁定 CPU 依赖、XcodeGen、实际模拟器 XCTest 和 iPhoneOS Release，并保存预设、自定义页面截图。

Python 回归、真实 L4、snapshot A/B 与实际 iOS 构建分别记录，不能用自动测试替代主观自然度或真机权限验收。当前构建结果见 [BUILD-STATUS-ZH.txt](BUILD-STATUS-ZH.txt)；云端测试见 [MODAL-DEPLOYMENT-ZH.md](MODAL-DEPLOYMENT-ZH.md)。Snapshot 只有在两种模型的冷启动中位数均降低至少 30%，且恢复、切换和输出验证通过时启用，否则关闭。

## 用户真机验收

- 重签后麦克风与语音识别权限是否正常；拒绝权限、关闭网络、中文/中英混读、数字、人名是否符合预期。
- 预设录完自动生成、自定义先校对再生成；改字不再识别、更换录音不串用上一段文字。
- 六个认可预设的自然度，九个 speaker 与手动 instruction 的表现；有问题保留原话和成品反馈。
- 停止等待、连接恢复、失败手动重试；超过 60 秒成品的回听、分享、延迟播放和完整混音。
- iOS 18.1.1 的原有播放、微信收录和通话中音频行为，仍按原真机协议检查。

参考：[Qwen3-TTS 官方接口](https://github.com/QwenLM/Qwen3-TTS)、[Apple 设备端识别](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)、[Modal 长请求](https://modal.com/docs/guide/webhook-timeouts)、[Modal GPU snapshot](https://modal.com/docs/guide/memory-snapshots)。

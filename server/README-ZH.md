# AudioRelayLab 电脑 AI 服务

当前版本是录音后 Seed-VC v2 转换，不是低延迟实时推流。安装和手机连接步骤见根目录 `AI-VOICE-GUIDE-ZH.md`。

服务端与 App 协议：

- 所有接口要求 `Authorization: Bearer <本机私有连接密钥>`。
- `GET /v1/health` 返回真实模型加载状态和设备；`GET /v1/voices` 返回实际存在参考文件的音色及来源。
- `POST /v1/jobs?voice=<ID>` 的 body 为单声道 PCM16 WAV，8–48 kHz、0.3–60 秒、最大 16 MB。返回任务 UUID 和 queued/loading/converting/complete/failed/cancelled 状态。
- `GET /v1/jobs/<UUID>` 查询；完成后 `GET /v1/jobs/<UUID>/audio` 返回实际生成 WAV 和 `X-Audio-SHA256`。
- `DELETE /v1/jobs/<UUID>` 取消。正在计算的模型步骤不能立即抢占，之后丢弃结果；已取消结果不能下载。

单模型工作队列，避免多个任务抢占显存；待处理队列上限 4。连接密钥、原声、参考、生成音频和模型缓存均在 Git 忽略的 `.private` / `.runtime` 中。原声和任务文件保留在本地便于诊断；不在日志中打印认证密钥。可在停止服务后自行清理 `.runtime/jobs`。

上游版本和源码 ZIP 校验值见 `upstream-lock.json`，参考来源固定值见 `reference-lock.json`。运行 `verify-conversion.py` 生成实际 GPU 样本与证据。`tests/test_ai_service.py` 是协议测试，不能当作模型效果证明。

运行适配器使用官方 CLI 同一 `convert_voice_with_streaming` 公共入口。上游 `stream_output=False` 不返回最终音频，旧非流式入口与 CFM 参数不匹配，因此使用流式入口取最终 numpy PCM；中间 MP3 块丢弃，发给 App 的 WAV 直接来自最终 PCM，没有 MP3 再解码。私有 FFmpeg 仅供上游内部流块封装。

本目录 Python 服务及上游适配器采用 GPL-3.0-only，文本见 `LICENSE-GPL-3.0.txt`。没有修改上游源码。CosyVoice 官方参考保留仓库 Apache-2.0 文本。模型权重与参考素材不从许可证名称推断成任意商用授权，使用各自发布来源的条款。

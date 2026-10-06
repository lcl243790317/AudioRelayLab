# 1.6.4 / build 14 验证与交付

验证日期：2026-10-06。Python 94 项、Simulator XCTest 226 项、UI XCTest 10 项全部通过；Simulator Debug / iPhoneOS Release 构建成功。

- 源码提交：`f021781327ab9790051502b76187eeb08392f580`。
- [实际 Actions 构建](https://github.com/lcl243790317/AudioRelayLab/actions/runs/37465511866)；运行编号 37465511866。
- 测试计数与源码测试方法数量完全一致，0 失败、无跳过。
- Swift 编译警告：2，均来自已有 `RevoiceJobTests` 的作用域末尾 `defer`；App 源码无 Swift 编译警告。
- Artifact 官方 SHA256 已逐字核对，完整 ZIP 通过 CRC，解包路径已验证。
- IPA 的 ZIP、arm64 Mach-O、iPhoneOS 平台、最低 iOS 17.0、后台音频与无签名结构重新验证通过。
- 实际 Info.plist：1.6.4 / build 14。
- IPA：`dist/AudioRelayLab-1.6.4-unsigned.ipa`，1428129 字节。
- SHA256：`47d5aa953c79a262b4327fb21dbfa069c521e94e64e1ee5c48942c91dca048d6`。

混音新增测试直接离线渲染音频，检测音乐加入前的静音、加入后的音乐、尾声、人声全段保留、不同采样率与音乐片段/速度。自动指令测试检查内容变化、所有表达维度、否定、疑问、混合情绪、长度上限、开关、设备识别、固定参考限制和任务恢复。UI 回归实际操作两种音频库的标签切换与导航返回，并检查播放状态。

自动 instruction 是本地文字/标点规则；没有新增云端语义模型或分析原声情绪。复杂语义仍可能判断不准，支持预览与关闭。IPA 需自行重签名；情绪听感、设备端语音识别和重签名权限仍须真机验收。

本轮未部署云端、未运行 GPU 推理、未合并 main 或正式发布。

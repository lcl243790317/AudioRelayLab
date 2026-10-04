# AudioRelayLab 1.6.2 / build 12 测试与交付记录

交付 `dist/AudioRelayLab-1.6.2-unsigned.ipa`，需要用户重新签名。源码提交：`14574ae3b20a284672bb3835f46f08ad1c71cb6b`；[真实 Actions 构建](https://github.com/lcl243790317/AudioRelayLab-private-history/actions/runs/37188923638)。功能分支 `feature/revoice-ios-1.6.0`，main 未合并。

SHA256：`aa293585dcea1812cb89d4cfec8e45b8379ca8ec16978c3093e138701b1a6ab9`。IPA 1,320,394 字节；可执行文件 4,732,712 字节。版本、build、iPhoneOS Mach-O、未签名状态及权限说明均重新检查，实际文件与 CI manifest 完全一致。

## 修复与证据

| 项目 | 实际验证 |
|---|---|
| 下载暂存 | 使用真实 URLSession 下载回调，同步读完借用的临时文件，再原子写入 App 自有受保护文件；回调返回后系统删除源文件，成品仍正确保存 |
| 暂存故障与重启恢复 | 故意删除借用文件，确认任务保留；模拟重启后 GET 取回同一 ID，随后新任务能保存；旧版错误记录兼容 |
| 权限差异 | 只读文件及目录无法执行旧 move，但新暂存方式能读取和保存，源文件内容及权限不变 |
| 待处理结果 | 首次 202/running、随后 200/WAV，重复 restore 合并，最终只保存一次 |
| 最新参数 | 捕获 9 个 speaker 的新请求正文，验证最新文字、原样 instruction、新 UUID；预设切换不携带自定义参数 |
| 旧任务与草稿 | 显式恢复使用旧任务冻结参数，保持当前草稿；旧回调不能覆盖新任务 ID 或状态 |
| 重启与过期 | pending 下载期间独立加载声线目录；过期释放等待并显示 24 小时提示，保留文字 |
| 界面 | 实际输入、完成键、speaker 选择、长列表滚动、深色大字体可达性、旧任务与当前草稿区分；截图与录屏已检查 |

| 自动检查 | 结果 |
|---|---|
| Python 3.12 回归 | 89 项通过 |
| iPhone Simulator XCTest | 191 项，0 失败，0 跳过 |
| UI XCTest | 6 项，0 失败，0 跳过 |
| Simulator Debug / iPhoneOS Release | BUILD SUCCEEDED |
| Swift 编译警告 | 0 |
| HTTPS fixture | 6 次成功、1 次 pending；未发送长期密钥 |
| 凭据审计 | 175 个 tracked 源文件及解压后 IPA 无实际密钥 |

环境：macOS 26.6.2 / 25G83；Xcode 26.6 / 17F113；Swift 6.3.3；iPhoneOS SDK 26.5；XcodeGen 2.46.0。

## 界面与云端

按 Build iOS Apps 的 ios-debugger-agent、swiftui-performance-audit、swiftui-ui-patterns、swiftui-view-refactor 技能审查与改进。Windows 上无法直接运行 XcodeBuildMCP 的 Apple 工具链，本轮使用真实 macOS CI、Simulator 测试、截图和录屏验证；没有用静态检查替代编译。

普通字号的文字框完整进入首屏；大字体选择器采用上下布局，深色指令框使用主题背景和更清晰的占位提示。当前草稿与旧任务冻结参数分开显示，旧任务区的实际滚动与文字核对由 UI 测试和录屏覆盖。未测 CPU 或帧率，不宣称性能提升百分比。

云端模型、固定参考与 snapshot 不变，GPU/常规 CPU 缩零窗口仍为 75 秒。本轮只读检查健康接口和既有 Vivian 成品：200、SHA256、24,000 Hz、3.12 秒均通过；没有提交新生成请求。既有真实 L4 测试见 1.6.1 报告，不把它当本轮手机锁屏的验证。

## 真机验收

安装与恢复步骤见 REVOICE-1.6.2-ZH.md；原连接 JSON 可继续使用。重点复测切换 App/锁屏后的取回，停止等待后用新 speaker/文字/instruction 生成，以及恢复失败后下一任务。

真实网络测试使用一次性模拟器信任的隔离 HTTPS fixture，生产 TLS 验证不变。它验证了 Foundation 下载回调和故障恢复，不等于已重现用户真机的具体 NSError。若手机再次失败，保留完整操作/domain/code 提示；新诊断不记录 URL、密钥或配音文字。前台备用取回须保持 App 打开，普通系统后台下载仍保留。重签名后的系统后台调度、锁屏自动保存和设备端识别仍由用户真机验收。

原始证据保存在 CI Artifact 以及本地 `dist/ci-run-37188923638/`：build-evidence.json、manifest、环境/构建/测试日志、xcresult、UI PNG/MP4；交付审计见 `dist/revoice-1.6.2/delivery-audit.json`。

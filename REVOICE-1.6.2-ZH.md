# AudioRelayLab 1.6.2 / build 12 签名测试说明

本轮修复配音结果暂存失败、旧任务覆盖新参数，以及重新打开后声线目录无法加载的问题。Modal 模型、参考声线、snapshot 和 75 秒缩零窗口沿用当前部署；main 继续等待用户签名验收。

## 使用与恢复

- 更新后无需删除已有录音或连接配置。旧版已保留的任务在 24 小时窗口内仍可取回；点击“继续取回这份配音”，取回的是卡片中显示的原始文字、声线和指令。
- 当前草稿可以编辑。点击“按当前内容生成新的配音”，使用点击时的最新文字、speaker/预设和指令，生成新任务；上一任务停止等待，迟到结果不会保存。先验证新输入再放弃旧任务。
- 暂存失败时，前台取回直接读取网络响应，绕过系统下载临时文件。此恢复期间请保持 App 在前台；普通任务仍采用系统后台下载，切换 App 不会取消云端推理。
- 若再次失败，提示包含操作和错误 domain/code；不含配音文字、下载 URL 或密钥。请提供完整错误提示以便确认真机具体原因。

## 本轮技术修复与验证范围

系统临时下载文件在回调返回前同步读取，再原子写入 App 自有文件；不再移动或修改系统文件。Apple 要求在下载回调结束前读取或保存临时文件：[下载回调说明](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate/urlsession(_:downloadtask:didfinishdownloadingto:))。文件采用首次解锁后可访问的保护等级：[Apple 文件保护说明](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication)。

新增真实本地 HTTPS 的 URLSession 下载、临时文件失效、重启取回、202→200 续取回与后续新任务测试；测试下载仅发送任务临时凭据。CI 的证书只加入一次性模拟器，生产 TLS 校验不变。模型输出仍须通过 WAV/SHA256/采样率/时长/目标身份校验才入库。

参数测试捕获请求正文，覆盖 9 个 speaker、修改文字和指令、预设切换、恢复旧任务不覆盖草稿、取消连接及旧回调不覆盖新状态。页面把当前输入移入首屏，待取回任务单独展示；新增浅色、深色、大字体截图和 UI 测试。

已使用 Build iOS Apps 的 ios-debugger-agent、swiftui-performance-audit、swiftui-ui-patterns、swiftui-view-refactor 技能进行代码审查。当前 Windows 无 Apple 工具链，真实编译与模拟器验证由 macOS CI 执行。构建结果以随包的 build-evidence.json 与后续测试报告为准，本文不提前宣称测试通过。

用户真机的原始 NSError 尚未取得：已确认代码中的临时文件权限依赖和旧参数覆盖问题，不能把某一权限错误表述为已证实的真机根因。重签名后的后台唤醒、锁屏保存和恢复体验仍需用户设备验收。

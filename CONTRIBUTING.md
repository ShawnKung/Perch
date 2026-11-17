# 参与贡献

欢迎提交问题和改进。提交前请先阅读 [AGENTS.md](AGENTS.md)，并在 macOS 13 或更新版本上使用 Xcode 或 Apple Command Line Tools 构建。

应用源码按职责放在 `src/App`、`src/Browser` 和 `src/AI`，独立钥匙串组件放在 `src/Helpers`；隔离自检放在 `tests`，工具放在 `scripts`，应用元数据放在 `resources`。新增 Swift 源文件时同步更新根目录 `build.sh` 中对应的编译列表。

运行 `make test` 验证编译、签名和隔离数据自检；涉及 WebKit、窗口或 UI 的修改还应运行对应的 `make test-web`、`make test-window` 或 `make test-ui`。GUI 检查需要可用的桌面会话。请在变更说明中注明运行的检查及无法验证的边界。

请勿提交 API 密钥、个人浏览数据、证书、钥匙串或构建产物。提交贡献即表示你同意以本项目的 MIT 许可证提供你的贡献；第三方材料须保留其原有许可与署名。

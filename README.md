<p align="center">
  <img src="assets/noto-bird.png" alt="Perch Logo" width="128" height="128">
</p>

# Perch

[![CI](https://github.com/ShawnKung/Perch/actions/workflows/ci.yml/badge.svg)](https://github.com/ShawnKung/Perch/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-555555?logo=apple)](https://github.com/ShawnKung/Perch/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Perch 是一款原生 macOS 菜单栏浏览器，让常用网页和 AI 对话随手可及。

## 功能

- 菜单栏快捷打开，支持多标签、书签、浏览历史和快捷键。
- 使用 Command 加号或减号缩放网页时，可在收藏按钮下方查看比例、调整或重置。
- 切换标签保留地址栏与首页搜索框的草稿、焦点和文字选区。
- 从其他浏览器导入数据，支持密码保存和网页链接预览。
- 接入兼容 OpenAI 或 Anthropic 协议的模型，支持网页引用、附件、联网搜索和对话历史。
- AI 回车发送或加入队列后立即清空输入框；发送未受理时保留草稿。
- Chat 支持后台执行：切换对话或关闭展示标签后继续生成，历史名称右侧显示运行转圈；空闲时悬停显示归档按钮。
- 在对话中查看 Markdown、表格与图表，导出文本文件。
- 在「设置 → 常规 → 外观」调整 Chat 正文字号，标题、历史列表、思考过程和其他文字按比例调整。

## 安装

从 [Releases](https://github.com/ShawnKung/Perch/releases) 下载 Apple Silicon 应用，解压后将 `Perch.app` 移到「应用程序」文件夹。

发布包使用固定的自签名证书，未经 Apple 公证，首次打开可能需要在 macOS 设置中手动允许。

### 发布新版本

将准备发布的代码合入 `main` 后，为该提交推送 `v主版本.次版本.修订号` 格式的标签，例如 `git tag v0.1.2 && git push origin v0.1.2`。CI 从标签设置应用的显示版本号，构建和自检通过后自动创建 GitHub Release 并上传 Apple Silicon 包。标签必须使用三段数字，不能包含前导零或预发布后缀；其他标签不会发布。不要移动或重复使用已经发布的标签。

本地构建的版本和构建号以 `resources/Info.plist` 为准；发布构建的构建号以其中的整数为基数，加上 GitHub Actions 的递增运行编号。发布时 CI 只修改运行器上的副本，不改仓库文件。发布新功能或修复时仍应按工程规范更新该文件的版本和构建号。

也可以在 GitHub Actions 手动运行 CI，并在 `verify_release_tag` 中填入拟发布的标签，预演对应版本的构建和签名；预演不会创建标签或 Release。

也可以在 Mac 上从源码构建并安装：

```sh
git clone https://github.com/ShawnKung/Perch.git
cd Perch
make install
```

需要 macOS 13+、Xcode 或 Apple Command Line Tools，以及 Python 3。源码构建使用本机签名，请保留 `~/Library/Application Support/Perch Signing/` 以便后续更新继续访问钥匙串。

## 开发

```text
src/
  App/          应用入口、主界面、设置与管理页
  Browser/      标签、导航、书签、导入、密码与网页预览
  AI/           对话、历史、供应商协议与内容渲染
  Helpers/      独立编译和签名的钥匙串组件
tests/          隔离 Swift 自检与 Python 合成接口服务
scripts/        安装、签名、图标生成与优化工具
resources/      应用元数据（Info.plist）
assets/         图标原图、本地 Markdown 库与第三方许可
.github/        CI 与发布工作流
build.sh        编译、资源打包与签名的唯一入口
Makefile        常用开发命令
```

运行 `make test` 检查编译、签名和隔离数据自检，`make check` 运行完整回归，`make help` 查看专项检查和预览命令。GUI 回归需要可用的 macOS 桌面会话；检查只使用隔离配置和合成数据。

源码仍通过 `swiftc` 构建，无需 Xcode 工程或 Swift Package。新增 Swift 文件时更新 `build.sh` 中对应的编译列表；Swift 自检随主程序编译，钥匙串组件单独构建。更多协作约定见 [AGENTS.md](AGENTS.md)，贡献说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 隐私

书签、设置和浏览历史保存在本机；对话和附件保存在本机应用支持目录。网站密码和 AI 密钥保存在 macOS 钥匙串。使用 AI 功能时，发送的消息和主动选择的内容会传给所选模型供应商。

## 许可证

项目代码采用 [MIT 许可证](LICENSE)。第三方资源的许可和署名见 [assets](assets/) 及 [Markdown 资源说明](assets/markdown/ATTRIBUTION.md)。

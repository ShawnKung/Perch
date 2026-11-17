# Perch

[![CI](https://github.com/ShawnKung/Perch/actions/workflows/ci.yml/badge.svg)](https://github.com/ShawnKung/Perch/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-555555?logo=apple)](https://github.com/ShawnKung/Perch/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Perch 是一款原生 macOS 菜单栏浏览器，让常用网页和 AI 对话随手可及。

## 功能

- 菜单栏快捷打开，支持多标签、书签、浏览历史和快捷键。
- 从其他浏览器导入数据，支持密码保存和网页链接预览。
- 接入兼容 OpenAI 或 Anthropic 协议的模型，支持网页引用、附件、联网搜索和对话历史。
- AI 回车发送或加入队列后立即清空输入框；发送未受理时保留草稿。
- 在对话中查看 Markdown、表格与图表，导出文本文件。

## 安装

从 [Releases](https://github.com/ShawnKung/Perch/releases) 下载 Apple Silicon 应用，解压后将 `Perch.app` 移到「应用程序」文件夹。

发布包使用临时自签名证书，未经 Apple 公证，首次打开可能需要在 macOS 设置中手动允许。不同构建的签名身份可能不同，更新后可能无法读取旧版保存在钥匙串中的密码或 AI 密钥。

也可以在 Mac 上从源码构建并安装：

```sh
git clone https://github.com/ShawnKung/Perch.git
cd Perch
make install
```

需要 Xcode 或 Apple Command Line Tools。源码构建使用本机签名，请保留 `~/Library/Application Support/Perch Signing/` 以便后续更新继续访问钥匙串。

## 隐私

书签、设置和浏览历史保存在本机；对话和附件保存在本机应用支持目录。网站密码和 AI 密钥保存在 macOS 钥匙串。使用 AI 功能时，发送的消息和主动选择的内容会传给所选模型供应商。

## 许可证

项目代码采用 [MIT 许可证](LICENSE)。第三方资源的许可和署名见 [assets](assets/) 及 [Markdown 资源说明](assets/markdown/ATTRIBUTION.md)。

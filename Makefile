SHELL := /bin/bash
.DEFAULT_GOAL := help
# GUI checks share focus, and builds/installations share the same app bundle.
.NOTPARALLEL:
.PHONY: help build verify test check test-ai test-navigation test-web test-ui test-window test-keychain install reinstall run preview clean

APP := build/Perch.app
BIN := $(APP)/Contents/MacOS/Perch

help:
	@printf '%s\n' \
	  'make build         编译、打包并签名 build/Perch.app' \
	  'make install       编译、自检并更新 /Applications/Perch.app，随后启动' \
	  'make reinstall     同 install，重新编译、安装并启动' \
	  'make run           启动已安装的 /Applications/Perch.app' \
	  'make test          编译、签名校验及隔离数据自检' \
	  'make check         数据、WebKit、原生 UI、窗口完整回归（需要桌面会话）' \
	  'make test-web      WebKit 合成页面回归' \
	  'make test-ai       AI 合成接口、页面提取与流式聊天回归' \
	  'make test-navigation 网页加载中、连续前进后退与 History API 回归' \
	  'make test-ui       原生 UI 回归' \
	  'make test-window   窗口与动画回归' \
	  'make test-keychain 合成钥匙串回归（单独运行）' \
	  'make preview       打开隔离 UI 预览，可追加 ARGS="--preview-settings"' \
	  'make clean         仅删除本工程 build/ 产物'

build:
	@bash build.sh

verify: build
	@plutil -lint "$(APP)/Contents/Info.plist"
	@codesign --verify --deep --strict "$(APP)"

test: verify
	@"$(BIN)" --self-test
	@"$(BIN)" --update-self-test

check: test
	@"$(BIN)" --ai-typography-self-test
	@python3 tests/ai-self-check.py "$(BIN)" --background-only
	@python3 tests/ai-self-check.py "$(BIN)"
	@python3 tests/ai-self-check.py "$(BIN)" --navigation
	@"$(BIN)" --web-self-test
	@"$(BIN)" --web-tabs-self-test
	@"$(BIN)" --scroll-self-test
	@"$(BIN)" --ui-self-test --compact
	@"$(BIN)" --update-ui-self-test
	@"$(BIN)" --window-self-test

test-web: verify
	@"$(BIN)" --web-self-test
	@"$(BIN)" --web-tabs-self-test
	@"$(BIN)" --scroll-self-test

test-ai: verify
	@"$(BIN)" --ai-typography-self-test
	@python3 tests/ai-self-check.py "$(BIN)" --background-only
	@python3 tests/ai-self-check.py "$(BIN)"

test-navigation: verify
	@python3 tests/ai-self-check.py "$(BIN)" --navigation

test-ui: verify
	@"$(BIN)" --ui-self-test --compact
	@"$(BIN)" --update-ui-self-test

test-window: verify
	@"$(BIN)" --window-self-test

test-keychain: verify
	@"$(BIN)" --keychain-self-test

install: test
	@bash scripts/install.sh

reinstall: install

run:
	@open "/Applications/Perch.app"

preview: verify
	@"$(BIN)" --ui-preview $(ARGS)

clean:
	@rm -rf build

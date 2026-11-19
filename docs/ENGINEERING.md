# Perch 工程说明

本文记录跨模块架构、数据边界与维护时需要保留的兼容行为。具体样式数值和局部实现以源码及回归用例为准；新增约束应说明原因，避免将单次修复过程累积为永久规则。

## 网页、标签与窗口

- `src/App/main.swift` 管理 Store、窗口与应用生命周期；`src/Browser/TabContents.swift` 管理网页、首页及完整 Chat 的平级原生内容控制器。
- 所有页面使用同一个 NSTabViewController，每个标签保留稳定控制器。平台负责选择当前页面，后台页面离开窗口和事件响应链，不以透明度、零宽度或隐藏叠层模拟切换。
- 切换标签不重建 WKWebView、不回写 DOM 滚动位置。后台网页保留视口，真实窗口尺寸变化只布局当前网页；NSHostingController 不用内容尺寸反推容器大小。
- 完整 Chat 为全局唯一标签，打开、恢复、历史、Fork 和网页对话转完整页均复用它。重复旧标签只合并入口，其对应对话仍保存在历史中。
- 网页 AI 侧栏仅打开时挂载；其会话、草稿、请求和阅读位置保留在 AIController。侧栏开关按网页标签记忆，完整 Chat 与侧栏共用会话状态。
- Chat 的运行 owner 独立于视图：切换历史、切换或关闭展示标签、新建对话不会取消旧会话；侧栏以可选 `aiOwner` 记录绑定，旧标签默认使用自身 ID。同一会话再次打开复用运行 owner，不从历史快照覆盖正文或重复启动请求。
- 导航入口复用 Browser.goBack/goForward，未提交导航及连续历史操作由 pendingHistoryItem 管理；旧导航失败不得覆盖新状态。
- 窗口只由主动操作收起，失焦不隐藏。保留多屏位置、可用区域、快速反向动画及系统减少动态效果。
- 设置可开启「主窗口跟随鼠标显示」，默认关闭；所有唤出入口在鼠标所在屏幕定位并收敛到可用区域，全屏期间不重定位。
- AppKit 为较高 sheet 抬升父窗口后，会在关闭时动画恢复旧坐标；`Panel.setPlacement` 标记 sheet 期间的显式定位，仅在该 sheet 的 `endSheet` 调用期间由公开的 [`constrainFrameRect(_:to:)`](https://developer.apple.com/documentation/appkit/nswindow/constrainframerect(_:to:)) 约束父窗口保持最新 frame，防止动画先回旧屏。没有显式定位的 sheet 保留系统恢复行为；不在动画结束后移动补偿。回归通过实际「完成」点击观察整个关闭过程的窗口移动通知。
- WebKit 的导航与新窗口委托统一携带后台打开标志，⌘点击/中键保持当前标签；`WKNavigationAction.buttonNumber` 实际是位掩码，中键为 `1 << 2`（参见 [WebEventFactory](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/mac/WebEventFactory.mm)），不同于 `NSEvent.buttonNumber == 2`。Option 预览的「在 Perch 中打开」由预览控制器回调创建标签并关闭预览。
- 使用原生红黄绿及其原有关闭路由，主窗口关闭保留标签。网页和图表预览为独立窗口，⌘W 按 keyWindow 路由。
- Option 与书签临时浏览共用预览窗口控制器。加入父窗口前设置初始透明度，关闭 AppKit 自动窗口动画，由显式透明度过渡统一负责显示与关闭；遵守减少动态效果，关闭期间立即停止接受操作。淡入回归检查窗口服务器的中间透明度，不能只检查结束值。
- 管理页复用同一窗口；侧栏调整、顶栏避让和分隔线命中按实际布局计算，不遮挡窗口按钮、标签或输入控件。

验证入口：`make test-web`、`make test-navigation`、`make test-window`、`make test-ui`。网页回归覆盖原生 RootView、整页和嵌套滚动、视口、输入选区、JS 身份、后台离窗及关闭释放。

## 输入、会话与交互

- 原生输入框保留编辑快捷键、图片粘贴和输入法 marked text。组合输入期间不回写 stringValue、不发布未提交文字、不抢候选词方向键、回车或 Escape。
- 默认回车发送、Shift+回车换行，可设置 Command+回车发送；输入法和网页引用候选确认优先。
- 发送受理后清空草稿，未受理保留。生成中可加入会话绑定的 FIFO 队列，冻结问题、附件、引用、模型与联网选择；完成后由 AIController 继续，不依赖视图挂载。
- 停止或失败暂停并保留队列；新对话、历史切换及关闭展示标签后，旧会话的队列继续在后台执行。归档、删除及受理历史编辑清理对应队列，不能发送到其他会话。队列只在内存保存，并保留数量和附件预算限制。
- 回到用户消息只进入编辑状态，保留历史及运行中的请求；取消恢复原草稿，只有发送受理才替换该轮及后续消息。Fork 在受理发送后创建副本，保留原对话。
- 新对话标题只尝试生成一次，失败回退；历史支持多选、归档、恢复及 Fork。永久删除仅作用于已归档记录，活动会话不能重新插入已删除记录。
- 模型供应商 UUID 与模型名随会话持久化，每次选择立即保存，不依赖发送；运行请求及队列保留已捕获的配置。完整 Chat 的加号返回尚未发送的新对话草稿，网页侧栏按网页标签独立保留草稿；发送后下次加号创建新的草稿。草稿文字、附件、网页和正文引用及空会话偏好随对话存档保存，退出时统一落盘，空草稿不进入历史列表。
- 历史右键支持重命名与置顶，手动名称优先于未完成的自动标题。置顶独立分组显示在 Chat 上方，保留原始会话来源和时间排序，取消后回原组；归档和 Fork 清除置顶状态。名称及置顶持久化，旧存档默认未置顶。
- macOS 27 默认隐藏 NSMenuItem 图像，会话菜单显式设置 preferredImageVisibility 为 visible，重命名使用 pencil 图标；通过检测公开 Objective-C setter 并使用 KVC 设置枚举原值 1，兼容尚未声明该属性的旧 SDK。旧版系统不存在此 setter，继续使用原生默认行为；macOS 27 UI 回归检查实际属性值。
- 阅读位置持久化为消息 ID 与消息内偏移，网页侧栏和完整 Chat 共用。延迟布局按消息锚点校正，不能用固定绝对坐标或强制滚到底部覆盖用户阅读。
- 消息布局保留已测量高度，Markdown 视图在视口附近加载、离屏释放。普通鼠标滚轮没有 phase，也必须通知阅读记录组件；事件监听随视图移除清理。
- 思考、搜索、工具和正文状态分别管理。运行中的 phase 不写入历史，不能仅凭累计正文是否为空推断当前状态。
- 历史行从实时会话读取运行状态：生成中右侧常显原生转圈，悬停不替换成归档；空闲时文字占满，悬停才渐显归档并为图标让位。图标位于行高亮内；减少动态效果时静态显示运行标记，动画随视图离窗暂停。
- 澄清工具在完整工具流验证后保存 awaiting_user 结果并结束本轮，答案作为新一轮续聊。后续建议的直接发送和填入草稿使用独立点击区域，不能冒泡触发彼此。

验证入口：`python3 tests/ai-self-check.py build/Perch.app/Contents/MacOS/Perch --composer-only`；同一服务也提供 `--background-only`、`--streaming-only`、`--experience-only` 及完整 AI 回归。后台专项使用独立 owner 与可控 SSE 阶段，覆盖历史行鼠标选择、跨会话/网页/侧栏切换、关闭重开、FIFO、显式停止、删除和工具后续轮次。

## 模型供应商、协议与联网

- 供应商配置使用可编辑且唯一的 Provider ID；钥匙串身份使用不可变 UUID，改名称或 ID 不丢密钥。探测模型需勾选后加入目录，不自动替换已选模型。
- 接入 OpenAI Chat Completions、OpenAI Responses 和 Anthropic Messages，按对应 SSE、附件、模型列表及工具回放协议实现；不写入私有服务地址、真实 Key 或专用环境变量名。
- Responses 使用 instructions/input 及 input_text/input_image，不请求远端存储会话；失败和未完成事件必须报错。工具 ID 和重复完整名称幂等处理，参数增量不能去重，保留旧存档兼容。
- 消息思考字段独立于正文、搜索记录和工具回放；展示限额不能中止回答。原生搜索证据限额只统计搜索内容，不统计普通正文、思考或工具参数。
- 联网能力由供应商显式声明，不能根据名称、品牌或私有地址猜测。自动模式只选一个后端，优先原生，失败不静默回退。
- 联网开关与来源选择独立持久化，关闭保留来源，改来源不自动开启。旧 off 值兼容关闭加自动；失效但已选择的路线保持可见。
- standard 原生搜索通过同供应商 Responses 执行，保留模型、UUID 和 Key，不写回配置；关闭和独立搜索仍按配置协议执行。已有明确 deepSeek 值不猜测迁移。
- 独立搜索使用独立配置与钥匙串账户，按 DeepSeek HTTP Search 协议发送 query/count/need_content；num 可作 count 的参数别名，两者同时存在必须一致。
- 搜索仅由模型工具调用执行，保留响应、参数和调用预算。来源过滤非 HTTP(S) 或含凭据 URL，来源及用量进入历史和导出。
- 提示词采用通用时效性、来源、证据和不确定性规则；提供当前日期与时区，不伪造知识截止日期，不为单个回答案例增加特例。
- 供应商编辑页使用直接密钥输入，不主动执行环境变量导入。旧 keyEnvironment 只兼容读写；AIEnvironment 仅用于明确授权的隔离 CLI 连接检查。

## 数据、签名与安全边界

- 书签、标签、设置、窗口和浏览历史使用 `dev.perch.menubar` UserDefaults；对话及附件使用 `~/Library/Application Support/Perch/Conversations`。损坏值和文件保留原始内容并阻止覆盖，不重置真实数据。
- 网站密码与 AI Key 分别由 PerchVault 和 PerchAIKeys 管理。AI Key 使用 `dev.perch.menubar.ai` 服务，以 Provider UUID 隔离；密钥不进入 UserDefaults、会话文件、命令参数或日志。用户明确勾选导出密钥时允许写入备份及受限临时目录。
- `~/Library/Application Support/Perch Signing/` 保存稳定本机证书、专用钥匙串与 helper 缓存。不能为修复构建删除它、改用 ad-hoc 签名或重建证书。
- 钥匙串 helper 验证父进程 bundle ID 与签名证书，凭据只通过管道传递。有意修改 helper 时验证升级访问、不同签名拒绝及旧记录迁移；不相关修改不重建缓存。
- 安装脚本在已安装 helper 与新包内容不同的时候停止；此类升级需先验证签名和迁移，再安排安装。
- 安装先暂存并验证新包，再替换；退出超时则中止，替换或签名验证失败恢复旧包。临时回滚包成功后清理；源码构建的本机签名不等于 Developer ID 或公证。
- 不自动修改系统信任、钥匙串搜索列表或系统权限，不绕过密码访问认证、macOS 访问控制或 TLS 校验，不自动降低到 HTTP。
- 浏览器导入源库只读，锁定数据库仅在受限临时快照上恢复。保留源隔离和分区 Cookie 跳过行为。
- 设置备份由 `src/App/Backup.swift` 定义版本化 ZIP，v2 按 `BackupScope` 只编码勾选的设置、AI 配置和书签，兼容 v1 全量备份；新增常规设置只维护原有 Codable 模型，不另列导出字段。布局偏好统一使用 `LayoutPreference` 键，捕获与恢复遍历其全部 case；新增独立配置模型时须接入 SettingsBackup 及 Store 的校验/应用流程。
- ZIP 只允许单个 `perch-backup.json`，限压缩文件 32 MB、正文 16 MB、书签 50,000 个及 64 层，不将归档路径解压到磁盘。先校验和编码，再暂存新密钥、注册快捷键与登录项，失败恢复原快捷键并清理暂存密钥，成功后统一写入所选类别。损坏的本机配置禁止被对应类别的导入导出覆盖。
- AI 密钥默认不导出，勾选后包含已保存的模型和搜索密钥；ZIP 为明文、文件权限 0600，临时目录 0700 且完成后清理。始终不含密码、Cookie、访问历史、标签或会话。导入配置重新生成凭据 UUID、清除旧账户与环境变量绑定，密钥写入新账户且不覆盖或删除本机已有账户。运行请求保持原配置，备份未含的密钥需重新填写。
- 导入窗口位置由 AppDelegate 立即恢复并适配当前屏幕，全屏或切换期间推迟到退出全屏；等待期间不让窗口移动/缩放通知覆盖导入位置。
- 真实连接检查只在明确授权后使用 `--ai-connectivity-check`，通过通用环境参数传入地址与变量名，使用隔离配置、内存 Key 和合成内容，不写生产配置。

## 网页引用与生成内容

- 网页由输入框 @ 主动引用，发送时提取正文并优先选中文字，排除表单、隐藏内容和秘密。HTML 仅经只读 get_page_html 工具按需获取。
- 追问可使用本对话以前引用且仍匹配的已加载网页；引用编号稳定，不重新编号或重复追加提示。工具不得导航、远程抓取或执行任意 JS。
- 引用匹配去除凭据、查询和片段，提取快照按完整 URL 校验，读取期间导航需报错。工具记录按供应商协议持久化和回放；历史裁剪保留完整问答与网页引用。
- 回答选区使用 `AIQuote` 保存消息 ID 与最多 12,000 字的文本快照，归属会话控制器；队列、编辑、取消、保存及导出均携带引用。可引用的可见选区存在时推迟流式 Markdown 替换，清空选区后显示最新正文；隐藏的图表源码选区不阻塞更新。引用经 XML 转义后放入 `quoted_response`，系统指令明确其为参考数据而非指令/已证实事实；三种协议使用同一消息转换。
- 引用提示词设计依据：[OpenAI Prompt engineering](https://platform.openai.com/docs/guides/prompt-engineering) 与 [Anthropic Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices) 的上下文分隔实践；数据分隔不能保证完全消除提示注入，原有工具权限仍独立校验。
- 独立文本产物通过三协议共用的 create_text_file(name, content) 登记，仅在完整流结束且 ID 和参数有效后处理。不执行源码、不采用模型指定路径。
- 保留文件数量、大小和历史预算，同轮同名更新稳定 ID，后续轮次保留原版本。下载排他创建以避让同名，另存为使用 NSSavePanel。
- 文件版本只关联当前及此前消息，不能泄露后续轮次。表格 CSV 使用 UTF-8 BOM、RFC 引号转义及公式前缀保护，diff 保留计算上限。

## Markdown、图表与资源

- Marked、DOMPurify 和 Mermaid 随应用本地打包，保留第三方许可。Mermaid 按需加载、strict 模式渲染并净化 SVG，未完成或错误图保留源码，旧异步渲染不能覆盖新内容。
- `chat.js` 使用 Marked 扩展兼容 `**中文句子。**后续中文` 的加粗边界，不改 vendor 或预处理代码/转义文本；背景见 [CommonMark 中文标点讨论](https://talk.commonmark.org/t/bold-failure-in-chinese-sentence-because-of-the-usage-of-chinese-punctuation-is-different-from-english/3478)。来源卡片优先匹配搜索元数据，普通 HTTP(S) 链接使用标题/域名回退，按实际行框定位。搜索列表复用同一原生来源弹窗；正文链接、列表按钮和卡片原链接通过显式回调交给 Store.openReferencedPage，网页菜单与预览同样在 Perch 内打开。
- Markdown 网页视图进入窗口时与浏览器网页视图一样开启 acceptsMouseMovedEvents。实机已观察到嵌入 SwiftUI 滚动容器的 WebKit 在正确原生命中、DOM 坐标命中链接时仍不更新 DOM 悬停状态；正文引用因此在现有原生事件监听中通过实际鼠标位置和 DOM 命中判定悬停，不拦截鼠标事件，不依赖 WebKit 私有跟踪区 owner。非嵌入网页保留 DOM 悬停，键盘聚焦共用同一引用状态；移动到同一链接不重置 600 毫秒延迟，离开、拖动选择、重绘及滚动清理预览。来源链接保留行内排版，纵向内边距覆盖文字下沿和虚线下划线附近的命中区域。悬停回归使用完整 Panel、RootHostingView 和 RootView，确认窗口命中正文后通过 NSApp.sendEvent 派发连续 NSEvent，验证停留、切换与离开；不能用直接调用 WebKit 跟踪区 owner 或 JavaScript dispatchEvent 代替应用事件路径。
- 内嵌 WKWebView 不吞掉正文纵向滚轮；图表区域保留 WebKit 缩放，代码和表格保留横向滚动。交互区域按当前可见视口判断，监听按生命周期清理。
- 图表平移和缩放不改变消息高度，源码切换保留状态；PNG 从完整净化 SVG 导出，不保存平移后的截屏。
- 图表窗口独立于 Markdown 生命周期，关闭移除桥和引用。HTML/SVG 文件预览使用 nonPersistent WebKit 和 sandbox=allow-scripts，不允许 same-origin、网络、文件系统、弹窗、下载或宿主桥。
- 主题通过 PerchTheme 同步原生 UI 与应用自身 Markdown/图表，原生标签显式刷新；不重建网页或聊天、不改变阅读位置和图表状态，不向真实网页注入主题。
- Chat 正文字号由 BrowserSettings 持久化，默认 13 pt，历史标题默认 13 pt；PerchTheme 同步原生文本和 Markdown CSS 变量，其他文字相对正文等比例缩放，行高随文字调整。顶部「AI 聊天」文案固定 13 pt，不随正文字号调整。带来源的历史标题和来源整体垂直居中。更新字号重新排版，不重建内容或清空草稿与选区；图表视口保持独立。
- 主程序体积优化使用既有编译与符号裁剪方案，并在 LTO 中额外运行一轮 LLVM [MachineOutliner](https://llvm.org/docs/doxygen/MachineOutliner_8cpp.html) 合并重复机器指令；保留运行时检查、类型元数据、异常展开及全部自检。Markdown 资源采用 LZMA 无损压缩并缓存解压结果。每次构建重建包内资源目录，避免旧资源残留。
- ICNS 在 zlib 的标准压缩策略中选择最小 PNG 数据，并验证解压字节及其他 chunks 不变；不能通过删除自检、图标尺寸、语言或图类型缩小体积。

验证入口：`build/Perch.app/Contents/MacOS/Perch --ai-markdown-self-test`，字号专项为 `--ai-typography-self-test`，文件专项为 Python 服务的 `--files-only`。通过 `open -W` 启动时，必须核对应用自检完成断言和 FAIL，不能把 open 的退出码或焦点超时视为成功。

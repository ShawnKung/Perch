# Perch 工程说明

本文记录跨模块架构、数据边界与维护时需要保留的兼容行为。具体样式数值和局部实现以源码及回归用例为准；新增约束应说明原因，避免将单次修复过程累积为永久规则。

## 更新检查

- 自动与手动检查共用 Store 的请求状态，优先读取 GitHub Releases API。仅在 API 返回 403 且 `X-RateLimit-Remaining: 0` 时，对公开 `releases/latest` 地址发起 HEAD 请求，从最终跳转的本仓库 HTTPS `releases/tag/<版本>` 地址比较三段数字版本；兜底不下载页面正文，也不需要内置凭据。其他 HTTP/网络失败、无效数据及无效跳转均按检查失败处理，不能误报「当前已是最新版本」。手动检查结果与按钮同排，位于按钮左侧，长消息省略并提供完整悬停说明。`--update-self-test` 验证 API 优先、限流兜底边界、失败保留已有提示、取消与重试；`--update-ui-self-test` 验证结果位置和原生按钮动作。

## 网页、标签与窗口

- 侧栏宽度的增量更新同时刷新可见标签和分组按钮的展开进度；不能只刷新组内图标而让按钮等待下一次元数据变化。分组按钮按当前 bounds 重绘，避免图层保留过渡尺寸。`--ui-preview --verify-sidebar-animation --verify-preview` 通过实际侧栏按钮点击、快速反向切换和箭头像素检查，验证无需点击分组即可保持正确位置。

- 标签分组由 Store 的 `tabGroups` 和 `Tab.groupID` 共同管理，组成员在有序标签集合中连续排列；固定标签不归组。`TabListRow` 将集合投影为组标题和可见标签，折叠不销毁页面或改变当前选择。若当前标签属于折叠组，在组标题下方临时显示一行普通标签，切走后消失；这一行不改变顺序、归属或持久化数据，重复点击当前行不展开分组。旧数据缺少 `groupID` 时保持未分组。
- 隐藏与折叠独立：隐藏分组将有序成员保存到 `TabGroup.hiddenTabs`，批量清理网页控制器并移除侧栏行，不写入最近关闭列表；已打开分组仍以 `Store.tabs` 为唯一成员来源，管理页直接投影两种状态。旧数据缺少 `hiddenTabs` 时为已打开分组；空的已打开分组自动移除，隐藏分组跨重启保留。重新打开清空快照并恢复标签，保留名称、颜色和顺序；仅恢复标签地址及应用状态，不恢复 WebKit 页面内存或前进后退栈。解散隐藏组会先恢复标签再移除归属，删除组同时删除快照。
- 加入分组菜单将「新建组」置顶，有已打开组时在其后添加分隔线，只列 `openTabGroups`；折叠组仍属于已打开组。新建颜色在 `Store.createTabGroup` 按 `TabGroupColor.allCases` 轮询，`nextTabGroupColor` 以原始颜色名保存在应用 UserDefaults 中；状态缺失、类型错误或未知颜色从默认蓝色恢复，创建失败不推进轮询，手动改色与隐藏/恢复不改变轮询状态。已保存组的颜色保持原值。
- 分组编辑弹窗的 SwiftUI `onHover` 未可靠更新菜单反馈，单纯移动状态归属也未解决。操作行与颜色按钮共用不参与命中的原生跟踪视图，以 `activeAlways` 跟踪区和弹窗内鼠标坐标更新悬停；本地事件监听只观察事件，视图离窗时清理。跟踪区显式初始化并随布局更新，范围取按钮 `bounds` 与 `visibleRect` 的交集：未裁切的 SwiftUI 托管祖先可能使 `visibleRect` 超出按钮，不能直接使用 `inVisibleRect`。跟踪区生命周期参考 [AppKit 官方说明](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html)。`--ui-preview --preview-saved-groups --verify-preview` 验证 NSApp 鼠标事件、实际背景像素、高亮转移、重绘与移出清除及整行点击，不移动系统鼠标。
- 原生拖放只在 Coordinator 中预览顺序和成员关系，接受落点后交给 Store 提交；取消、离开列表和外部结构变化会丢弃预览。标题与组内行接纳标签，左侧留白、组末尾边缘与列表外侧落点移出分组；整组移动保持成员顺序并临时收起。布局使用 200ms ease-in-out，并遵循「减少动态效果」。参考 Chromium 的 `tab_collection_animating_layout_manager.cc`、`tab_drag_handler.cc` 与 `tab_group_view_vertical_layout.cc`（`chrome/browser/ui/views/tabs/common/`）。
- 首页入口、标签与分组标题共用 `DragPreview.swift` 绘制圆角浮层，背景与内容合成后统一应用 88% 不透明度，原位置留空并实时补位。`--ui-preview --verify-tab-drag --verify-home-shortcut-drag --verify-preview` 覆盖真实窗口内的鼠标按下路径、宽窄侧栏、预览行位置、元数据刷新、固定边界、取消与接受落点；系统拖动捕获与落点使用合成夹具，不替代真实鼠标拖动验收。
- 原生鼠标按下时记录行的 UUID，标签选择与组标题动作使用同一点击身份，避免擦除期间动态行高更新使 `clickedRow` 或选中行号指向其他对象；沿用 NSTableView 的原生跟踪与拖放流程，鼠标跟踪结束后清理点击身份。
- 标签与分组擦除共用 `TabWipeAnimation`，通过 [NSAnimation](https://developer.apple.com/documentation/appkit/nsanimation) 的非阻塞主线程进度驱动行高和色线，使用 common run-loop modes，按当前屏幕刷新率采样。反向操作停止旧驱动，从当前实际进度开始；不通过自定义 NSView 属性的隐式 animator 推断显示进度。
- 每个分组的色线由独立原生视图绘制一条连续路径，只在整组首尾圆角，避免逐行圆角的抗锯齿露出底色；展开栏与窄栏均通过实际窗口截图的接缝像素检查。`--ui-preview --preview-groups --verify-preview` 可单独运行分组原生事件与布局回归。
- 分组展开/折叠采用 280ms 擦除，图标与色线共用原生可动画属性的进度。组内行按从上到下的擦除边界更新可见高度，图标和文字保持原尺寸并裁切，不叠加淡入、滑动或压缩；收起期间保留成员，擦除到零后移除。选中项在两个方向均保持完整行高，原顺序不变，前面的行擦除后自然上移，结束时成为标题下的临时标签，不另加重排动画。擦除进度统一控制行高，分组行插入、删除不再叠加 AppKit 行位置动画；检查所有显示行的缓存高度，仅通知实际变化的行，防止普通点击触发布局或非擦除行继承旧高度。滚动仅改变视口偏移，遵循「减少动态效果」。原生 `TabListContainer` 在自己的图层边界裁切标签、色线与滚动视图，防止列表布局过渡的中间帧越界覆盖下方新建按钮。`--ui-preview --verify-group-transition --verify-preview` 覆盖组外及组内首项、中间项、末项选择，验证 16ms 反向切换、选中项完整行高与顺序、中间帧像素及实际图标点击的纵向坐标。
- 窄栏色线以 2pt 宽度绘制在标签列表左侧独立的 3pt 留白中，与选中背景保留 2pt 间隙，独立于组标题按钮，色线从按钮顶部圆角起笔并连续延伸。容器与 SwiftUI 布局在展开和收起状态下均保留相同的左侧空间，避免原生留白立即切换而 SwiftUI 补偿边距渐变造成图标位移；避免把色线画到原生滚动视图外而被裁切。色线位置、起笔高度、组内图标与高亮缩进由 SwiftUI 同一个连续展开进度驱动，随侧栏宽度一起过渡，反向操作沿用当前进度，并遵守减少动态效果。色线随滚动更新、按生命周期清理监听。窄栏组内标签不偏移选中背景，图标、背景和组按钮共用水平中心；窄栏组按钮保持原高度，左右边界与高亮块一致。
- 分组收起时不立即清除显示标签的组归属：图标及选中背景的横向缩进使用「侧栏展开进度 × 分组擦除进度」，由同一进度逐帧更新原生约束，不额外启动横移动画。色线下沿取表格当前可见成员高度，扣除保留选中项中尚未展开的部分，末端保持固定 4pt 留白；更新行高后同步完成原生布局，避免色线先走、图标后走。中间帧回归同时检查真实行高、色线边界和图标/高亮缩进。

- `src/App/main.swift` 管理 Store、窗口与应用生命周期；`src/Browser/TabContents.swift` 管理网页、首页及完整 Chat 的平级原生内容控制器。
- 所有页面使用同一个 NSTabViewController，标签首次选中才创建内容控制器。网页、Chat、有输入或阅读位置的首页保留稳定控制器；连续切换到空白首页时，可复用当前无草稿、原生输入、输入法组合文本、滚动位置及弹窗的首页 hosting tree，避免在擦除期间重建整页。具有 Browser 历史的首页不参与复用。平台负责选择当前页面，后台页面离开窗口和事件响应链，不以透明度、零宽度或隐藏叠层模拟切换。
- `TabContentState` 只向当前页转发 Store 更新，并在即将选中时通知对应后台页读取最新数据；独立 Browser、AI 请求与数据状态继续正常运行。首页和工具栏按显式输入值刷新，地址输入身份绑定所属标签，不绑定全局选择，避免连续新建时重建后台输入框。窗口控件留白变化仍更新所有保留控制器。`--ui-preview --verify-tab-burst --verify-preview` 连续创建 60 个首页，覆盖擦除重叠、输入框身份与草稿、首页滚动保留及最终列表一致性。
- 切换标签不重建 WKWebView、不回写 DOM 滚动位置。后台网页保留视口，真实窗口尺寸变化只布局当前网页；NSHostingController 不用内容尺寸反推容器大小。
- 完整 Chat 为全局唯一标签，打开、恢复、历史、Fork 和网页对话转完整页均复用它。重复旧标签只合并入口，其对应对话仍保存在历史中。
- 网页 AI 侧栏仅打开时挂载；其会话、草稿、请求和阅读位置保留在 AIController。侧栏开关按网页标签记忆，完整 Chat 与侧栏共用会话状态。
- Chat 的运行 owner 独立于视图：切换历史、切换或关闭展示标签、新建对话不会取消旧会话；侧栏以可选 `aiOwner` 记录绑定，旧标签默认使用自身 ID。同一会话再次打开复用运行 owner，不从历史快照覆盖正文或重复启动请求。
- 新建对话共用 `AIController.newChatOwner`：当前输入包含文字、附件或引用时，带入新对话；当前已经是空白会话时保留其 owner。文字、网页/已关闭网页引用及选区引用一起复制，旧会话的历史、草稿和请求保留；不同的既存未发送草稿继续可恢复，不覆盖。没有当前草稿时沿用既有空白草稿复用规则，发送仍需用户确认。数据自检覆盖重启与既存草稿，`--verify-web-selection-ai` 覆盖侧栏新对话按钮的实际点击及原生输入框内容。
- 侧栏历史按网页 URL（忽略查询参数和片段）筛选，路径变化后旧网页对话仍保存在全局历史。菜单的「全部历史对话」打开完整 Chat 和历史列表，沿用当前会话 owner 保留输入；空白草稿不进入历史。数据自检覆盖新建会话与重启后的旧记录及网页筛选边界。
- 导航入口复用 Browser.goBack/goForward，未提交导航及连续历史操作由 pendingHistoryItem 管理；旧导航失败不得覆盖新状态。
- WebKit 的 `didFinish` 可能先于 `title` 更新，下载后继续导航也会出现此行为。Browser 观察原生 `title` 属性，在已完成的当前文档上同步标签与既有历史项标题，不新增历史、不用延时或页面脚本补偿。
- 主框架交接给 `WKDownload` 后即结束该导航的生命周期，保留已提交页面；GitHub 发布资源等跨域下载会在交接后返回 `WebKitErrorDomain` 102，旧导航的迟到失败不能覆盖原页面。不全局屏蔽错误码；子框架下载不结束主页面导航。下载回归覆盖跨域跳转后主页、网页和内部记录页的地址、历史及无错误状态。
- 下载行与分组菜单复用 `NativeHoverRegion`，以原生跟踪区和窗口内鼠标事件更新悬停，避免弹层内 SwiftUI `onHover` 漏事件；装饰跟踪视图不参与命中，监听按窗口生命周期清理。
- 下载使用 `WKNavigationAction.shouldPerformDownload`、不可显示的 MIME 响应及 HTTP `Content-Disposition: attachment` 转交 `WKDownload`，保留 WebKit 会话、Cookie 与原始下载请求。仅检查 MIME 无法覆盖 HTML 等可显示的附件；附件 disposition 按分号前的 token 大小写无关匹配。下载转交后恢复当前主页或网页的地址、标题与导航状态，不追加浏览历史。Store 持有 `DownloadController`，任务不由标签视图管理；记录存于独立 `downloads` 本机配置，不归入浏览历史或导出备份。损坏记录保留原数据，重启后的未完成记录标为中断，不自动重新请求。文件在「下载」目录内的独立隐藏临时路径写入，成功时添加系统 quarantine 元数据并避让同名文件后移动到最终位置，失败清理临时文件。
- 下载按钮紧邻更多菜单，圆环显示最新未完成任务；总大小未知时转圈，遵循减少动态效果。近期弹层与完整原生列表共用记录及文件操作，删除或清空仅影响记录，后台传输继续。文件不存在时禁用打开与 Finder 操作，列表显示期间刷新文件状态。`perch://downloads` 通过独立 scheme handler 建立 WebKit 历史项，再显示原生内容；地址栏、后退与持久化恢复共用此路径，内部地址校验不扩展外部 URL、书签和 AI 引用的信任范围。`make test-downloads` 使用隔离配置、临时文件与本机 HTTP 服务验证下载和导航。
- 网页右键在 `Browser.extendContextMenu` 精确移除 WebKit 的导航项，再统一追加中文导航；其他原生链接、图片和编辑项保留。后退、前进、重新加载使用 `NSMenuItem.identifier`；停止加载没有标识，仅匹配 WebKit 转发动作和 macOS 的 Stop tag 11。依据为 WebKit 的 [菜单构造](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebContextMenuProxyMac.mm)、[标识定义](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKMenuItemIdentifiers.mm) 和 [动作枚举](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/ContextMenuItem.h)，系统 WebKit 升级时以实际右键回归复核。`存储为…` 在隔离 JavaScript world 中克隆当前 HTML，保留 doctype、统一 UTF-8 并固定原页面 baseURI，不修改现场 DOM；原生保存面板选择 `.html` 文件，使用原子写入。保存面板期间页面切换不改变已捕获快照；外部图片、样式等资源仍通过原网址加载，不打包为离线资源。`--ui-preview --verify-web-context-menu --verify-preview` 验证实际右键事件、去重、原生项保留与本地 HTML 编码及相对链接回读。
- 文字选区右键保留原生中文「复制」，移除查询、翻译、系统搜索、带高亮链接、分享、朗读与系统写作入口；通过 NSMenu 的公开配置关闭自动追加的上下文插件。`WebSelectionTracker` 在隔离 world 的各 frame 中仅监听 `contextmenu`，冻结最多 12,000 字的非表单选中文字；导航开始时清理，网页脚本不能调用桥接入口。主网页的「问 AI」通过 Store 激活来源标签、打开侧栏、去重添加网页引用并设置文字引用，保留已有问题及运行请求，等待用户发送；引用使用去除凭据、查询和片段的网页 URL。`AIQuote.page` 为可选网页来源，旧回答引用的 `messageID` 数据保持兼容；文字经 XML 转义后作为独立引用发送，焦点请求只在运行时按会话传递。`--ui-preview --verify-web-selection-ai --verify-preview` 覆盖真实选区右键、菜单结束跟踪、选区变化后的快照、侧栏引用和原生输入焦点。
- AppKit 的 Services 菜单不属于 `NSMenu.items`，关闭上下文插件也不能移除；`PageWebView.validRequestor` 返回 nil，网页不参与系统 Services，防止系统追加此入口。原生复制、粘贴及其他视图的 Services 保持原行为。隔离 WKWebView 实验通过实际菜单截图验证，自动回归检查网页 Services 请求者边界。「问 AI」使用侧栏同款 `sparkles`；macOS 27 的 AppKit 默认可能隐藏菜单图片，需通过公开 `preferredImageVisibility` 指定 `NSMenuItemImageVisibilityVisible`（整数值 1）。`NSMenuItem.showImageIfSupported` 先检查 setter，再经 KVC 设置此公开属性，以支持旧 SDK 编译；缺少 setter 的系统沿用默认图片显示。仅运行时 `#available` 不能让旧 SDK 识别新属性。
- 新标签页首次提交网址或搜索时，Browser 先通过 WKURLSchemeHandler 建立内部 `perch-home://new-tab/` 历史项，再打开目标网页；后退至该项显示原生首页，保留同一 Browser 与前进栈。首页中央和工具栏输入草稿按标签独立保留，重新提交沿用 WebKit 的历史分支行为。内部首页不写入浏览历史、不作为 AI 网页引用，历史栈与草稿仅在本次运行中保留。
- 首页书签直接在当前标签导航，复用首页返回和草稿保留逻辑；网页中打开书签仍新建标签。新标签优先继承显式来源，否则继承当前标签的分组并插入其后；批量打开书签同样保持组内连续顺序。
- 首页「全部书签」入口复用管理页，以 `BookmarkScope.all` 初始展示个人与导入目录；书签管理和历史入口分别指定 `.root` 与 `.history`。显示范围由 Store 的临时 `libraryBookmarkScope` 与管理页同步，关闭时重置，不写入书签或首页排序。`--ui-preview --verify-home-bookmarks --verify-preview` 验证首页按钮的实际点击、完整书签树及未固定书签在当前首页标签打开。
- 首页入口顺序单独保存在 `homeShortcutOrder`，不改变收藏列表与目录顺序。隐藏入口保留其位置，新入口追加；原生拖放使用半透明卡片和实时换位，接受本地落点后才保存，取消或离开区域恢复预览。顺序归入 v3 书签备份，旧备份缺省时恢复收藏顺序，损坏数据保留并阻止覆盖。
- 书签管理页的个人书签行支持单选与多选拖动排序，使用同一半透明浮层与原生 `NSOutlineView.moveItem` 实时补位；拖到个人目录仍移动归属。只有接受本地落点才保存 `sites` 顺序，未显示的书签保留其位置和元数据，并先固定首页当前顺序，保持两处排序独立。拖动期间保留列表项对象身份、原地更新名称与网址，取消、离开列表或外部结构变化时恢复显示顺序。`--ui-preview --verify-bookmark-drag --verify-preview` 覆盖原生点击路径、预览位置、选区与元数据保留、多选、保存/重启、拒绝/取消、目录移动和导入只读边界；拖动捕获和目标回调使用隔离合成夹具。
- 全部书签和个人书签使用同一个个人目录树投影，搜索保留匹配项的祖先目录；左侧只保留个人书签总入口。目录箭头由 `frameOfOutlineCell` 返回空布局隐藏，保留原生展开/收起能力；不能通过 `shouldShowOutlineCell=false` 隐藏，该选项会连同 `collapseItem` 一起禁用。双击目录切换展开/收起，行末打开按钮进入个人目录，顶部返回按钮按实际父目录逐层返回。展开的子目录内排序限定于同级书签，不改变归属。`--ui-preview --verify-bookmark-folders --verify-preview` 通过隔离窗口双击和按钮事件验证导入/个人目录开合、两种视图的层级、子目录排序及元数据保留、侧栏去重与多级返回。
- 星标、⌘D 和网页收藏菜单通过同一书签编辑请求打开无箭头的原生浮窗，按按钮的屏幕坐标紧贴下方并右对齐，屏幕边缘自动约束；首页右键编辑复用编辑器并显示网址。名称、网址、目录及首页显示标记一起校验、保存；点击完成或在外部关闭时保存，错误保留编辑草稿。新星标书签显式设置 `showOnHome = false`，旧数据缺省值仍视为显示。导入目录保持只读。
- 关闭当前标签时优先回到本次运行中最近激活且仍存在的标签，尚无激活历史时回退到相邻标签；关闭其他标签保持当前选择。标签插入、移除与分组展开收起使用连续行高擦除，关闭行保留到擦除完成；列表高度与加号沿用相同过渡，移动期间暂停悬停切换，静止后按实际指针位置恢复，遵循「减少动态效果」。
- 标签插入、移除动画将同一主队列周期的进度与完成回调合并，只通知实际变化的行高，批量结束时统一清理并重排一次；分组色线与成员布局保留同步更新。擦除生命周期由动画完成回调结束，反向操作以修订号拒绝旧完成回调，不能仅凭某次进度值等于目标就提前释放擦除行。元数据未变化的 SwiftUI 视口更新不重建列表，结构变化时仍核对所有缓存行高，保留选中项与复用行的正确布局。同一标签在移除动画中恢复时沿用当前高度，交错关闭按后续行身份保留相对顺序；`--ui-preview --verify-tab-performance --verify-preview` 可测量隔离多标签更新、新建擦除的逐帧行高与反向收放的主线程间隔。
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
- 模型供应商 UUID 与模型名随会话持久化，每次选择立即保存，不依赖发送。空白新对话另存自身上次选择的模型，后续新建对话使用该选择；已有消息的会话切换模型只更新自身，不改变新对话偏好或供应商配置。新对话偏好随对话存档保存，未选择或供应商/模型失效时使用配置中的默认值。运行请求及队列保留已捕获的配置。完整 Chat 的加号返回尚未发送的新对话草稿，保留草稿自身的模型，网页侧栏按网页标签独立保留草稿；发送后下次加号创建新的草稿。草稿文字、附件、网页和正文引用及空会话偏好随对话存档保存，退出时统一落盘，空草稿不进入历史列表。
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
- 设置备份由 `src/App/Backup.swift` 定义版本化 ZIP，v3 按 `BackupScope` 只编码勾选的设置、AI 配置和书签与标签组，兼容 v1 全量及 v2 分类备份；旧备份没有标签组时不覆盖现有分组。标签组统一导出为隐藏快照，导入校验网址、归属及 ID，生成新的组和标签 ID、清除 AI 会话关联，已有打开页面保留并解除旧分组。新增常规设置只维护原有 Codable 模型，不另列导出字段。布局偏好统一使用 `LayoutPreference` 键，捕获与恢复遍历其全部 case；新增独立配置模型时须接入 SettingsBackup 及 Store 的校验/应用流程。
- ZIP 只允许单个 `perch-backup.json`，限压缩文件 32 MB、正文 16 MB、书签 50,000 个及 64 层，不将归档路径解压到磁盘。先校验和编码，再暂存新密钥、注册快捷键与登录项，失败恢复原快捷键并清理暂存密钥，成功后统一写入所选类别。损坏的本机配置禁止被对应类别的导入导出覆盖。
- AI 密钥默认不导出，勾选后包含已保存的模型和搜索密钥；ZIP 为明文、文件权限 0600，临时目录 0700 且完成后清理。始终不含密码、Cookie、访问历史或会话，标签仅保存分组内的标题与地址及应用元数据。导入配置重新生成凭据 UUID、清除旧账户与环境变量绑定，密钥写入新账户且不覆盖或删除本机已有账户。运行请求保持原配置，备份未含的密钥需重新填写。
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

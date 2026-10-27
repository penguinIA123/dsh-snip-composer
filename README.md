# dsh-snip-composer

一个 [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) 插件：在聊天输入框左侧加一个「📷 截图提问」按钮，下拉选择截图方式，截完图自动粘贴进输入框，**不自动发送**（你接着打字再发）。

## 功能

- 📷 **框选截图** —— 拖选屏幕任意区域
- 🙈 **隐藏 DSH 后框选** —— 先隐藏 DSH 窗口再框选，截图完成后自动把 DSH 切回前台（适合截 DSH 自己遮挡不到的界面）
- 🖥️ **全屏截图** —— 截取整个虚拟屏幕（含多显示器）

截图通过网页端派发 `paste` 事件插入聊天输入框（Lexical 编辑器），**不依赖全局焦点状态，每次都稳定**；图片**不经过系统剪贴板**，所以不会有剪贴板残留。

## 平台要求

- **Windows only**：截图内核基于 Windows Forms + `CopyFromScreen`，通过 PowerShell 脚本（`lib/snip.ps1`）执行。
- 需要 DeepSeek Harness 客户端（Electron 版，Windows）。

## 安装

把本插件放进某个 DSH **profile** 的 `node_modules` 下，并在该 profile 的 `package.json` 里声明加载：

1. 复制整个 `dsh-snip-composer` 目录到
   `<你的 profile>/node_modules/dsh-snip-composer/`
   （profile 目录通常位于：`%USERPROFILE%\.dsh\profiles\<profile-name>\`，例如 `desktop`）。
2. 在该 profile 的 `package.json` 中：
   - `dependencies` 加入 `"dsh-snip-composer": "0.1.0"`
   - `dsh.profile.bundles` 数组加入 `"dsh-snip-composer"`
3. 完全退出并重启 DeepSeek Harness。

> 本插件自带 `cordis.patch.yml` 注入点（`package.json` 中 `dsh.bundle.patch` 声明），profile 自己的 `cordis.patch.yml` 无需再写；如需要可继续覆盖。

## 工作原理

| 文件 | 作用 |
| --- | --- |
| `lib/index.js` | Node 半部：注册本地路由 `POST /_dsh/snip-composer/capture`，用 `execFile` 启动 `snip.ps1` 并把截图以 base64 回报。 |
| `lib/client.js` | 浏览器半部：注入输入框左侧按钮 + 下拉菜单，调用路由取回截图，再构造 `DataTransfer` + `ClipboardEvent` 派发到 Lexical 编辑器根节点插入图片。 |
| `lib/snip.ps1` | 截图内核（PowerShell / Windows Forms）：高 DPI 适配、区域拖选、全屏捕获、隐藏 DSH 后框选。 |

## 已知限制 / 踩坑记录

- `snip.ps1` 必须保存为 **UTF-8 with BOM**，否则 PowerShell 5.1 按 GBK 读取中文注释会乱码。
- 启动 PowerShell 时**不要**加 `-NonInteractive`：它会跳过所有 `ShowDialog`，导致选择窗 / 拖选覆盖层不出现（脚本会「假成功」）。
- 聊天输入框是 Lexical 编辑器，其原生 `paste` 监听器挂在 `[data-lexical-editor="true"]` 根节点上（不在 `document`），所以派发事件必须落到该元素；且 `ClipboardEvent` 构造函数不接收 `clipboardData` 参数，需用 `Object.defineProperty` 钉上去。

## License

MIT —— 见 [LICENSE](./LICENSE)。

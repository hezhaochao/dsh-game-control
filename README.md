# dsh-game-control 🎮 游戏操控工具集

[![Test](https://github.com/hezhaochao/dsh-game-control/actions/workflows/test.yml/badge.svg)](./actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6)]()
[![DSH](https://img.shields.io/badge/DeepSeek%20Harness-0.2.x-4d93f8)](https://github.com/deepseek-ai/deepseek-harness)

一个 [DeepSeek Harness（DSH）](https://github.com/deepseek-ai/deepseek-harness)插件：
给 agent 加上**操控游戏**的手——扫描码级键盘输入（长按键移动）、鼠标相对位移（控视角）、
带时序的连招序列、屏幕截图与窗口管理。全部通过 MCP 工具暴露，装好即用，零额外依赖。

## 这是给谁用的

- 让 AI 玩/测试**单机游戏**：走位、点菜单、开技能、读屏决策
- 给游戏脚本/攻略测试做自动化：定时按序列按键、模拟长按、控制镜头
- 任何"游戏只认原始输入"的场景——普通 UI 自动化（SendMessage/SendKeys）在游戏里大多无效，
  本插件走 **SendInput 扫描码**，这是 DirectInput/多数游戏引擎实际读取的层

## 工具一览（装好后模型看到 `mcp__gamectl__<名>`）

| 工具 | 作用 | 游戏场景 |
|---|---|---|
| `key` | 扫描码按键，`tap`/`down`/`up` 三种模式 | 点技能、**长按 W 走路**（down…up） |
| `mouse_move` | 绝对移动（x,y）或**相对位移**（dx,dy） | 拖动镜头、甩视角、瞄准 |
| `mouse_click` | 左/右/中键，单击/双击/按住 | 攻击、开镜、拖拽物品 |
| `mouse_wheel` | 垂直/水平滚轮 | 切换武器、缩放地图 |
| `sequence` | 一条调用里按毫秒时序执行组合键序列 | **连招**：w down → 200ms → shift+q → … |
| `screenshot` | 全屏/区域截图存 PNG，返回路径与尺寸 | 给视觉模型看画面再决策 |
| `windows` | 列出可见窗口（标题/pid/矩形） | 找到游戏窗口 |
| `focus` | 按 pid 或标题把窗口带到前台 | 开局聚焦游戏 |

按键名支持 `a-z`、`0-9`、`f1-f12`、方向键、`space/enter/esc/tab/shift/ctrl/alt`、
`home/end/pgup/pgdn/insert/delete`、小键盘、`minus/equal/bracket_left/…`、`win`。

## 安装

```bash
# npm 渠道（推荐）
dsh plugin --profile <你的 profile> add dsh-game-control

# 或从 GitHub
dsh plugin --profile <你的 profile> add github:hezhaochao/dsh-game-control

# 或本地 link（克隆本仓库后开发调试用）
dsh plugin --profile <你的 profile> add link:"<本仓库绝对路径>"
# link: 方式不会自动装 peer 依赖，需在 profile 目录手动补：
#   node <dsh 内置 pnpm 的 pnpm.cjs> add @deepseek-ai/dsh-mcp-client
```

安装后**完全退出 DSH（含托盘）再重启**。`desktop` profile 请走桌面端插件面板。

### 卸载

```bash
dsh plugin --profile <你的 profile> remove dsh-game-control
```

## 典型用法（对话里直接说）

> "聚焦标题带『Stellaris』的窗口，截个图看看现在什么局面，然后帮我点开左上角的舰队菜单"

> "按住 W 三秒往前走，然后连招：q、等 300ms、e、等 200ms、右键"

agent 会自行组合 `focus` → `screenshot` → `sequence` 完成任务。
截图拿到的是 PNG 路径，配合视觉工具/模型读画面即可形成"看 → 想 → 打"的循环。

## 工作原理

```
DSH (cordis)
 └─ dsh-game-control (mcp/dsh-plugin.mjs 适配器)
     └─ ctx.plugin(@deepseek-ai/dsh-mcp-client, {
          serverName: "gamectl", transport: "stdio",
          command: process.execPath + ELECTRON_RUN_AS_NODE=1,
          args: [mcp/server.mjs] })
         └─ MCP stdio 服务器（零依赖裸 JSON-RPC, 2024-11-05）
             └─ spawn powershell.exe -File scripts/gamectl.ps1（SendInput 后端）
```

- **键盘**：`SendInput` + `KEYEVENTF_SCANCODE`（`wVk=0`），游戏读到的是硬件扫描码；
  导航键/Win 键自动加 `KEYEVENTF_EXTENDEDKEY`
- **鼠标**：绝对移动走 `MOUSEEVENTF_ABSOLUTE`（归一化 0-65535），
  相对位移走裸 `MOUSEEVENTF_MOVE`（`dx,dy` 像素增量，镜头控制专用）
- **进程**：启动即 `SetProcessDPIAware()`，所有坐标都是物理像素；
  后端 stdout 强制纯 ASCII（非 ASCII 转 `\uXXXX`），不受控制台编码影响
- **聚焦**：`AttachThreadInput` 前台锁规避 + `IsIconic` 恢复 + 结果校验

## 兼容性

- 声明 `engines.dsh: ">=0.2.0-rc.1 <0.3.0-0"`，已在 **v0.2.1-rc.3**（当前最新版）上
  完成安装 / 配置树组合 / 卸载验证
- peer 依赖 `@deepseek-ai/dsh-mcp-client >=0.1.0-rc.2 || >=0.2.0-rc.2`，
  正常渠道安装时 pnpm 会自动装进 profile
- 需要 Windows 10/11 + PowerShell 5.1（系统自带），Node 由 DSH 内置运行时提供

## 安全与游戏道德（请务必读）

- **只用于单机游戏或你有权自动化的场景**。任何网游里使用输入自动化都可能违反
  用户协议并导致封号——本插件不提供、也不会提供任何反检测/反作弊规避能力
- 输入是真实系统级注入：`sequence` 有 30 秒硬上限、单键 hold 上限 5 秒、
  click hold 上限 10 秒，避免失控长按
- 聚焦/按键前请先手动保存工作；插件不知道你切了窗口，盲发按键会打进当前前台程序
- 部分游戏（尤其是带内核级反作弊或独占全屏的）可能忽略合成输入或拒绝被聚焦，
  属预期行为——改用窗口化/无边框模式通常可解

## 开发与测试

```bash
git clone https://github.com/hezhaochao/dsh-game-control.git
cd dsh-game-control
npm test          # MCP 协议层：握手/工具清单/全链路（Windows 上含截图实拍）
npm run test:backend   # 真实输入 E2E：鼠标往返归位、扫描码注入 choice.exe、窗口列表
```

E2E 的按键验证方式：spawn 一个等待按键的 `choice.exe` 控制台，聚焦后注入扫描码 `b`，
`choice` 立即返回 `B` 即证明合成输入到达了真实程序（收不到则 20s 超时返回 `A`，测试失败）。

本地真机验证插件挂载：

```bash
dsh plugin --profile zz-test add link:"<本仓库绝对路径>"
dsh --profile zz-test --dump-config   # 应能看到 id: mcp-game-control 条目
```

## 已知限制

- 相对位移的像素精度受系统指针加速影响，游戏内"转多少度"需要按游戏实测校准
- 独占全屏游戏可能拒绝被聚焦（返回 `ok:false` 与提示），建议无边框窗口
- 部分游戏使用原始输入驱动（Raw Input / 驱动级鼠标），SendInput 可能无效——
  这类游戏本插件不打算支持（也没有安全的方式支持）
- 多显示器下 `screenshot` 默认抓虚拟屏全图，`region` 用物理屏幕坐标

## 许可

[MIT](./LICENSE) © hezhaochao

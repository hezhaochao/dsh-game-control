#!/usr/bin/env node
/**
 * dsh-game-control — MCP stdio 服务器（零依赖、裸 JSON-RPC 实现）
 *
 * 协议：newline-delimited JSON-RPC 2.0，MCP 2024-11-05。
 * 实现的方法：initialize / ping / tools/list / tools/call；
 * 通知（notifications/*）只吞不答；未知带 id 的方法回 -32601。
 *
 * 工具共 8 个，全部委托给 scripts/gamectl.ps1（PowerShell SendInput 后端）：
 *   screenshot / key / mouse_move / mouse_click / mouse_wheel /
 *   sequence / windows / focus
 *
 * 纪律：
 *   - 任何工具失败都回 isError 结果，绝不 crash 进程（stdin 断开才退出）；
 *   - 非 Windows 平台工具照常列出，调用时返回明确错误（CI 也能跑握手）；
 *   - stdout 只输出协议消息，日志一律走 stderr。
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BACKEND = path.join(PLUGIN_ROOT, "scripts", "gamectl.ps1");
const VERSION = "0.1.0";
const IS_WINDOWS = process.platform === "win32";
const POWERSHELL = process.env.GAMECTL_POWERSHELL || "powershell.exe";
const TOOL_CALL_BUDGET_MS = 75_000;

/* ────────────────────────── 工具定义 ────────────────────────── */

const obj = (properties, required = []) => ({
  type: "object",
  properties,
  required,
  additionalProperties: false,
});

const TOOLS = [
  {
    name: "screenshot",
    description:
      "Capture the screen (or a pixel region) to a PNG file and return its path and size. Use it to see the game before/after acting; pair with a vision tool to read pixels. Coordinates are physical screen pixels.",
    inputSchema: obj({
      region: {
        type: "array",
        description: "Optional crop [x, y, width, height] in screen pixels.",
        items: { type: "integer" },
        minItems: 4,
        maxItems: 4,
      },
      out: { type: "string", description: "Optional output PNG path. Defaults to a temp file." },
    }),
  },
  {
    name: "key",
    description:
      "Send a keyboard key to the focused window as a hardware SCAN CODE (SendInput) — this is what games actually read, unlike virtual-key events. Use action 'down'/'up' pairs to hold movement keys (e.g. hold 'w' to walk), or action 'tap' with duration_ms for a quick press.",
    inputSchema: obj(
      {
        key: {
          type: "string",
          description:
            "Key name: a-z, 0-9, f1-f12, up/down/left/right, space, enter, esc, tab, shift, ctrl, alt, home/end/pgup/pgdn/insert/delete, numpad0-9, minus/equal/bracket_left/bracket_right/backslash/semicolon/quote/grave/comma/period/slash, win.",
        },
        action: { type: "string", enum: ["tap", "down", "up"], description: "Default: tap." },
        duration_ms: {
          type: "integer",
          description: "For 'tap': how long the key stays down (default 50, max 5000). For 'down'/'up' it is ignored.",
        },
      },
      ["key"],
    ),
  },
  {
    name: "mouse_move",
    description:
      "Move the mouse. Absolute mode jumps to (x, y) screen pixels. Relative mode (dx, dy) moves the pointer by an offset — use it for camera look / aiming in games; large dx values pan the view. The window must already be focused.",
    inputSchema: obj({
      x: { type: "integer", description: "Absolute target X (physical pixels)." },
      y: { type: "integer", description: "Absolute target Y (physical pixels)." },
      dx: { type: "integer", description: "Relative movement X (pixels)." },
      dy: { type: "integer", description: "Relative movement Y (pixels)." },
    }),
  },
  {
    name: "mouse_click",
    description:
      "Click at the current pointer position (move first with mouse_move). Supports left/right/middle, single or double, and an optional hold_ms for press-and-hold (charging, dragging).",
    inputSchema: obj({
      button: { type: "string", enum: ["left", "right", "middle"], description: "Default: left." },
      double: { type: "boolean", description: "Double-click instead of single." },
      hold_ms: { type: "integer", description: "Keep the button held this long (max 10000)." },
    }),
  },
  {
    name: "mouse_wheel",
    description: "Scroll the wheel. delta 120 = one notch up, -120 = one notch down (use -600 for five). Optional horizontal mode and target point.",
    inputSchema: obj({
      delta: { type: "integer", description: "Wheel delta, multiples of 120." },
      horizontal: { type: "boolean", description: "Horizontal scroll instead of vertical." },
      x: { type: "integer", description: "Move pointer here before scrolling." },
      y: { type: "integer", description: "Move pointer here before scrolling." },
    }),
  },
  {
    name: "sequence",
    description:
      "Execute a timed input sequence (a combo) in one call: key taps/holds, waits, mouse moves and clicks with millisecond pacing. Far more precise than calling tools one by one. Total duration is capped at 30 s; a human-visible notice is not shown for full-screen games, so keep sequences short and reversible.",
    inputSchema: obj(
      {
        steps: {
          type: "array",
          description:
            "Steps in order. Each step is one of: {op:'key', key, mode:'tap'|'down'|'up', ms?}, {op:'wait', ms}, {op:'move', x?, y?, dx?, dy?}, {op:'click', button?, hold_ms?}, {op:'wheel', delta, horizontal?}.",
          items: { type: "object" },
          maxItems: 120,
        },
      },
      ["steps"],
    ),
  },
  {
    name: "windows",
    description: "List visible top-level windows with pid, process name, title and rectangle. Use it to find the game window before focusing.",
    inputSchema: obj({}),
  },
  {
    name: "focus",
    description: "Bring a window to the foreground by pid or a case-insensitive title substring (verified after focusing). Full-screen exclusive games may steal focus back; prefer windowed/borderless mode.",
    inputSchema: obj({
      title: { type: "string", description: "Title substring to match." },
      pid: { type: "integer", description: "Process id to focus." },
    }),
  },
];

/* ────────────────────────── 后端调用 ────────────────────────── */

function runBackend(action, payload) {
  return new Promise((resolve) => {
    if (!IS_WINDOWS) {
      resolve({ ok: false, error: "dsh-game-control 仅支持 Windows（SendInput 后端）。" });
      return;
    }
    let json;
    try {
      json = JSON.stringify(payload ?? {});
    } catch {
      resolve({ ok: false, error: "参数无法序列化为 JSON。" });
      return;
    }
    const started = Date.now();
    const child = spawn(
      POWERSHELL,
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", BACKEND, "-Action", action],
      { windowsHide: true, env: { ...process.env, GAMECTL_JSON: json } },
    );
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(killer);
      resolve(result);
    };
    const killer = setTimeout(() => {
      try {
        child.kill("killed");
      } catch {
        /* 进程已退出时忽略 */
      }
      finish({ ok: false, error: `backend timeout after ${Date.now() - started}ms`, elapsed_ms: Date.now() - started });
    }, TOOL_CALL_BUDGET_MS);
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish({ ok: false, error: `无法启动 PowerShell 后端：${String(error)}` });
    });
    child.on("close", (code) => {
      const trimmed = stdout.trim();
      if (!trimmed) {
        finish({ ok: false, error: `backend exited with code ${code}${stderr ? `: ${stderr.trim().slice(0, 500)}` : ""}` });
        return;
      }
      try {
        const parsed = JSON.parse(trimmed);
        if (code !== 0 && parsed.ok !== false) parsed.ok = false;
        finish(parsed);
      } catch {
        finish({ ok: false, error: `backend 输出不是 JSON（code=${code}）：${trimmed.slice(0, 400)}` });
      }
    });
  });
}

/** 把后端 JSON 结果包装成 MCP CallToolResult。成功时不带 isError 字段。 */
function toToolResult(result) {
  const ok = result && result.ok !== false;
  const text = JSON.stringify(result ?? { ok: false, error: "empty backend result" });
  const out = { content: [{ type: "text", text }] };
  if (!ok) out.isError = true;
  return out;
}

/* ────────────────────────── JSON-RPC 骨架 ────────────────────────── */

function writeMessage(message) {
  try {
    process.stdout.write(JSON.stringify(message) + "\n");
  } catch {
    /* stdout 断开时由 stdin close 负责退出 */
  }
}

function reply(id, result) {
  writeMessage({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
  writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
}

function toolError(message) {
  return { content: [{ type: "text", text: message }], isError: true };
}

const TOOL_ACTIONS = {
  screenshot: "screenshot",
  key: "key",
  mouse_move: "mouse",
  mouse_click: "mouse",
  mouse_wheel: "mouse",
  sequence: "sequence",
  windows: "windows",
  focus: "focus",
};

async function callTool(name, args) {
  const action = TOOL_ACTIONS[name];
  if (!action) return toolError(`未知工具：${name}`);
  const result = await runBackend(action, { tool: name, ...(args ?? {}) });
  return toToolResult(result);
}

const serverInfo = { name: "dsh-game-control", version: VERSION };

async function dispatch(message) {
  const { id, method, params } = message;
  switch (method) {
    case "initialize":
      reply(id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo,
      });
      return;
    case "ping":
      reply(id, {});
      return;
    case "tools/list":
      reply(id, { tools: TOOLS });
      return;
    case "tools/call": {
      const name = params?.name ?? "";
      try {
        reply(id, await callTool(name, params?.arguments));
      } catch (error) {
        reply(id, toolError(`工具执行异常：${String(error)}`));
      }
      return;
    }
    default:
      if (id !== undefined && id !== null && method && !method.startsWith("notifications/")) {
        replyError(id, -32601, `Method not found: ${method}`);
      }
  }
}

function main() {
  if (!IS_WINDOWS) {
    process.stderr.write("[dsh-game-control] 非 Windows 平台启动：协议可用，工具调用会返回错误。\n");
  }
  try {
    mkdirSync(os.tmpdir(), { recursive: true });
  } catch {
    /* tmpdir 总是存在的 */
  }
  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let message;
    try {
      message = JSON.parse(trimmed);
    } catch {
      process.stderr.write(`[dsh-game-control] 丢弃非 JSON 行：${trimmed.slice(0, 120)}\n`);
      return;
    }
    Promise.resolve(dispatch(message)).catch((error) => {
      process.stderr.write(`[dsh-game-control] dispatch 异常：${String(error)}\n`);
      if (message && message.id !== undefined && message.id !== null) {
        replyError(message.id, -32603, "Internal error");
      }
    });
  });
  rl.on("close", () => {
    process.exit(0);
  });
}

main();

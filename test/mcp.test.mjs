/**
 * dsh-game-control — MCP 协议层测试。
 *
 * 真实拉起 mcp/server.mjs 子进程，按 newline-delimited JSON-RPC 走完整握手：
 * initialize → notifications/initialized → tools/list → tools/call。
 * Windows 上额外抽查 backend 全链路（pos / screenshot / 非法键名）；
 * 非 Windows 只验证协议形状与「明确的平台错误」。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";

const SERVER = fileURLToPath(new URL("../mcp/server.mjs", import.meta.url));
const IS_WINDOWS = process.platform === "win32";

function startServer() {
  const child = spawn(process.execPath, [SERVER], { stdio: ["pipe", "pipe", "pipe"] });
  const pending = new Map();
  let nextId = 1;
  const rl = createInterface({ input: child.stdout, terminal: false });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      return;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const resolve = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    }
  });
  let stderrBuf = "";
  child.stderr.on("data", (chunk) => {
    stderrBuf += chunk;
  });

  function request(method, params) {
    const id = nextId++;
    const message = { jsonrpc: "2.0", id, method };
    if (params !== undefined) message.params = params;
    const promise = new Promise((resolve, reject) => {
      pending.set(id, resolve);
      setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error(`请求超时: ${method}\nstderr: ${stderrBuf.slice(-400)}`));
        }
      }, 90_000);
    });
    child.stdin.write(JSON.stringify(message) + "\n");
    return promise;
  }

  function notify(method, params) {
    const message = { jsonrpc: "2.0", method };
    if (params !== undefined) message.params = params;
    child.stdin.write(JSON.stringify(message) + "\n");
  }

  async function close() {
    try {
      child.kill();
    } catch {
      /* ignore */
    }
  }

  return { request, notify, close, child };
}

test("MCP 握手与工具清单", async () => {
  const server = startServer();
  try {
    const init = await server.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "gamectl-test", version: "0.0.0" },
    });
    assert.equal(init.result.protocolVersion, "2024-11-05");
    assert.equal(init.result.serverInfo.name, "dsh-game-control");
    assert.ok(init.result.capabilities.tools, "应声明 tools 能力");

    server.notify("notifications/initialized");

    const ping = await server.request("ping");
    assert.deepEqual(ping.result, {});

    const list = await server.request("tools/list");
    const names = list.result.tools.map((t) => t.name);
    assert.deepEqual(
      [...names].sort(),
      ["focus", "key", "mouse_click", "mouse_move", "mouse_wheel", "screenshot", "sequence", "windows"],
    );
    for (const tool of list.result.tools) {
      assert.equal(typeof tool.description, "string");
      assert.equal(tool.inputSchema.type, "object");
    }
  } finally {
    await server.close();
  }
});

test("tools/call 未知工具返回 isError", async () => {
  const server = startServer();
  try {
    await server.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "gamectl-test", version: "0.0.0" },
    });
    server.notify("notifications/initialized");
    const call = await server.request("tools/call", { name: "no_such_tool", arguments: {} });
    assert.equal(call.result.isError, true);
  } finally {
    await server.close();
  }
});

test("pos 全链路：MCP → server → PowerShell → JSON 结果", async (t) => {
  if (!IS_WINDOWS) {
    t.skip("需要 Windows");
    return;
  }
  const server = startServer();
  try {
    await server.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "gamectl-test", version: "0.0.0" },
    });
    server.notify("notifications/initialized");
    const call = await server.request("tools/call", { name: "windows", arguments: {} });
    assert.equal(call.result.isError, undefined, `windows 不应报错: ${call.result.content?.[0]?.text}`);
    const payload = JSON.parse(call.result.content[0].text);
    assert.equal(payload.ok, true);
    assert.ok(payload.count >= 0);

    const key = await server.request("tools/call", {
      name: "key",
      arguments: { key: "not_a_real_key", action: "tap" },
    });
    assert.equal(key.result.isError, true);
    assert.ok(key.result.content[0].text.includes("ok"), "错误结果应是 JSON 文本");
  } finally {
    await server.close();
  }
});

test("screenshot 全链路：返回存在的 PNG 路径", async (t) => {
  if (!IS_WINDOWS) {
    t.skip("需要 Windows");
    return;
  }
  const server = startServer();
  try {
    await server.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "gamectl-test", version: "0.0.0" },
    });
    server.notify("notifications/initialized");
    const outPath = path.join(os.tmpdir(), `gamectl-mcp-test-${process.pid}.png`);
    const call = await server.request("tools/call", {
      name: "screenshot",
      arguments: { region: [0, 0, 320, 200], out: outPath },
    });
    assert.equal(call.result.isError, undefined, `screenshot 不应报错: ${call.result.content?.[0]?.text}`);
    const payload = JSON.parse(call.result.content[0].text);
    assert.equal(payload.ok, true);
    assert.equal(payload.width, 320);
    assert.equal(payload.height, 200);
    assert.ok(fs.existsSync(outPath), "PNG 文件应已生成");
    fs.unlinkSync(outPath);
  } finally {
    await server.close();
  }
});

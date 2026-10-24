/**
 * dsh-game-control — 宿主适配器（cordis 入口）
 *
 * 职责只有一件事：把本包自带的 MCP stdio 服务器（mcp/server.mjs）通过
 * DSH 内置的 @deepseek-ai/dsh-mcp-client 桥接挂进宿主，让模型看到
 * mcp__gamectl__<tool> 这一组游戏操控工具。
 *
 * 形状对齐生态惯例（参考 dsh-computer-use-win 的桥接方式）：
 *   - name / inject 导出供 Loader 识别
 *   - apply 里 ctx.plugin(bridge, bridgeConfig()) 挂载子插件并等待连接
 *   - command 用 process.execPath + ELECTRON_RUN_AS_NODE=1，
 *     这样在 Electron 宿主里也能以纯 Node 拉起子进程
 *
 * ⚠️ 两条真机踩坑结论（2026-10-25，dsh 0.2.1-rc.3）：
 *   1. apply 必须是「同步普通函数」：cordis 加载器以 new apply(ctx, config)
 *      构造方式调用，async 函数不可构造，宿主条目会被静默跳过（无任何报错）。
 *   2. 不要写 export default —— 加载器优先读 default 导出，会丢失 inject/name。
 */
import { fileURLToPath } from "node:url";

export const name = "game-control";

/** MCP 工具最终要注册进宿主的工具注册表，必须等 tools 服务就绪。 */
export const inject = ["tools"];

export function bridgeConfig() {
  return {
    serverName: "gamectl",
    transport: "stdio",
    command: process.execPath,
    args: [fileURLToPath(new URL("./server.mjs", import.meta.url))],
    env: { ELECTRON_RUN_AS_NODE: "1" },
    toolCallTimeoutMs: 90_000,
    failOnStartupError: false,
  };
}

/**
 * @param ctx 宿主 cordis 上下文
 */
export function apply(ctx) {
  import("@deepseek-ai/dsh-mcp-client")
    .then((bridge) => {
      const connection = ctx.plugin(bridge, bridgeConfig());
      return connection;
    })
    .catch((error) => {
      try {
        console.error("[dsh-game-control] MCP 桥接挂载失败：", error);
      } catch {
        /* ignore */
      }
    });
}

/**
 * dsh-desktop-ctl — DSH 桌面操控插件。
 *
 * 把 cli/ 下的 dctl（Linux: AT-SPI + ydotool；Windows: UI Automation + SendInput）
 * 变成 agent 可直接调用的一项能力：一个 desktop 工具，argv 原样转发给 dctl。
 *
 * 设计取舍：
 * - 只有一个工具、参数就是 dctl 的命令行参数数组。教程、排错、示例脚本里的
 *   命令可以原样粘进 argv，agent 学到的是同一套心智模型，插件不做二次包装。
 * - 输出走 render 正文（不返回「执行成功」这类空壳状态），agent 看得到界面文本。
 * - Windows 下直接 spawn powershell.exe -File dctl.ps1，绕开 .cmd 的引号与编码坑。
 *
 * @module dsh-desktop-ctl
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import z from "@deepseek-ai/schemastery";
import { defineTool } from "@deepseek-ai/dsh-tools";

/** Cordis 插件名。 */
const name = "desktop-ctl";

/** 需要的宿主服务。 */
const inject = ["tools"];

/** 包根目录（node_modules/dsh-desktop-ctl）。 */
const PKG_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** 工具说明里的动词表，也作为系统提示词正文。 */
const VERBS = [
  "apps（列顶层窗口）",
  "find <文字> [--app 名] [--role Edit] [--depth N]（在无障碍树里找元素，返回 ref）",
  "tree <app> [--depth 12]（打印整棵树）",
  "info <ref> / read <ref>（读属性 / 读文本）",
  "act <ref>（点按钮、勾选、展开：默认选第一个可用动作）",
  "set <ref> <文本>（写输入框，中文与 emoji 都可靠）",
  "focus <ref>",
  "key ctrl+s / key alt+f4 / key win",
  "type <文本>（往当前焦点打字）",
  "click <x> <y>（最后手段，坐标来自截图换算或 geom）",
  "launch notepad [--wait 10] / wait --app 记事本 / wait --text 保存成功",
  "shot --json（截全屏存文件，拿路径后自己用 read_image 看）",
  "geom / doctor / selftest（坐标系体检、环境自检、全链路自检）",
].join("\n  - ");

/** 插件配置。 */
const Config = z.object({
  /** 覆盖 dctl 可执行文件路径；留空=用包内 cli/ 的默认后端。 */
  cliPath: z.string().default(""),
  /** Windows 下使用的 PowerShell 可执行文件。 */
  powershell: z.string().default("powershell.exe"),
  /** 单次调用超时（毫秒）。 */
  timeoutMs: z.number().default(120000),
  /** 是否往系统提示词注入一段用法说明。 */
  promptSection: z.boolean().default(true),
});

/**
 * 选后端可执行文件。
 * @param {object} cfg 插件配置
 * @param {string[]} argv dctl 参数
 * @returns {{ file: string, args: string[] }}
 */
function buildInvocation(cfg, argv) {
  const custom = String(cfg.cliPath || "").trim();
  if (process.platform === "win32") {
    if (custom) return { file: cfg.powershell, args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", custom, ...argv] };
    const ps1 = join(PKG_ROOT, "cli", "windows", "dctl.ps1");
    if (existsSync(ps1)) return { file: cfg.powershell, args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, ...argv] };
    return { file: "dctl", args: argv };
  }
  const sh = custom || join(PKG_ROOT, "cli", "linux", "dctl");
  return { file: existsSync(sh) ? sh : "dctl", args: argv };
}

/**
 * 跑一次 dctl，收集 stdout/stderr。
 * @returns {Promise<{ code: number, stdout: string, stderr: string, timedOut: boolean }>}
 */
function runDctl(cfg, argv) {
  const { file, args } = buildInvocation(cfg, argv);
  return new Promise((resolvePromise) => {
    let child;
    try {
      child = spawn(file, args, { windowsHide: true, env: { ...process.env, PYTHONIOENCODING: "utf-8" } });
    } catch (error) {
      resolvePromise({ code: -1, stdout: "", stderr: String(error?.message ?? error), timedOut: false });
      return;
    }
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill(); } catch { /* 已退出 */ }
    }, cfg.timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const finish = (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr, timedOut });
    };
    child.on("error", (error) => { stderr += String(error?.message ?? error); finish(-1); });
    child.on("close", (code) => finish(typeof code === "number" ? code : -1));
  });
}

/** 拼出可读命令行（仅用于展示）。 */
function display(argv) {
  return ["dctl", ...argv].map((part) => (/[\s"]/.test(part) ? JSON.stringify(part) : part)).join(" ");
}

/**
 * 注册工具。
 * @param {any} ctx cordis 上下文
 * @param {any} config 插件配置
 */
function apply(ctx, config) {
  const cfg = () => ({ ...Config(config) });

  ctx.tools.register(defineTool({
    name: "desktop",
    description:
      "操控本机图形桌面（Windows=UI Automation，Linux=AT-SPI）：找界面元素、点按钮、填输入框、按快捷键、截图。" +
      "元素级操作，不需要坐标、不抢焦点，是首选；坐标点击只做兜底。argv 就是 dctl 的参数数组，逐项传。\n" +
      "可用动词：\n  - " + VERBS + "\n" +
      "规则：改界面优先 act/set（按 ref），而不是 click 坐标；中文/emoji 只用 set 或 type，别用 key 拼；" +
      "截图只用来「看」，别拿截图像素当点击坐标；网页里的操作走 browser_*，不要用坐标点网页。加 --json 拿结构化输出。",
    parameters: {
      argv: {
        type: "array",
        items: { type: "string" },
        required: true,
        description: "dctl 的参数数组，例如 [\"find\",\"确定\",\"--app\",\"记事本\"] 或 [\"act\",\"3/0/2/1\"] 或 [\"shot\",\"--json\"]。",
      },
    },
    output: {
      schema: {
        type: "object",
        additionalProperties: false,
        properties: {
          command: { type: "string" },
          exitCode: { type: "integer" },
          text: { type: "string" },
        },
      },
      render: (_args, value) => {
        const head = value.exitCode === 0 ? "" : "(exit " + value.exitCode + ") ";
        return [{ type: "text", text: head + value.text }];
      },
    },
    isConcurrencySafe: () => false,
    async execute(args) {
      const argv = Array.isArray(args.argv) ? args.argv.map((s) => String(s)) : [];
      if (argv.length === 0) throw new Error("desktop: argv 不能为空，例如 [\"apps\"] 或 [\"find\",\"确定\",\"--app\",\"记事本\"]");
      const c = cfg();
      const result = await runDctl(c, argv);
      const body = [result.stdout, result.stderr].filter((s) => s && s.trim()).join("\n").trim();
      const text = result.timedOut ? body + "\n(超时 " + c.timeoutMs + "ms，进程已终止)" : body || "(无输出)";
      return { command: display(argv), exitCode: result.code, text };
    },
    presentCall: (args) => ({
      card: "generic",
      title: display(Array.isArray(args.argv) ? args.argv : []),
      kind: "other",
      rawInput: args,
    }),
  }));

  // 用法提示注入：让 agent 知道有这张牌，且知道先元素后坐标。
  if (config?.promptSection !== false) {
    ctx.inject(["systemPrompt"], (sctx) => {
      sctx.effect(() => {
        const dispose = sctx.systemPrompt.section({
          name: "desktop-ctl:usage",
          order: 460,
          text: [
            "## 操控本机桌面：desktop 工具",
            "`desktop` 工具的 argv 直接就是 dctl 的参数。顺序：apps → find <文字> --app <名> 拿 ref → act/set/read（ref 形如 3/0/1）。",
            "优先元素级操作（零坐标、不抢焦点）；click x y 只在没有无障碍树的界面用。",
            "中文与 emoji 用 set/type；截图用 shot --json 拿路径，再用 read_image 看。",
            "网页里的操作走 browser_*，不要用坐标点击网页。环境异常先跑 doctor，全链路验证跑 selftest。",
          ].join("\n"),
        });
        return () => { try { dispose?.(); } catch { /* 已释放 */ } };
      }, "desktop-ctl: usage prompt");
    });
  }
}

export { Config, apply, inject, name };

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { StringDecoder } from "node:string_decoder";

const MAX_OUTPUT_BYTES = 50 * 1024;
const MAX_OUTPUT_LINES = 2000;
const STARTUP_TIMEOUT_MS = 10_000;

function assertRecord(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

export function parseManifest(value) {
  const manifest = assertRecord(value, "MCP manifest");
  if (manifest.schema !== 1 || !Array.isArray(manifest.servers)) {
    throw new Error("MCP manifest must use schema 1 and contain a servers array");
  }

  const names = new Set();
  return manifest.servers.map((value, index) => {
    const server = assertRecord(value, `MCP server ${index}`);
    if (typeof server.name !== "string" || server.name.length === 0) {
      throw new Error(`MCP server ${index} has no name`);
    }
    if (names.has(server.name)) {
      throw new Error(`MCP manifest repeats server name '${server.name}'`);
    }
    names.add(server.name);
    if (typeof server.command !== "string" || server.command.length === 0) {
      throw new Error(`MCP server '${server.name}' has no command`);
    }
    if (!Array.isArray(server.args) || !server.args.every((arg) => typeof arg === "string")) {
      throw new Error(`MCP server '${server.name}' args must be strings`);
    }
    const env = assertRecord(server.env, `MCP server '${server.name}' env`);
    if (!Object.values(env).every((entry) => typeof entry === "string")) {
      throw new Error(`MCP server '${server.name}' env values must be strings`);
    }
    return { name: server.name, command: server.command, args: server.args, env };
  });
}

function truncateText(text) {
  const lines = text.split("\n");
  let content = lines.slice(0, MAX_OUTPUT_LINES).join("\n");
  let truncated = lines.length > MAX_OUTPUT_LINES;
  const bytes = Buffer.from(content, "utf8");
  if (bytes.length > MAX_OUTPUT_BYTES) {
    content = new TextDecoder().decode(bytes.subarray(0, MAX_OUTPUT_BYTES));
    truncated = true;
  }
  return { content, truncated };
}

async function formatResult(result, serverName, toolName) {
  const blocks = Array.isArray(result.content) ? result.content : [];
  const text = [];
  const images = [];

  for (const block of blocks) {
    if (block?.type === "text" && typeof block.text === "string") {
      text.push(block.text);
    } else if (
      block?.type === "image"
      && typeof block.data === "string"
      && typeof block.mimeType === "string"
    ) {
      images.push({ type: "image", data: block.data, mimeType: block.mimeType });
    } else {
      text.push(JSON.stringify(block));
    }
  }
  if (text.length === 0 && result.structuredContent !== undefined) {
    text.push(JSON.stringify(result.structuredContent));
  }

  const fullText = text.join("\n");
  const truncated = truncateText(fullText);
  if (truncated.truncated) {
    const outputPath = `/tmp/wrix-mcp-${randomUUID()}.log`;
    await writeFile(outputPath, fullText, { encoding: "utf8", mode: 0o600 });
    truncated.content += `\n\n[MCP output truncated. Full output saved to: ${outputPath}]`;
  }

  const content = [];
  if (truncated.content.length > 0) {
    content.push({ type: "text", text: truncated.content });
  }
  content.push(...images);
  if (content.length === 0) {
    content.push({ type: "text", text: "MCP tool completed without content." });
  }
  return {
    content,
    details: { server: serverName, tool: toolName },
  };
}

export class StdioClient {
  constructor(server) {
    this.server = server;
    this.nextId = 1;
    this.pending = new Map();
    this.decoder = new StringDecoder("utf8");
    this.buffer = "";
    this.stderr = "";
    this.closed = false;
    this.child = spawn(server.command, server.args, {
      cwd: process.cwd(),
      env: { ...process.env, ...server.env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stdout.on("data", (chunk) => this.readChunk(chunk));
    this.child.stdout.on("end", () => this.readEnd());
    this.child.stderr.on("data", (chunk) => {
      this.stderr = `${this.stderr}${chunk.toString("utf8")}`.slice(-8192);
    });
    this.child.on("error", (error) => this.fail(error));
    this.child.on("exit", (code, signal) => {
      if (!this.closed) {
        this.fail(new Error(`MCP server '${server.name}' exited (code=${code}, signal=${signal})`));
      }
    });
  }

  readChunk(chunk) {
    this.buffer += this.decoder.write(chunk);
    this.readLines(false);
  }

  readEnd() {
    this.buffer += this.decoder.end();
    this.readLines(true);
  }

  readLines(flush) {
    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline === -1) break;
      let line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (line.length > 0) this.receive(line);
    }
    if (flush && this.buffer.length > 0) {
      const line = this.buffer.endsWith("\r") ? this.buffer.slice(0, -1) : this.buffer;
      this.buffer = "";
      if (line.length > 0) this.receive(line);
    }
  }

  receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      this.fail(new Error(`MCP server '${this.server.name}' emitted invalid JSON: ${error.message}`));
      return;
    }

    if (message.id !== undefined && this.pending.has(message.id)) {
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error !== undefined) {
        pending.reject(new Error(`MCP error ${message.error.code}: ${message.error.message}`));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (message.id !== undefined && typeof message.method === "string") {
      this.send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: `Unsupported server request: ${message.method}` },
      }).catch((error) => this.fail(error));
    }
  }

  fail(error) {
    const detail = this.stderr.trim();
    const failure = detail.length === 0 ? error : new Error(`${error.message}: ${detail}`);
    for (const pending of this.pending.values()) pending.reject(failure);
    this.pending.clear();
  }

  send(message) {
    if (this.closed || this.child.stdin.destroyed) {
      return Promise.reject(new Error(`MCP server '${this.server.name}' is not writable`));
    }
    return new Promise((resolve, reject) => {
      this.child.stdin.write(`${JSON.stringify(message)}\n`, (error) => {
        if (error) reject(error);
        else resolve();
      });
    });
  }

  request(method, params, options = {}) {
    const id = this.nextId;
    this.nextId += 1;
    const timeoutMs = options.timeoutMs ?? 0;
    const signal = options.signal;

    return new Promise((resolve, reject) => {
      let timer;
      const finish = (callback, value) => {
        if (timer !== undefined) clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
        callback(value);
      };
      const abort = () => {
        this.pending.delete(id);
        finish(reject, new Error(`MCP request '${method}' was aborted`));
      };
      this.pending.set(id, {
        resolve: (value) => finish(resolve, value),
        reject: (error) => finish(reject, error),
      });
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          this.pending.delete(id);
          finish(reject, new Error(`MCP request '${method}' timed out after ${timeoutMs}ms`));
        }, timeoutMs);
      }
      if (signal?.aborted) {
        abort();
        return;
      }
      signal?.addEventListener("abort", abort, { once: true });
      this.send({ jsonrpc: "2.0", id, method, params }).catch((error) => {
        this.pending.delete(id);
        finish(reject, error);
      });
    });
  }

  async initialize() {
    await this.request(
      "initialize",
      {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "wrix-pi-mcp", version: "1" },
      },
      { timeoutMs: STARTUP_TIMEOUT_MS },
    );
    await this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  }

  async listTools() {
    const tools = [];
    let cursor;
    do {
      const result = await this.request(
        "tools/list",
        cursor === undefined ? {} : { cursor },
        { timeoutMs: STARTUP_TIMEOUT_MS },
      );
      if (!Array.isArray(result?.tools)) {
        throw new Error(`MCP server '${this.server.name}' returned an invalid tools/list result`);
      }
      tools.push(...result.tools);
      cursor = result.nextCursor;
    } while (typeof cursor === "string" && cursor.length > 0);
    return tools;
  }

  callTool(name, args, signal) {
    return this.request("tools/call", { name, arguments: args }, { signal });
  }

  close() {
    this.closed = true;
    const failure = new Error(`MCP server '${this.server.name}' closed`);
    for (const pending of this.pending.values()) pending.reject(failure);
    this.pending.clear();
    this.child.stdin.end();
    if (this.child.exitCode === null && this.child.signalCode === null) {
      const shutdownTimer = setTimeout(() => this.child.kill("SIGTERM"), 1000);
      shutdownTimer.unref();
      this.child.once("exit", () => clearTimeout(shutdownTimer));
    }
  }
}

export default function wrixMcpExtension(pi) {
  const clients = [];
  let initialized = false;

  pi.on("session_start", async () => {
    if (initialized) return;
    const manifestPath = process.env.WRIX_MCP_MANIFEST;
    if (manifestPath === undefined || manifestPath.length === 0) return;

    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    const servers = parseManifest(manifest);
    const registrations = [];
    const names = new Set(pi.getAllTools().map((tool) => tool.name));

    try {
      for (const server of servers) {
        const client = new StdioClient(server);
        clients.push(client);
        await client.initialize();
        const tools = await client.listTools();
        for (const tool of tools) {
          if (typeof tool?.name !== "string" || tool.name.length === 0) {
            throw new Error(`MCP server '${server.name}' returned a tool without a name`);
          }
          if (names.has(tool.name)) {
            throw new Error(`MCP tool name '${tool.name}' conflicts with an existing Pi tool`);
          }
          names.add(tool.name);
          const inputSchema = assertRecord(tool.inputSchema ?? { type: "object" }, `MCP tool '${tool.name}' schema`);
          registrations.push({ server, client, tool, inputSchema });
        }
      }

      for (const registration of registrations) {
        const { server, client, tool, inputSchema } = registration;
        pi.registerTool({
          name: tool.name,
          label: `${tool.name} (${server.name})`,
          description: tool.description ?? `Run ${tool.name} through the ${server.name} MCP server.`,
          parameters: { ...inputSchema, "~unsafe": null },
          async execute(_toolCallId, params, signal) {
            const result = await client.callTool(tool.name, params, signal);
            const formatted = await formatResult(result, server.name, tool.name);
            if (result?.isError === true) {
              const message = formatted.content
                .filter((block) => block.type === "text")
                .map((block) => block.text)
                .join("\n");
              throw new Error(message || `MCP tool '${tool.name}' failed`);
            }
            return formatted;
          },
        });
      }
      initialized = true;
    } catch (error) {
      for (const client of clients.splice(0)) client.close();
      throw error;
    }
  });

  pi.on("session_shutdown", () => {
    for (const client of clients.splice(0)) client.close();
    initialized = false;
  });
}

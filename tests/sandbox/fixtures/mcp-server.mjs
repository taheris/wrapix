import { StringDecoder } from "node:string_decoder";

const decoder = new StringDecoder("utf8");
let buffer = "";

function respond(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function receive(line) {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    respond({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "wrix-test-mcp", version: "1" },
      },
    });
  } else if (message.method === "tools/list") {
    respond({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        tools: [
          {
            name: "wrix_test_echo",
            description: "Echo text through the MCP test server.",
            inputSchema: {
              type: "object",
              properties: { text: { type: "string" } },
              required: ["text"],
              additionalProperties: false,
            },
          },
        ],
      },
    });
  } else if (message.method === "tools/call") {
    respond({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        content: [
          {
            type: "text",
            text: `${process.env.WRIX_MCP_TEST_ENV}:${message.params.arguments.text}`,
          },
        ],
      },
    });
  }
}

function readLines(flush) {
  while (true) {
    const newline = buffer.indexOf("\n");
    if (newline === -1) break;
    let line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (line.endsWith("\r")) line = line.slice(0, -1);
    if (line.length > 0) receive(line);
  }
  if (flush && buffer.length > 0) {
    receive(buffer.endsWith("\r") ? buffer.slice(0, -1) : buffer);
    buffer = "";
  }
}

process.stdin.on("data", (chunk) => {
  buffer += decoder.write(chunk);
  readLines(false);
});
process.stdin.on("end", () => {
  buffer += decoder.end();
  readLines(true);
});

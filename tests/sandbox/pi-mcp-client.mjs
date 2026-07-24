import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const [extensionPath, fixturePath, realServerCommand] = process.argv.slice(2);
if (extensionPath === undefined || fixturePath === undefined) {
  throw new Error("usage: pi-mcp-client.mjs <extension> <fixture> [real-server]");
}

const { StdioClient, parseManifest } = await import(pathToFileURL(extensionPath));

async function connect(server) {
  const client = new StdioClient(server);
  await client.initialize();
  return client;
}

const [fixtureServer] = parseManifest({
  schema: 1,
  servers: [
    {
      name: "test",
      command: process.execPath,
      args: [fixturePath],
      env: { WRIX_MCP_TEST_ENV: "manifest-env" },
    },
  ],
});
const fixtureClient = await connect(fixtureServer);
try {
  const tools = await fixtureClient.listTools();
  assert.deepEqual(tools.map((tool) => tool.name), ["wrix_test_echo"]);
  const result = await fixtureClient.callTool("wrix_test_echo", { text: "round-trip" });
  assert.equal(result.content[0].text, "manifest-env:round-trip");
} finally {
  fixtureClient.close();
}

if (realServerCommand !== undefined) {
  const [realServer] = parseManifest({
    schema: 1,
    servers: [{ name: "tmux", command: realServerCommand, args: [], env: {} }],
  });
  const realClient = await connect(realServer);
  try {
    const names = (await realClient.listTools()).map((tool) => tool.name);
    assert(names.includes("tmux_create_pane"));
    assert(names.includes("tmux_capture_pane"));
  } finally {
    realClient.close();
  }
}

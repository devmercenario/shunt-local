import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-eval-'));
const configDir = path.join(tmpDir, '.config', 'shunt-local');
fs.mkdirSync(configDir, { recursive: true });

process.env.HOME = tmpDir;
process.env.SHUNT_MOCK_ONLINE = "1";

const smallFile = path.join(tmpDir, 'small.txt');
fs.writeFileSync(smallFile, Array.from({ length: 50 }, (_, i) => `line ${i + 1}\n`).join(''));

const largeFile = path.join(tmpDir, 'large.txt');
fs.writeFileSync(largeFile, Array.from({ length: 400 }, (_, i) => `line ${i + 1}\n`).join(''));

let passed = 0;
let failed = 0;

function check(name, expected, actual, desc) {
  if (expected === actual) {
    console.log(`  \x1b[32mPASS\x1b[0m  ${name.padEnd(30)} ${desc}`);
    passed++;
  } else {
    console.log(`  \x1b[31mFAIL\x1b[0m  ${name.padEnd(30)} expected=[${expected}] got=[${actual}]`);
    failed++;
  }
}

async function run() {
  console.log("OpenCode Plugin Evals (plugins/opencode/shunt-local.ts)");
  console.log("────────────────────────────────────────────────────────────────");

  let pluginModule;
  try {
    pluginModule = await import('../plugins/opencode/shunt-local.ts');
  } catch (err) {
    console.error(`Failed to import plugin: ${err.message}`);
    console.log(`## 0 1`);
    process.exit(1);
  }

  const pluginFn = pluginModule.ShuntLocalOpenCodePlugin || pluginModule.default;
  if (!pluginFn) {
    console.error("Plugin export not found in shunt-local.ts");
    process.exit(1);
  }

  // Mock OpenCode context
  const mockContext = {
    $: async () => ({ stdout: "", stderr: "", exitCode: 0 })
  };

  const hooks = await pluginFn(mockContext);
  const hookFn = hooks["tool.execute.before"];

  // Test 1: Small file should not be blocked
  try {
    await hookFn({ tool: "read", sessionID: "s1", callID: "c1" }, { args: { filePath: smallFile } });
    check("small-file", "allowed", "allowed", "Files under threshold pass through");
  } catch (err) {
    check("small-file", "allowed", "blocked", err.message);
  }

  // Test 2: Large file should be blocked
  try {
    await hookFn({ tool: "read", sessionID: "s1", callID: "c2" }, { args: { filePath: largeFile } });
    check("large-file", "blocked", "allowed", "Files over threshold should be blocked");
  } catch (err) {
    const isRedirect = err.message.includes("bulk-reader");
    check("large-file", true, isRedirect, "Throws error redirecting to bulk-reader");
  }

  // Test 3: Targeted read with offset/limit should pass through
  try {
    await hookFn({ tool: "read", sessionID: "s1", callID: "c3" }, { args: { filePath: largeFile, offset: 10, limit: 20 } });
    check("targeted-read-offset", "allowed", "allowed", "Targeted read passes through");
  } catch (err) {
    check("targeted-read-offset", "allowed", "blocked", err.message);
  }

  // Test 4: Master switch disabled file should bypass
  const disabledFile = path.join(configDir, 'disabled');
  fs.writeFileSync(disabledFile, '');
  try {
    await hookFn({ tool: "read", sessionID: "s1", callID: "c4" }, { args: { filePath: largeFile } });
    check("master-switch-disabled", "allowed", "allowed", "Master switch OFF passes through");
  } catch (err) {
    check("master-switch-disabled", "allowed", "blocked", err.message);
  }
  fs.unlinkSync(disabledFile);

  // Test 5: Server offline should fail-open
  process.env.SHUNT_MOCK_ONLINE = "0";
  process.env.SHUNT_ENDPOINT = "http://127.0.0.1:59999/v1/chat/completions";
  try {
    await hookFn({ tool: "read", sessionID: "s1", callID: "c5" }, { args: { filePath: largeFile } });
    check("server-offline-fail-open", "allowed", "allowed", "Fails open when offline");
  } catch (err) {
    check("server-offline-fail-open", "allowed", "blocked", err.message);
  }
  process.env.SHUNT_MOCK_ONLINE = "1";

  // Test 6: Cat large file in bash tool
  try {
    await hookFn({ tool: "bash", sessionID: "s1", callID: "c6" }, { args: { command: `cat ${largeFile}` } });
    check("bash-cat-large-file", "blocked", "allowed", "cat large file should be blocked");
  } catch (err) {
    const isRedirect = err.message.includes("bulk-reader");
    check("bash-cat-large-file", true, isRedirect, "Throws redirect message for bash cat");
  }

  // Test 7: Piped cat in bash tool should pass through
  try {
    await hookFn({ tool: "bash", sessionID: "s1", callID: "c7" }, { args: { command: `cat ${largeFile} | grep "foo"` } });
    check("bash-cat-pipe", "allowed", "allowed", "Piped cat passes through");
  } catch (err) {
    check("bash-cat-pipe", "allowed", "blocked", err.message);
  }

  // Test 8: Restricted system directory access should throw security error
  try {
    await hookFn({ tool: "read", sessionID: "s1", callID: "c8" }, { args: { filePath: "/etc/passwd" } });
    check("security-restricted-path", "blocked", "allowed", "/etc/passwd should be denied");
  } catch (err) {
    const isSecurityErr = err.message.includes("restricted system directory");
    check("security-restricted-path", true, isSecurityErr, "Denies access to restricted system directory");
  }

  // Cleanup
  fs.rmSync(tmpDir, { recursive: true, force: true });

  console.log(`\n## ${passed} ${failed}`);
  console.log(`Results: ${passed} passed, ${failed} failed\n`);
  if (failed > 0) process.exit(1);
}

run();

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

interface OpenCodePluginContext {
  $?: any;
}

interface ToolExecuteInput {
  tool: string;
  sessionID: string;
  callID: string;
}

interface ToolExecuteOutput {
  args: any;
}

const RESTRICTED_SYSTEM_DIRS = ['/etc', '/boot', '/root', '/sys', '/proc', '/dev', '/usr/bin', '/usr/sbin', '/bin', '/sbin'];

function isSafePath(filePath: string): boolean {
  try {
    const resolved = fs.realpathSync(path.resolve(filePath));
    for (const sysDir of RESTRICTED_SYSTEM_DIRS) {
      if (resolved === sysDir || resolved.startsWith(sysDir + path.sep)) {
        return false;
      }
    }
    return true;
  } catch {
    // If path doesn't exist yet, check its resolved parent
    const resolved = path.resolve(filePath);
    for (const sysDir of RESTRICTED_SYSTEM_DIRS) {
      if (resolved === sysDir || resolved.startsWith(sysDir + path.sep)) {
        return false;
      }
    }
    return true;
  }
}

function loadConfig(): {
  enabled: boolean;
  minLines: number;
  endpoint: string;
  hookViewFile: boolean;
  hookRunCommand: boolean;
} {
  const homeDir = process.env.HOME || os.homedir();
  const disabledFile = path.join(homeDir, '.config', 'shunt-local', 'disabled');

  if (fs.existsSync(disabledFile)) {
    return { enabled: false, minLines: 350, endpoint: '', hookViewFile: false, hookRunCommand: false };
  }

  let cfgPath = '';
  if (process.env.SHUNT_CONFIG_PATH && fs.existsSync(process.env.SHUNT_CONFIG_PATH)) {
    cfgPath = process.env.SHUNT_CONFIG_PATH;
  } else if (fs.existsSync('./shunt.config.json')) {
    cfgPath = './shunt.config.json';
  } else {
    const userCfg = path.join(homeDir, '.config', 'shunt-local', 'config.json');
    if (fs.existsSync(userCfg)) cfgPath = userCfg;
  }

  let cfg: any = {};
  if (cfgPath) {
    try {
      cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf-8'));
    } catch {
      // Ignore parse errors, fallback to defaults
    }
  }

  const enabled = process.env.SHUNT_ENABLED !== undefined
    ? process.env.SHUNT_ENABLED === 'true' || process.env.SHUNT_ENABLED === '1'
    : (cfg.enabled !== undefined ? Boolean(cfg.enabled) : true);

  const minLines = Number(process.env.SHUNT_MIN_LINES || cfg.min_lines || 350);
  const endpoint = process.env.SHUNT_ENDPOINT || cfg.endpoint || 'http://127.0.0.1:8080/v1/chat/completions';
  const hookViewFile = process.env.SHUNT_HOOK_VIEW_FILE !== undefined
    ? process.env.SHUNT_HOOK_VIEW_FILE !== 'false' && process.env.SHUNT_HOOK_VIEW_FILE !== '0'
    : (cfg.hooks?.view_file !== undefined ? Boolean(cfg.hooks.view_file) : true);

  const hookRunCommand = process.env.SHUNT_HOOK_RUN_COMMAND !== undefined
    ? process.env.SHUNT_HOOK_RUN_COMMAND !== 'false' && process.env.SHUNT_HOOK_RUN_COMMAND !== '0'
    : (cfg.hooks?.run_command !== undefined ? Boolean(cfg.hooks.run_command) : true);

  return { enabled, minLines: isNaN(minLines) ? 350 : minLines, endpoint, hookViewFile, hookRunCommand };
}

async function isServerOnline(endpoint: string): Promise<boolean> {
  if (process.env.SHUNT_MOCK_ONLINE === '1') return true;
  if (process.env.SHUNT_MOCK_ONLINE === '0') return false;

  try {
    let healthUrl = endpoint.replace(/\/+$/, '');
    if (healthUrl.endsWith('/v1/chat/completions')) {
      healthUrl = healthUrl.replace(/\/v1\/chat\/completions$/, '/v1/models');
    }
    const res = await fetch(healthUrl, {
      method: 'GET',
      signal: AbortSignal.timeout(300),
    });
    return res.ok || res.status === 401 || res.status === 403; // Any responsive HTTP status means server is up
  } catch {
    return false;
  }
}

function countFileLines(filePath: string): number {
  try {
    const fd = fs.openSync(filePath, 'r');
    const buffer = Buffer.alloc(64 * 1024);
    let lines = 0;
    let bytesRead = 0;
    while ((bytesRead = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0) {
      for (let i = 0; i < bytesRead; i++) {
        if (buffer[i] === 10) lines++;
      }
    }
    fs.closeSync(fd);
    return lines;
  } catch {
    return 0;
  }
}

export const ShuntLocalOpenCodePlugin = async (_ctx: OpenCodePluginContext) => {
  return {
    'tool.execute.before': async (input: ToolExecuteInput, output: ToolExecuteOutput) => {
      const toolName = String(input?.tool ?? '').toLowerCase();

      // Intercept 'read' / 'file_read'
      if (toolName === 'read' || toolName === 'file_read') {
        const args = output?.args;
        if (!args || typeof args !== 'object') return;

        const filePath = String(args.filePath || args.path || args.file || '');
        if (!filePath) return;

        // Targeted read check (offset, limit, start_line, end_line)
        if (args.offset !== undefined || args.limit !== undefined || args.start_line !== undefined || args.end_line !== undefined) {
          return;
        }

        // Security check for system paths
        if (!isSafePath(filePath)) {
          throw new Error(`Access denied: file '${filePath}' resides in a restricted system directory.`);
        }

        if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
          return;
        }

        const config = loadConfig();
        if (!config.enabled || !config.hookViewFile) {
          return;
        }

        const lines = countFileLines(filePath);
        if (lines <= config.minLines) {
          return;
        }

        const online = await isServerOnline(config.endpoint);
        if (!online) {
          return; // Fail open when local model server is offline
        }

        throw new Error(
          `File ${filePath} has ${lines} lines (threshold: ${config.minLines}).\n` +
          `Do not read this file directly into context.\n` +
          `Delegate to the local LLM using the /bulk-reader skill or CLI command:\n` +
          `  bulk-read "${filePath}" "<your query>"`
        );
      }

      // Intercept 'bash' / 'shell'
      if (toolName === 'bash' || toolName === 'shell') {
        const args = output?.args;
        if (!args || typeof args !== 'object') return;

        const cmd = String(args.command ?? '').trim();
        if (!cmd) return;

        // Skip piped commands or redirections
        if (cmd.includes('|') || cmd.includes('>')) return;

        // Match cat, head, tail, less, more
        const match = cmd.match(/^(cat|head|tail|less|more)\s+(.+)$/);
        if (!match) return;

        const rawArgs = match[2].trim();
        // Extract filename ignoring flags
        const tokens = rawArgs.split(/\s+/);
        let targetFile = '';
        for (const tok of tokens) {
          if (!tok.startsWith('-')) {
            targetFile = tok.replace(/['"]/g, '');
            break;
          }
        }

        if (!targetFile || !fs.existsSync(targetFile) || !fs.statSync(targetFile).isFile()) {
          return;
        }

        // Security check
        if (!isSafePath(targetFile)) {
          throw new Error(`Access denied: file '${targetFile}' resides in a restricted system directory.`);
        }

        const config = loadConfig();
        if (!config.enabled || !config.hookRunCommand) return;

        const lines = countFileLines(targetFile);
        if (lines <= config.minLines) return;

        const online = await isServerOnline(config.endpoint);
        if (!online) return;

        throw new Error(
          `File ${targetFile} has ${lines} lines (threshold: ${config.minLines}).\n` +
          `Intercepted bash read. Delegate to the local LLM using the /bulk-reader skill or CLI command:\n` +
          `  bulk-read "${targetFile}" "<your query>"`
        );
      }
    },
  };
};

export default ShuntLocalOpenCodePlugin;

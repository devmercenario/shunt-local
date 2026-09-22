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

const RESTRICTED_SYSTEM_DIRS = [
  '/etc', '/boot', '/root', '/sys', '/proc', '/dev', '/usr/bin', '/usr/sbin', '/bin', '/sbin',
  // macOS resolves these through /private (e.g. /etc -> /private/etc).
  '/private/etc', '/private/var', '/private/tmp', '/private/root',
];

const SENSITIVE_NAMES = new Set([
  '.git', '.github', '.gitlab', '.circleci', '.husky', '.githooks',
  '.env', '.env.local', '.env.production', '.npmrc', '.pypirc', '.netrc',
  '.gitmodules', '.gitattributes', '.bashrc', '.profile', '.zshrc',
  'package.json', 'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock',
  'pnpm-lock.yaml', 'Makefile', 'makefile', 'GNUmakefile', 'Dockerfile',
  'docker-compose.yml', 'docker-compose.yaml', 'Gemfile', 'Gemfile.lock',
  'Cargo.toml', 'Cargo.lock', 'go.mod', 'go.sum', 'pyproject.toml',
  'setup.py', 'setup.cfg', 'pytest.ini', 'tox.ini', 'requirements.txt',
  'poetry.lock', 'shunt.config.json', 'install.sh', 'shunt-update',
  'authorized_keys', 'id_rsa', 'id_ed25519', 'credentials',
]);

function isSafeWritePath(filePath: string): boolean {
  const resolved = path.resolve(filePath);
  const home = process.env.HOME || os.homedir();
  if (resolved.startsWith(home + path.sep + '.')) return false;
  const allowOutside = process.env.SHUNT_ALLOW_WRITES_OUTSIDE_CWD === 'true';
  const rel = path.relative(process.cwd(), resolved);
  const inside = rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
  if (!inside && !allowOutside) return false;
  if (process.env.SHUNT_ALLOW_SENSITIVE_WRITES !== 'true') {
    if (SENSITIVE_NAMES.has(path.basename(resolved))) return false;
    if (rel.split(path.sep).some((part) => SENSITIVE_NAMES.has(part))) return false;
  }
  return true;
}

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
  } else if (process.env.SHUNT_ALLOW_PROJECT_CONFIG === 'true' && fs.existsSync('./shunt.config.json')) {
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

function isLocalEndpoint(endpoint: string): boolean {
  try {
    const u = new URL(endpoint);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
    return ['127.0.0.1', 'localhost', '::1', '[::1]', '0.0.0.0'].includes(u.hostname);
  } catch {
    return false;
  }
}

function isSupportedEndpoint(endpoint: string): boolean {
  try {
    const protocol = new URL(endpoint).protocol;
    return protocol === 'http:' || protocol === 'https:';
  } catch {
    return false;
  }
}

async function isServerOnline(endpoint: string): Promise<boolean> {
  if (process.env.SHUNT_MOCK_ONLINE === '1') return true;
  if (process.env.SHUNT_MOCK_ONLINE === '0') return false;

  // Fail closed on unsupported schemes and non-local endpoints unless explicitly
  // allowed. This prevents a config-poisoned endpoint from becoming a beacon on
  // every intercepted read/bash.
  if (!isSupportedEndpoint(endpoint)) {
    return false;
  }
  const isLocal = isLocalEndpoint(endpoint);
  if (!isLocal && process.env.SHUNT_ALLOW_REMOTE !== 'true') {
    return false;
  }
  if (!isLocal && !endpoint.toLowerCase().startsWith('https://')) {
    return false; // Remote endpoints must use TLS.
  }

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
      if (toolName === 'bash' || toolName === 'shell') {        const args = output?.args;
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

      // Intercept 'write' / 'edit' / 'multiedit' — block protected paths.
      if (toolName === 'write' || toolName === 'edit' || toolName === 'multiedit') {
        const args = output?.args;
        if (!args || typeof args !== 'object') return;
        const filePath = String(args.filePath || args.file_path || args.path || args.file || '');
        if (!filePath) return;
        if (!isSafeWritePath(filePath)) {
          throw new Error(
            `shunt-local blocked this write: '${filePath}' is a protected or out-of-project path.\n` +
            `Set SHUNT_ALLOW_SENSITIVE_WRITES=true or SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true if this is intentional.`
          );
        }
      }
    },
  };
};

export default ShuntLocalOpenCodePlugin;

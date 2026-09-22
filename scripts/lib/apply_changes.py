import sys, os, re, hashlib, tempfile
sys.path.insert(0, os.environ.get('SHUNT_LIB_DIR') or os.path.dirname(os.path.abspath(__file__)))
import paths

response = sys.argv[1]
targets = [paths.to_native(t) for t in sys.argv[2:]]

# C3: Security — all writes restricted to the current working directory (symlinks
# resolved). Declared --files targets are NOT implicitly trusted, because they are
# chosen by the agent (which is prompt-injectable). Operators who genuinely need to
# write outside the project tree must set SHUNT_ALLOW_WRITES_OUTSIDE_CWD=true.
CWD = os.path.realpath(os.getcwd())
HOME = os.path.expanduser('~')
ALLOWED_TARGETS = set(os.path.realpath(os.path.abspath(t)) for t in targets)
ALLOW_OUTSIDE_CWD = os.environ.get('SHUNT_ALLOW_WRITES_OUTSIDE_CWD') == 'true'
ALLOW_SENSITIVE = os.environ.get('SHUNT_ALLOW_SENSITIVE_WRITES') == 'true'

# Write safety is shared with the PreToolUse guard (scripts/lib/paths.py).
def is_safe_target(t):
    return paths.is_safe_write(
        t, cwd=CWD, home=HOME, allow_outside=ALLOW_OUTSIDE_CWD,
        allow_sensitive=ALLOW_SENSITIVE, allowed_targets=ALLOWED_TARGETS)

# When SHUNT_STAGE_DIR is set, writes are staged there instead of applied, so
# the caller can review a diff before anything touches the working tree.
STAGE_DIR = paths.to_native(os.environ.get('SHUNT_STAGE_DIR', ''))
STAGE_ONLY = bool(STAGE_DIR)

def emit_write(target, content):
    if STAGE_ONLY:
        os.makedirs(STAGE_DIR, exist_ok=True)
        digest = hashlib.sha1(target.encode('utf-8', 'surrogatepass')).hexdigest()[:10]
        staged = os.path.join(STAGE_DIR, digest + '-' + os.path.basename(target))
        with open(staged, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"STAGED_WRITE:{target}:{staged}")
    else:
        # Write to a sibling temp file then os.replace: this is atomic and, unlike
        # open(target, 'w'), replaces the directory entry instead of following a
        # symlink, so a symlinked target cannot redirect the write (TOCTOU).
        target_dir = os.path.dirname(os.path.abspath(target))
        os.makedirs(target_dir, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=target_dir, prefix='.shunt-', suffix='.tmp')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                f.write(content)
            os.replace(tmp_path, target)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
        print(f"WROTE_FILE:{target}")

# 1. Look for SEARCH/REPLACE blocks first
search_replace_pattern = re.compile(r'<<<<<<< SEARCH\n(.*?)\n=======\n(.*?)\n>>>>>>> REPLACE', re.DOTALL)
matches = list(search_replace_pattern.finditer(response))

if matches and len(targets) == 1:
    target_path = targets[0]
    if is_safe_target(target_path) and os.path.exists(target_path):
        with open(target_path, 'r', encoding='utf-8') as f:
            content = f.read()
        applied = 0
        for m in matches:
            search_block = m.group(1)
            replace_block = m.group(2)
            if search_block in content:
                content = content.replace(search_block, replace_block, 1)
                applied += 1
        if applied > 0:
            emit_write(target_path, content)
            sys.exit(0)

# 2. Look for code fences with target filename in fence info or header
fence_pattern = re.compile(r'```(?:[a-zA-Z0-9_-]+[ \t]+)?([^\n`]*)\n(.*?)\n```', re.DOTALL)
fence_matches = list(fence_pattern.finditer(response))

handled = set()
for m in fence_matches:
    header = m.group(1).strip()
    code = m.group(2)
    
    # Try to match header with one of the target files
    matched_target = None
    for t in targets:
        if t in header or os.path.basename(t) in header:
            matched_target = t
            break
    
    if not matched_target and len(targets) == 1 and not handled:
        matched_target = targets[0]

    if matched_target and matched_target not in handled:
        if not is_safe_target(matched_target):
            print(f"SECURITY_ERROR: Target path escapes working directory: {matched_target}", file=sys.stderr)
            continue
        emit_write(matched_target, code + '\n')
        handled.add(matched_target)

# 3. Fallback: if single target and response has a generic code block without filename
if not handled and len(targets) == 1:
    raw_blocks = re.findall(r'```(?:[a-zA-Z0-9_-]+)?\n(.*?)\n```', response, re.DOTALL)
    if raw_blocks:
        t = targets[0]
        if is_safe_target(t):
            emit_write(t, raw_blocks[0] + '\n')

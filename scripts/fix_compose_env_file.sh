#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p backups scripts

cp -a docker-compose.yml "backups/docker-compose.yml.${TS}.fixenv.bak"
echo "OK: backup -> backups/docker-compose.yml.${TS}.fixenv.bak"

python3 - <<'PY'
import re, pathlib

p = pathlib.Path("docker-compose.yml")
txt = p.read_text(encoding="utf-8")
lines = txt.splitlines(True)

# locate service block: "  litellm:"
start = None
for i, line in enumerate(lines):
    if re.match(r"^  litellm:\s*$", line):
        start = i
        break
if start is None:
    raise SystemExit("ERROR: cannot find 'services: litellm:' block (line: '  litellm:') in docker-compose.yml")

# end at next service with same indentation ("  xxx:")
end = len(lines)
for j in range(start+1, len(lines)):
    if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j]):
        end = j
        break

block = lines[start:end]

def ensure_env_file_string(block):
    out = []
    i = 0
    fixed = False
    while i < len(block):
        line = block[i]
        # inline list: env_file: [".env"]
        m_inline = re.match(r"^(\s{4})env_file:\s*\[(.*)\]\s*$", line)
        if m_inline:
            indent = m_inline.group(1)
            # take first item if present, else default .env
            inside = m_inline.group(2).strip()
            first = ".env"
            if inside:
                # naive split by comma
                first = inside.split(",")[0].strip().strip("'\"") or ".env"
            out.append(f"{indent}env_file: {first}\n")
            i += 1
            fixed = True
            continue

        # block list:
        if re.match(r"^\s{4}env_file:\s*$", line):
            indent = "    "
            # consume following list items
            i += 1
            first = ".env"
            while i < len(block) and re.match(r"^\s{6}-\s*", block[i]):
                item = block[i].strip().lstrip("-").strip().strip("'\"")
                if item:
                    first = item
                    break
                i += 1
            # also skip remaining list items
            while i < len(block) and re.match(r"^\s{6}-\s*", block[i]):
                i += 1
            out.append(f"{indent}env_file: {first}\n")
            fixed = True
            continue

        # already string: env_file: .env
        if re.match(r"^\s{4}env_file:\s*[^#\s]+\s*$", line):
            out.append(line)
            i += 1
            continue

        out.append(line)
        i += 1

    # if no env_file at all, insert after image line if possible
    joined = "".join(out)
    if "env_file:" not in joined:
        inserted = False
        new_out = []
        for line in out:
            new_out.append(line)
            if (not inserted) and re.match(r"^\s{4}image:\s+", line):
                new_out.append("    env_file: .env\n")
                inserted = True
        out = new_out if inserted else (out[:1] + ["    env_file: .env\n"] + out[1:])
        fixed = True

    return out, fixed

def ensure_ports_localhost(block):
    out = []
    in_ports = False
    ports_found = False
    has_local = False

    for line in block:
        if re.match(r"^\s{4}ports:\s*$", line):
            in_ports = True
            ports_found = True
            out.append(line)
            continue

        if in_ports:
            if re.match(r"^\s{6}-\s*", line):
                s = line.strip().lstrip("-").strip().strip("'\"")
                if s.endswith("4000:4000"):
                    out.append('      - "127.0.0.1:4000:4000"\n')
                    has_local = True
                else:
                    out.append(line)
                continue
            # leaving ports section
            if re.match(r"^\s{4}\S", line):
                in_ports = False

        out.append(line)

    joined = "".join(out)
    if not ports_found:
        # insert ports after env_file if possible, else after image
        inserted = False
        new_out = []
        for line in out:
            new_out.append(line)
            if (not inserted) and re.match(r"^\s{4}env_file:\s*", line):
                new_out.append("    ports:\n")
                new_out.append('      - "127.0.0.1:4000:4000"\n')
                inserted = True
        if not inserted:
            new_out = []
            inserted2 = False
            for line in out:
                new_out.append(line)
                if (not inserted2) and re.match(r"^\s{4}image:\s+", line):
                    new_out.append("    ports:\n")
                    new_out.append('      - "127.0.0.1:4000:4000"\n')
                    inserted2 = True
            inserted = inserted2
        out = new_out if inserted else (out[:1] + ["    ports:\n", '      - "127.0.0.1:4000:4000"\n'] + out[1:])
    else:
        # ports existed but we might not have any localhost mapping (e.g. only others)
        if not re.search(r'127\.0\.0\.1:4000:4000', joined):
            # if it contains 4000:4000 but not localhost, normalize again
            out2 = []
            for line in out:
                if re.match(r'^\s{6}-\s*["\']?4000:4000["\']?\s*$', line.strip()):
                    out2.append('      - "127.0.0.1:4000:4000"\n')
                else:
                    out2.append(line)
            out = out2

    return out

def ensure_environment_flags(block):
    txt = "".join(block)
    need_json = "JSON_LOGS" not in txt
    need_lvl = "LITELLM_LOG" not in txt
    if not (need_json or need_lvl):
        return block

    out = []
    env_idx = None
    for i, line in enumerate(block):
        if re.match(r"^\s{4}environment:\s*$", line):
            env_idx = i
            break

    if env_idx is None:
        # insert after env_file if possible
        inserted = False
        for line in block:
            out.append(line)
            if (not inserted) and re.match(r"^\s{4}env_file:\s*", line):
                out.append("    environment:\n")
                if need_json: out.append("      - JSON_LOGS=True\n")
                if need_lvl: out.append("      - LITELLM_LOG=ERROR\n")
                inserted = True
        return out if inserted else (block[:1] + ["    environment:\n", "      - JSON_LOGS=True\n", "      - LITELLM_LOG=ERROR\n"] + block[1:])

    # if environment exists, just add list-style entries right after it
    for i, line in enumerate(block):
        out.append(line)
        if i == env_idx:
            if need_json: out.append("      - JSON_LOGS=True\n")
            if need_lvl: out.append("      - LITELLM_LOG=ERROR\n")
    return out

block, _ = ensure_env_file_string(block)
block = ensure_ports_localhost(block)
block = ensure_environment_flags(block)

new_lines = lines[:start] + block + lines[end:]
p.write_text("".join(new_lines), encoding="utf-8")
print("OK: docker-compose.yml fixed (env_file string + localhost port + json logs)")
PY

echo "OK: validate compose..."
docker compose config >/dev/null

echo "OK: restart..."
docker compose down
docker compose up -d

echo "OK: ps"
docker compose ps

echo "OK: router test"
./scripts/test_router.sh

echo "OK: model tests"
./scripts/test_models.sh deepseek-chat kimi-chat default-chat long-chat premium-chat best-effort-chat

echo "DONE ✅ compose fixed + tests passed."

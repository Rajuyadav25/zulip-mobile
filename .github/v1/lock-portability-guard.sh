#!/usr/bin/env bash
# Release Pipeline V1 — Lock Portability Guard (inspection-checklist.md §13A)
#
# Run after a dependency installation that may rewrite a source-controlled
# lock. Fails closed unless every difference between the committed lock and
# the working lock is a recorded non-portable (checkout-path-dependent)
# entry whose value is re-proven by path substitution.
#
# Usage: lock-portability-guard.sh <config-file> [evidence-dir]
#
# Config (KEY=VALUE, '#' comments; values are repository-specific and must
# trace to build-requirements.md):
#   LOCK_FILE=<repo-relative lock path>
#   RECORDED_ROOT=<absolute checkout root that produced the committed lock>
#   ENTRY_PATTERN=<Python regex with {name}; group 1 captures the entry value>
#   HASH_ALGORITHM=<hashlib algorithm used for entry values, e.g. sha1>
#   ENTRY=<entry name>|<repo-relative generated input whose hash is the value>
#   (ENTRY may repeat; zero ENTRY lines means no lock line may differ.)
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <config-file> [evidence-dir]" >&2
  exit 2
fi
CONFIG_FILE="$1"
EVIDENCE_DIR="${2:-}"
ROOT="$(git rev-parse --show-toplevel)"
COMMITTED_REF="${LOCK_GUARD_COMMITTED_REF:-HEAD}"

export ROOT CONFIG_FILE EVIDENCE_DIR COMMITTED_REF
python3 - <<'PY'
import difflib, hashlib, os, re, subprocess, sys

root = os.environ["ROOT"]
config_path = os.environ["CONFIG_FILE"]
evidence_dir = os.environ["EVIDENCE_DIR"]
ref = os.environ["COMMITTED_REF"]

cfg, entries = {}, []
with open(config_path) as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        if key == "ENTRY":
            name, _, generated = value.partition("|")
            entries.append((name, generated))
        else:
            cfg[key] = value
for required in ("LOCK_FILE", "RECORDED_ROOT", "ENTRY_PATTERN", "HASH_ALGORITHM"):
    if not cfg.get(required):
        sys.exit(f"lock guard: config missing {required}")

lock_rel = cfg["LOCK_FILE"]
recorded_root = cfg["RECORDED_ROOT"]
pattern = cfg["ENTRY_PATTERN"]
report, failures = [], []
log = report.append

def git(*args):
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, text=True).stdout

def digest(data):
    h = hashlib.new(cfg["HASH_ALGORITHM"])
    h.update(data)
    return h.hexdigest()

committed = git("show", f"{ref}:{lock_rel}").splitlines()
with open(os.path.join(root, lock_rel)) as f:
    current = f.read().splitlines()

log(f"lock_file={lock_rel}")
log(f"committed_ref={ref} ({git('rev-parse', ref).strip()})")
log(f"checkout_root={root}")
log(f"recorded_root={recorded_root}")
log(f"declared_entries={','.join(n for n, _ in entries) or '(none)'}")

changed = [l for l in difflib.ndiff(committed, current) if l[:2] in ("- ", "+ ")]
log(f"changed_lock_lines={len(changed)}")
for line in changed:
    log(f"  {line}")

declared = {name: generated for name, generated in entries}
seen = {}
for line in changed:
    sign, text = line[0], line[2:]
    match_name = None
    for name in declared:
        m = re.fullmatch(pattern.replace("{name}", re.escape(name)), text)
        if m:
            match_name = name
            seen.setdefault(name, {})[sign] = m.group(1)
            break
    if match_name is None:
        failures.append(f"undeclared lock change: {line}")

for name, generated in declared.items():
    gen_path = os.path.join(root, generated)
    old_new = seen.get(name)
    if not os.path.isfile(gen_path):
        failures.append(f"{name}: generated input missing: {generated}")
        continue
    data = open(gen_path, "rb").read()
    actual = digest(data)
    mapped = digest(data.replace(root.encode(), recorded_root.encode()))
    embeds_root = root.encode() in data
    committed_value = None
    for l in committed:
        m = re.fullmatch(pattern.replace("{name}", re.escape(name)), l)
        if m:
            committed_value = m.group(1)
    log(f"entry {name}: generated={generated} embeds_checkout_root={embeds_root}")
    log(f"  committed={committed_value} current_input_hash={actual} path_mapped_hash={mapped}")
    if committed_value is None:
        failures.append(f"{name}: entry absent from committed lock")
        continue
    if old_new is None:
        if actual != committed_value:
            failures.append(f"{name}: unchanged lock entry but generated input hash {actual} != {committed_value}")
        else:
            log(f"  {name}: identical at this checkout path")
        continue
    if old_new.get("+") != actual:
        failures.append(f"{name}: working lock value {old_new.get('+')} != generated input hash {actual}")
    if mapped != committed_value:
        failures.append(f"{name}: path-substitution proof failed ({mapped} != committed {committed_value})")
    else:
        log(f"  {name}: path-dependent difference PROVEN by substitution")

other = [l for l in git("status", "--porcelain", "--untracked-files=no").splitlines() if l[3:] != lock_rel]
if other:
    failures.append("tracked files other than the lock changed: " + "; ".join(other))

verdict = "PASS" if not failures else "FAIL"
for item in failures:
    log(f"FAILURE: {item}")
log(f"verdict={verdict}")
text = "\n".join(report) + "\n"
sys.stdout.write(text)
if evidence_dir:
    os.makedirs(evidence_dir, exist_ok=True)
    with open(os.path.join(evidence_dir, "lock-portability-guard.txt"), "w") as f:
        f.write(text)
    with open(os.path.join(evidence_dir, "lock-portability-diff.patch"), "w") as f:
        f.write("".join(difflib.unified_diff([l + "\n" for l in committed], [l + "\n" for l in current],
                                             f"{ref}:{lock_rel}", f"working:{lock_rel}")))
sys.exit(0 if verdict == "PASS" else 1)
PY

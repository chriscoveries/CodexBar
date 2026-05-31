#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLI="${CODEXBAR_CLI:-$ROOT/CodexBar.app/Contents/Helpers/CodexBarCLI}"
TIMEOUT_BIN="${TIMEOUT_BIN:-$(command -v gtimeout || command -v timeout || true)}"
WEB_TIMEOUT="${CODEXBAR_QA_WEB_TIMEOUT:-12}"
CASE_TIMEOUT="${CODEXBAR_QA_CASE_TIMEOUT:-60}"

usage() {
  cat <<'USAGE'
Usage:
  live_provider_matrix.sh --enabled
  live_provider_matrix.sh --default
  live_provider_matrix.sh --provider all
  live_provider_matrix.sh --providers openai,zai,deepseek

Environment:
  CODEXBAR_CLI=/path/to/CodexBarCLI
  CODEXBAR_QA_WEB_TIMEOUT=12
  CODEXBAR_QA_CASE_TIMEOUT=60
USAGE
}

if [[ ! -x "$CLI" ]]; then
  echo "missing CodexBarCLI at $CLI" >&2
  exit 2
fi
if [[ -z "$TIMEOUT_BIN" ]]; then
  echo "missing timeout command (install coreutils for gtimeout)" >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  echo "missing node" >&2
  exit 2
fi

mode="${1:-}"
shift || true

providers=()
case "$mode" in
  --enabled)
    if [[ ! -f "$HOME/.codexbar/config.json" ]]; then
      echo "missing ~/.codexbar/config.json" >&2
      exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "missing jq" >&2
      exit 2
    fi
    provider_list="$(mktemp)"
    if ! jq -r '(.providers // [])[] | select(.enabled == true) | .id' "$HOME/.codexbar/config.json" >"$provider_list"; then
      rm -f "$provider_list"
      echo "failed to parse ~/.codexbar/config.json" >&2
      exit 2
    fi
    while IFS= read -r provider; do
      [[ -n "$provider" ]] && providers+=("$provider")
    done <"$provider_list"
    rm -f "$provider_list"
    if [[ "${#providers[@]}" -eq 0 ]]; then
      echo "no enabled providers found in ~/.codexbar/config.json" >&2
      exit 2
    fi
    ;;
  --default)
    providers=("__default__")
    ;;
  --provider)
    if [[ -z "${1:-}" ]]; then
      echo "missing provider" >&2
      exit 2
    fi
    providers=("${1:-}")
    ;;
  --providers)
    if [[ -z "${1:-}" ]]; then
      echo "missing providers" >&2
      exit 2
    fi
    IFS=',' read -r -a providers <<< "${1:-}"
    ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    echo "unknown mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac

redact_node='
const redact = s => String(s || "")
  .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, "<email>")
  .replace(/sk-[A-Za-z0-9_-]{12,}/g, "sk-REDACTED")
  .replace(/gsk_[A-Za-z0-9_-]{12,}/g, "gsk_REDACTED")
  .replace(/[A-Za-z0-9_-]{32,}/g, m => /[A-Za-z]/.test(m) && /[0-9]/.test(m) ? "<redacted-token>" : m);
'

run_one() {
  local name="$1"
  shift
  local out err start end elapsed st node_status
  out="$(mktemp)"
  err="$(mktemp)"
  start="$(date +%s)"
  "$TIMEOUT_BIN" "$CASE_TIMEOUT" "$CLI" usage "$@" --format json --json-only --web-timeout "$WEB_TIMEOUT" >"$out" 2>"$err"
  st=$?
  end="$(date +%s)"
  elapsed=$((end - start))
  node - "$name" "$st" "$elapsed" "$out" "$err" <<NODE
const fs = require("fs");
$redact_node
const [name, st, elapsed, outPath, errPath] = process.argv.slice(2);
const raw = fs.readFileSync(outPath, "utf8").trim();
const err = fs.readFileSync(errPath, "utf8").trim();
let rows = [];
let formatterFailed = false;
try {
  const payload = raw ? JSON.parse(raw) : [];
  const arr = Array.isArray(payload) ? payload : [payload];
  for (const p of arr) {
    rows.push(
      \`\${p.provider || name}:\${p.error ? "fail" : "ok"}:source=\${p.source || "unknown"}\` +
      (p.account ? \`,account=\${redact(p.account)}\` : "") +
      (p.usage ? ",usage=yes" : "") +
      (p.credits ? ",credits=yes" : "") +
      (p.error ? \`,error=\${redact(p.error.message).slice(0, 180)}\` : "")
    );
  }
} catch (error) {
  formatterFailed = true;
  rows.push(\`\${name}:parse-fail:error=\${redact(error.message)} stdout=\${redact(raw).slice(0, 200)} stderr=\${redact(err).slice(0, 200)}\`);
}
if (!rows.length) {
  formatterFailed = true;
  rows.push(\`\${name}:empty:stderr=\${redact(err).slice(0, 200)}\`);
}
console.log(\`TEST \${name} exit=\${st} elapsed=\${elapsed}s :: \${rows.join(" | ")}\`);
if (formatterFailed) process.exit(1);
NODE
  node_status=$?
  rm -f "$out" "$err"
  if [[ "$node_status" -ne 0 ]]; then
    return 1
  fi
  return "$st"
}

overall=0
ran=0
for provider in "${providers[@]}"; do
  [[ -z "$provider" ]] && continue
  ran=$((ran + 1))
  if [[ "$provider" == "__default__" ]]; then
    run_one default || overall=1
  elif [[ "$provider" == "all" ]]; then
    run_one all --provider all || overall=1
  else
    run_one "$provider" --provider "$provider" || overall=1
  fi
done
if [[ "$ran" -eq 0 ]]; then
  echo "no provider cases ran" >&2
  exit 2
fi
exit "$overall"

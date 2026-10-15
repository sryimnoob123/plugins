#!/usr/bin/env bash
# opendesign wire patch installer — 2026-10-15
#
# What it does: puts the per-model API patch (magpie-community/plugins PR #141,
# fork branch sryimnoob123/plugins@opendesign-0.1.5) into the opendesign plugin
# magpie actually loads, so a chat client gets the models' thinking again.
#
# Why: the installed 0.1.4 declares "@ai-sdk/openai" (the Responses API) for
# every model, and magpie reads a model's API off that package. amr-link streams
# deepseek-v4.1-flash's thinking only in the closing item of a Responses stream,
# which magpie's translation to Chat Completions drops — no thinking chain in
# Hermes/ZCode for any request the provider served. The patch asks each model on
# the API its thinking comes back on (chat completions by default, Responses for
# claude-haiku-5.5 and deepseek-v4-pro, Anthropic's messages for glm-5.3-flash),
# which also declares all three of the provider's endpoints.
#
# Safe to re-run: it aborts unless the installed file is the untouched 0.1.4, and
# it keeps a .bak-<timestamp> of whatever it replaces.
#
#   bash install-opendesign-wire.sh
#
# Needs: curl, sha256sum, magpie on PATH. No secrets, nothing else is touched.

set -euo pipefail

RAW="https://raw.githubusercontent.com/sryimnoob123/plugins/opendesign-0.1.5/packages/opendesign/index.mjs"
WANT="89649dd7dc401d84aefda078503883ad119fe38bfef0a4a98b7198cff713ebf8"
PLUGIN_DIR="$HOME/.config/magpie/plugins/node_modules/@magpie-community/opencode-opendesign-auth"
DEST="$PLUGIN_DIR/index.mjs"
PRE_STATE='const NPM = "@ai-sdk/openai" // the Responses API, at LINK'

say() { printf '%s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

[ -f "$DEST" ] || die "no installed opendesign plugin at $PLUGIN_DIR (is the plugin installed on this machine?)"

if grep -q 'const WIRE = {' "$DEST"; then
  say "already patched — nothing to do."
  exit 0
fi
grep -qF "$PRE_STATE" "$DEST" || die "the installed index.mjs is not the untouched 0.1.4 this patch expects — look at it before forcing anything"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "fetching the patched file…"
# curl is a native Windows binary here: it cannot write an MSYS-style path, so
# the file is fetched from inside the temp directory under a relative name
fetch() { ( cd "$TMP" && curl -fsSL --connect-timeout 20 "$@" "$RAW" -o index.mjs ); }
if ! fetch 2>/dev/null; then
  say "  direct fetch failed; trying the local proxy 127.0.0.1:7897"
  fetch -x http://127.0.0.1:7897 || die "could not fetch $RAW (no network, no proxy?)"
fi

GOT="$(cd "$TMP" && sha256sum index.mjs | cut -d' ' -f1)"
[ "$GOT" = "$WANT" ] || die "sha256 mismatch: got $GOT, wanted $WANT — do not install a file that does not check out"
say "  sha256 ok"

BAK="$DEST.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$DEST" "$BAK"
cp "$TMP/index.mjs" "$DEST"
say "installed. backup: $BAK"

say "reloading the plugin (restarts the bun plugin host; the tray instance stays up)…"
magpie plugin off opendesign >/dev/null 2>&1 || true
magpie plugin on  opendesign >/dev/null 2>&1 || true
sleep 7

say "declared APIs per model:"
# python here is a native Windows binary: it needs a Windows path, not the
# MSYS-style one this shell carries
PPJSON="$HOME/.config/magpie/plugin-providers.json"
if command -v cygpath >/dev/null 2>&1; then PPJSON="$(cygpath -w "$PPJSON")"; fi
python - "$PPJSON" <<'PY' || say "  (could not read plugin-providers.json — check by hand)"
import json, sys, collections
d = json.load(open(sys.argv[1], encoding="utf-8"))
o = [x for x in d if x.get("id") == "opendesign"][0]
c = collections.Counter(m.get("npm") for m in o["models"])
for k, v in sorted(c.items()):
    print(f"  {k}: {v}")
print("  expected: @ai-sdk/openai-compatible 8, @ai-sdk/openai 2, @ai-sdk/anthropic 1")
PY

say "probe through magpie (expect reasoning deltas, not content alone):"
python - <<'PY' || say "  (probe failed — is the gateway on 127.0.0.1:3425 up?)"
import json, urllib.request, collections
body = {"model": "opendesign/deepseek-v4.1-flash", "stream": True, "max_tokens": 300,
        "reasoning_effort": "high",
        "messages": [{"role": "user", "content": "Think step by step: 17*23?"}]}
req = urllib.request.Request("http://127.0.0.1:3425/v1/chat/completions", data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json",
                                      "Authorization": "Bearer magpie",
                                      "User-Agent": "hermes-agent"})
got, n = collections.Counter(), 0
for raw in urllib.request.urlopen(req, timeout=180):
    line = raw.decode("utf-8", "replace").strip()
    if not line.startswith("data:"):
        continue
    d = line[5:].strip()
    if d in ("", "[DONE]"):
        continue
    try:
        o = json.loads(d)
    except Exception:
        continue
    delta = (o.get("choices") or [{}])[0].get("delta") or {}
    for k, v in delta.items():
        if v:
            got[k] += 1
    n += len(str(delta.get("reasoning") or delta.get("reasoning_content") or ""))
print("  delta fields:", dict(got))
print("  thinking chars:", n)
print("  OK" if n > 0 else "  NO THINKING — stop and report")
PY

say "done. To undo: cp the .bak-<timestamp> file back and 'magpie plugin off opendesign && magpie plugin on opendesign'."

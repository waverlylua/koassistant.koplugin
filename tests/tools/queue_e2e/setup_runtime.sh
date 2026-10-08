#!/bin/sh
set -eu
# Official portable runtime; no root/system package installation and no core patch.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=${1:?Usage: setup_runtime.sh /path/to/koassistant.koplugin}
URL=https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-linux-x86_64-v2026.07.1.tar.xz
SHA=299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0
mkdir -p "$ROOT/downloads" "$ROOT/logs" "$ROOT/screenshots"
if [ ! -f "$ROOT/downloads/koreader-linux.tar.xz" ]; then curl -fL "$URL" -o "$ROOT/downloads/koreader-linux.tar.xz"; fi
printf '%s  %s\n' "$SHA" "$ROOT/downloads/koreader-linux.tar.xz" | sha256sum -c -
tar -xJf "$ROOT/downloads/koreader-linux.tar.xz" --exclude=README.md -C "$ROOT"
PLUGIN="$ROOT/lib/koreader/plugins/koassistant.koplugin"
mkdir -p "$PLUGIN"
# Copy tracked/untracked plugin sources without user's .git, secrets or local config.
(cd "$REPO" && tar --exclude=.git --exclude=apikeys.lua --exclude=configuration.lua --exclude=tests -cf - .) | (cd "$PLUGIN" && tar -xf -)
cat > "$PLUGIN/configuration.lua" <<'EOF'
return {provider='openai',model='gpt-4o-mini',provider_settings={openai={base_url='http://127.0.0.1:8765/v1/chat/completions'}},features={enable_streaming=false,enable_web_search=false,auto_check_updates=false,render_markdown=true}}
EOF
cat > "$PLUGIN/apikeys.lua" <<'EOF'
return {openai='local-mock-only-no-credential'}
EOF
printf 'Ready: python3 %s/run_process_tests.py\n' "$ROOT"

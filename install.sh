#!/bin/bash
# install.sh — self-contained installer for the mailmate MCP server.
#
# Everything lands under ~/.mailmate-mcp (override with MAILMATE_MCP_HOME):
#   ruby/        a private relocatable Ruby — only if no Ruby >= 3.0 is found
#   gems/        an isolated GEM_HOME (never touches system or Homebrew gems)
#   bin/         the mailmate-mcp shim that MCP clients invoke
#   ruby-path    absolute path of the Ruby this install uses
#
# Nothing outside that directory is modified: no system Ruby, no Homebrew,
# no shell profile. Uninstall = `./install.sh --uninstall` (or just delete
# the directory and `claude mcp remove mailmate`).
#
# Usage:
#   ./install.sh                  full install: gem + shim + register with Claude Code
#   ./install.sh --no-register    full install, but only print registration instructions
#   ./install.sh --runtime-only   Ruby + gem dependencies only (used by the Claude Code
#                                 plugin launcher, which runs the bundled source instead
#                                 of the released gem)
#   ./install.sh --portable-ruby  skip system-Ruby detection; always provision the
#                                 private Ruby
#   ./install.sh --uninstall      remove the install directory
set -euo pipefail

MMHOME="${MAILMATE_MCP_HOME:-$HOME/.mailmate-mcp}"
MIN_RUBY="3.0"
RUNTIME_ONLY=false
NO_REGISTER=false
FORCE_PORTABLE=false

log() { printf '[mailmate-mcp install] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --runtime-only)  RUNTIME_ONLY=true ;;
    --no-register)   NO_REGISTER=true ;;
    --portable-ruby) FORCE_PORTABLE=true ;;
    --uninstall)
      rm -rf "$MMHOME"
      log "Removed $MMHOME."
      log 'If registered with Claude Code, also run: claude mcp remove mailmate'
      exit 0
      ;;
    -h|--help) sed -n '2,24p' "$0" >&2; exit 0 ;;
    *) die "Unknown option: $arg (see --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "This gem drives MailMate and only runs on macOS."

# ---- Ruby discovery ---------------------------------------------------------

ruby_ok() {
  [ -x "$1" ] && "$1" -e "exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('$MIN_RUBY') ? 0 : 1)" >/dev/null 2>&1
}

find_ruby() {
  # A previously provisioned private Ruby always wins (stable across upgrades).
  if ruby_ok "$MMHOME/ruby/bin/ruby"; then
    echo "$MMHOME/ruby/bin/ruby"
    return 0
  fi
  $FORCE_PORTABLE && return 1
  local candidates=()
  if command -v ruby >/dev/null 2>&1; then
    candidates+=("$(command -v ruby)")
  fi
  candidates+=(/opt/homebrew/opt/ruby/bin/ruby /usr/local/opt/ruby/bin/ruby)
  local r
  for r in "${candidates[@]}"; do
    if ruby_ok "$r"; then
      echo "$r"
      return 0
    fi
  done
  return 1
}

# Download Homebrew's relocatable portable-ruby into $MMHOME/ruby. This is the
# same prebuilt Ruby Homebrew bootstraps itself with — no compiler needed.
provision_portable_ruby() {
  local arch pattern api json url tmp verdir
  arch="$(uname -m)"
  case "$arch" in
    arm64)  pattern='arm64' ;;
    x86_64) pattern='el_capitan|x86_64' ;;
    *) die "Unsupported architecture: $arch" ;;
  esac
  log "No Ruby >= $MIN_RUBY found — downloading a private relocatable Ruby (~15 MB, one-time)..."
  api="https://api.github.com/repos/Homebrew/homebrew-portable-ruby/releases/latest"
  json="$(curl -fsSL "$api")" || die "Could not query $api (offline? rate-limited?). Install Ruby >= $MIN_RUBY yourself and re-run."
  url="$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]+"' | grep -oE 'https[^"]+' | grep -E "$pattern" | grep -E '\.tar\.gz$' | head -1)"
  [ -n "$url" ] && [ "${url#https://github.com/Homebrew/}" != "$url" ] \
    || die "No portable-ruby release asset matched arch '$arch'."
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT
  curl -fsSL "$url" -o "$tmp/portable-ruby.tar.gz"
  tar -xzf "$tmp/portable-ruby.tar.gz" -C "$tmp"
  verdir="$(find "$tmp/portable-ruby" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$verdir" ] || die "Unexpected portable-ruby archive layout."
  mkdir -p "$MMHOME"
  rm -rf "$MMHOME/ruby"
  mv "$verdir" "$MMHOME/ruby"
  ruby_ok "$MMHOME/ruby/bin/ruby" || die "Downloaded Ruby failed its self-check."
  log "Private Ruby installed at $MMHOME/ruby ($("$MMHOME/ruby/bin/ruby" -e 'print RUBY_VERSION'))."
}

RUBY="$(find_ruby)" || { provision_portable_ruby; RUBY="$MMHOME/ruby/bin/ruby"; }
GEM="$(dirname "$RUBY")/gem"
[ -x "$GEM" ] || die "gem executable not found next to $RUBY"

mkdir -p "$MMHOME"
printf '%s\n' "$RUBY" > "$MMHOME/ruby-path"

export GEM_HOME="$MMHOME/gems"
export GEM_PATH="$MMHOME/gems"

have_gem() { "$RUBY" -e "gem '$1'" >/dev/null 2>&1; }

install_optional_markdown() {
  # reverse_markdown powers `message markdown:true` (HTML mail -> readable
  # markdown). Its nokogiri dependency ships precompiled for darwin, but if
  # installation fails anyway the server degrades gracefully — so tolerate it.
  if ! have_gem reverse_markdown; then
    log "Installing reverse_markdown (optional, for HTML->markdown rendering)..."
    "$GEM" install --no-document reverse_markdown >/dev/null 2>&1 \
      || log "WARNING: reverse_markdown failed to install; 'markdown: true' will fall back to raw HTML."
  fi
}

if $RUNTIME_ONLY; then
  # Plugin-launcher mode: the launcher runs the bundled gem source, so we only
  # need the runtime dependencies present in the isolated GEM_HOME.
  if ! have_gem mail || ! have_gem csv; then
    log "Installing gem dependencies (mail, csv) into $GEM_HOME..."
    "$GEM" install --no-document mail csv >/dev/null
  fi
  install_optional_markdown
  exit 0
fi

# ---- Full install: released gem + shim --------------------------------------

log "Installing the mailmate gem into $GEM_HOME..."
"$GEM" install --no-document mailmate >/dev/null
install_optional_markdown

mkdir -p "$MMHOME/bin"
cat > "$MMHOME/bin/mailmate-mcp" <<SHIM
#!/bin/bash
# Generated by mailmate install.sh — isolated launcher for the MCP server.
export GEM_HOME="$MMHOME/gems"
export GEM_PATH="$MMHOME/gems"
export PATH="$(dirname "$RUBY"):\$PATH"
exec "$MMHOME/gems/bin/mailmate-mcp" "\$@"
SHIM
chmod +x "$MMHOME/bin/mailmate-mcp"
log "Shim written: $MMHOME/bin/mailmate-mcp"

if ! $NO_REGISTER && command -v claude >/dev/null 2>&1; then
  if claude mcp add --scope user mailmate "$MMHOME/bin/mailmate-mcp" >/dev/null 2>&1; then
    log "Registered with Claude Code (user scope). Restart Claude Code sessions to pick it up."
  else
    log "claude mcp add failed (already registered?). Current entry can be replaced with:"
    log "  claude mcp remove mailmate && claude mcp add --scope user mailmate $MMHOME/bin/mailmate-mcp"
  fi
else
  log "To register with Claude Code:"
  log "  claude mcp add --scope user mailmate $MMHOME/bin/mailmate-mcp"
fi

log 'For Claude Desktop, add to ~/Library/Application Support/Claude/claude_desktop_config.json:'
log "  { \"mcpServers\": { \"mailmate\": { \"command\": \"$MMHOME/bin/mailmate-mcp\" } } }"
log "Done."

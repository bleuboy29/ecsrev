#!/usr/bin/env bash
# ECS helper for GitHub Codespaces + Supabase.
# Put this file in the ROOT of the repo (next to README.md and the services folder).
#   ./ecs.sh setup      - install tools, ask for DB data, create configs, migrate, build
#   ./ecs.sh configure  - only (re)create config files (asks for DB data again)
#   ./ecs.sh patch      - auto-approve registration applications (needed for the first account)
#   ./ecs.sh start      - start everything
#   ./ecs.sh stop       - stop everything
#   ./ecs.sh logs       - show the last lines of the logs
set -uo pipefail

ROOT="${ECS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SVC="$ROOT/services"
LOGS="$ROOT/.ecs-logs"
mkdir -p "$LOGS"

export PATH="$HOME/.dotnet:$PATH"
export DOTNET_ROOT="$HOME/.dotnet"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

load_node() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  if command -v nvm >/dev/null 2>&1; then
    nvm use 18 >/dev/null 2>&1 || nvm install 18 >/dev/null 2>&1 || true
    nvm use 18 >/dev/null 2>&1 || true
  fi
}

install_tools() {
  say "Installing Redis"
  if ! command -v redis-server >/dev/null 2>&1; then
    sudo apt-get update -y >/dev/null && sudo apt-get install -y redis-server >/dev/null || die "Redis install failed"
  fi

  say "Installing .NET 6 (this takes a minute)"
  if ! "$HOME/.dotnet/dotnet" --list-sdks 2>/dev/null | grep -q '^6\.'; then
    curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh || die "cannot download dotnet-install.sh"
    bash /tmp/dotnet-install.sh --channel 6.0 --install-dir "$HOME/.dotnet" || die ".NET 6 install failed"
  fi

  say "Node.js 18"
  load_node
  node -v | grep -q '^v18' || die "Node 18 is not active. Run: nvm install 18 && nvm use 18"

  say "Go (only for asset uploads, optional)"
  if ! command -v go >/dev/null 2>&1; then
    sudo apt-get install -y golang-go >/dev/null 2>&1 || echo "Go was not installed - uploads of items will not work, the rest is fine."
  fi
}

configure() {
  say "Database settings (Supabase -> Connect -> Session pooler)"
  echo "Nothing is sent anywhere: the data is only written into config files inside this Codespace."
  read -r -p "Host (like aws-0-eu-central-1.pooler.supabase.com): " DB_HOST
  read -r -p "Port [5432]: " DB_PORT; DB_PORT="${DB_PORT:-5432}"
  read -r -p "User (like postgres.abcdefghijklmnop): " DB_USER
  read -r -p "Database name [postgres]: " DB_NAME; DB_NAME="${DB_NAME:-postgres}"
  read -r -s -p "Password (typing is hidden): " DB_PASS; echo
  [ -n "$DB_HOST" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ] || die "Host, user and password are required"

  export DB_HOST DB_PORT DB_USER DB_NAME DB_PASS ROOT
  if [ -n "${CODESPACE_NAME:-}" ]; then
    export PUBLIC_URL="https://${CODESPACE_NAME}-5000.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
  else
    export PUBLIC_URL="http://localhost:5000"
  fi
  export AUTH_RENDER="$(openssl rand -hex 16)"
  export AUTH_GAME="$(openssl rand -hex 16)"
  export AUTH_BOT="$(openssl rand -hex 16)"
  export AUTH_RCC="$(openssl rand -hex 16)"
  export AUTH_ASSET="$(openssl rand -hex 16)"
  export JWT_SESSIONS="$(openssl rand -hex 32)"

  mkdir -p "$SVC/api/storage/asset" \
           "$SVC/api/public/images/thumbnails" \
           "$SVC/api/public/images/groups" \
           "$SVC/api/public/UnsecuredContent"

  python3 - <<'PY' || die "could not write config files"
import json, os
root = os.environ["ROOT"]; svc = root + "/services"
e = os.environ

# 1) knex config for migrations
knex = {"knex": {"client": "pg", "connection": {
    "host": e["DB_HOST"], "port": int(e["DB_PORT"]), "user": e["DB_USER"],
    "password": e["DB_PASS"], "database": e["DB_NAME"],
    "ssl": {"rejectUnauthorized": False}}}}
json.dump(knex, open(svc + "/api/config.json", "w"), indent=2)

# 2) .NET website config
path = svc + "/Roblox/Roblox.Website/appsettings.example.json"
cfg = json.load(open(path))
pw = e["DB_PASS"].replace('"', '""')
cfg["Postgres"] = ('Host=%s; Port=%s; Database=%s; Username=%s; Password="%s"; '
                   'SSL Mode=Require; Trust Server Certificate=true; Maximum Pool Size=10'
                   % (e["DB_HOST"], e["DB_PORT"], e["DB_NAME"], e["DB_USER"], pw))
cfg["Redis"] = "127.0.0.1"
cfg["OwnerUserId"] = "1"
cfg["BaseUrl"] = e["PUBLIC_URL"]
cfg["Authorization"] = e["AUTH_RENDER"]
cfg["GameServerAuthorization"] = e["AUTH_GAME"]
cfg["BotAuthorization"] = e["AUTH_BOT"]
cfg["RccAuthorization"] = e["AUTH_RCC"]
cfg["AssetValidation"]["Authorization"] = e["AUTH_ASSET"]
cfg["Render"]["Authorization"] = e["AUTH_RENDER"]
cfg["Jwt"]["Sessions"] = e["JWT_SESSIONS"]
old = "/home/my_username/source-code/"
for k, v in cfg["Directories"].items():
    cfg["Directories"][k] = v.replace(old, root + "/")
json.dump(cfg, open(svc + "/Roblox/Roblox.Website/appsettings.json", "w"), indent=2)
print("config files written")
PY

  # keep secrets out of git
  touch "$ROOT/.gitignore"
  for f in "services/api/config.json" "services/Roblox/Roblox.Website/appsettings.json" ".ecs-logs/" "services/2016-roblox-main/config.json"; do
    grep -qxF "$f" "$ROOT/.gitignore" || echo "$f" >> "$ROOT/.gitignore"
  done
  unset DB_PASS
}

patch_autoaccept() {
  say "Patching auto-approve of applications"
  python3 - "$SVC/Roblox/Roblox.Services/Users/ApplicationProcessorService.cs" <<'PY' || die "patch failed"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "usAutoApprove" in s:
    print("already patched"); sys.exit(0)
needle = "var userId = long.Parse(media.identifier);"
if needle not in s:
    print("pattern not found"); sys.exit(1)
add = needle + """
            {
                using var usAutoApprove = ServiceProvider.GetOrCreate<UsersService>();
                await usAutoApprove.AcquireApplicationLocks(1, new[] {entry.id});
                await usAutoApprove.ProcessApplication(entry.id, 1, UserApplicationStatus.Approved);
                return;
            }"""
open(p, "w", encoding="utf-8").write(s.replace(needle, add, 1))
print("patched")
PY
}

build_all() {
  load_node
  say "API: npm install + database migrations"
  (cd "$SVC/api" && npm i --no-audit --no-fund && npx knex migrate:latest) || die "migrations failed - check host/user/password and that you used the Session pooler"

  say "Admin panel build"
  (cd "$SVC/admin" && npm i --no-audit --no-fund && npm run build) || die "admin build failed"

  say "Frontend build (slow, several minutes)"
  (cd "$SVC/2016-roblox-main" && { [ -f config.json ] || node ./util/create_config.js; } && npm i --no-audit --no-fund && npm run build) || die "frontend build failed"

  say "Compiling the website (.NET)"
  (cd "$SVC/Roblox/Roblox.Website" && dotnet build -c Release) || die ".NET build failed - send me the error text"
}

start_all() {
  load_node
  say "Starting Redis"
  (redis-cli ping >/dev/null 2>&1) || (redis-server --daemonize yes >/dev/null)

  if command -v go >/dev/null 2>&1; then
    say "Starting asset validation (Go)"
    (cd "$SVC/AssetValidationServiceV2" && nohup go run main.go >"$LOGS/assets.log" 2>&1 & echo $! >"$LOGS/assets.pid")
  fi

  say "Starting frontend (port 3000)"
  (cd "$SVC/2016-roblox-main" && nohup npm run start >"$LOGS/frontend.log" 2>&1 & echo $! >"$LOGS/frontend.pid")

  say "Starting website (port 5000)"
  (cd "$SVC/Roblox/Roblox.Website" && nohup dotnet run -c Release >"$LOGS/website.log" 2>&1 & echo $! >"$LOGS/website.pid")

  echo
  echo "Wait ~1 minute, then open the PORTS tab in Codespaces, find port 5000,"
  echo "set Visibility = Public and open the link."
  echo "Registration page: <that link>/auth/application   Admin: <that link>/admin"
  echo "Logs: ./ecs.sh logs"
}

stop_all() {
  for n in website frontend assets; do
    [ -f "$LOGS/$n.pid" ] && kill "$(cat "$LOGS/$n.pid")" 2>/dev/null
    rm -f "$LOGS/$n.pid"
  done
  pkill -f "Roblox.Website" 2>/dev/null
  pkill -f "next start" 2>/dev/null
  echo "stopped"
}

case "${1:-}" in
  setup)     install_tools; configure; patch_autoaccept; build_all; say "Done. Now run: ./ecs.sh start" ;;
  configure) configure ;;
  patch)     patch_autoaccept ;;
  start)     start_all ;;
  stop)      stop_all ;;
  logs)      for f in "$LOGS"/*.log; do echo "----- $f"; tail -n 25 "$f"; done ;;
  *)         sed -n '2,10p' "$0" ;;
esac

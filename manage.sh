#!/usr/bin/env bash
# ============================================================================
# Tivora Community Edition — Management
# Dienstplan | WERIT Solutions
#
#   ./manage.sh <command>
#
# status | start | stop | restart | update | logs | backup | restore |
# health | version | help
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"
BACKUP_DIR="$SCRIPT_DIR/backups"
APP_VOLUME="tivora-ce-app-data"

c_reset="\033[0m"; c_blue="\033[1;34m"; c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_dim="\033[2m"
info()  { printf "${c_blue}➜${c_reset} %s\n" "$*"; }
ok()    { printf "${c_green}✓${c_reset} %s\n" "$*"; }
warn()  { printf "${c_yellow}⚠${c_reset} %s\n" "$*" >&2; }
err()   { printf "${c_red}✗${c_reset} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

[[ -f "$ENV_FILE" ]] || die "Keine .env gefunden. Bitte zuerst ./install.sh ausführen."
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${APP_PORT:=3000}"; : "${POSTGRES_USER:=tivora_owner}"; : "${POSTGRES_DB:=tivora}"; : "${APP_VERSION:=1.0.0}"

# Podman: Docker-kompatiblen API-Socket sicherstellen (Compose braucht ihn).
if command -v podman >/dev/null 2>&1 || docker --version 2>/dev/null | grep -qi podman; then
  if [[ "$(id -u)" -eq 0 ]]; then
    systemctl enable --now podman.socket >/dev/null 2>&1 || true
    [[ -S /run/podman/podman.sock ]] && export DOCKER_HOST="unix:///run/podman/podman.sock"
  else
    systemctl --user enable --now podman.socket >/dev/null 2>&1 || true
    _psock="/run/user/$(id -u)/podman/podman.sock"
    [[ -S "$_psock" ]] && export DOCKER_HOST="unix://${_psock}"
  fi
fi

# Docker-Compose-Wrapper — wählt die Variante, die die compose.yml WIRKLICH parst
# (fängt alte docker-compose v1 / Podman-Shims ab).
DC=""
dc() { $DC -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }
for _cand in "docker compose" "docker-compose"; do
  if $_cand version >/dev/null 2>&1; then
    DC="$_cand"
    $DC -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config >/dev/null 2>&1 && break
    DC=""
  fi
done
[[ -n "$DC" ]] || die "Kein kompatibles Docker Compose v2 gefunden. Bitte ./install.sh ausführen (installiert Compose v2)."

# Registry-Image (ghcr.io/...) → per pull aktualisieren; lokaler Name → bauen.
is_registry_ref() {
  local ref="${1:-}"; local host="${ref%%/*}"
  case "$host" in *.*|*:*|localhost) return 0 ;; *) return 1 ;; esac
}

active_users() {
  dc exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    "SELECT count(*) FROM users WHERE active AND NOT billing_exempt" 2>/dev/null | tr -d '[:space:]' || echo "?"
}

app_healthy() { curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1; }
db_healthy()  { dc exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; }

cmd_status() {
  local img="${APP_IMAGE:-}"
  printf "Image     : "
  if [[ -n "$img" ]] && docker image inspect "$img" >/dev/null 2>&1; then
    printf "%s  (lokal vorhanden \u2713)\n" "$img"
  else
    printf "%s  (nicht lokal \u2014 wird bei Start gezogen/gebaut)\n" "${img:-?}"
  fi
  echo "Container :"
  dc ps 2>/dev/null || warn "Keine Container (noch nicht gestartet?)."
  echo
  if app_healthy; then
    ok "Tivora LÄUFT und ist erreichbar: ${APP_URL:-http://localhost:$APP_PORT}"
  else
    warn "Tivora ist NICHT erreichbar (nicht gestartet oder noch am Starten). Start: ./manage.sh start"
  fi
  echo
  cmd_health
}

cmd_start()   { info "Starte Stack ..."; dc up -d; ok "Gestartet"; }
cmd_stop()    { info "Stoppe Stack (Daten bleiben erhalten) ..."; dc stop; ok "Gestoppt"; }
cmd_restart() { info "Neustart ..."; dc restart; ok "Neu gestartet"; }
cmd_logs()    { dc logs -f --tail="${2:-100}" "${SERVICE:-}"; }

cmd_version() {
  printf "Tivora Community Edition\n"
  printf "  Version : %s\n" "$APP_VERSION"
  printf "  Edition : Community (max. 5 aktive Benutzer)\n"
  local img; img="$(dc images app 2>/dev/null | awk 'NR==2{print $2":"$3}')" || true
  [[ -n "${img:-}" ]] && printf "  Image   : %s\n" "$img"
}

cmd_health() {
  local a="unreachable" d="unreachable" u="?"
  app_healthy && a="healthy"
  db_healthy  && { d="healthy"; u="$(active_users)"; }
  printf "  %-14s %s\n" "Application" "$a"
  printf "  %-14s %s\n" "Database"    "$d"
  printf "  %-14s %s\n" "Version"     "$APP_VERSION"
  printf "  %-14s %s\n" "Edition"     "Community"
  printf "  %-14s %s / 5\n" "Users"   "$u"
}

# ---------------------------------------------------------------------------
# Backup: DB (pg_dump) + App-Daten (Vault/Lizenz) + .env → Zeitstempel-Ordner
# ---------------------------------------------------------------------------
cmd_backup() {
  local ts dest
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  dest="$BACKUP_DIR/$ts"
  mkdir -p "$dest"
  info "Erstelle Backup in backups/$ts ..."

  db_healthy || die "Datenbank nicht erreichbar — Backup abgebrochen."
  info "  • Datenbank (pg_dump) ..."
  dc exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
    | gzip > "$dest/database.sql.gz"

  info "  • Anwendungsdaten (Vault/Lizenz) ..."
  docker run --rm -v "${APP_VOLUME}:/data:ro" -v "$dest:/backup" alpine \
    sh -c "tar czf /backup/app-data.tar.gz -C /data . 2>/dev/null || true"

  info "  • Konfiguration (.env) ..."
  cp "$ENV_FILE" "$dest/env.backup"
  chmod 600 "$dest/env.backup"

  cat > "$dest/manifest.txt" <<EOF
Tivora Community Edition Backup
created: $(date -Iseconds)
version: $APP_VERSION
database: database.sql.gz
appdata: app-data.tar.gz
EOF

  ok "Backup abgeschlossen: backups/$ts"
  printf "  %s\n" "$(du -sh "$dest" | awk '{print $1}') gesamt"
}

# ---------------------------------------------------------------------------
# Restore: ersetzt vorhandene Daten (mit Warnung + Validierung)
# ---------------------------------------------------------------------------
cmd_restore() {
  local src="${2:-}"
  [[ -n "$src" ]] || die "Nutzung: ./manage.sh restore <backup-ordner-oder-name>"
  [[ -d "$src" ]] || src="$BACKUP_DIR/$src"
  [[ -d "$src" ]] || die "Backup nicht gefunden: $src"

  # Validierung
  [[ -f "$src/database.sql.gz" ]] || die "Ungültiges Backup: database.sql.gz fehlt."
  gzip -t "$src/database.sql.gz" 2>/dev/null || die "database.sql.gz ist beschädigt."
  ok "Backup validiert: $src"

  warn "ACHTUNG: Der Restore ERSETZT die aktuelle Datenbank und Anwendungsdaten!"
  warn "Alle seit dem Backup vorgenommenen Änderungen gehen verloren."
  read -r -p "Zum Fortfahren 'RESTORE' eingeben: " confirm
  [[ "$confirm" == "RESTORE" ]] || die "Abgebrochen."

  info "Erzeuge Sicherheits-Backup vor dem Restore ..."
  cmd_backup >/dev/null 2>&1 || warn "Vorab-Backup fehlgeschlagen (fahre fort)."

  info "Stoppe Anwendung ..."
  dc stop app >/dev/null 2>&1 || true

  info "Stelle Datenbank wieder her ..."
  db_healthy || dc up -d postgres
  sleep 3
  gunzip -c "$src/database.sql.gz" | dc exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
  ok "Datenbank wiederhergestellt"

  if [[ -f "$src/app-data.tar.gz" ]]; then
    info "Stelle Anwendungsdaten wieder her ..."
    docker run --rm -v "${APP_VOLUME}:/data" -v "$src:/backup:ro" alpine \
      sh -c "rm -rf /data/* /data/..?* 2>/dev/null; tar xzf /backup/app-data.tar.gz -C /data" || warn "App-Daten-Restore teilweise fehlgeschlagen."
    ok "Anwendungsdaten wiederhergestellt"
  fi

  info "Starte Anwendung ..."
  dc up -d
  ok "Restore abgeschlossen."
}

# ---------------------------------------------------------------------------
# Update: Backup → Images ziehen → sauber stoppen → migrieren → starten → Health
# Löscht NIEMALS persistente Volumes.
# ---------------------------------------------------------------------------
cmd_update() {
  info "1/6 Backup vor Update ..."
  cmd_backup

  local build_flag="" 
  if is_registry_ref "${APP_IMAGE:-}"; then
    info "2/6 Neue Images ziehen (${APP_IMAGE}) ..."
    dc pull || warn "Pull fehlgeschlagen — versuche vorhandene Images."
  else
    info "2/6 Lokales Image — wird neu gebaut."
    dc pull postgres 2>/dev/null || true
    build_flag="--build"
  fi

  info "3/6 Anwendung sauber stoppen ..."
  dc stop app >/dev/null 2>&1 || true

  info "4/6 Datenbank-Migrationen anwenden ..."
  dc up -d postgres
  dc run --rm migrate

  info "5/6 Neue Container starten ..."
  dc up -d $build_flag

  info "6/6 Health-Check ..."
  local tries=0
  until app_healthy; do
    tries=$((tries+1)); [[ "$tries" -ge 40 ]] && { err "Update: Anwendung nicht gesund."; dc logs --tail=40 app; exit 1; }
    sleep 3
  done
  ok "Update erfolgreich abgeschlossen."
  cmd_health
}

# ---------------------------------------------------------------------------
# Uninstall: Container + Netzwerke entfernen; Daten (Volumes) optional löschen
# ---------------------------------------------------------------------------
cmd_uninstall() {
  warn "Uninstall stoppt und entfernt alle Tivora-Container und -Netzwerke."
  read -r -p "Fortfahren? (yes/no): " c
  [[ "$c" == "yes" ]] || die "Abgebrochen."

  warn "Sollen auch die DATEN gelöscht werden (Volumes: Datenbank + Vault/Lizenz)?"
  warn "Das ist UNWIDERRUFLICH. Vorher ggf. './manage.sh backup' ausführen."
  read -r -p "Zum LÖSCHEN 'DELETE' eingeben, sonst Enter (Daten behalten): " d
  if [[ "$d" == "DELETE" ]]; then
    dc down -v --remove-orphans
    ok "Container, Netzwerke und Volumes entfernt — Daten gelöscht."
  else
    dc down --remove-orphans
    ok "Container & Netzwerke entfernt. Daten (Volumes) bleiben erhalten."
    info "Erneut starten:  ./manage.sh start   oder   ./install.sh"
  fi
}

cmd_help() {
  cat <<EOF
Tivora — Management

  ./manage.sh status           Status: Image da? Container gebaut/laufen? Health
  ./manage.sh start            Stack starten
  ./manage.sh stop             Stack stoppen (Daten bleiben erhalten)
  ./manage.sh restart          Stack neu starten
  ./manage.sh update           Backup → Images → Migrationen → Start → Health
  ./manage.sh logs [service]   Live-Logs (optional: app | postgres)
  ./manage.sh backup           Datenbank + Anwendungsdaten sichern
  ./manage.sh restore <name>   Backup wiederherstellen (ersetzt Daten!)
  ./manage.sh uninstall        Container/Netzwerke entfernen (Daten optional löschen)
  ./manage.sh health           Health-Report (App/DB/Version/Edition/Users)
  ./manage.sh version          Version & Edition anzeigen
  ./manage.sh help             Diese Hilfe

Persistente Daten:
  Volume  tivora-ce-postgres-data   PostgreSQL
  Volume  tivora-ce-app-data        Vault-Schlüssel + Lizenz
  Ordner  ./backups                 Backups
EOF
}

main() {
  local command="${1:-help}"
  case "$command" in
    status)  cmd_status "$@" ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    update)  cmd_update ;;
    logs)    SERVICE="${2:-}"; dc logs -f --tail=100 ${SERVICE:+$SERVICE} ;;
    backup)  cmd_backup ;;
    restore) cmd_restore "$@" ;;
    uninstall) cmd_uninstall ;;
    health)  cmd_health ;;
    version) cmd_version ;;
    help|-h|--help) cmd_help ;;
    *) err "Unbekannter Befehl: $command"; echo; cmd_help; exit 1 ;;
  esac
}

main "$@"

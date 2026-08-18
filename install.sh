#!/usr/bin/env bash
# ============================================================================
# Tivora Community Edition — Installer
# Dienstplan | WERIT Solutions
#
#   ./install.sh
#
# Führt eine geführte Erstinstallation durch: System-Check, Konfiguration,
# sichere Secret-Erzeugung, Container-Start, Datenbank-Migrationen,
# Anlage des ersten Administrators und abschließende Health-Checks.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/compose.yml"

# Admin-Daten (werden bei Neuinstallation abgefragt; bei .env-Wiederverwendung leer)
ADMIN_EMAIL=""; ADMIN_FIRST=""; ADMIN_LAST=""; ADMIN_PW=""; ADMIN_PW2=""

# ---- Ausgabe-Helfer --------------------------------------------------------
c_reset="\033[0m"; c_blue="\033[1;34m"; c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_dim="\033[2m"
info()  { printf "${c_blue}➜${c_reset} %s\n" "$*"; }
ok()    { printf "${c_green}✓${c_reset} %s\n" "$*"; }
warn()  { printf "${c_yellow}⚠${c_reset} %s\n" "$*" >&2; }
err()   { printf "${c_red}✗${c_reset} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { printf "${c_dim}%s${c_reset}\n" "------------------------------------------------------------"; }

banner() {
  printf "\n${c_blue}"
  cat <<'EOF'
  ████████╗██╗██╗   ██╗ ██████╗ ██████╗  █████╗
  ╚══██╔══╝██║██║   ██║██╔═══██╗██╔══██╗██╔══██╗
     ██║   ██║██║   ██║██║   ██║██████╔╝███████║
     ██║   ██║╚██╗ ██╔╝██║   ██║██╔══██╗██╔══██║
     ██║   ██║ ╚████╔╝ ╚██████╔╝██║  ██║██║  ██║
     ╚═╝   ╚═╝  ╚═══╝   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
EOF
  printf "${c_reset}  Community Edition — Self-Hosted Dienstplan\n\n"
}

# ---- Secret-Erzeugung ------------------------------------------------------
gen_secret() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  elif command -v node >/dev/null 2>&1; then
    node -e "console.log(require('crypto').randomBytes(${bytes}).toString('hex'))"
  else
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# ---- Docker-Compose-Wrapper ------------------------------------------------
DC=""
dc() { $DC -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

# Paketmanager + sudo erkennen
PKG=""; SUDO=""
have() { command -v "$1" >/dev/null 2>&1; }
detect_pkg() {
  if [[ "$(id -u)" -eq 0 ]]; then SUDO=""; elif have sudo; then SUDO="sudo"; else SUDO=""; fi
  if   have apt-get; then PKG="apt"
  elif have dnf;     then PKG="dnf"
  elif have yum;     then PKG="yum"
  elif have apk;     then PKG="apk"
  elif have pacman;  then PKG="pacman"
  else PKG=""; fi
}
pkg_install() {
  case "$PKG" in
    apt)    $SUDO apt-get update -y >/dev/null 2>&1; $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    apk)    $SUDO apk add --no-cache "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    *)      return 1 ;;
  esac
}
ask_yes() { local a; read -r -p "$(printf "${c_blue}%s${c_reset} [Y/n]: " "$1")" a || true; [[ "${a,,}" != "n" ]]; }

# Prüft, ob $DC die compose.yml WIRKLICH parst (entlarvt alte docker-compose v1
# bzw. Podman-Shims, die den modernen Compose-Spec nicht verstehen).
compose_works() {
  [[ -n "$DC" ]] || return 1
  local tmp rc; tmp="$(mktemp)"
  printf 'POSTGRES_USER=x\nPOSTGRES_PASSWORD=x\nPG_APP_USER=x\nPG_APP_PASSWORD=x\nSESSION_SECRET=00000000000000000000000000000000\nVAULT_MASTER_KEY=x\n' > "$tmp"
  $DC -f "$COMPOSE_FILE" --env-file "$tmp" config >/dev/null 2>&1; rc=$?
  rm -f "$tmp"; return $rc
}
# Wählt die Compose-Variante, die die Datei tatsächlich parst.
detect_compose() {
  local cand
  for cand in "docker compose" "docker-compose"; do
    if $cand version >/dev/null 2>&1; then DC="$cand"; compose_works && return 0; fi
  done
  DC=""; return 1
}
install_docker() {
  info "Installiere Docker Engine (get.docker.com) ..."
  if have curl; then curl -fsSL https://get.docker.com | $SUDO sh
  elif have wget; then $SUDO sh -c "$(wget -qO- https://get.docker.com)"
  else return 1; fi
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || $SUDO service docker start >/dev/null 2>&1 || true
}
install_compose_v2() {
  info "Installiere Docker Compose v2 ..."
  case "$PKG" in apt|dnf|yum) pkg_install docker-compose-plugin >/dev/null 2>&1 || true ;; esac
  detect_compose && return 0
  # Standalone-Binary (nutzt den vorhandenen Docker-/Podman-Socket)
  local os arch url; os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-${os}-${arch}"
  if have curl; then $SUDO curl -fsSL "$url" -o /usr/local/bin/docker-compose && $SUDO chmod +x /usr/local/bin/docker-compose
  elif have wget; then $SUDO wget -qO /usr/local/bin/docker-compose "$url" && $SUDO chmod +x /usr/local/bin/docker-compose; fi
}

# Ist APP_IMAGE ein Registry-Ref (z.B. ghcr.io/owner/img) → dann kann per
# `docker pull` ein vorgefertigtes Image geladen werden statt lokal zu bauen.
# Lokale Namen ohne Registry-Host (z.B. tivora/community) werden gebaut.
is_registry_ref() {
  local ref="${1:-}"; local host="${ref%%/*}"
  case "$host" in
    *.*|*:*|localhost) return 0 ;;   # host enthält Punkt/Port → Registry
    *) return 1 ;;
  esac
}

# ============================================================================
# 1) System-Check — prüft Abhängigkeiten und bietet Installation an
# ============================================================================
system_check() {
  hr; info "System-Check"; hr
  detect_pkg
  local failed=0

  # --- curl (für Health-Check & Ersteinrichtung) ---
  if have curl; then
    ok "curl vorhanden"
  else
    warn "curl fehlt (wird für Health-Check/Setup benötigt)."
    if [[ -n "$PKG" ]] && ask_yes "curl jetzt installieren?"; then
      pkg_install curl && ok "curl installiert" || { err "curl-Installation fehlgeschlagen."; failed=1; }
    else failed=1; fi
  fi

  # --- Docker Engine ---
  if have docker; then
    ok "Docker installiert ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ','))"
  else
    warn "Docker ist nicht installiert."
    if ask_yes "Docker Engine jetzt automatisch installieren?"; then
      install_docker && have docker && ok "Docker installiert" || { err "Docker-Installation fehlgeschlagen (siehe https://docs.docker.com/engine/install/)."; failed=1; }
    else
      err "Docker wird benötigt: https://docs.docker.com/engine/install/"; failed=1
    fi
  fi

  # --- Docker-Daemon ---
  if have docker; then
    docker info >/dev/null 2>&1 || { info "Starte Docker-Daemon ..."; $SUDO systemctl start docker >/dev/null 2>&1 || $SUDO service docker start >/dev/null 2>&1 || true; }
    if docker info >/dev/null 2>&1; then
      ok "Docker-Daemon erreichbar / ausreichende Rechte"
    else
      err "Docker-Daemon nicht erreichbar. Benutzer zur 'docker'-Gruppe hinzufügen und neu einloggen:"
      echo "    sudo usermod -aG docker \"\$USER\" && newgrp docker"
      failed=1
    fi
  fi

  # --- Docker Compose v2 (muss die compose.yml wirklich parsen) ---
  if have docker && docker info >/dev/null 2>&1; then
    if detect_compose; then
      ok "Docker Compose v2 verfügbar ($DC)"
    else
      warn "Kein kompatibles Docker Compose v2 gefunden (alte docker-compose v1 bzw. Podman-Shim parst die Datei nicht)."
      if ask_yes "Docker Compose v2 jetzt installieren?"; then
        install_compose_v2
        if detect_compose; then
          ok "Docker Compose v2 installiert ($DC)"
        else
          err "Docker Compose v2 weiterhin nicht nutzbar."
          echo "    Podman-System? Bitte echtes Docker installieren:  curl -fsSL https://get.docker.com | sudo sh"
          echo "    Oder Compose v2 manuell: https://docs.docker.com/compose/install/"
          failed=1
        fi
      else failed=1; fi
    fi
  fi

  # --- Architektur ---
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64|aarch64|arm64) ok "Architektur unterstützt ($arch)" ;;
    *) warn "Architektur '$arch' ist nicht offiziell getestet." ;;
  esac

  # --- Projektdateien ---
  [[ -f "$COMPOSE_FILE" ]] && ok "Compose-Datei vorhanden" || { err "compose.yml fehlt"; failed=1; }
  if [[ -f "$SCRIPT_DIR/Dockerfile" ]]; then
    ok "Dockerfile vorhanden (lokaler Build möglich)"
  else
    info "Kein Dockerfile — Installation per vorgefertigtem Image (Pull-Modus)"
  fi

  [[ "$failed" -eq 0 ]] || die "System-Check fehlgeschlagen. Bitte die obigen Punkte beheben."
  echo
}

port_available() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ! ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"
  elif command -v nc >/dev/null 2>&1; then
    ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1
  else
    ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
  fi
}

# ============================================================================
# 2) Konfiguration
# ============================================================================
prompt() {
  # prompt <var> <label> <default>
  local __var="$1" __label="$2" __def="${3:-}" __in
  if [[ -n "$__def" ]]; then
    read -r -p "$(printf "${c_blue}%s${c_reset} [${c_dim}%s${c_reset}]: " "$__label" "$__def")" __in || true
    __in="${__in:-$__def}"
  else
    read -r -p "$(printf "${c_blue}%s${c_reset}: " "$__label")" __in || true
  fi
  printf -v "$__var" '%s' "$__in"
}

configure() {
  hr; info "Konfiguration"; hr

  if [[ -f "$ENV_FILE" ]]; then
    warn "Es existiert bereits eine .env."
    prompt REUSE "Vorhandene .env wiederverwenden? (y/n)" "y"
    if [[ "${REUSE,,}" == "y" ]]; then
      ok "Verwende vorhandene .env"
      # shellcheck disable=SC1090
      set -a; source "$ENV_FILE"; set +a
      return 0
    fi
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    warn "Alte .env gesichert."
  fi

  prompt APP_URL   "Anwendungs-URL"        "https://dienstplan.example.com"
  prompt APP_PORT  "Host-Port"             "3000"
  prompt TZ        "Zeitzone"              "Europe/Berlin"
  prompt ADMIN_EMAIL "Admin E-Mail"        "admin@example.com"
  prompt ADMIN_FIRST "Admin Vorname"       "Admin"
  prompt ADMIN_LAST  "Admin Nachname"      "Administrator"

  # Passwort verdeckt einlesen (wird NICHT ausgegeben).
  while :; do
    read -r -s -p "$(printf "${c_blue}Admin-Passwort (min. 12 Zeichen)${c_reset}: ")" ADMIN_PW; echo
    read -r -s -p "$(printf "${c_blue}Passwort wiederholen${c_reset}: ")" ADMIN_PW2; echo
    [[ "$ADMIN_PW" == "$ADMIN_PW2" ]] || { warn "Passwörter stimmen nicht überein."; continue; }
    [[ "${#ADMIN_PW}" -ge 12 ]] || { warn "Mindestens 12 Zeichen erforderlich."; continue; }
    break
  done

  # HTTPS? → Secure-Cookies
  local secure="false"
  [[ "$APP_URL" == https://* ]] && secure="true"

  # Port-Verfügbarkeit
  if port_available "$APP_PORT"; then
    ok "Port $APP_PORT verfügbar"
  else
    warn "Port $APP_PORT ist bereits belegt. Installation kann fehlschlagen."
  fi

  info "Erzeuge Secrets & Datenbank-Zugangsdaten ..."
  local POSTGRES_PASSWORD PG_APP_PASSWORD SESSION_SECRET VAULT_MASTER_KEY SETUP_TOKEN
  POSTGRES_PASSWORD="$(gen_secret 24)"
  PG_APP_PASSWORD="$(gen_secret 24)"
  SESSION_SECRET="$(gen_secret 48)"
  VAULT_MASTER_KEY="$(gen_secret 32)"
  SETUP_TOKEN="$(gen_secret 24)"

  umask 077
  cat > "$ENV_FILE" <<EOF
# Automatisch erzeugt von install.sh am $(date -Iseconds)
APP_URL=${APP_URL%/}
APP_PORT=${APP_PORT}
COOKIE_SECURE=${secure}
TZ=${TZ}
APP_VERSION=1.0.0
APP_IMAGE=${APP_IMAGE_OVERRIDE:-ghcr.io/timo4467/tivora-community:1.0}

POSTGRES_DB=tivora
POSTGRES_USER=tivora_owner
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
PG_APP_USER=tivora_app
PG_APP_PASSWORD=${PG_APP_PASSWORD}
RLS_STRICT=false

SESSION_SECRET=${SESSION_SECRET}
VAULT_MASTER_KEY=${VAULT_MASTER_KEY}
SETUP_TOKEN=${SETUP_TOKEN}

MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
MICROSOFT_TENANT_ID=
REDIRECT_URI=
EOF
  chmod 600 "$ENV_FILE"
  ok ".env erstellt (Rechte 600)"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  echo
}

# ============================================================================
# 3) Verzeichnisse
# ============================================================================
make_dirs() {
  mkdir -p "$SCRIPT_DIR/backups" "$SCRIPT_DIR/data/license"
  ok "Persistente Verzeichnisse angelegt (backups/, data/license/)"
}

confirm_start() {
  hr
  printf "  Anwendungs-URL : %s\n" "$APP_URL"
  printf "  Host-Port      : %s\n" "$APP_PORT"
  printf "  Zeitzone       : %s\n" "$TZ"
  printf "  Admin          : %s\n" "${ADMIN_EMAIL:-(aus vorhandener .env)}"
  printf "  Datenbank      : automatisch generiert\n"
  hr
  prompt GO "Installation starten? (Y/n)" "Y"
  [[ "${GO,,}" != "n" ]] || die "Abgebrochen."
  echo
}

# ============================================================================
# 4) Start + Migrationen + Health
# ============================================================================
start_stack() {
  # Modus: vorgefertigtes Image ziehen (schnell) ODER lokal bauen.
  #   INSTALL_MODE=pull|build (via --pull/--build überschreibbar)
  local mode="${INSTALL_MODE:-auto}"
  if [[ "$mode" == "auto" ]]; then
    if is_registry_ref "${APP_IMAGE:-}"; then mode="pull"; else mode="build"; fi
  fi

  if [[ "$mode" == "pull" ]]; then
    info "Lade vorgefertigtes Image: ${APP_IMAGE} ..."
    if dc pull; then
      ok "Image geladen"
      dc up -d
    elif [[ -f "$SCRIPT_DIR/Dockerfile" ]]; then
      warn "Pull fehlgeschlagen — baue stattdessen lokal."
      dc up -d --build
    else
      err "Image konnte nicht geladen werden: ${APP_IMAGE}"
      err "Privates Image? Bitte zuerst anmelden:  docker login ghcr.io -u <github-user>"
      die "Danach ./install.sh erneut starten."
    fi
  else
    info "Baue & starte Container (das kann beim ersten Mal einige Minuten dauern) ..."
    dc up -d --build
  fi
  ok "Container gestartet"

  info "Warte auf Datenbank & Migrationen ..."
  # migrate-Service läuft einmalig; app startet erst nach dessen Erfolg.
  info "Warte auf Anwendung (Health-Check) ..."
  local tries=0 max=60
  until curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" >/dev/null 2>&1; do
    tries=$((tries+1))
    [[ "$tries" -ge "$max" ]] && { dc logs --tail=50 app; die "Anwendung wurde nicht rechtzeitig gesund."; }
    sleep 3
  done
  ok "Anwendung ist erreichbar"
  echo
}

create_admin() {
  # Bereits eingerichtet (z.B. bei .env-Wiederverwendung)? → Admin-Anlage überspringen.
  local st
  st="$(curl -fsS "http://127.0.0.1:${APP_PORT}/api/system/setup-status" 2>/dev/null || echo '')"
  case "$st" in
    *'"configured":true'*)
      info "Installation ist bereits eingerichtet — Admin-Anlage übersprungen."; echo; return 0 ;;
  esac
  if [[ -z "${ADMIN_PW:-}" || -z "${ADMIN_EMAIL:-}" ]]; then
    warn "Keine Admin-Daten angegeben (vorhandene .env wiederverwendet)."
    warn "Ersteinrichtung im Browser abschließen: ${APP_URL}"
    echo; return 0
  fi
  info "Lege ersten Administrator an ..."
  local payload status body
  payload=$(cat <<JSON
{"token":"${SETUP_TOKEN}","admin":{"email":"${ADMIN_EMAIL}","firstName":"${ADMIN_FIRST}","lastName":"${ADMIN_LAST}","password":"${ADMIN_PW}"},"companyName":"","timezone":"${TZ}","locale":"de","appUrl":"${APP_URL%/}"}
JSON
)
  body=$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST "http://127.0.0.1:${APP_PORT}/api/system/setup" \
    -d "$payload" 2>/dev/null) || true
  status="$body"
  # Passwort aus dem Speicher entfernen.
  unset ADMIN_PW ADMIN_PW2 payload
  if [[ "$status" == "200" ]]; then
    ok "Administrator '${ADMIN_EMAIL}' angelegt"
  elif [[ "$status" == "403" ]]; then
    warn "Setup bereits abgeschlossen — überspringe Admin-Anlage."
  else
    warn "Admin-Anlage per CLI nicht möglich (HTTP ${status:-?})."
    warn "Bitte die Ersteinrichtung im Browser abschließen: ${APP_URL}"
  fi
  echo
}

summary() {
  hr
  printf "${c_green}Installation erfolgreich abgeschlossen.${c_reset}\n\n"
  printf "Anwendung:\n  %s\n\n" "$APP_URL"
  printf "Lokaler Zugriff:\n  http://127.0.0.1:%s\n\n" "$APP_PORT"
  printf "Edition:\n  Community Edition — max. 5 aktive Benutzer\n\n"
  printf "Admin:\n  %s\n\n" "$ADMIN_EMAIL"
  printf "Nützliche Befehle:\n"
  printf "  ./manage.sh status\n  ./manage.sh update\n  ./manage.sh backup\n  ./manage.sh logs\n  ./manage.sh help\n"
  hr
}

main() {
  # Flags: --pull (vorgefertigtes Image), --build (lokal bauen), --image REF
  INSTALL_MODE="auto"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pull)  INSTALL_MODE="pull"; shift ;;
      --build) INSTALL_MODE="build"; shift ;;
      --image) APP_IMAGE_OVERRIDE="${2:-}"; shift 2 ;;
      -h|--help)
        cat <<EOF
Tivora Community Edition — Installer

  ./install.sh [Optionen]

Optionen:
  --pull            Vorgefertigtes Image aus der Registry ziehen (schnell)
  --build           Image lokal aus dem Quellcode bauen
  --image REF       Bestimmtes Image verwenden (z.B. ghcr.io/OWNER/tivora-community:1.0.0)
  -h, --help        Diese Hilfe

Ohne Option: automatisch (Registry-Image -> pull, sonst lokal bauen).
EOF
        exit 0 ;;
      *) warn "Unbekannte Option: $1"; shift ;;
    esac
  done
  export INSTALL_MODE

  banner
  echo "Willkommen bei der Tivora Community Edition."
  echo
  system_check
  configure
  make_dirs
  confirm_start
  start_stack
  create_admin
  summary
}

main "$@"

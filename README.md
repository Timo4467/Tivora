# Tivora — Community Edition

**Selbst gehosteter Dienstplan für Teams.** Schicht- und Einsatzplanung, Pausen,
Rufbereitschaft, Team-Kalender, Berichte und 2-Faktor-Authentifizierung — als
kostenlose, selbst gehostete Docker-Installation für **bis zu 5 aktive Benutzer**.

> Community Edition · Version 1.0.0 · installierbar mit einem einzigen Befehl.

```
┌──────────────────────────────────────────────┐
│  Docker Host                                   │
│   ├── app        Frontend + Backend (Port 5000)│
│   ├── postgres   Datenbank (nur intern)        │
│   └── Volumes    persistente Daten & Backups   │
└──────────────────────────────────────────────┘
```

---

## Features

- Schicht-/Dienstplanung mit Team-Kalender und Schichtdefinitionen
- Pausenplanung (Break-Management) inkl. Regeln & Tausch
- Rufbereitschaft (On-Call)
- Schichttausch-Board (Swap Requests)
- Basis-Berichte & Auswertungen
- Benutzer- und Rollenverwaltung (Admin/User)
- 2-Faktor-Authentifizierung (TOTP)
- Audit-Protokoll mit Hash-Chain
- Row-Level-Security auf Datenbankebene (Mandanten-Isolation)
- Web-basierter Ersteinrichtungs-Assistent
- Verschlüsselter Vault für Integrations-Secrets

## Community Edition

Kostenlose, selbst gehostete Installation für **bis zu 5 aktive Benutzer**.
Das Limit wird serverseitig erzwungen. Bestehende Benutzer funktionieren immer
normal — es werden niemals Benutzer automatisch gelöscht oder deaktiviert.

> Als „aktiver Benutzer" zählt ein Benutzer mit `active = true`, der nicht als
> Systemkonto (`billingExempt`) markiert ist. Gelöschte und dauerhaft
> deaktivierte Benutzer zählen **nicht**.

## Requirements

- Linux-Server (x86_64 oder arm64)
- Docker Engine 20.10+ und Docker Compose v2
- ca. 1 GB freier RAM, 2 GB Speicherplatz
- Offener Port (Standard `3000`) bzw. ein vorgelagerter Reverse Proxy

## Quick Start

```bash
git clone <repository> tivora
cd tivora
chmod +x install.sh
./install.sh
```

Der Installer prüft das System, erzeugt alle Secrets automatisch, startet die
Container, führt die Datenbank-Migrationen aus und legt den ersten Administrator
an. Danach ist die Anwendung sofort einsatzbereit.

### Schneller Start mit vorgefertigtem Image (docker pull)

Statt lokal zu bauen, kann das veröffentlichte Image direkt gezogen werden —
das spart den mehrminütigen Build:

```bash
git clone <repository> tivora
cd tivora
chmod +x install.sh
./install.sh --pull --image ghcr.io/timo4467/tivora-community:latest
```

Oder manuell vorab:

```bash
docker pull ghcr.io/timo4467/tivora-community:latest
```

Docker Compose wird dennoch verwendet — für den **PostgreSQL-Container** und die
**persistenten Volumes**, damit Ihre Daten Updates und Neustarts überstehen.
Setzen Sie `APP_IMAGE=ghcr.io/timo4467/tivora-community:latest` in der `.env`,
damit auch `./manage.sh update` das Image zieht statt neu zu bauen.

> Das Image wird per GitHub Actions ([.github/workflows/release.yml](.github/workflows/release.yml))
> bei jedem Release-Tag (`v*`) nach GHCR veröffentlicht (linux/amd64 + arm64).

## Installation

Der Installer (`./install.sh`) führt folgende Schritte aus:

1. **System-Check** — Docker, Docker Compose, Rechte, Port, Architektur
2. **Konfiguration** — Anwendungs-URL, Admin-Konto, Zeitzone
3. **Secrets** — Datenbank-Zugangsdaten und Schlüssel werden sicher erzeugt
4. **Start** — Container werden gebaut und gestartet
5. **Migrationen** — Datenbankschema wird angelegt
6. **Admin** — erster Administrator wird angelegt
7. **Health-Check** — Anwendung und Datenbank werden geprüft

Nichts wird ohne Rückfrage am System installiert. Fehlt Docker, erklärt der
Installer, wie es installiert wird.

## First Setup

Wird die App gestartet, ohne dass ein Administrator existiert, öffnet sich beim
Aufruf der URL automatisch ein **web-basierter Einrichtungs-Assistent**:

```
Willkommen → System-Check → Administrator → Unternehmen → Einstellungen → Fertig
```

Der Assistent ist durch das einmalige `SETUP_TOKEN` (aus Ihrer `.env`) geschützt
und wird nach Abschluss automatisch deaktiviert. Eine erneute Einrichtung ist nur
durch einen angemeldeten Administrator möglich.

## Updating

```bash
./manage.sh update
```

Der Update-Vorgang erstellt zuerst ein Backup, zieht die neuesten Images, stoppt
die Anwendung sauber, wendet Datenbank-Migrationen an, startet neu und prüft die
Gesundheit. **Persistente Volumes werden dabei niemals gelöscht.**

## Backup & Restore

```bash
./manage.sh backup                 # Datenbank + Anwendungsdaten + Konfiguration
./manage.sh restore 2026-08-11_09-30-00
```

Backups werden mit Zeitstempel unter `backups/` abgelegt und enthalten
Datenbank-Dump, Vault/Lizenz und `.env`. Vor einem Restore wird gewarnt, das
Backup validiert und automatisch ein Sicherheits-Backup erstellt.

## Configuration

Alle Einstellungen liegen in der `.env` (siehe [.env.example](.env.example)).
Wichtige Variablen:

| Variable | Bedeutung |
|---|---|
| `APP_URL` | Öffentliche URL der Anwendung |
| `APP_PORT` | Host-Port (Standard 3000) |
| `POSTGRES_*` | Datenbank (Owner-Rolle, Migrationen) |
| `PG_APP_*` | Runtime-Rolle der App (NOBYPASSRLS) |
| `SESSION_SECRET` | Session-Signaturschlüssel |
| `VAULT_MASTER_KEY` | Verschlüsselung des Secret-Vaults |
| `SETUP_TOKEN` | Schutz des Ersteinrichtungs-Assistenten |
| `TZ` | Zeitzone |

Secrets werden vom Installer automatisch erzeugt. **Committen Sie niemals eine
echte `.env`** — sie ist über `.gitignore` ausgeschlossen.

## SMTP

E-Mail-Versand (Passwort-Reset, Benachrichtigungen) ist optional. SMTP kann im
Einrichtungs-Assistenten oder später unter **Einstellungen** konfiguriert werden.

## Reverse Proxy

Für Produktion empfiehlt sich ein vorgelagerter Reverse Proxy (nginx, Caddy,
Traefik), der TLS terminiert und auf den App-Port weiterleitet:

```nginx
server {
    server_name dienstplan.example.com;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Setzen Sie `COOKIE_SECURE=true` in der `.env`, sobald HTTPS aktiv ist.

## HTTPS

TLS wird üblicherweise am Reverse Proxy terminiert (z.B. via Let's Encrypt /
certbot oder Caddy-Automatik). Der App-Container selbst spricht intern HTTP.

## Troubleshooting

| Problem | Lösung |
|---|---|
| App nicht erreichbar | `./manage.sh logs app` prüfen |
| Datenbank-Fehler | `./manage.sh logs postgres`, `./manage.sh health` |
| Port belegt | `APP_PORT` in `.env` ändern und `./manage.sh restart` |
| Einrichtung neu starten | Als Admin unter **System** zurücksetzen |
| Status prüfen | `./manage.sh status` |

## Community vs Professional

| | Community | Professional |
|---|:---:|:---:|
| Selbst gehostet | ✓ | ✓ |
| Preis | kostenlos | Lizenz |
| Aktive Benutzer | 5 | gemäß Lizenz |
| Dienst-/Schichtplanung | ✓ | ✓ |
| Microsoft 365 SSO | – | ✓ |
| Teams-/Outlook-Integration | – | ✓ |
| Personio / Autotask | – | ✓ |
| Erweiterte Berichte & Audit | – | ✓ |
| Support | Community | Enterprise |

Eine Professional-Lizenz wird als signierte Offline-Datei installiert
(**System → Lizenz** oder `data/license/license.json`) und hebt das Benutzerlimit
auf. Die Architektur ist modular über `LicenseService.isFeatureEnabled()`
gesteuert — die Community-Grenze funktioniert vollständig ohne Lizenzserver.

## Security

- Starke Zufalls-Secrets, automatisch erzeugt
- PostgreSQL ist **nicht** öffentlich erreichbar (nur internes Docker-Netz)
- Row-Level-Security (App-Rolle mit `NOBYPASSRLS`)
- Container ohne zusätzliche Privilegien (`no-new-privileges`), App als non-root
- `.env` mit Rechten `600`, Secrets werden nicht geloggt
- Setup-Assistent durch Token geschützt und nach Abschluss gesperrt
- Benutzerlimit & Lizenzprüfung werden **serverseitig** erzwungen
- Lizenzdateien werden signaturgeprüft (ungültige werden abgelehnt)

## Support

Community-Support über das Projekt-Repository. Für Professional-Support und
Lizenzen wenden Sie sich an WERIT Solutions.

---

### Nützliche Befehle

```bash
./manage.sh status      # Container-Status + Health
./manage.sh logs        # Live-Logs
./manage.sh backup      # Backup erstellen
./manage.sh update      # Anwendung aktualisieren
./manage.sh version     # Version anzeigen
./manage.sh help        # alle Befehle
```

### Persistente Daten

| Ort | Inhalt |
|---|---|
| Volume `tivora-ce-postgres-data` | PostgreSQL-Datenbank |
| Volume `tivora-ce-app-data` | Vault-Schlüssel + Lizenz |
| Ordner `./backups` | Backups |

Diese werden bei `docker compose down` / `pull` / `up -d` **nie** überschrieben.

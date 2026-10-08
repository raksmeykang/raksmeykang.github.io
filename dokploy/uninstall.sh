#!/bin/bash
#
# Dokploy Mod — interactive uninstaller
#
# Lets you pick exactly which components to remove, so you can keep the
# database, keep Traefik, or tear the whole thing down.
#
# Usage:
#   curl -fsSL https://raksmeykang.github.io/dokploy/uninstall.sh | sudo bash
#   sudo bash uninstall.sh              # interactive menu
#   sudo bash uninstall.sh --all        # remove everything, no prompts
#   sudo bash uninstall.sh --app --db   # remove only what you name
#   sudo bash uninstall.sh --dry-run    # show what would be removed
#
set -euo pipefail

# ---------------------------------------------------------------- colours ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { printf '%s\n' "$*"; }
info() { printf "${BLUE}%s${NC}\n" "$*"; }
ok()   { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }
die()  { printf "${RED}ERROR: %s${NC}\n" "$*" >&2; exit 1; }

# ------------------------------------------------------------- preflight ----
if [ "$(id -u)" != "0" ]; then
    die "This script must be run as root (try: sudo bash $0)"
fi

if ! command -v docker >/dev/null 2>&1; then
    die "Docker is not installed — nothing to uninstall."
fi

DRY_RUN=0
declare -A WANT=(
    [app]=0 [db]=0 [traefik]=0 [swarm]=0
    [network]=0 [secrets]=0 [config]=0 [docker]=0
)

# --------------------------------------------------------- arg handling -----
for arg in "$@"; do
    case "$arg" in
        --all)    for k in "${!WANT[@]}"; do WANT[$k]=1; done ;;
        --app)    WANT[app]=1 ;;
        --db)     WANT[db]=1 ;;
        --traefik) WANT[traefik]=1 ;;
        --swarm)  WANT[swarm]=1 ;;
        --network) WANT[network]=1 ;;
        --secrets) WANT[secrets]=1 ;;
        --config) WANT[config]=1 ;;
        --docker) WANT[docker]=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "Unknown option: $arg (try --help)" ;;
    esac
done

# --------------------------------------------------- component detection ---
service_exists() { docker service ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }
container_exists() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
volume_exists() { docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }
network_exists() { docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }
secret_exists() { docker secret ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }

FOUND_APP=0; FOUND_DB=0; FOUND_TRAEFIK=0; FOUND_SWARM=0
FOUND_NETWORK=0; FOUND_SECRETS=0; FOUND_CONFIG=0

service_exists dokploy            && FOUND_APP=1
service_exists dokploy-postgres   && FOUND_DB=1
container_exists dokploy-traefik  && FOUND_TRAEFIK=1
docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active && FOUND_SWARM=1
network_exists dokploy-network    && FOUND_NETWORK=1
{ secret_exists dokploy_postgres_password || secret_exists dokploy_auth_secret; } && FOUND_SECRETS=1
[ -d /etc/dokploy ]               && FOUND_CONFIG=1

# ------------------------------------------------------------- the menu -----
draw_menu() {
    clear
    printf "${BOLD}Dokploy Mod — uninstaller${NC}\n\n"
    printf "Detected on this machine:\n"
    printf "  %s Dokploy application service\n"        "$([ $FOUND_APP = 1 ] && echo '✓' || echo '—')"
    printf "  %s PostgreSQL database service + volume\n" "$([ $FOUND_DB = 1 ] && echo '✓' || echo '—')"
    printf "  %s Traefik container\n"                  "$([ $FOUND_TRAEFIK = 1 ] && echo '✓' || echo '—')"
    printf "  %s Docker Swarm\n"                       "$([ $FOUND_SWARM = 1 ] && echo '✓' || echo '—')"
    printf "  %s dokploy-network\n"                   "$([ $FOUND_NETWORK = 1 ] && echo '✓' || echo '—')"
    printf "  %s Dokploy secrets\n"                   "$([ $FOUND_SECRETS = 1 ] && echo '✓' || echo '—')"
    printf "  %s /etc/dokploy\n"                      "$([ $FOUND_CONFIG = 1 ] && echo '✓' || echo '—')"
    printf "\n"
    printf "${BOLD}Choose what to remove:${NC}\n"
    printf "  ${CYAN}1${NC}) Dokploy application        ${YELLOW}(keeps database & Traefik)${NC}\n"
    printf "  ${CYAN}2${NC}) PostgreSQL database        ${RED}— destroys all data${NC}\n"
    printf "  ${CYAN}3${NC}) Traefik reverse proxy      ${YELLOW}— frees ports 80/443${NC}\n"
    printf "  ${CYAN}4${NC}) Docker Swarm\n"
    printf "  ${CYAN}5${NC}) dokploy-network\n"
    printf "  ${CYAN}6${NC}) Dokploy secrets\n"
    printf "  ${CYAN}7${NC}) /etc/dokploy config\n"
    printf "  ${CYAN}8${NC}) Docker Engine              ${RED}— affects every container on this host${NC}\n"
    printf "\n"
    printf "  ${CYAN}a${NC}) All of the above\n"
    printf "  ${CYAN}q${NC}) Quit\n"
    printf "\n"
}

if [ "$DRY_RUN" = 1 ]; then
    printf "${BOLD}Dry run — nothing will be removed.${NC}\n\n"
    for k in app db traefik swarm network secrets config docker; do
        [ "${WANT[$k]}" = 1 ] && printf "  would remove: %s\n" "$k"
    done
    exit 0
fi

# Interactive mode: no component flags were passed
if [ "${WANT[app]}" = 0 ] && [ "${WANT[db]}" = 0 ] && [ "${WANT[traefik]}" = 0 ] \
   && [ "${WANT[swarm]}" = 0 ] && [ "${WANT[network]}" = 0 ] && [ "${WANT[secrets]}" = 0 ] \
   && [ "${WANT[config]}" = 0 ] && [ "${WANT[docker]}" = 0 ]; then

    while true; do
        draw_menu
        read -rp "Enter numbers (space separated), 'a' for all, 'q' to quit: " input
        input=$(echo "$input" | tr 'A-Z' 'a-z')

        [ "$input" = "q" ] && { log "Aborted, nothing changed."; exit 0; }
        [ "$input" = "a" ] && { for k in "${!WANT[@]}"; do WANT[$k]=1; done; break; }

        valid=1
        for tok in $input; do
            case "$tok" in
                1) WANT[app]=1 ;;
                2) WANT[db]=1 ;;
                3) WANT[traefik]=1 ;;
                4) WANT[swarm]=1 ;;
                5) WANT[network]=1 ;;
                6) WANT[secrets]=1 ;;
                7) WANT[config]=1 ;;
                8) WANT[docker]=1 ;;
                *) warn "Ignoring unknown option: $tok"; valid=0 ;;
            esac
        done
        [ "$valid" = 1 ] && break
        warn "Press Enter to continue..."; read -r
    done
fi

# ------------------------------------------------------------ summary ------
printf "\n${BOLD}You selected to remove:${NC}\n"
for k in app db traefik swarm network secrets config docker; do
    [ "${WANT[$k]}" = 1 ] && printf "  • %s\n" "$k"
done

if [ "${WANT[db]}" = 1 ]; then
    printf "\n${RED}${BOLD}WARNING: removing the database permanently destroys all${NC}\n"
    printf "${RED}${BOLD}Dokploy data — applications, settings, logs. This cannot be undone.${NC}\n"
fi
if [ "${WANT[docker]}" = 1 ]; then
    printf "\n${RED}${BOLD}WARNING: removing Docker Engine affects every container${NC}\n"
    printf "${RED}${BOLD}and image on this host, not just Dokploy.${NC}\n"
fi

printf "\n"
read -rp "Type 'yes' to confirm: " confirm
[ "$confirm" = "yes" ] || { log "Aborted, nothing changed."; exit 0; }

run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf "  [dry-run] %s\n" "$*"
    else
        printf "  %s\n" "$*"
        eval "$@"
    fi
}

# ------------------------------------------------------- removal (ordered) --
printf "\n${BOLD}Uninstalling...${NC}\n"

# 1. Application service
if [ "${WANT[app]}" = 1 ] && [ "$FOUND_APP" = 1 ]; then
    info "Removing Dokploy application service..."
    run "docker service rm dokploy"
    run "docker volume rm dokploy 2>/dev/null || true"
    ok "Application removed."
fi

# 2. Database
if [ "${WANT[db]}" = 1 ] && [ "$FOUND_DB" = 1 ]; then
    info "Removing PostgreSQL service and volume..."
    run "docker service rm dokploy-postgres"
    run "docker volume rm dokploy-postgres 2>/dev/null || true"
    ok "Database removed."
fi

# 3. Traefik
if [ "${WANT[traefik]}" = 1 ] && [ "$FOUND_TRAEFIK" = 1 ]; then
    info "Removing Traefik container..."
    run "docker rm -f dokploy-traefik"
    ok "Traefik removed."
fi

# 4. Secrets
if [ "${WANT[secrets]}" = 1 ] && [ "$FOUND_SECRETS" = 1 ]; then
    info "Removing Dokploy secrets..."
    run "docker secret rm dokploy_postgres_password 2>/dev/null || true"
    run "docker secret rm dokploy_auth_secret 2>/dev/null || true"
    ok "Secrets removed."
fi

# 5. Network
if [ "${WANT[network]}" = 1 ] && [ "$FOUND_NETWORK" = 1 ]; then
    info "Removing dokploy-network..."
    run "docker network rm dokploy-network 2>/dev/null || true"
    ok "Network removed."
fi

# 6. Config directory
if [ "${WANT[config]}" = 1 ] && [ "$FOUND_CONFIG" = 1 ]; then
    info "Removing /etc/dokploy..."
    run "rm -rf /etc/dokploy"
    ok "Config directory removed."
fi

# 7. Swarm
if [ "${WANT[swarm]}" = 1 ] && [ "$FOUND_SWARM" = 1 ]; then
    info "Leaving Docker Swarm..."
    run "docker swarm leave --force 2>/dev/null || true"
    ok "Swarm left."
fi

# 8. Docker Engine
if [ "${WANT[docker]}" = 1 ]; then
    info "Removing Docker Engine..."
    if command -v apt-get >/dev/null 2>&1; then
        run "apt-get purge -y docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true"
        run "apt-get autoremove -y 2>/dev/null || true"
    elif command -v dnf >/dev/null 2>&1; then
        run "dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true"
    elif command -v yum >/dev/null 2>&1; then
        run "yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true"
    else
        warn "No supported package manager found — remove Docker manually."
    fi
    run "rm -rf /var/lib/docker /etc/docker /var/lib/containerd 2>/dev/null || true"
    ok "Docker Engine removed."
fi

printf "\n${GREEN}${BOLD}Done.${NC}\n"
printf "Reboot recommended if you removed Docker Engine or left Swarm.\n"

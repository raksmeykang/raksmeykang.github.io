#!/bin/bash

set -e

DOCKER_VERSION="28.5.0"

detect_version() {
    local version="${DOKPLOY_VERSION:-v0.29.10}"
    echo "$version"
}

is_proxmox_lxc() {
    if [ -n "$container" ] && [ "$container" = "lxc" ]; then
        return 0
    fi
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        return 0
    fi
    return 1
}

generate_random_password() {
    local password=""
    if command -v openssl >/dev/null 2>&1; then
        password=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    elif [ -r /dev/urandom ]; then
        password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
    else
        if command -v sha256sum >/dev/null 2>&1; then
            password=$(date +%s%N | sha256sum | base64 | head -c 32)
        elif command -v shasum >/dev/null 2>&1; then
            password=$(date +%s%N | shasum -a 256 | base64 | head -c 32)
        else
            password=$(echo "$(date +%s%N)-$(hostname)-$$-$RANDOM" | base64 | tr -d "=+/" | head -c 32)
        fi
    fi
    if [ -z "$password" ] || [ ${#password} -lt 20 ]; then
        echo "Error: Failed to generate random password" >&2
        exit 1
    fi
    echo "$password"
}

install_dokploy() {
    VERSION_TAG=$(detect_version)
    DOCKER_IMAGE="ghcr.io/raksmeykang/dokploy-mod:${VERSION_TAG}"

    echo "Installing Dokploy Mod version: ${VERSION_TAG}"
    echo "Image: ${DOCKER_IMAGE}"

    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    if [ "$(uname)" = "Darwin" ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    if [ -f /.dockerenv ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    if ss -tulnp | grep ':80 ' >/dev/null; then
        echo "Error: something is already running on port 80" >&2
        exit 1
    fi

    if ss -tulnp | grep ':443 ' >/dev/null; then
        echo "Error: something is already running on port 443" >&2
        exit 1
    fi

    if ss -tulnp | grep ':3000 ' >/dev/null; then
        echo "Error: something is already running on port 3000" >&2
        exit 1
    fi

    command_exists() {
        command -v "$@" > /dev/null 2>&1
    }

    if command_exists docker; then
        echo "Docker already installed"
    else
        curl -sSL https://get.docker.com | sh -s -- --version $DOCKER_VERSION
        if command_exists apt-mark; then
            apt-mark hold docker-ce docker-ce-cli docker-ce-rootless-extras
        fi
    fi

    endpoint_mode=""
    if [ "$ENDPOINT_MODE" = "dnsrr" ]; then
        endpoint_mode="--endpoint-mode dnsrr"
    elif is_proxmox_lxc; then
        echo "WARNING: Detected Proxmox LXC container environment!"
        endpoint_mode="--endpoint-mode dnsrr"
        sleep 5
    fi

    docker swarm leave --force 2>/dev/null

    get_ip() {
        local ip=""
        ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        fi
        if [ -z "$ip" ]; then
            ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi
        if [ -z "$ip" ]; then
            ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        fi
        if [ -z "$ip" ]; then
            ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        fi
        if [ -z "$ip" ]; then
            ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        fi
        if [ -z "$ip" ]; then
            echo "Error: Could not determine server IP." >&2
            exit 1
        fi
        echo "$ip"
    }

    get_private_ip() {
        ip -o -4 addr show scope global \
            | awk '$2 !~ /^(docker|br-|veth)/ {print $4}' \
            | cut -d/ -f1 \
            | grep -E "^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)" \
            | head -n1
    }

    advertise_addr="${ADVERTISE_ADDR:-$(get_private_ip)}"
    if [ -z "$advertise_addr" ]; then
        advertise_addr=$(get_ip)
    fi
    if [ -z "$advertise_addr" ]; then
        echo "ERROR: Could not detect server IP." >&2
        exit 1
    fi
    echo "Using advertise address: $advertise_addr"

    swarm_init_args="${DOCKER_SWARM_INIT_ARGS:-}"
    if [ -n "$swarm_init_args" ]; then
        docker swarm init --advertise-addr $advertise_addr $swarm_init_args
    else
        docker swarm init --advertise-addr $advertise_addr
    fi

    if [ $? -ne 0 ]; then
        echo "Error: Failed to initialize Docker Swarm" >&2
        exit 1
    fi

    docker network rm -f dokploy-network 2>/dev/null
    docker network create --driver overlay --attachable dokploy-network

    mkdir -p /etc/dokploy
    chmod 777 /etc/dokploy

    POSTGRES_PASSWORD=$(generate_random_password)
    echo "$POSTGRES_PASSWORD" | docker secret create dokploy_postgres_password - 2>/dev/null || true

    AUTH_SECRET=$(openssl rand -hex 32)
    echo "$AUTH_SECRET" | docker secret create dokploy_auth_secret - 2>/dev/null || true
    echo "Generated secure credentials"

    docker service create \
        --name dokploy-postgres \
        --constraint 'node.role==manager' \
        --network dokploy-network \
        --env POSTGRES_USER=dokploy \
        --env POSTGRES_DB=dokploy \
        --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
        --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
        --mount type=volume,source=dokploy-postgres,target=/var/lib/postgresql/data \
        $endpoint_mode \
        postgres:16

    echo "Waiting for Postgres..."
    sleep 10

    docker service create \
        --name dokploy \
        --replicas 1 \
        --network dokploy-network \
        --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
        --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
        --mount type=volume,source=dokploy,target=/root/.docker \
        --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
        --secret source=dokploy_auth_secret,target=/run/secrets/dokploy_auth_secret \
        --publish published=3000,target=3000,mode=host \
        --update-parallelism 1 \
        --update-order stop-first \
        --constraint 'node.role == manager' \
        $endpoint_mode \
        -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
        -e BETTER_AUTH_SECRET_FILE=/run/secrets/dokploy_auth_secret \
        "$DOCKER_IMAGE"

    sleep 4

    docker run -d \
        --name dokploy-traefik \
        --restart always \
        --network dokploy-network \
        -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
        -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -p 80:80/tcp \
        -p 443:443/tcp \
        -p 443:443/udp \
        traefik:v3.6.7

    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m"

    format_ip_for_url() {
        local ip="$1"
        if echo "$ip" | grep -q ':'; then
            echo "[${ip}]"
        else
            echo "${ip}"
        fi
    }

    public_ip="${ADVERTISE_ADDR:-$(get_ip)}"
    private_ip=$(get_private_ip)
    formatted_addr=$(format_ip_for_url "$public_ip")
    echo ""
    printf "${GREEN}Dokploy Mod installed!${NC}\n"
    printf "${BLUE}Wait 15 seconds for the server to start${NC}\n"
    printf "${YELLOW}Go to http://${formatted_addr}:3000${NC}\n"
    if [ -n "$private_ip" ] && [ "$private_ip" != "$public_ip" ]; then
        printf "${YELLOW}Or on local network: http://${private_ip}:3000${NC}\n"
    fi
    printf "\n"
}

update_dokploy() {
    VERSION_TAG=$(detect_version)
    DOCKER_IMAGE="ghcr.io/raksmeykang/dokploy-mod:${VERSION_TAG}"

    echo "Updating to version: ${VERSION_TAG}"
    docker pull "$DOCKER_IMAGE"
    docker service update --image "$DOCKER_IMAGE" dokploy
    echo "Update complete"
}

if [ "$1" = "update" ]; then
    update_dokploy
else
    install_dokploy
fi

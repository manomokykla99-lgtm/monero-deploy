#!/usr/bin/env bash
#
# deploy.sh — one-script Monero (XMRig) miner deployment.
# For machines YOU OWN or are explicitly authorized to use.
#
# Usage:
#   sudo bash deploy.sh                     # auto worker name: <hostname>-<id>
#   sudo bash deploy.sh my-worker           # custom worker name
#   sudo bash deploy.sh --uninstall         # remove miner completely
#   curl -fsSL https://your-url/deploy.sh | sudo bash   # remote one-liner
#
set -euo pipefail

XMRIG_VERSION="6.26.0"
XMRIG_SHA256="fc6f8ae5f64e4f17481f7e3be29a1c56949f216a998414188003eae1db20c9e5"
WALLET="48YdxBuKBGYCBkTkRmb7kTJpapTSbWbbcddNz59GxTwxQgBjCuiwyvQWzihEsbvoE3VTjfXqdznv78ggzebDYtji7eWDtSt"
POOL="pool.supportxmr.com:443"
INSTALL_DIR="/opt/xmrig"
SERVICE="xmrig"

# --- Argument parsing ---------------------------------------------------------
WORKER_NAME=""
case "${1:-}" in
    --uninstall) DO_UNINSTALL=1 ;;
    --help|-h)
        grep '^#' "$0" | head -10 | cut -c3-
        exit 0 ;;
    "") : ;;
    *) WORKER_NAME="$1" ;;
esac

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root, e.g.:  sudo bash deploy.sh" >&2
    exit 1
fi

# --- Uninstall ----------------------------------------------------------------
if [[ "${DO_UNINSTALL:-0}" == 1 ]]; then
    echo "==> Removing XMRig miner"
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    sed -i '/vm.nr_hugepages=/d' /etc/sysctl.conf 2>/dev/null || true
    echo "==> Removed. Wallet/pool config untouched (none stored outside ${INSTALL_DIR})."
    exit 0
fi

# --- Sanity checks --------------------------------------------------------------
if ! command -v systemctl >/dev/null; then
    echo "ERROR: this script needs a systemd-based distro (Ubuntu/Debian/etc.)" >&2
    exit 1
fi

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if (( MEM_MB < 3000 )); then
    echo "WARNING: only ${MEM_MB} MB RAM — RandomX fast mode needs ~2.5 GB."
    echo "         Mining will be extremely slow on this machine."
fi

# Gentle mode: mine on ~20% of threads (min 1)
THREADS=$(( ($(nproc) + 4) / 5 ))

# Unique worker name: hostname + 4 chars of machine-id (survives cloned VMs)
if [[ -z "$WORKER_NAME" ]]; then
    SUFFIX=$(cut -c1-4 /etc/machine-id 2>/dev/null || echo "xx")
    WORKER_NAME="$(hostname)-${SUFFIX}"
fi
# Pool-safe worker name (alphanumeric, dash, underscore only)
WORKER_NAME=$(echo "$WORKER_NAME" | tr -cd '[:alnum:]-_' | cut -c1-32)

echo "==> Deploying XMRig ${XMRIG_VERSION}"
echo "    worker : ${WORKER_NAME}"
echo "    pool   : ${POOL}"
echo "    cpus   : $(nproc) threads, mining on ~${THREADS} (gentle 20%), ${MEM_MB} MB RAM"

# --- Fetch tool (curl or wget; install curl if neither) -------------------------
if ! command -v curl >/dev/null && ! command -v wget >/dev/null; then
    echo "==> No curl/wget found, installing curl"
    apt-get update -qq && apt-get install -y -qq curl
fi
fetch() {  # fetch <url> <outfile>
    if command -v curl >/dev/null; then
        curl -fsSL --retry 3 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

# --- Download & verify ----------------------------------------------------------
TARBALL="xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz"
echo "==> Downloading XMRig"
fetch "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/${TARBALL}" "/tmp/${TARBALL}"
echo "${XMRIG_SHA256}  /tmp/${TARBALL}" | sha256sum -c - >/dev/null \
    || { echo "ERROR: checksum mismatch — aborting" >&2; exit 1; }
echo "    checksum OK"

# --- Install (idempotent: stop old service first) -------------------------------
systemctl stop "$SERVICE" 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
tar -xzf "/tmp/${TARBALL}" --strip-components=1 -C "$INSTALL_DIR"
rm -f "/tmp/${TARBALL}"

# --- Performance tuning: huge pages sized to this machine -----------------------
# RandomX dataset needs 1168 x 2MB pages + 1 per mining thread.
HUGEPAGES=$(( 1168 + THREADS ))
echo "$HUGEPAGES" > /proc/sys/vm/nr_hugepages
sed -i '/vm.nr_hugepages=/d' /etc/sysctl.conf
echo "vm.nr_hugepages=${HUGEPAGES}" >> /etc/sysctl.conf
modprobe msr 2>/dev/null || true

# --- Config ---------------------------------------------------------------------
cat > "${INSTALL_DIR}/config.json" <<EOF
{
    "http": { "enabled": true, "host": "127.0.0.1", "port": 8080, "access-token": null, "restricted": true },
    "autosave": false,
    "background": false,
    "colors": false,
    "randomx": { "mode": "auto", "1gb-pages": true, "rdmsr": true, "wrmsr": true, "numa": true },
    "cpu": { "enabled": true, "huge-pages": true, "huge-pages-jit": false, "yield": true, "max-threads-hint": 20, "asm": true },
    "opencl": { "enabled": false },
    "cuda": { "enabled": false },
    "donate-level": 1,
    "pools": [
        {
            "coin": "monero",
            "url": "${POOL}",
            "user": "${WALLET}.${WORKER_NAME}",
            "pass": "x",
            "keepalive": true,
            "enabled": true,
            "tls": true
        }
    ],
    "print-time": 60,
    "retries": 5,
    "retry-pause": 5,
    "syslog": true,
    "watch": true
}
EOF
chmod 600 "${INSTALL_DIR}/config.json"

# --- systemd service --------------------------------------------------------------
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=XMRig Monero miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xmrig --config=${INSTALL_DIR}/config.json
Restart=always
RestartSec=10
Nice=10
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE"

sleep 3
echo
if systemctl is-active --quiet "$SERVICE"; then
    echo "==> SUCCESS — miner is running and will start on every boot."
else
    echo "==> WARNING: service not active. Check: journalctl -u ${SERVICE} -n 30" >&2
    exit 1
fi
cat <<MSG

  Worker '${WORKER_NAME}' will appear within a few minutes on:
    https://supportxmr.com/#/dashboard  (paste your wallet address)

  Useful commands:
    journalctl -u ${SERVICE} -f              # live miner log
    curl -s localhost:8080/2/summary | jq    # live hashrate
    sudo bash $(basename "$0") --uninstall   # remove completely
MSG

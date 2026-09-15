# monero-deploy

One-script deployment of an [XMRig](https://github.com/xmrig/xmrig) Monero miner
for **my own headless machines** (VMs and servers I own).

## Usage

```bash
curl -fsSL https://github.com/manomokykla99-lgtm/monero-deploy/releases/latest/download/deploy.sh | sudo bash
```

Or with a custom worker name:

```bash
curl -fsSL https://github.com/manomokykla99-lgtm/monero-deploy/releases/latest/download/deploy.sh | sudo bash -s my-worker
```

Uninstall:

```bash
sudo bash deploy.sh --uninstall
```

## What it does

- Downloads the pinned XMRig release and verifies its SHA256
- Auto-names the worker `<hostname>-<machine-id>` (no collisions on cloned VMs)
- Tunes huge pages for the machine's CPU count
- Installs a self-restarting, boot-enabled systemd service
- Workers report to the mining pool; monitoring is done via the pool's
  dashboard/API — nothing extra runs on the workers

## Notes

- Only ever run this on machines you own or are explicitly authorized to use.
- Most VPS providers prohibit mining in their ToS; expect suspensions if you
  ignore that.
- The 1% `donate-level` is XMRig's built-in dev donation; set it to `0` in the
  script if you prefer.

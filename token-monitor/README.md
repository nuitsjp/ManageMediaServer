# Token Monitor Hub

This directory deploys two isolated [Token Monitor](https://github.com/Javis603/token-monitor)
Node hubs and one headless agent.

| Service | Listen address | Purpose |
| --- | --- | --- |
| `hub-private` | `192.168.0.23:17321`, `127.0.0.1:17321` | Private devices over the home LAN or Tailscale |
| `hub-work` | `127.0.0.1:17322` | Work devices over Tailscale only |
| `agent-private` | No published ports | Reads this host's Codex and Claude logs and sends them to `hub-private`; downloads model pricing over an outbound bridge |

Both hubs use the same shared secret, but have separate containers and edge bridge networks,
data files, logs, and backup directories. The work hub has no LAN-published
port. The bridge networks must permit Docker's published-port forwarding;
exposure is restricted by the explicit host bindings instead of Docker's
`internal` network flag. The private Agent uses an internal bridge shared with
the private Hub and a separate outbound bridge for model-pricing downloads.
It publishes no ports and does not join the work Hub's network.
Tailscale Serve terminates HTTPS for both localhost ports.

## Files and data

Tracked deployment files live in this directory. Real environment files are
stored in `config/env/*.env` and ignored by Git. Persistent state is outside the
repository:

```text
/mnt/data/token-monitor/private/data/devices.json
/mnt/data/token-monitor/work/data/devices.json
/mnt/data/token-monitor/agent-private/state/
/mnt/data/token-monitor/update/logs/update.log
/mnt/backup/token-monitor/
```

The agent container sets `hostname: home-ubuntu` so the Hub and Analytics show
the host name rather than Docker's random container ID.

The agent mounts only `/home/ubuntu/.codex` and `/home/ubuntu/.claude`, both
read-only. Provider-limit probing is disabled so provider credentials do not
need to be mounted into the container. It runs as UID 1000 with the
`mediaserver` group so its archive can be backed up while remaining separate
from both Hub stores.

`TOKSCALE_CONFIG_DIR=/var/lib/token-monitor/tokscale` stores pricing and scan
caches in the agent's writable persistent state volume. This permits cache
updates while the container root filesystem stays read-only. Pricing downloads
require outbound Internet access; a missing cache with no outbound access can
leave token totals populated while estimated costs are zero.

## Install

The real `config/env/token-monitor-common.env` must exist before installation.
Run the single installer from the development checkout:

```bash
sudo ./scripts/ops/install-token-monitor.sh
```

The installer validates required files, backs up an existing production copy,
creates the persistent directories, builds the pinned image, enables
`token-monitor.service`, configures Tailscale Serve, and runs health checks.
It deploys the integrated daily maintenance through
`scripts/ops/install-media-daily-maintenance-systemd.sh`, which installs every
script the workflow calls and enables the timer only after
`media-daily-maintenance.sh --preflight` passes.

## Client URLs

Private clients on the trusted home LAN connect directly:

```text
http://192.168.0.23:17321
```

Tailscale clients use:

```text
https://home-ubuntu.tail1bf795.ts.net:17321  # private
https://home-ubuntu.tail1bf795.ts.net:17322  # work
```

All clients use the shared `TOKEN_MONITOR_SECRET`. Do not expose either port
through router port forwarding. Because the LAN endpoint uses HTTP, keep guest
and IoT networks from reaching TCP 17321.

## Operations

```bash
sudo systemctl status token-monitor.service --no-pager
sudo journalctl -u token-monitor.service -n 100 --no-pager
sudo -u mediaserver ./token-monitor/scripts/healthcheck.sh
sudo -u mediaserver ./token-monitor/scripts/healthcheck.sh --require-agent
sudo -u mediaserver ./token-monitor/scripts/update.sh --check-only
sudo -u mediaserver ./token-monitor/scripts/update.sh --dry-run
```

The normal update entry point is `media-daily-maintenance.service`.
`token-monitor-update.timer` is installed but deliberately disabled to prevent
two update schedules from overlapping.

An update checks the latest stable GitHub release, backs up each hub store,
builds one shared image, runs the Hub/Agent/storage test subset, verifies a candidate hub, and then updates
the work hub, private hub, and private agent. On failure it restores the prior
image version.

The updater compares the running image IDs of all three containers with the
target image, even when the deployment version already matches the latest
release. Missing, stopped, or outdated containers trigger reconciliation.
It checks the image IDs and hub health again after rollout.

Agent backups stop the collector and copy its state through Docker. This lets
the daily maintenance user back up owner-only cache directories created by the
collector without changing their permissions. Backup copies belong to the
maintenance user; both hub stores and the full agent state remain included.

Manual rollback keeps hub data and changes only the runtime:

```bash
sudo -u mediaserver ./token-monitor/scripts/rollback.sh v0.60.0
```

## Work agent

No work agent is enabled. Sending the same host logs to both hubs would defeat
the private/work data boundary. Add a separate work agent only when its source
logs are owned by a separate Unix account or use a separate `CODEX_HOME`.

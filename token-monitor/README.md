# Token Monitor Hub

This directory deploys two isolated [Token Monitor](https://github.com/Javis603/token-monitor)
Node hubs and one headless agent.

| Service | Listen address | Purpose |
| --- | --- | --- |
| `hub-private` | `192.168.0.23:17321`, `127.0.0.1:17321` | Private devices over the home LAN or Tailscale |
| `hub-work` | `127.0.0.1:17322` | Work devices through Tailscale Serve or the protected public Funnel |
| Public proxy | `127.0.0.1:17422` | Authenticates and limits public work-Hub requests |
| `agent-private` | No published ports | Reads this host's Codex and Claude logs and sends them to `hub-private`; downloads model pricing over an outbound bridge |

Both hubs use the same shared secret, but have separate containers and edge bridge networks,
data files, logs, and backup directories. The work hub has no LAN-published
port. The bridge networks must permit Docker's published-port forwarding;
exposure is restricted by the explicit host bindings instead of Docker's
`internal` network flag. The private Agent uses an internal bridge shared with
the private Hub and a separate outbound bridge for model-pricing downloads.
It publishes no ports and does not join the work Hub's network.
Tailscale Serve terminates HTTPS for both localhost ports. TCP 443 is
intentionally public through Funnel and forwards to the dedicated nginx proxy,
which then forwards to the work Hub. The private Hub and Analytics stay private.

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
https://home-ubuntu.tail1bf795.ts.net        # work, public HTTPS Funnel
```

All clients use the shared `TOKEN_MONITOR_SECRET`. Do not expose either port
through router port forwarding. Because the LAN endpoint uses HTTP, keep guest
and IoT networks from reaching TCP 17321.

## Public Funnel protection

The public route is `Funnel :443 -> 127.0.0.1:17422 -> work Hub :17322`.
Install or refresh it from the Git working checkout with
`scripts/ops/install-token-monitor-public.sh` as root. Existing Hub clients keep
their URL and secret. The installer snapshots the existing files and Serve
configuration under `/mnt/backup/token-monitor-public.*`, verifies the new local
proxy before switching Funnel, and restores the old route/configuration if a
verification fails. It verifies that all other Serve endpoints match the snapshot.

Data requests require the current secret at both nginx and the Hub, using
`Authorization: Bearer ...` or `X-Token-Monitor-Secret`. nginx's additional gate
continues to deny anonymous requests if Hub authentication is disabled by
mistake. `/api/health` remains available without a secret because desktop clients
use it to compare Hub build compatibility; it includes build details and a device
count. OPTIONS requests retain the client's CORS contract. The API accepts no
query-string authentication.

`/etc/token-monitor-public/auth.conf` contains the existing running work Hub's
secret. It is generated without executing an env file, owned by root, and mode
0640 for the dedicated service group. It is never stored in Git or printed.
When rotating the Hub secret, rerun the installer to refresh this map. Until
then the two authentication gates disagree and authenticated requests are denied.

Default limits in `public/nginx.conf`:

| Limit | Value |
| --- | --- |
| Requests per client | 5/second, burst 40 |
| Requests across all clients | 50/second, burst 100 |
| Active requests/streams | 20 per client, 100 total |
| Request body | 1 MiB, matching the Hub limit |
| Client header/body timeout | 10/15 seconds of inactivity |
| Upstream connect/send/read timeout | 5/15/90 seconds of inactivity |

SSE buffering is disabled; the Hub's 30-second heartbeat keeps active streams
alive. Excess traffic receives HTTP 429; large bodies receive HTTP 413.
Only the loopback Tailscale proxy is trusted to supply `X-Forwarded-For`.
Tailscale 1.104.1 replaces that header with the original client address.

`token-monitor-public.service` runs as a separate non-login account with only
its own group. It has no Docker or sudo group, no Linux capabilities, read-only
system/home protection, loopback-only network access, and a 256 MiB memory limit.
Logs contain time, client IP, method, normalized path, status, size, and duration.
Headers, request bodies, and query strings are omitted. The sanitized access log
is rotated daily; nginx error logging is restricted to critical process errors
because ordinary nginx errors can include a request query.

The existing 10-minute media health check verifies the public service, HTTPS,
Hub authentication, and rejection of anonymous/invalid-token data reads. Normal
failure/recovery notifications remain with that existing check. The public
protections limit application traffic; Funnel's TLS/transport resource use and
network saturation still depend on Tailscale and the host's available resources.

Integration tests use real nginx against an isolated Hub fixture:

```bash
python3 -B -m unittest discover -s token-monitor/tests -p test_public.py -v
```

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

#!/bin/sh
# Keep the privileged updater independent of the caller's shell environment.
exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
    /usr/bin/bash /usr/local/libexec/token-monitor-analytics/update.sh "$@"

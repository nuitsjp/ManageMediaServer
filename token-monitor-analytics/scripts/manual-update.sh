#!/bin/sh
# Keep the privileged updater independent of the caller's shell environment.
# The passwordless entry point accepts published releases only. Local packages
# require an administrator to invoke update.sh directly with ordinary sudo.
HELP_REQUESTED=false
reject_options() {
    echo 'Allowed options: --version vX.Y.Z, --check-only, --dry-run, --help' >&2
    exit 2
}
check_options() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                shift
                [ "$#" -gt 0 ] && [ -n "$1" ] || reject_options
                ;;
            --check-only|--dry-run) ;;
            --help|-h) HELP_REQUESTED=true ;;
            *) reject_options ;;
        esac
        shift
    done
}
check_options "$@"
if [ "$HELP_REQUESTED" = true ]; then
    echo 'Usage: token-monitor-analytics-update [--version vX.Y.Z] [--check-only|--dry-run]'
    echo 'Local packages require administrator authentication and direct invocation of update.sh.'
    exit 0
fi
exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
    /usr/bin/bash /usr/local/libexec/token-monitor-analytics/update.sh "$@"

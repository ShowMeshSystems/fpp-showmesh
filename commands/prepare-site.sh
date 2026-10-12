#!/bin/sh
# The optional first argument is the "Stop playlists" command argument. Only
# a true value asks the coordinator to also stop what FPP is playing; turned
# on from inside a playlist it stops that playlist too.
case "${1:-}" in
    true | TRUE | True | 1)
        exec "${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}/night-command.sh" prepare-site --stop-playlists
        ;;
esac
exec "${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}/night-command.sh" prepare-site

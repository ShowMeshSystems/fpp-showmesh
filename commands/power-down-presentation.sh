#!/bin/sh
# The optional first argument is the "Force" command argument. Only a true
# value skips waiting for the show to finish and for FPP to confirm it stopped.
case "${1:-}" in
    true | TRUE | True | 1)
        exec "${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}/night-command.sh" power-down-presentation --force
        ;;
esac
exec "${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}/night-command.sh" power-down-presentation

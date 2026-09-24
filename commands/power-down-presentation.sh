#!/bin/sh
exec "${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}/night-command.sh" power-down-presentation

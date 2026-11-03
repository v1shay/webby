#!/bin/sh
# Build all current Webby changes with the existing signing identity, back up the
# installed app and replace it without quitting Webby or modifying browser data.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$script_dir/install-ide-widget.sh"

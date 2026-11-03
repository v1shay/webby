#!/bin/sh
# Uses Webby's existing signing identity, with a backup; leaves Webby running.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$script_dir/install-ide-widget.sh"

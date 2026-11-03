#!/bin/sh
# Run from your own Terminal when the signing key is available. Leaves Webby running.
set -eu
source_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
workspace=$(CDPATH= cd -- "$source_dir/.." && pwd)
stage="$workspace/work/Webby-IDE-Widget-signed.app"
WEBBY_BUILD_APP="$stage" WEBBY_BUILD_ICON_SOURCE="$source_dir/Webby.app/Contents/Resources/Webby.icns" WEBBY_SIGN_IDENTITY="system local code signing" sh "$source_dir/build.sh"
codesign --verify --deep --strict "$stage"
python3 - "$source_dir" "$stage" "$workspace/work" <<'PY'
from pathlib import Path
from datetime import datetime
import sys
source,stage,work=map(Path,sys.argv[1:])
current=source/'Webby.app'
backup=work/('Webby-before-ide-widget-'+datetime.now().strftime('%Y%m%d-%H%M%S'))
current.rename(backup)
try:stage.rename(current)
except BaseException:
 backup.rename(current)
 raise
print('Installed. Reopen Webby when ready. Rollback:',backup)
PY
codesign --verify --deep --strict "$source_dir/Webby.app"

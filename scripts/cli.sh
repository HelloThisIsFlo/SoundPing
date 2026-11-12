#!/usr/bin/env bash
set -euo pipefail

swift build --product soundping
exec "$(swift build --show-bin-path)/soundping" "$@"

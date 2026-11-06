#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh release
exec ./dist/cleanmoss install "$@"

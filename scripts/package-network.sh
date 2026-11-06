#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
base_url="${1:?Usage: scripts/package-network.sh BASE_URL [--skip-build]}"
if [[ "${2:-}" != --skip-build ]]; then ./scripts/build.sh release universal; fi
lipo dist/Cleanmoss.app/Contents/MacOS/Cleanmoss -verify_arch arm64 x86_64
lipo dist/cleanmoss -verify_arch arm64 x86_64
codesign --verify --strict dist/Cleanmoss.app
codesign --verify --strict dist/cleanmoss
mkdir -p dist/network
staging="$(mktemp -d "$PWD/dist/.network.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp -R dist/Cleanmoss.app "$staging/Cleanmoss.app"
cp dist/cleanmoss "$staging/cleanmoss"
(cd "$staging" && zip -q -r -X -y release.zip Cleanmoss.app cleanmoss)
checksum="$(shasum -a 256 "$staging/release.zip")"
checksum="${checksum%% *}"
destination="$PWD/dist/network/releases/$checksum"
mkdir -p "$destination"
mv "$staging/release.zip" "$destination/cleanmoss-macos-universal.zip"
python3 - "$base_url" "$checksum" <<'PY'
import json, pathlib, shlex, sys, urllib.parse
base, checksum = sys.argv[1:]
url = urllib.parse.urlsplit(base)
if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
    raise SystemExit('BASE_URL must be an HTTP(S) origin and path with no credentials, query, or fragment.')
archive = base.rstrip('/') + '/releases/' + checksum + '/cleanmoss-macos-universal.zip'
source = pathlib.Path('scripts/install-network.sh').read_text()
source = source.replace('@@ARCHIVE_URL@@', shlex.quote(archive)).replace('@@SHA256@@', shlex.quote(checksum))
root = pathlib.Path('dist/network')
temporary = root / '.install.sh.new'
temporary.write_text(source)
temporary.chmod(0o755)
temporary.replace(root / 'install.sh')
(root / 'release.json').write_text(json.dumps({'archive': archive, 'sha256': checksum, 'architectures': ['arm64', 'x86_64'], 'minimumMacOS': '14.0'}, indent=2) + '\n')
print('Install from any connected Mac:')
print('curl -fsSL ' + shlex.quote(base.rstrip('/') + '/install.sh') + ' | bash')
PY
bash -n dist/network/install.sh

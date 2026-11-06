#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project="$PWD"
mode="${1:-}"
case "$mode" in
  ''|--skip-build|--stop) ;;
  *) echo 'Usage: scripts/serve-tailnet.sh [--skip-build|--stop]' >&2; exit 2 ;;
esac
command -v tailscale >/dev/null || { echo 'Tailscale must be installed and connected on the host Mac.' >&2; exit 1; }
dns_name="$(tailscale status --json | /usr/bin/python3 -c '
import json, re, sys
try:
    status = json.load(sys.stdin)
    name = status["Self"]["DNSName"].rstrip(".")
    assert status.get("BackendState") == "Running" and re.fullmatch(r"[a-z0-9.-]+", name)
except Exception:
    raise SystemExit("Cannot read a connected Tailscale device. Run this script in Terminal with Tailscale connected.")
print(name)
')"
base_url="http://$dns_name:52742/cleanmoss"
target='http://127.0.0.1:52741'
tailscale serve status --json | /usr/bin/python3 -c '
import json, sys
try:
    config = json.load(sys.stdin)
except Exception:
    raise SystemExit("Cannot read Tailscale Serve configuration.")
if config.get("TCP", {}).get("52742", {}).get("HTTPS"):
    raise SystemExit("Port 52742 already serves HTTPS. Choose a different distribution port before proceeding.")
for host, web in config.get("Web", {}).items():
    if not host.endswith(":52742"):
        continue
    for path, handler in web.get("Handlers", {}).items():
        if path.rstrip("/") == "/cleanmoss" and handler.get("Proxy") != "http://127.0.0.1:52741":
            raise SystemExit("The Cleanmoss route is already owned by another service; preserving it.")
'
agent="$HOME/Library/LaunchAgents/com.cleanmoss.distribution.plist"
service="gui/$(id -u)/com.cleanmoss.distribution"
if [[ "$mode" == --stop ]]; then
  tailscale serve --http=52742 --set-path=/cleanmoss off
  launchctl bootout "$service" >/dev/null 2>&1 || true
  if [[ -f "$agent" ]]; then rm "$agent"; fi
  echo 'Stopped the Cleanmoss distribution service.'
  exit 0
fi
if [[ "$mode" == --skip-build ]]; then
  ./scripts/package-network.sh "$base_url" --skip-build
else
  ./scripts/package-network.sh "$base_url"
fi
mkdir -p "$project/dist/hosting" "$HOME/Library/LaunchAgents"
/usr/bin/python3 - "$project" "$agent" <<'PY'
import pathlib, plistlib, sys
project, destination = map(pathlib.Path, sys.argv[1:])
config = {
    'Label': 'com.cleanmoss.distribution',
    'ProgramArguments': ['/usr/bin/python3', str(project / 'scripts/distribution-server.py'), '--root', str(project / 'dist/network'), '--port', '52741'],
    'RunAtLoad': True,
    'KeepAlive': True,
    'ProcessType': 'Background',
    'ThrottleInterval': 10,
    'StandardOutPath': str(project / 'dist/hosting/server.stdout.log'),
    'StandardErrorPath': str(project / 'dist/hosting/server.stderr.log'),
}
temporary = destination.with_suffix('.new')
with temporary.open('wb') as stream:
    plistlib.dump(config, stream)
temporary.replace(destination)
PY
launchctl bootout "$service" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$agent"
curl --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 15 \
  http://127.0.0.1:52741/install.sh -o "$project/dist/hosting/served-install.sh"
if ! cmp -s "$project/dist/hosting/served-install.sh" "$project/dist/network/install.sh"; then
  launchctl bootout "$service" >/dev/null 2>&1 || true
  echo 'The local distribution port returned an unexpected file. Tailscale routing was not changed.' >&2
  exit 1
fi
tailscale serve --bg --http=52742 --set-path=/cleanmoss "$target"
echo
echo 'Install from any Mac connected to this tailnet (macOS 14+):'
echo "curl -fsSL $base_url/install.sh | bash"
echo 'The host Mac must be awake and logged in. The service restarts at login.'

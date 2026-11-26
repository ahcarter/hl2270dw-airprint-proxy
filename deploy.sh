#!/bin/bash
# deploy.sh -- push this folder to a Pi over SSH and run the installer there.
# Works from Linux, macOS, or Git Bash on Windows. Needs key-based SSH and passwordless sudo.
# Usage: ./deploy.sh [--wait] HOST [-- install.sh args]
#   --wait   poll until HOST answers SSH (up to 6 h), then deploy
# Example (first install): ./deploy.sh raspberrypi.local -- --printer 192.168.1.50
set -euo pipefail
cd "$(dirname "$0")"
WAIT=0
[ "${1:-}" = "--wait" ] && { WAIT=1; shift; }
HOST=${1:?usage: ./deploy.sh [--wait] HOST [-- install.sh args]}
shift
[ "${1:-}" = "--" ] && shift
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"

if [ $WAIT -eq 1 ]; then
    for i in $(seq 1 1440); do
        $SSH "$HOST" true 2>/dev/null && break
        [ "$i" -eq 1440 ] && { echo "$HOST never came up" >&2; exit 1; }
        sleep 15
    done
fi

echo "== copying to $HOST:~/hl2270-proxy"
tar -cf - install.sh uninstall.sh README.md files |
    $SSH "$HOST" 'rm -rf ~/hl2270-proxy.new && mkdir -p ~/hl2270-proxy.new &&
                  tar -xf - -C ~/hl2270-proxy.new &&
                  find ~/hl2270-proxy.new -type f -exec sed -i "s/\r$//" {} + &&
                  rm -rf ~/hl2270-proxy && mv ~/hl2270-proxy.new ~/hl2270-proxy'
echo "== installing"
$SSH "$HOST" "sudo -n bash ~/hl2270-proxy/install.sh $*"

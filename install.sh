#!/bin/bash
# install.sh -- turn a Raspberry Pi into an AirPrint proxy for the Brother HL-2270DW.
# Idempotent: re-running repairs and updates; it never touches unrelated services.
# Usage: sudo ./install.sh [--printer HOST] [--test-page]
#   --printer HOST   printer hostname or IP; needed on first install, remembered after
#   --test-page      print one CUPS test page after the self-test
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
F=$HERE/files
CONF=/etc/hl2270-proxy.conf
TEST_PAGE=0
PRINTER=""
while [ $# -gt 0 ]; do
    case $1 in
        --test-page) TEST_PAGE=1 ;;
        --printer)   PRINTER=${2:?--printer needs a hostname or IP}; shift ;;
        *)           echo "unknown option: $1 (see the header of $0)" >&2; exit 1 ;;
    esac
    shift
done
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
WARNINGS=0

step "1/6 Preflight"
# The config is written once and then left alone, so local edits survive re-installs.
[ -e "$CONF" ] || install -m 0644 "$F/hl2270-proxy.conf" "$CONF"
if [ -n "$PRINTER" ]; then
    case $PRINTER in *[!A-Za-z0-9.:-]*) echo "invalid printer host: $PRINTER" >&2; exit 1 ;; esac
    sed -i "s|^PRINTER_HOST=.*|PRINTER_HOST=$PRINTER|" "$CONF"
fi
if ! (. "$CONF"; [ -n "${PRINTER_HOST:-}" ]); then
    echo "No printer set. Run: sudo $0 --printer <printer hostname or IP>" >&2
    exit 1
fi
holders=$(ss -ltnpH 'sport = :631' 2>/dev/null | grep -v cupsd || true)
if [ -n "$holders" ]; then
    echo "Port 631 is held by something other than cupsd (a Docker container?):" >&2
    echo "$holders" >&2
    exit 1
fi

step "2/6 Packages (no recommends: no cups-browsed, no colord, no extra drivers)"
export DEBIAN_FRONTEND=noninteractive
PKGS="cups cups-ipp-utils printer-driver-brlaser avahi-daemon avahi-utils libnss-mdns iw"
for try in 1 2 3; do
    apt-get update -qq && apt-get install -y -qq --no-install-recommends $PKGS && break
    [ $try -eq 3 ] && { echo "apt failed 3 times" >&2; exit 1; }
    sleep 20
done
if systemctl list-unit-files cups-browsed.service >/dev/null 2>&1 &&
   systemctl is-enabled -q cups-browsed 2>/dev/null; then
    # cups-browsed creates and deletes queues on its own; a print server does not want that.
    systemctl disable --now cups-browsed
fi

step "3/6 Files"
install -m 0755 "$F/bripp"              /usr/lib/cups/backend/bripp
install -m 0755 "$F/hl2270-setup-queue"  /usr/local/sbin/hl2270-setup-queue
install -m 0755 "$F/hl2270-health"       /usr/local/sbin/hl2270-health
install -m 0644 "$F/hl2270-health.service" /etc/systemd/system/hl2270-health.service
install -m 0644 "$F/hl2270-health.timer"   /etc/systemd/system/hl2270-health.timer
for svc in cups avahi-daemon; do
    install -d /etc/systemd/system/$svc.service.d
    printf '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestart=always\nRestartSec=5\n' \
        > /etc/systemd/system/$svc.service.d/hl2270-restart.conf
done
systemctl daemon-reload

step "4/6 CUPS: share over AirPrint, LAN only, retry instead of stopping the queue"
[ -e /etc/cups/cupsd.conf.pre-hl2270 ] || cp -p /etc/cups/cupsd.conf /etc/cups/cupsd.conf.pre-hl2270
systemctl enable -q --now avahi-daemon cups
for i in $(seq 1 30); do lpstat -r >/dev/null 2>&1 && break; sleep 1; done
# Any cupsctl write makes cupsd exit and be restarted by systemd, which would interrupt a
# job mid-print. So write only when a setting differs; a re-run on a healthy Pi changes nothing.
WANT="_share_printers=1 _remote_admin=0 _remote_any=0 _user_cancel_any=0
      ErrorPolicy=retry-job JobRetryInterval=30 JobRetryLimit=60"
have=$(cupsctl 2>/dev/null || true)
stale=""
for kv in $WANT; do grep -qxF "$kv" <<<"$have" || stale="$stale $kv"; done
if [ -n "$stale" ]; then
    echo "updating CUPS settings:$stale"
    cupsctl --share-printers --no-remote-admin --no-remote-any --no-user-cancel-any \
        ErrorPolicy=retry-job JobRetryInterval=30 JobRetryLimit=60
    sleep 5   # cupsctl restarts cupsd asynchronously; let the old process exit first
    for i in $(seq 1 30); do lpstat -r >/dev/null 2>&1 && break; sleep 1; done
else
    echo "CUPS settings already correct; scheduler left running"
fi
/usr/local/sbin/hl2270-setup-queue
systemctl enable -q --now hl2270-health.timer

step "5/6 Hardening"
# Wi-Fi power save drops multicast, which makes AirPrint discovery flaky.
if [ -d /sys/class/net/wlan0/wireless ]; then
    iw dev wlan0 set power_save off || warn "could not turn off wlan0 power save"
    if [ -d /etc/NetworkManager/conf.d ]; then
        printf '[connection]\n# 2 = disable (set by hl2270-proxy)\nwifi.powersave = 2\n' \
            > /etc/NetworkManager/conf.d/hl2270-wifi-powersave.conf
    fi
fi
# Hardware watchdog: reboot if the kernel or systemd hangs for 14 s.
WD_CONF=/etc/systemd/system.conf.d/hl2270-watchdog.conf
if [ -e /dev/watchdog ] && ! systemctl is-active -q watchdog 2>/dev/null; then
    cur=$(systemctl show -p RuntimeWatchdogUSec --value)
    if [ -e "$WD_CONF" ] || [ "$cur" = "0" ] || [ "$cur" = "infinity" ]; then
        install -d /etc/systemd/system.conf.d
        printf '[Manager]\nRuntimeWatchdogSec=14s\nRebootWatchdogSec=2min\n' > "$WD_CONF"
        systemctl daemon-reexec
    fi
fi

step "6/6 Self-test (prints nothing unless --test-page)"
# Checks pipe into grep -q / head, which exit early and SIGPIPE the producer;
# under pipefail that reads as failure, so judge each pipeline by its last command.
set +o pipefail
Q=$(. /etc/hl2270-proxy.conf; echo "$QUEUE")
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; FAILS=$((FAILS + 1)); fi; }
FAILS=0
export LC_ALL=C
sleep 3
attrs=$(ipptool -tv "ipp://localhost/printers/$Q" get-printer-attributes.test 2>&1 || true)
check "queue $Q enabled"                   "lpstat -p $Q | grep -q 'enabled'"
check "queue $Q accepting jobs"            "lpstat -a $Q | grep -q 'accepting requests'"
check "queue is shared"                    "grep -q 'printer-is-shared (boolean) = true' <<<\"\$attrs\""
check "advertises Apple raster (URF)"      "grep -q 'urf-supported' <<<\"\$attrs\""
check "accepts image/urf and PDF"          "grep 'document-format-supported' <<<\"\$attrs\" | grep -q 'image/urf' && grep 'document-format-supported' <<<\"\$attrs\" | grep -q 'application/pdf'"
check "URF converts to printer format"     "cupsfilter -e --list-filters -p /etc/cups/ppd/$Q.ppd -m printer/foo -i image/urf /dev/null >/dev/null 2>&1"
check "PDF renders through the driver"     "cupsfilter -e -p /etc/cups/ppd/$Q.ppd -m printer/foo /usr/share/cups/data/default-testpage.pdf 2>/dev/null | head -c 256 | grep -aq '@PJL'"
# Bonjour registration can lag queue creation by several seconds; poll up to 30 s.
browse() { for _ in 1 2 3 4 5 6; do timeout 10 avahi-browse -t -r -p "$1" 2>/dev/null | grep -q "$2" && return 0; sleep 5; done; return 1; }
check "Bonjour _ipp._tcp advertisement"    "browse _ipp._tcp 'rp=printers/$Q'"
check "Bonjour _universal (AirPrint) subtype" "browse _universal._sub._ipp._tcp '$(hostname -s)'"
check "printer accepts a PCL IPP/1.0 job (Validate-Job)" \
      "DEVICE_URI=\$(lpstat -v $Q | awk '{print \$NF}') /usr/lib/cups/backend/bripp --probe >/dev/null 2>&1"
check "health timer active"                "systemctl is-active -q hl2270-health.timer"
check "Wi-Fi power save off (if Wi-Fi)"    "[ ! -d /sys/class/net/wlan0/wireless ] || iw dev wlan0 get power_save | grep -q off"
check "hardware watchdog armed"            "[ ! -e /dev/watchdog ] || [ \"\$(systemctl show -p RuntimeWatchdogUSec --value)\" != 0 ]"

if [ $TEST_PAGE -eq 1 ]; then
    lp -d "$Q" -t "hl2270-proxy test" /usr/share/cups/data/default-testpage.pdf
fi

echo
if [ $FAILS -eq 0 ]; then
    echo "READY: iPhone -> Share -> Print -> \"$(. /etc/hl2270-proxy.conf; echo "$QUEUE_INFO") @ $(hostname -s)\"  ($WARNINGS warnings)"
else
    echo "NOT READY: $FAILS self-test check(s) failed ($WARNINGS warnings)"
    exit 2
fi

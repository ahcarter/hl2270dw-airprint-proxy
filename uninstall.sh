#!/bin/bash
# uninstall.sh -- remove the HL-2270DW AirPrint proxy and restore the prior CUPS config.
# Leaves packages installed; remove them with:
#   sudo apt-get purge cups cups-ipp-utils printer-driver-brlaser avahi-utils
set -u
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
Q=$(. /etc/hl2270-proxy.conf 2>/dev/null; echo "${QUEUE:-HL2270DW}")

systemctl disable --now hl2270-health.timer 2>/dev/null
lpadmin -x "$Q" 2>/dev/null
rm -f /usr/lib/cups/backend/bripp /usr/local/sbin/hl2270-setup-queue /usr/local/sbin/hl2270-health \
      /etc/systemd/system/hl2270-health.service /etc/systemd/system/hl2270-health.timer \
      /etc/systemd/system/cups.service.d/hl2270-restart.conf \
      /etc/systemd/system/avahi-daemon.service.d/hl2270-restart.conf \
      /etc/NetworkManager/conf.d/hl2270-wifi-powersave.conf
rm -rf /usr/local/share/hl2270-proxy  # left by early versions
if [ -e /etc/systemd/system.conf.d/hl2270-watchdog.conf ]; then
    rm -f /etc/systemd/system.conf.d/hl2270-watchdog.conf
    systemctl daemon-reexec
fi
if [ -e /etc/cups/cupsd.conf.pre-hl2270 ]; then
    mv /etc/cups/cupsd.conf.pre-hl2270 /etc/cups/cupsd.conf
fi
systemctl daemon-reload
systemctl restart cups 2>/dev/null
echo "Removed. /etc/hl2270-proxy.conf kept; delete it by hand if unwanted."

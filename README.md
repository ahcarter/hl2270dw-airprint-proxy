# hl2270dw-airprint-proxy

Make a Brother HL-2270DW print from an iPhone or iPad. A Raspberry Pi on the same network advertises the printer
over AirPrint, renders each job with the open-source `brlaser` driver, and forwards it to the printer. Install is
one command, re-running it repairs everything, and a 13-point self-test proves the path works without using paper.

Verified on a Raspberry Pi 3B+ running Debian 13 (trixie): an iOS two-sided PDF job printed, a LAN test page
printed, and the proxy came back from a cold reboot with nothing to repair.

## How it works

```
iPhone --AirPrint (Bonjour + IPP, PDF or Apple raster)--> Pi: CUPS --brlaser--> bripp --IPP/1.0, PCL label--> HL-2270DW
```

The Pi runs stock CUPS with Avahi. CUPS advertises one shared queue with the AirPrint subtype and the `URF` key,
renders each job with `brlaser` (exact HL-2270DW model, duplex supported), and hands the result to `bripp`, a
small Python CUPS backend.

The custom backend exists because the printer defeats every stock CUPS path. Its IPP server speaks only IPP/1.0,
answers in HTTP/1.0, and rejects every document-format except `application/vnd.hp-PCL`; its raw ports, 9100 and
515, may be closed. `ipptool` treats an HTTP/1.0 reply as a failure even when the job succeeds, which would make
CUPS reprint every job up to 60 times. `bripp` sends one Print-Job labeled PCL, with a Content-Length header, and
judges the result by the IPP status code alone.

## Install

Requirements: a Raspberry Pi (or any Debian-based box) on the printer's LAN, key-based SSH, and passwordless sudo.
From a computer with this repository:

```
./deploy.sh raspberrypi.local -- --printer <printer hostname or IP>
```

Or on the Pi itself: `sudo ./install.sh --printer <printer hostname or IP>`. The printer address is remembered in
`/etc/hl2270-proxy.conf`; later runs need only `./deploy.sh <pi>`. Add `--test-page` to print one page. On the
iPhone, choose **"Brother HL-2270DW @ <pi hostname>"** in the Print sheet.

Optionally list fallback addresses in `FALLBACK_HOSTS` (the printer's `BRN….local` mDNS name, its IP) so a DHCP
change does not stop printing, then run `sudo hl2270-setup-queue`.

## What makes it hard to break

| Failure | Response |
|---|---|
| Printer off or asleep | Job waits and retries every 30 s for 30 min; the queue never stops |
| Printer changes IP | Backend tries `PRINTER_HOST`, then each `FALLBACK_HOSTS` entry |
| Printer rejects a job | That job is cancelled; the queue keeps running |
| Queue disabled or rejecting | Health check re-enables it within 2 min |
| Queue deleted | Health check recreates it |
| cupsd or avahi crashes | systemd restarts it in 5 s, with no restart limit |
| AirPrint advertisement vanishes | Health check restarts avahi, then cupsd (at most once per 30 min) |
| Kernel or systemd hangs | Hardware watchdog reboots the Pi (armed by the installer if the OS had none) |
| Wi-Fi power save drops multicast | Power save off now and on every reconnect |
| Re-running the installer | Changes nothing that is already right; a job mid-print is not interrupted |
| Power cut | Everything is enabled at boot |

## Files

| Path on the Pi | Purpose |
|---|---|
| `/etc/hl2270-proxy.conf` | Settings: printer hosts, queue name, paper. Kept across re-installs |
| `/usr/lib/cups/backend/bripp` | The backend |
| `/usr/local/sbin/hl2270-setup-queue` | Creates or repairs the queue |
| `/usr/local/sbin/hl2270-health` + `hl2270-health.timer` | 2-minute health check; silent unless it repairs |
| `/etc/systemd/system/{cups,avahi-daemon}.service.d/hl2270-restart.conf` | Always-restart policy |
| `/etc/NetworkManager/conf.d/hl2270-wifi-powersave.conf` | Wi-Fi power save off |
| `/etc/systemd/system.conf.d/hl2270-watchdog.conf` | Watchdog, only if the OS had none |
| `/etc/cups/cupsd.conf.pre-hl2270` | Backup of the original CUPS config |

Packages added, all without recommends: `cups`, `cups-ipp-utils`, `printer-driver-brlaser`, `avahi-daemon`,
`avahi-utils`, `libnss-mdns`, `iw`. `cups-browsed` is deliberately absent, because it creates and deletes queues on
its own.

## Operating it

```
lpstat -p HL2270DW -o                         # queue state and pending jobs
sudo journalctl -t hl2270-health              # repairs the health check made (this boot, if the journal is volatile)
DEVICE_URI=$(lpstat -v HL2270DW | awk '{print $NF}') /usr/lib/cups/backend/bripp --probe   # printer reachable? prints nothing
```

Uninstall: `sudo bash ~/hl2270-proxy/uninstall.sh`. It restores the original CUPS config and leaves the packages.

## Known limits

A job whose reply is lost after the printer has received every byte will print twice, because the backend prefers
a duplicate to a silent loss. Jobs sent while the printer stays off for more than 30 minutes are dropped, not
printed hours later. The CUPS log line "Scheduler shutting down due to program error" after a settings change is
CUPS restarting itself under systemd, not a crash.

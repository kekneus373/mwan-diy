# mwan-diy 🐱‍💻

**Multi-WAN automatic failover for OpenWRT — handmade, no dependencies on mwan3.**

This is a lightweight shell script that monitors your primary WAN interface and automatically fails over to a backup WAN when things go sideways. It was built out of necessity:  mwan3  [*"needs to be migrated/refactored to use nftables"*](https://forum.openwrt.org/t/mwan3-compatibility-in-openwrt-24-10/219952/2) for newer OpenWRT releases and isn't reliable in the meantime. This script fills that gap with no frills, no bloat, and no 800-line Lua packages.

Tested in  **2 production environments**,  connected with each other via OpenVPN, and holding steady.

----------

## ✨ What it does

-   Monitors a primary WAN (`eth1`) and fails over to a backup WAN (`eth2`)
-   Health checks via ICMP ping to multiple targets (Google, Cloudflare, Cisco)
-   Requires  **2 consecutive failures**  before failing over (anti-flap)
-   **Cooldown period**  after failover to prevent bouncing between links
-   Automatically  **restores the primary**  when it recovers
-   Detects and fixes UCI-disabled interfaces on the fly
-   Logs everything to  `/var/log/multi_wan_failover.log`  with built-in rotation
-   Runs as a proper  `procd`  service (auto-restart, clean shutdown)

## 🛠️ Requirements

-   OpenWRT (tested on recent snapshots/stable (25.12.4) where mwan3 is broken)
-   `bash`  (`apk -U add bash`) - the script's base
-   `jq`  (`apk -U add jq`) - extracts the default route from any of 2 WANs ([even inactive](https://gist.github.com/kekneus373/96b0b0153dc598d7faad3b5250e0def0))
-   Root access (the script checks for this)
-   Two WAN interfaces configured in  `/etc/config/network`

## 📦 Installation

```bash
# Clone or download the files
git clone https://github.com/kekneus373/mwan-diy.git
cd mwan-diy

# Copy the monitor script
cp multi_wan_monitor.sh /etc/multi_wan_monitor.sh
chmod +x /etc/multi_wan_monitor.sh

# Copy the service unit file
cp mwan-diy /etc/init.d/mwan-diy
chmod +x /etc/init.d/mwan-diy

# Enable and start the service
service mwan-diy enable
service mwan-diy start
```

## ⚙️ Configuration

Open  `/etc/multi_wan_monitor.sh`  and edit the variables at the top to match your setup:

```ini
PRIORITY_WAN="eth1"                    # Your preferred gateway device
BACKUP_WAN="eth2"                       # Your fallback gateway device
INTERFACE_NAME_PRIMARY="wan"           # UCI interface name for primary
INTERFACE_NAME_BACKUP="wan2"           # UCI interface name for backup
PING_TARGETS="8.8.8.8 1.1.1.1 208.67.222.222"
RETRIES_PER_TARGET=3
CONSECUTIVE_FAILURES_REQUIRED=2
CHECK_INTERVAL=30
COOLDOWN_AFTER_FAILOVER=120
INITIAL_DELAY=10
LOG_FILE="/var/log/multi_wan_failover.log"
MAX_LOG_SIZE_KB=1500
```

Most setups just need the device names and UCI interface names changed. The defaults are sane for a typical dual-WAN OpenWRT box.

## 🔧 Service Management

```bash
# Start / stop / restart
service mwan-diy start
service mwan-diy stop
service mwan-diy restart

# Enable on boot
service mwan-diy enable

# Disable on boot
service mwan-diy disable
```

The service auto-restarts on crash thanks to  `procd respawn`. Default respawn settings are 5s timeout, 5 retries, 3600s threshold — tweak in  `/etc/init.d/mwan-diy`  if you want different behavior.

## 📋 Logs

```bash
# Watch live logs
tail -f /var/log/multi_wan_failover.log

# Or check syslog for startup/shutdown events
logread -e mwan_diy
```

Logs auto-rotate at 1.5MB with 3 backup copies kept (`.1`,  `.2`,  `.3`).

## 🧠 How it works (quick version)

1.  Every 30 seconds, the script pings three public IPs through the primary WAN interface
2.  If both the interface is UP  **and**  pings succeed → all good, go back to sleep
3.  If pings fail twice in a row → grab the backup WAN's gateway info via  `ifstatus`  +  `jq`, and  `ip route replace`  the default route to point at the backup
4.  Once on backup, it keeps checking if the primary comes back. If it does → verify connectivity → swap the route back
5.  A 120-second cooldown after any switch prevents flapping during intermittent issues

The script also handles edge cases like interfaces getting soft-disabled in UCI (it re-enables them), physical link drops, and missing IP assignments.

## 🤷 Why does this exist?

`mwan3`  requires a significant rewrite for modern OpenWRT because of the [old deprecated `iptables` base](https://forum.openwrt.org/t/confusion-about-mwan3-dependencies-for-v24-10/235103/3). That's great — it'll be awesome when it lands. But right now, if you need dual-WAN failover  _today_  and mwan3 isn't cooperating, you need something that just works. So here it is.

This isn't a load balancer. It's not multi-WAN policy routing. It's a blunt instrument:  **if primary dies, switch to backup; if primary comes back, switch back.**  That's it. Sometimes that's all you need.

<sub>*Inspired by TP-LINK TL-ER6120 failover logic (which, BTW, got WRT clone under the hood 😏 )*</sub>

## ⚠️ Limitations

-   **Two WAN interfaces only**  (primary + backup). No 3+ WAN chaining.
-   **Active/passive only**  — no load balancing or traffic splitting.
-   **ICMP-based health checks**  — won't detect application-layer issues (e.g., DNS works but HTTP is blocked upstream).
-   **Route-based failover**  — uses  `ip route replace`  for the default route. If your OpenWRT setup uses policy routing,  `mptcp`, or other advanced routing configs, you may need to adapt the failover logic.
-   Tested on OpenWRT with  `bash`  installed. BusyBox  `ash`  **won't work**  due to bashisms (`(( ))`,  `local`, arrays-ish behavior). Install bash.

## 🪲 Troubleshooting

**Service won't start:**  Check that  `/etc/multi_wan_monitor.sh`  is executable and that bash is installed:  `which bash`.

**Failover doesn't trigger:**  Tail the log:  `tail -f /var/log/multi_wan_failover.log`. Look for the connectivity check messages. Make sure your  `PING_TARGETS`  aren't being blocked by your ISP or firewall.

**Route replacement fails:**  The script pulls gateway info from  `ifstatus <interface>`. Make sure your backup WAN interface actually gets a gateway assigned by your modem/DHCP. Run  `ifstatus wan2 | jq .`  to verify.

**Both WANs show as down:**  Either your internet is actually dead on both lines, or the  `PING_TARGETS`  are being blocked. Try replacing them with IPs you know respond (your ISP's DNS, for example).

## 📜 License

Do whatever you want with this. Attribution is appreciated but not required. If it saves your bacon, maybe buy someone a coffee. ☕

----------

## A note on "vibe-coding" 🎹

This script was born from frustration, fueled by fruit juice, Vaporwave and refined through trial and error in two real environments that couldn't afford downtime. I'm not a networking engineer or a shell wizard — I'm just someone who needed dual-WAN failover to work  _now_, not "when the rewrite lands."

The code is commented honestly (including the parts where past-me made mistakes and future-me left notes about it). It's version 10 for a reason. Each version fixed something that broke at 3 AM.

If it helps you bridge the gap until mwan3 is ready, mission accomplished. PRs welcome, especially from people who actually know what they're doing. 😄


> Much thanks to [Lumo AI](https://lumo.proton.me/). 💪👌

> Written with [StackEdit](https://stackedit.io/). 6️⃣7️⃣

# Wi-Fi slowdown finder

Run one script on the computer that has the slow Wi-Fi. It checks the usual causes and
lists the ones that are actually affecting you, with the fix for each.

| OS | Command |
|---|---|
| macOS / Linux | `bash wifi-check.sh` (add `--quick` to skip the speed test) |
| Windows | `powershell -ExecutionPolicy Bypass -File .\wifi-check.ps1` (add `-Quick`) |

What it checks:

- **Signal**: strength, signal-to-noise ratio, negotiated link rate
- **Band and channel**: 2.4 GHz vs 5/6 GHz, channel width, how many neighbouring networks share your channel
- **Wi-Fi link vs ISP**: ping, jitter and loss to your router, compared with the internet, to show whether the slowdown is in your Wi-Fi or upstream
- **DNS**: lookup speed of your DNS server vs 1.1.1.1
- **Bufferbloat**: latency while a download is running (the cause of "it lags whenever someone streams")
- **Local bandwidth hogs**: cloud sync, backups, torrents, game launchers, OS updates, and the top network-using processes
- **VPN / routing**: whether traffic actually goes over Wi-Fi
- **Device count**: how many devices share the network

It is read-only and changes no settings. Run it where and when the Wi-Fi feels slow.

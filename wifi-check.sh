#!/usr/bin/env bash
# wifi-check.sh — find what is slowing down your Wi-Fi (macOS and Linux).
#
# Usage:   bash wifi-check.sh            # full run (~1 minute)
#          bash wifi-check.sh --quick    # skip the speed / bufferbloat test
#
# Read-only: it changes nothing. Network traffic it generates: pings to your
# router and to 1.1.1.1 / 8.8.8.8, a few DNS lookups, and (unless --quick) a
# ~25 MB download from speed.cloudflare.com.

set -u
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

OS=$(uname -s)
PROBLEMS=()   # things clearly hurting performance
WARNINGS=()   # things that may be hurting performance

bad()  { PROBLEMS+=("$1"); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
warn() { WARNINGS+=("$1"); printf '  \033[33m! %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
# float compare: fgt A B  -> true if A > B
fgt()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }

# ping TARGET COUNT -> prints "avg jitter loss" (ms ms %), or nothing on failure
ping_stats() {
  local out
  out=$(ping -c "$2" -i 0.2 "$1" 2>/dev/null) || out=$(ping -c "$2" "$1" 2>/dev/null)
  [ -z "$out" ] && return
  local loss avg jit
  loss=$(printf '%s\n' "$out" | grep -o '[0-9.]*% packet loss' | grep -o '^[0-9.]*')
  avg=$(printf '%s\n' "$out" | awk -F'= ' '/min\/avg/{split($2,a,"/"); print a[2]}')
  jit=$(printf '%s\n' "$out" | awk -F'= ' '/min\/avg/{split($2,a,"/"); sub(/ .*/,"",a[4]); print a[4]}')
  [ -n "$avg" ] && echo "$avg $jit $loss" || echo "- - ${loss:-100}"
}

# ---------------------------------------------------------------- interface
hdr "Connection"
IFACE=""; GATEWAY=""; DEFIF=""
if [ "$OS" = "Darwin" ]; then
  IFACE=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
  GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  DEFIF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
else
  have iw && IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
  [ -z "$IFACE" ] && have nmcli && IFACE=$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
  GATEWAY=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
  DEFIF=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
fi
info "Wi-Fi interface: ${IFACE:-not found}"
info "Default route:   ${DEFIF:-none} via ${GATEWAY:-?}"

if [ -z "$IFACE" ]; then
  warn "No Wi-Fi interface found — radio checks skipped"
elif [ -n "$DEFIF" ] && [ "$DEFIF" != "$IFACE" ]; then
  warn "Internet traffic goes through '$DEFIF', not Wi-Fi '$IFACE' (a VPN or wired link). A VPN adds latency and caps speed — retest with it off."
fi

# ---------------------------------------------------------------- radio
hdr "Signal, band and channel"
RSSI=""; NOISE=""; CHAN=""; BAND=""; WIDTH=""; RATE=""; PHY=""; NEIGH_CHANS=""
if [ "$OS" = "Darwin" ]; then
  SP=$(system_profiler SPAirPortDataType 2>/dev/null)
  # sections end at the next line indented <= 10 spaces
  CUR=$(printf '%s\n' "$SP" | awk '/Current Network Information:/{f=1;next} f{match($0,/^ */); if(RLENGTH<=10)exit; print}')
  OTH=$(printf '%s\n' "$SP" | awk '/Other Local Wi-Fi Networks:/{f=1;next} f{match($0,/^ */); if(RLENGTH<=10)exit; print}')
  SN=$(printf '%s\n' "$CUR" | grep -m1 'Signal / Noise' | grep -o '\-[0-9]*')   # "-67\n-90"
  RSSI=$(printf '%s\n' "$SN" | sed -n 1p); NOISE=$(printf '%s\n' "$SN" | sed -n 2p)
  CHLINE=$(printf '%s\n' "$CUR" | awk -F': ' '/Channel:/{print $2; exit}')     # e.g. "149 (5GHz, 80MHz)"
  CHAN=$(printf '%s' "$CHLINE" | awk '{print $1}')
  BAND=$(printf '%s' "$CHLINE" | grep -o '[0-9.]*GHz' | head -1); [ "$BAND" = "2GHz" ] && BAND=2.4GHz
  WIDTH=$(printf '%s' "$CHLINE" | grep -o '[0-9]*MHz' | head -1)
  RATE=$(printf '%s\n' "$CUR" | awk -F': ' '/Transmit Rate:/{print $2; exit}')
  PHY=$(printf '%s\n' "$CUR"  | awk -F': ' '/PHY Mode:/{print $2; exit}')
  B=${BAND%%.*}; B=${B%GHz}   # only count neighbours on the same band
  NEIGH_CHANS=$(printf '%s\n' "$OTH" | awk -F': ' -v b="(${B}" '/Channel:/ && index($2,b){split($2,a," "); print a[1]}')
elif [ -n "$IFACE" ]; then
  if have iw; then
    LINK=$(iw dev "$IFACE" link 2>/dev/null)
    RSSI=$(printf '%s\n' "$LINK" | awk '/signal:/{print $2; exit}')
    FREQ=$(printf '%s\n' "$LINK" | awk '/freq:/{print int($2); exit}')
    RATE=$(printf '%s\n' "$LINK" | awk '/tx bitrate:/{print $3; exit}')
    WIDTH=$(printf '%s\n' "$LINK" | grep -o '[0-9]*MHz' | head -1)
    if [ -n "${FREQ:-}" ]; then
      if   [ "$FREQ" -lt 3000 ]; then BAND=2.4GHz; CHAN=$(( FREQ==2484 ? 14 : (FREQ-2407)/5 ))
      elif [ "$FREQ" -lt 5925 ]; then BAND=5GHz;   CHAN=$(( (FREQ-5000)/5 ))
      else                            BAND=6GHz;   CHAN=$(( (FREQ-5950)/5 )); fi
    fi
    PS=$(iw dev "$IFACE" get power_save 2>/dev/null | awk '{print $NF}')
    [ "${PS:-}" = "on" ] && warn "Wi-Fi power saving is ON — adds latency spikes. Disable: sudo iw dev $IFACE set power_save off"
  fi
  if have nmcli; then
    nmcli dev wifi rescan >/dev/null 2>&1
    NEIGH_CHANS=$(nmcli -t -f IN-USE,CHAN dev wifi list 2>/dev/null | awk -F: '$1!="*"{print $2}')
  fi
fi

info "Band: ${BAND:-?}  Channel: ${CHAN:-?}  Width: ${WIDTH:-?}  PHY: ${PHY:-?}"
info "Signal: ${RSSI:-?} dBm  Noise: ${NOISE:-?} dBm  Link rate: ${RATE:-?} Mbps"

if [ -n "$RSSI" ]; then
  if   [ "$RSSI" -lt -70 ]; then bad  "Weak signal ($RSSI dBm). Move closer to the router, remove obstructions, or add a mesh node / access point."
  elif [ "$RSSI" -lt -60 ]; then warn "Mediocre signal ($RSSI dBm). Below -60 dBm speeds drop noticeably."
  else ok "Signal strength good ($RSSI dBm)"; fi
fi
if [ -n "$RSSI" ] && [ -n "$NOISE" ]; then
  SNR=$(( RSSI - NOISE ))
  if [ "$SNR" -lt 25 ]; then warn "Low signal-to-noise ratio (${SNR} dB) — interference from microwaves, Bluetooth, baby monitors or neighbours."
  else ok "Signal-to-noise ratio fine (${SNR} dB)"; fi
fi
case "$BAND" in
  2*) bad "Connected on 2.4 GHz — slow and crowded. Join the 5 GHz (or 6 GHz) network if your router has one; if it uses one name for both bands, check band steering." ;;
  5*|6*) ok "On the $BAND band" ;;
esac
[ "$BAND" = "5GHz" ] && [ "$WIDTH" = "20MHz" ] && warn "5 GHz channel width is only 20 MHz — set 80 MHz in the router for up to 4x throughput."
if [ -n "$RATE" ]; then
  if fgt 100 "$RATE"; then warn "Low link rate (${RATE} Mbps) — your device and router are negotiating a slow connection (distance, old Wi-Fi standard, or narrow channel)."
  else ok "Link rate ${RATE} Mbps"; fi
fi

# channel congestion
if [ -n "$CHAN" ] && [ -n "$NEIGH_CHANS" ]; then
  TOTAL=$(printf '%s\n' "$NEIGH_CHANS" | grep -c .)
  if [ "$BAND" = "2.4GHz" ]; then   # 2.4 GHz channels within 4 of each other overlap
    SAME=$(printf '%s\n' "$NEIGH_CHANS" | awk -v c="$CHAN" '$1<=14 && ($1-c<5 && c-$1<5)' | grep -c .)
  else
    SAME=$(printf '%s\n' "$NEIGH_CHANS" | awk -v c="$CHAN" '$1==c' | grep -c .)
  fi
  info "Nearby networks: $TOTAL, sharing/overlapping your channel: $SAME"
  if   [ "$SAME" -ge 5 ]; then bad  "Channel $CHAN is congested ($SAME other networks). Pick a less used channel in the router (2.4 GHz: 1, 6 or 11)."
  elif [ "$SAME" -ge 2 ]; then warn "$SAME other networks share channel $CHAN — consider changing channel."
  else ok "Channel $CHAN is not crowded"; fi
  info "Busiest channels nearby: $(printf '%s\n' "$NEIGH_CHANS" | sort -n | uniq -c | sort -rn | head -5 | awk '{printf "ch%s(%s) ", $2, $1}')"
fi

# ---------------------------------------------------------------- latency
hdr "Latency and packet loss (local Wi-Fi vs internet)"
GW_AVG=""; NET_AVG=""
if [ -n "$GATEWAY" ]; then
  read -r GW_AVG GW_JIT GW_LOSS <<<"$(ping_stats "$GATEWAY" 30)"
  info "Router  ($GATEWAY): avg ${GW_AVG:-?} ms, jitter ${GW_JIT:-?} ms, loss ${GW_LOSS:-?}%"
  if [ "${GW_AVG:--}" = "-" ]; then warn "Router did not answer ping (some routers block it) — local test skipped"; GW_AVG=""
  else
    LOCAL_BAD=0
    fgt "${GW_LOSS:-0}" 0  && { bad "Packet loss between you and the router (${GW_LOSS}%) — that is the Wi-Fi link itself."; LOCAL_BAD=1; }
    fgt "$GW_AVG" 15       && { bad "Slow responses from the router (${GW_AVG} ms avg; should be <5 ms) — interference, weak signal or overloaded router."; LOCAL_BAD=1; }
    fgt "${GW_JIT:-0}" 10  && { warn "Jittery Wi-Fi link (${GW_JIT} ms) — hurts calls and gaming."; LOCAL_BAD=1; }
    [ $LOCAL_BAD = 0 ] && ok "Wi-Fi link to router is healthy"
  fi
fi
read -r NET_AVG NET_JIT NET_LOSS <<<"$(ping_stats 1.1.1.1 30)"
info "Internet (1.1.1.1): avg ${NET_AVG:-?} ms, jitter ${NET_JIT:-?} ms, loss ${NET_LOSS:-?}%"
if [ "${NET_AVG:--}" = "-" ]; then bad "No ping reply from the internet"; NET_AVG=""
else
  ISP_BAD=0
  fgt "${NET_LOSS:-0}" 1 && { bad "Packet loss to the internet (${NET_LOSS}%)."; ISP_BAD=1; }
  fgt "$NET_AVG" 60      && { warn "High internet latency (${NET_AVG} ms)."; ISP_BAD=1; }
  if [ $ISP_BAD = 1 ] && [ -n "$GW_AVG" ] && ! fgt "$GW_AVG" 15 && ! fgt "${GW_LOSS:-0}" 0; then
    info "→ Your Wi-Fi link is fine but the internet path is not: the problem is the modem, router WAN, or your ISP."
  fi
  [ $ISP_BAD = 0 ] && ok "Internet latency fine"
fi

# ---------------------------------------------------------------- DNS
hdr "DNS"
if have dig; then
  SYS_T=0; CF_T=0; N=0
  for d in wikipedia.org github.com apple.com bbc.co.uk; do
    s=$(dig +tries=1 +time=3 "$d" 2>/dev/null | awk '/Query time/{print $4}')
    c=$(dig +tries=1 +time=3 @1.1.1.1 "$d" 2>/dev/null | awk '/Query time/{print $4}')
    [ -n "$s" ] && [ -n "$c" ] && { SYS_T=$((SYS_T+s)); CF_T=$((CF_T+c)); N=$((N+1)); }
  done
  if [ $N -gt 0 ]; then
    SYS_A=$((SYS_T/N)); CF_A=$((CF_T/N))
    info "Your DNS: ${SYS_A} ms avg   Cloudflare 1.1.1.1: ${CF_A} ms avg"
    if [ $SYS_A -gt 100 ] && [ $SYS_A -gt $((CF_A*2)) ]; then
      bad "Slow DNS (${SYS_A} ms) — every new site waits on this. Switch DNS to 1.1.1.1 or 8.8.8.8 in your router or device."
    elif [ $SYS_A -gt 100 ]; then warn "DNS lookups are slow (${SYS_A} ms)"
    else ok "DNS is fast"; fi
  else warn "DNS lookups failed"; fi
else
  info "(install 'dig' for a DNS speed test)"
fi

# ---------------------------------------------------------------- speed + bufferbloat
if [ $QUICK = 0 ] && have curl; then
  hdr "Speed and bufferbloat (latency under load)"
  info "Downloading ~25 MB from speed.cloudflare.com while pinging..."
  TMP=$(mktemp)
  curl -s -o /dev/null -w '%{speed_download}' --max-time 30 \
       'https://speed.cloudflare.com/__down?bytes=25000000' >"$TMP" &
  CPID=$!
  sleep 1
  read -r LOAD_AVG _ _ <<<"$(ping_stats 1.1.1.1 20)"
  wait $CPID
  BPS=$(cat "$TMP"); rm -f "$TMP"
  MBPS=$(awk -v b="${BPS:-0}" 'BEGIN{printf "%.0f", b*8/1000000}')
  info "Download: ~${MBPS} Mbps   Latency idle ${NET_AVG:-?} ms → under load ${LOAD_AVG:-?} ms"
  if [ "$MBPS" = 0 ]; then warn "Speed test download failed"
  elif [ "$MBPS" -lt 10 ]; then bad "Very low download speed (~${MBPS} Mbps)"; fi
  if [ -n "$NET_AVG" ] && [ -n "${LOAD_AVG:-}" ] && [ "$LOAD_AVG" != "-" ]; then
    DELTA=$(awk -v a="$LOAD_AVG" -v b="$NET_AVG" 'BEGIN{printf "%.0f", a-b}')
    if   [ "$DELTA" -gt 100 ]; then bad  "Severe bufferbloat (+${DELTA} ms under load) — everything lags when anyone downloads/uploads. Enable SQM / Smart Queue / QoS in the router."
    elif [ "$DELTA" -gt 30 ];  then warn "Moderate bufferbloat (+${DELTA} ms under load). Router SQM/QoS would help."
    else ok "Little bufferbloat (+${DELTA} ms)"; fi
  fi
fi

# ---------------------------------------------------------------- local hogs
hdr "Apps on this computer using the network"
HOGS="dropbox|onedrive|google ?drive|googledrivefs|backblaze|bztransmit|crashplan|carbonite|transmission|qbittorrent|deluge|utorrent|bittorrent|steam|epicgames|battle.net|origin|softwareupdated|backupd|cloudd|bird|photolibraryd|nsurlsessiond|zoom|teams|obs"
RUNNING=$(ps -axo comm= 2>/dev/null | awk -F/ '{print $NF}' | grep -Eio "$HOGS" | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
[ -n "$RUNNING" ] && warn "Running apps that often use lots of bandwidth: $RUNNING— pause syncs/downloads and retest."

if [ "$OS" = "Darwin" ] && have nettop; then
  info "Top processes by traffic over 5 seconds:"
  nettop -P -d -x -L 2 -s 5 -J bytes_in,bytes_out 2>/dev/null \
    | awk -F, 'NR>1 && /^time/{s=1;next} s && NF>3 {t=$3+$4; if(t>0) printf "%12d  %s\n", t, $2}' \
    | sort -rn | head -5 \
    | awk '{b=$1; u="B"; if(b>1e6){b/=1e6;u="MB"}else if(b>1e3){b/=1e3;u="KB"}; printf "      %-35s %.1f %s\n", $2, b, u}'
elif have ss; then
  info "Processes with the most open connections:"
  ss -tnpH state established 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 \
    | sort | uniq -c | sort -rn | head -5 | awk '{printf "      %-25s %s connections\n", $2, $1}'
fi

# ---------------------------------------------------------------- devices
hdr "Other devices on your network"
DEV=$(arp -an 2>/dev/null | grep -vc 'incomplete')
info "Devices recently seen on the LAN: ${DEV:-?} (each streaming device, camera or console shares the airtime)"
[ "${DEV:-0}" -gt 30 ] && warn "Many devices ($DEV) share this network — check the router for any that are uploading or downloading constantly."

# ---------------------------------------------------------------- summary
hdr "Summary"
if [ ${#PROBLEMS[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
  ok "Nothing obvious is slowing your Wi-Fi from this device. Test from where it feels slow, and at the time it feels slow."
else
  [ ${#PROBLEMS[@]} -gt 0 ] && { printf '\033[31mProblems (%d):\033[0m\n' ${#PROBLEMS[@]}; for p in "${PROBLEMS[@]}"; do echo "  - $p"; done; }
  [ ${#WARNINGS[@]} -gt 0 ] && { printf '\033[33mWorth checking (%d):\033[0m\n' ${#WARNINGS[@]}; for w in "${WARNINGS[@]}"; do echo "  - $w"; done; }
fi
echo

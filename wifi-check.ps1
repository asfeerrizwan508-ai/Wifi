# wifi-check.ps1 — find what is slowing down your Wi-Fi (Windows 10/11).
#
# Usage (PowerShell):  powershell -ExecutionPolicy Bypass -File .\wifi-check.ps1 [-Quick]
#
# Read-only: it changes nothing. Generates pings to your router and 1.1.1.1,
# a few DNS lookups, and (unless -Quick) a ~25 MB download from speed.cloudflare.com.
# Note: parses 'netsh' output, which is in English only on English Windows.

param([switch]$Quick)
$Problems = @(); $Warnings = @()
function Bad($m)  { $script:Problems += $m; Write-Host "  x $m" -ForegroundColor Red }
function Warn($m) { $script:Warnings += $m; Write-Host "  ! $m" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "  + $m" -ForegroundColor Green }
function Info($m) { Write-Host "    $m" }
function Hdr($m)  { Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Field($text, $name) {
  $l = $text | Select-String -Pattern "^\s*$name\s*:\s*(.+)$" | Select-Object -First 1
  if ($l) { $l.Matches[0].Groups[1].Value.Trim() }
}
function PingStats($target, $count) {
  $p = New-Object System.Net.NetworkInformation.Ping; $t = @(); $lost = 0
  for ($i = 0; $i -lt $count; $i++) {
    try { $r = $p.Send($target, 1000); if ($r.Status -eq 'Success') { $t += $r.RoundtripTime } else { $lost++ } } catch { $lost++ }
    Start-Sleep -Milliseconds 200
  }
  if ($t.Count -eq 0) { return $null }
  $avg = ($t | Measure-Object -Average).Average
  $jit = 0; for ($i = 1; $i -lt $t.Count; $i++) { $jit += [math]::Abs($t[$i] - $t[$i-1]) }
  if ($t.Count -gt 1) { $jit = $jit / ($t.Count - 1) }
  [pscustomobject]@{ Avg = [math]::Round($avg,1); Jitter = [math]::Round($jit,1); Loss = [math]::Round(100*$lost/$count,1) }
}

# ---------------------------------------------------------------- connection
Hdr "Connection"
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
$gw = $route.NextHop; $defIf = $route.InterfaceAlias
$wlan = (netsh wlan show interfaces) -join "`n"
$wifiName = Field $wlan 'Name'
Info "Wi-Fi interface: $(if ($wifiName) { $wifiName } else { 'not found' })"
Info "Default route:   $defIf via $gw"
if (-not $wifiName) { Warn "No Wi-Fi interface found — radio checks skipped" }
elseif ($defIf -and $defIf -ne $wifiName) { Warn "Internet traffic goes through '$defIf', not Wi-Fi (a VPN or wired link). A VPN adds latency and caps speed — retest with it off." }

# ---------------------------------------------------------------- radio
Hdr "Signal, band and channel"
$sigPct = Field $wlan 'Signal'; $chan = Field $wlan 'Channel'; $radio = Field $wlan 'Radio type'
$band = Field $wlan 'Band'; $rate = Field $wlan 'Receive rate \(Mbps\)'
if (-not $band -and $chan) { $band = if ([int]$chan -le 14) { '2.4 GHz' } else { '5 GHz' } }
Info "Band: $band  Channel: $chan  PHY: $radio  Signal: $sigPct  Link rate: $rate Mbps"
if ($sigPct) {
  $pct = [int]($sigPct -replace '%',''); $dbm = [int]($pct/2 - 100)
  if ($dbm -lt -70)     { Bad  "Weak signal (~$dbm dBm, $sigPct). Move closer to the router, remove obstructions, or add a mesh node / access point." }
  elseif ($dbm -lt -60) { Warn "Mediocre signal (~$dbm dBm, $sigPct). Below -60 dBm speeds drop noticeably." }
  else                  { Ok "Signal strength good ($sigPct)" }
}
if ($band -like '2.4*') { Bad "Connected on 2.4 GHz — slow and crowded. Join the 5 GHz (or 6 GHz) network if your router has one." }
elseif ($band) { Ok "On the $band band" }
if ($rate -and [double]$rate -lt 100) { Warn "Low link rate ($rate Mbps) — distance, old Wi-Fi standard, or narrow channel." }
elseif ($rate) { Ok "Link rate $rate Mbps" }

if ($chan) {
  $c = [int]$chan
  $neigh = netsh wlan show networks mode=bssid | Select-String '^\s*Channel\s*:\s*(\d+)' | ForEach-Object { [int]$_.Matches[0].Groups[1].Value }
  $neigh = @($neigh)
  if ($neigh.Count -gt 0) {
    if ($c -le 14) { $same = @($neigh | Where-Object { $_ -le 14 -and [math]::Abs($_ - $c) -lt 5 }).Count - 1 }
    else           { $same = @($neigh | Where-Object { $_ -eq $c }).Count - 1 }
    if ($same -lt 0) { $same = 0 }
    Info "Nearby access points: $($neigh.Count), sharing/overlapping your channel: $same"
    if ($same -ge 5)     { Bad  "Channel $c is congested ($same other access points). Pick a less used channel in the router (2.4 GHz: 1, 6 or 11)." }
    elseif ($same -ge 2) { Warn "$same other access points share channel $c — consider changing channel." }
    else                 { Ok "Channel $c is not crowded" }
    $busy = $neigh | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "ch$($_.Name)($($_.Count))" }
    Info "Busiest channels nearby: $($busy -join ' ')"
  }
}

# ---------------------------------------------------------------- latency
Hdr "Latency and packet loss (local Wi-Fi vs internet)"
$g = $null
if ($gw) {
  $g = PingStats $gw 30
  if (-not $g) { Warn "Router did not answer ping — local test skipped" }
  else {
    Info "Router  ($gw): avg $($g.Avg) ms, jitter $($g.Jitter) ms, loss $($g.Loss)%"
    $lb = $false
    if ($g.Loss -gt 0)    { Bad "Packet loss between you and the router ($($g.Loss)%) — that is the Wi-Fi link itself."; $lb = $true }
    if ($g.Avg -gt 15)    { Bad "Slow responses from the router ($($g.Avg) ms; should be <5 ms) — interference, weak signal or overloaded router."; $lb = $true }
    if ($g.Jitter -gt 10) { Warn "Jittery Wi-Fi link ($($g.Jitter) ms) — hurts calls and gaming."; $lb = $true }
    if (-not $lb) { Ok "Wi-Fi link to router is healthy" }
  }
}
$n = PingStats '1.1.1.1' 30
if (-not $n) { Bad "No ping reply from the internet" }
else {
  Info "Internet (1.1.1.1): avg $($n.Avg) ms, jitter $($n.Jitter) ms, loss $($n.Loss)%"
  $ib = $false
  if ($n.Loss -gt 1) { Bad "Packet loss to the internet ($($n.Loss)%)."; $ib = $true }
  if ($n.Avg -gt 60) { Warn "High internet latency ($($n.Avg) ms)."; $ib = $true }
  if ($ib -and $g -and $g.Avg -le 15 -and $g.Loss -eq 0) { Info "-> Your Wi-Fi link is fine but the internet path is not: modem, router WAN, or your ISP." }
  if (-not $ib) { Ok "Internet latency fine" }
}

# ---------------------------------------------------------------- DNS
Hdr "DNS"
$sys = @(); $cf = @()
foreach ($d in 'wikipedia.org','github.com','apple.com','bbc.co.uk') {
  try { $sys += (Measure-Command { Resolve-DnsName $d -DnsOnly -NoHostsFile -ErrorAction Stop | Out-Null }).TotalMilliseconds } catch {}
  try { $cf  += (Measure-Command { Resolve-DnsName $d -DnsOnly -NoHostsFile -Server 1.1.1.1 -ErrorAction Stop | Out-Null }).TotalMilliseconds } catch {}
}
if ($sys.Count -and $cf.Count) {
  $sa = [int]($sys | Measure-Object -Average).Average; $ca = [int]($cf | Measure-Object -Average).Average
  Info "Your DNS: $sa ms avg   Cloudflare 1.1.1.1: $ca ms avg"
  if ($sa -gt 100 -and $sa -gt 2*$ca) { Bad "Slow DNS ($sa ms) — every new site waits on this. Switch DNS to 1.1.1.1 or 8.8.8.8 in your router or adapter settings." }
  elseif ($sa -gt 100) { Warn "DNS lookups are slow ($sa ms)" }
  else { Ok "DNS is fast" }
} else { Warn "DNS lookups failed" }

# ---------------------------------------------------------------- speed + bufferbloat
if (-not $Quick) {
  Hdr "Speed and bufferbloat (latency under load)"
  Info "Downloading ~25 MB from speed.cloudflare.com while pinging..."
  $job = Start-Job {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { (New-Object Net.WebClient).DownloadData('https://speed.cloudflare.com/__down?bytes=25000000') | Out-Null; 200e6 / $sw.Elapsed.TotalSeconds } catch { 0 }
  }
  Start-Sleep 1
  $l = PingStats '1.1.1.1' 20
  $bps = Receive-Job $job -Wait -AutoRemoveJob
  $mbps = [int]($bps / 1e6)
  Info "Download: ~$mbps Mbps   Latency idle $($n.Avg) ms -> under load $($l.Avg) ms"
  if ($mbps -eq 0) { Warn "Speed test download failed" }
  elseif ($mbps -lt 10) { Bad "Very low download speed (~$mbps Mbps)" }
  if ($n -and $l) {
    $delta = [int]($l.Avg - $n.Avg)
    if ($delta -gt 100)    { Bad  "Severe bufferbloat (+$delta ms under load) — everything lags when anyone downloads/uploads. Enable SQM / Smart Queue / QoS in the router." }
    elseif ($delta -gt 30) { Warn "Moderate bufferbloat (+$delta ms under load). Router SQM/QoS would help." }
    else                   { Ok "Little bufferbloat (+$delta ms)" }
  }
}

# ---------------------------------------------------------------- local hogs
Hdr "Apps on this computer using the network"
$hogPattern = 'dropbox|onedrive|googledrive|backblaze|bztransmit|crashplan|carbonite|qbittorrent|utorrent|bittorrent|transmission|deluge|steam|epicgames|battle\.net|origin|eadesktop|zoom|teams|obs64|msedgewebview|wuauserv|delivery'
$hogs = Get-Process | Where-Object { $_.ProcessName -match $hogPattern } | Select-Object -ExpandProperty ProcessName -Unique
if ($hogs) { Warn "Running apps that often use lots of bandwidth: $($hogs -join ', ') — pause syncs/downloads and retest." }
$do = Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Downloading' }
if ($do) { Warn "Windows Update / Store is downloading in the background ($(@($do).Count) files)." }
Info "Processes with the most open connections:"
Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Group-Object OwningProcess |
  Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
    $pn = (Get-Process -Id $_.Name -ErrorAction SilentlyContinue).ProcessName
    Info ("  {0,-25} {1} connections" -f $pn, $_.Count)
  }

# ---------------------------------------------------------------- devices
Hdr "Other devices on your network"
$dev = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.State -in 'Reachable','Stale','Delay','Probe' }).Count
Info "Devices recently seen on the LAN: $dev (each streaming device, camera or console shares the airtime)"
if ($dev -gt 30) { Warn "Many devices ($dev) share this network — check the router for any that are uploading or downloading constantly." }

# ---------------------------------------------------------------- summary
Hdr "Summary"
if (-not $Problems -and -not $Warnings) { Ok "Nothing obvious is slowing your Wi-Fi from this device. Test from where it feels slow, and at the time it feels slow." }
if ($Problems) { Write-Host "Problems ($($Problems.Count)):" -ForegroundColor Red; $Problems | ForEach-Object { Write-Host "  - $_" } }
if ($Warnings) { Write-Host "Worth checking ($($Warnings.Count)):" -ForegroundColor Yellow; $Warnings | ForEach-Object { Write-Host "  - $_" } }
Write-Host ""

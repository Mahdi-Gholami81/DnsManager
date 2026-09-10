$ScriptVersion = "1.1.1"
$VersionFile = Join-Path $PSScriptRoot "version.txt"
if (Test-Path $VersionFile) {
    $fileVer = (Get-Content $VersionFile -Raw).Trim()
    if ($fileVer -match '^\d+\.\d+\.\d+$') { $ScriptVersion = $fileVer }
}
$RepoOwner = "mahdi-gholami81"
$RepoName = "dns-manager"
# Check for administrator privileges — auto-elevate via UAC
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges (UAC dialog)..." -ForegroundColor Yellow
    try {
        $psi = $PSCommandPath
        if ([string]::IsNullOrEmpty($psi)) { $psi = Join-Path $PSScriptRoot "DnsManager.ps1" }
        $hostExe = "powershell.exe"
        if ($PSVersionTable.PSEdition -eq "Core") {
            $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if ($pwsh) { $hostExe = $pwsh }
        }
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$psi`""
    }
    catch {
        Write-Host "Administrator privileges are required." -ForegroundColor Red
        Write-Host "UAC was declined or elevation failed. Right-click terminal -> 'Run as Administrator' and retry." -ForegroundColor Yellow
        Read-Host "Press Enter to continue..." | Out-Null
    }
    exit
}

$IniPath = "$PSScriptRoot\servers.ini"
$UIWidth = 56

# ────────────────────────────────────────────────────────────
#  UI Helpers
# ────────────────────────────────────────────────────────────
function Pause {
    Read-Host "Press Enter to continue..." | Out-Null
}

function Write-Banner {
    param([string]$Title)
    $title = $Title.ToUpper()
    $dash = [char]0x2550
    $left = [math]::Floor(($UIWidth - $title.Length) / 2)
    if ($left -lt 0) { $left = 0 }
    Write-Host (" " * $left + $title) -ForegroundColor Cyan
    Write-Host (" " * $left + ("$dash" * $title.Length)) -ForegroundColor Cyan
}

function Write-Rule {
    param([ConsoleColor]$Color = "DarkGray")
    $dash = [char]0x2500
    Write-Host ("$dash" * $UIWidth) -ForegroundColor $Color
}

function Write-Section {
    param([string]$Label, [ConsoleColor]$Color = "Cyan")
    $dash = [char]0x2500
    $prefix = ("{0}{0} {1} " -f [char]0x2500, $Label)
    $right = $UIWidth - $prefix.Length
    if ($right -lt 0) { $right = 0 }
    Write-Host ($prefix + ("$dash" * $right)) -ForegroundColor $Color
}

function Write-Line {
    param([string]$Text = "", [ConsoleColor]$Color = "Gray", [string]$Prefix = "  ")
    Write-Host ($Prefix + $Text) -ForegroundColor $Color
}

# ────────────────────────────────────────────────────────────
#  DNS list (servers.ini)
# ────────────────────────────────────────────────────────────
function Read-DNSList {
    $dnsList = @()

    if (-not (Test-Path $IniPath)) {
        Write-Host "INI file not found."
        return $dnsList
    }

    Get-Content $IniPath | ForEach-Object {
        if ($_ -match "=") {
            $name, $values = $_ -split "=", 2
            $dnsServers = @($values -split "," |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne "" })

            if ($dnsServers.Count -eq 0) { continue }

            $dnsList += [PSCustomObject]@{
                Name = $name.Trim()
                DNS  = $dnsServers
            }
        }
    }

    return $dnsList
}

function Save-DnsList {
    param($List)
    $lines = $List | ForEach-Object { "$($_.Name)=$($_.DNS -join ',')" }
    Set-Content -Path $IniPath -Value $lines -Encoding ASCII
}

function Get-ActiveDnsServers {
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($a in $adapters) {
        $dns = Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex `
            -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $s = @($dns.ServerAddresses | Where-Object { $_ })
        if ($s.Count -gt 0) { return $s }
    }
    return @()
}

function Apply-DnsServers {
    param([string[]]$Servers, [string]$Label)
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    if ($adapters.Count -eq 0) { throw "No active network adapters found." }
    foreach ($a in $adapters) {
        Write-Line "Applying to: $($a.Name)" -Color Gray
        Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $Servers
    }
    Write-Line "DNS applied successfully." -Color Green
    Repair-NetworkAfterDNS
}

# ────────────────────────────────────────────────────────────
#  Network helpers
# ────────────────────────────────────────────────────────────
function Repair-NetworkAfterDNS {
    Write-Line "Refreshing network so the new DNS actually takes effect..." -Color Gray
    Write-Rule -Color DarkGray

    try {
        ipconfig /flushdns | Out-Null
        Write-Line "[OK] DNS cache flushed." -Color Green
    }
    catch {
        Write-Line "[!] Could not flush DNS cache." -Color Red
    }

    try {
        Restart-Service -Name "Dnscache" -Force -ErrorAction Stop
        Write-Line "[OK] DNS Client service restarted." -Color Green
    }
    catch {
        Write-Line "[!] Could not restart DNS Client service." -Color Red
    }

    try {
        ipconfig /release | Out-Null
        ipconfig /renew | Out-Null
        Write-Line "[OK] IP configuration renewed." -Color Green
    }
    catch {
        Write-Line "[!] Could not renew IP configuration." -Color Red
    }
}

function Show-CompactStatus {
    Write-Section -Label "Current Network"
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    if ($adapters.Count -eq 0) {
        Write-Line "No active adapters." -Color Red
        return
    }
    foreach ($a in $adapters) {
        $type = switch ($a.InterfaceType) {
            "Wireless80211" { "Wi-Fi" }
            "Ethernet" { "Ethernet" }
            default { $a.InterfaceType }
        }
        $ipc = Get-NetIPConfiguration -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
        $ipv4 = (($ipc.IPv4Address | Where-Object { $_.IPAddress }).IPAddress) -join ', '
        $gw = (($ipc.IPv4DefaultGateway | Where-Object { $_.NextHop }).NextHop) -join ', '
        $dns = Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex `
            -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $servers = @($dns.ServerAddresses | Where-Object { $_ })
        $dnsColor = if ($servers.Count -gt 0) { "White" } else { "Yellow" }
        $d1 = if ($servers.Count -ge 1) { $servers[0] } else { "none" }
        $d2 = if ($servers.Count -ge 2) { $servers[1] } else { "-" }

        Write-Line "$($a.Name)  [$type]" -Color White
        Write-Line ("{0,-7}: {1}" -f "IPv4", $ipv4) -Color Gray
        Write-Line ("{0,-7}: {1}" -f "Gateway", $gw) -Color Gray
        Write-Line ("{0,-7}: {1,-18} {2,-7}: {3}" -f "DNS 1", $d1, "DNS 2", $d2) -Color $dnsColor
        Write-Host ""
    }
}

# ────────────────────────────────────────────────────────────
#  Menu actions
# ────────────────────────────────────────────────────────────
function Select-And-SetDNS {
    Clear-Host
    $dnsList = Read-DNSList

    Write-Banner -Title "Select DNS Server"
    Write-Host ""

    if ($dnsList.Count -eq 0) {
        Write-Line "DNS list is empty." -Color Yellow
        Pause
        return
    }

    $active = @(Get-ActiveDnsServers | Sort-Object)
    $activeKey = ($active -join ',')

    Write-Host ("  {0,-3} {1,-15} {2,-15} {3,-15} {4}" -f "#", "NAME", "DNS 1", "DNS 2", "STATUS") -ForegroundColor DarkGray
    Write-Rule -Color DarkGray

    for ($i = 0; $i -lt $dnsList.Count; $i++) {
        $entry = $dnsList[$i]
        $d1 = if ($entry.DNS.Count -ge 1) { $entry.DNS[0] } else { "" }
        $d2 = if ($entry.DNS.Count -ge 2) { $entry.DNS[1] } else { "" }
        $isActive = ((@($entry.DNS | Sort-Object) -join ',') -eq $activeKey)
        $status = if ($isActive) { [char]0x25CF } else { "" }
        if ($isActive) {
            Write-Host ("  {0,-3} {1,-15} {2,-15} {3,-15} " -f ($i + 1), $entry.Name, $d1, $d2) -NoNewline -ForegroundColor Gray
            Write-Host $status -ForegroundColor Green
        }
        else {
            Write-Host ("  {0,-3} {1,-15} {2,-15} {3,-15} " -f ($i + 1), $entry.Name, $d1, $d2) -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Line "[0] Back" -Color Yellow -Prefix "  "
    $choice = Read-Host "`nSelect DNS number"

    if ($choice -eq "0") { return }
    if ($choice -lt 1 -or $choice -gt $dnsList.Count) {
        Write-Line "Invalid selection." -Color Red
        Pause
        return
    }

    $selected = $dnsList[$choice - 1]
    Write-Host ""
    Write-Line "Setting DNS: $($selected.Name)" -Color Cyan
    try {
        Apply-DnsServers -Servers $selected.DNS -Label $selected.Name
        $testUrl = Read-Host "`nTest a site now? Enter URL or press Enter to skip"
        if ($testUrl -ne "") { Test-SiteConnectivity -Url $testUrl }
    }
    catch {
        Write-Line "Failed to set DNS." -Color Red
        Write-Line "Error: $_" -Color Red
    }
    Write-Host ""
    Pause
}

function Manage-DnsList {
    while ($true) {
        Clear-Host
        Write-Banner -Title "Manage DNS List"
        Write-Host ""

        $list = Read-DNSList

        if ($list.Count -eq 0) {
            Write-Line "DNS list is empty." -Color Yellow
        }
        else {
            for ($i = 0; $i -lt $list.Count; $i++) {
                $e = $list[$i]
                $d2 = if ($e.DNS.Count -ge 2) { $e.DNS[1] } else { "" }
                Write-Host ("  {0,-3} {1,-16} {2,-16} {3}" -f ($i + 1), $e.Name, $e.DNS[0], $d2) -ForegroundColor Gray
            }
        }

        Write-Host ""
        Write-Line "[A] Add    [E #] Edit    [D #] Delete    [0] Back" -Color Cyan
        $cmd = (Read-Host "`nCommand").Trim()

        if ($cmd -eq "0") { return }
        if ($cmd -eq "") { continue }

        if ($cmd -eq "A" -or $cmd -eq "a") {
            Write-Host ""
            $name = Read-Host "DNS Name"
            if ($name.Trim() -eq "") { continue }
            $dns1 = Read-Host "Primary DNS"
            if ($dns1.Trim() -eq "") { continue }
            $dns2 = Read-Host "Secondary DNS (Enter to skip)"
            if ($dns2.Trim() -eq "") {
                $list += [PSCustomObject]@{ Name = $name.Trim(); DNS = @($dns1.Trim()) }
            }
            else {
                $list += [PSCustomObject]@{ Name = $name.Trim(); DNS = @($dns1.Trim(), $dns2.Trim()) }
            }
            Save-DnsList -List $list
            Write-Line "DNS added successfully." -Color Green
            Pause
            continue
        }

        if ($cmd -match '^([EDed])\s*(\d+)$') {
            $op = $Matches[1].ToUpper()
            $idx = [int]$Matches[2] - 1
            if ($idx -lt 0 -or $idx -ge $list.Count) {
                Write-Line "Invalid entry number." -Color Red
                Pause
                continue
            }

            if ($op -eq "D") {
                $newList = @()
                for ($j = 0; $j -lt $list.Count; $j++) {
                    if ($j -ne $idx) { $newList += $list[$j] }
                }
                Save-DnsList -List $newList
                Write-Line "Entry deleted." -Color Green
                Pause
                continue
            }

            # Edit
            $entry = $list[$idx]
            Write-Host ""
            $newName = Read-Host ("Name [{0}]" -f $entry.Name)
            if ($newName.Trim() -eq "") { $newName = $entry.Name }
            $newD1 = Read-Host ("Primary DNS [{0}]" -f $entry.DNS[0])
            if ($newD1.Trim() -eq "") { $newD1 = $entry.DNS[0] }
            $curD2 = if ($entry.DNS.Count -ge 2) { $entry.DNS[1] } else { "" }
            $newD2 = Read-Host ("Secondary DNS [{0}] (Enter to skip)" -f $curD2)
            if ($newD2.Trim() -eq "") { $newD2 = $curD2 }
            $newServers = if ($newD2 -eq "") { @($newD1) } else { @($newD1, $newD2) }
            $newList = @()
            for ($j = 0; $j -lt $list.Count; $j++) {
                if ($j -eq $idx) {
                    $newList += [PSCustomObject]@{ Name = $newName.Trim(); DNS = $newServers }
                }
                else {
                    $newList += $list[$j]
                }
            }
            Save-DnsList -List $newList
            Write-Line "Entry updated." -Color Green
            Pause
            continue
        }

        Write-Line "Unknown command. Use A, E #, D #, or 0." -Color Red
        Pause
    }
}

function Flush-DNS {
    Clear-Host
    Write-Banner -Title "Flush DNS Cache"
    Write-Host ""
    Write-Line "Flushing DNS cache..."
    try {
        ipconfig /flushdns | Out-Null
        Write-Line "DNS cache flushed successfully." -Color Green
    }
    catch {
        Write-Line "Failed to flush DNS cache." -Color Red
        Write-Line "Error: $_" -Color Red
    }
    Write-Host ""
    Pause
}

function Reset-DNSToDefault {
    Clear-Host
    Write-Banner -Title "Reset DNS"
    Write-Host ""
    Write-Line "Resetting DNS to default (Automatic / DHCP)..."
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
        if ($adapters.Count -eq 0) { throw "No active network adapters found." }
        foreach ($adapter in $adapters) {
            Write-Line "Resetting: $($adapter.Name)" -Color Gray
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses
        }
        Write-Line "DNS reset to default." -Color Green
        Repair-NetworkAfterDNS
        $testUrl = Read-Host "`nTest a site now? Enter URL or press Enter to skip"
        if ($testUrl -ne "") { Test-SiteConnectivity -Url $testUrl }
    }
    catch {
        Write-Host ""
        Write-Line "Failed to reset DNS." -Color Red
        Write-Line "Error: $_" -Color Red
    }
    Write-Host ""
    Pause
}

function Get-HttpStatusCode {
    param([string]$HostName)

    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

    foreach ($scheme in @("https", "http")) {
        $uri = "${scheme}://$HostName"
        try {
            $req = [System.Net.HttpWebRequest]::Create($uri)
            $req.Method = "GET"
            $req.Timeout = 8000
            $req.AllowAutoRedirect = $true
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            return $code
        }
        catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if ($resp -ne $null) {
                $code = [int]$resp.StatusCode
                $resp.Close()
                return $code
            }
        }
        catch { }
    }
    return $null
}

function Test-SiteConnectivity {
    param([string]$Url = "")
    while ($true) {
        Clear-Host
        Write-Banner -Title "Test Connection"
        Write-Line "[0] Back" -Color Yellow
        Write-Host ""

        if ($Url -eq "") {
            $Url = Read-Host "Enter URL (e.g. google.com) or 0 to go back"
        }
        if ($Url -eq "0") { return }

        $hostName = $Url -replace "^https?://" -replace "/.*$"
        if ($hostName -eq "") {
            Write-Line "Invalid URL." -Color Red
            Pause
            return
        }

        Write-Rule -Color DarkGray
        Write-Line "Target : $hostName" -Color Gray

        try {
            $resolved = Resolve-DnsName -Name $hostName -ErrorAction Stop
            $ips = ($resolved |
                Where-Object { $_.Type -eq "A" -or $_.Type -eq "AAAA" }).IPAddress
            Write-Line "DNS    : $($ips -join ', ')" -Color Gray
        }
        catch {
            Write-Line "DNS    : FAILED to resolve (DNS not working)" -Color Red
            Write-Rule -Color DarkGray
            Pause
            return
        }

        $code = Get-HttpStatusCode -HostName $hostName
        Write-Rule -Color DarkGray
        if ($code -eq $null) {
            Write-Line "Result : UNREACHABLE - could not connect" -Color Red
        }
        elseif ($code -ge 200 -and $code -lt 400) {
            Write-Line "Result : OK - reachable (HTTP $code)" -Color Green
        }
        elseif ($code -eq 403 -or $code -eq 401) {
            Write-Line "Result : BLOCKED (HTTP $code - likely filtered)" -Color Red
        }
        elseif ($code -ge 400 -and $code -lt 500) {
            Write-Line "Result : Client error (HTTP $code)" -Color Yellow
        }
        else {
            Write-Line "Result : Server error (HTTP $code)" -Color Yellow
        }
        Write-Rule -Color DarkGray

        $reachable = ($code -ne $null -and $code -ge 200 -and $code -lt 400)
        if (-not $reachable) {
            $scan = Read-Host "`nScan all DNS servers to find one that can reach '$hostName'? (y/n)"
            if ($scan -match '^[yY]') {
                Find-BestDNSForSite -Url $hostName
            }
        }

        Pause
        return
    }
}

function Find-BestDNSForSite {
    param([string]$Url)

    Clear-Host
    Write-Banner -Title "DNS Scan For Site"
    $hostName = $Url -replace "^https?://" -replace "/.*$"
    $dnsList = Read-DNSList

    if ($dnsList.Count -eq 0) {
        Write-Line "DNS list is empty." -Color Red
        Pause
        return
    }

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    if ($adapters.Count -eq 0) {
        Write-Line "No active network adapters found." -Color Red
        Pause
        return
    }

    $saved = @{}
    foreach ($a in $adapters) {
        $cfg = Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
        $saved[$a.InterfaceIndex] = $cfg.ServerAddresses
    }

    Write-Host ""
    Write-Line "Testing $($dnsList.Count) DNS servers against '$hostName'." -Color Gray
    Write-Line "Your current DNS will be restored automatically at the end." -Color Gray
    Write-Rule -Color DarkGray

    $results = @()
    for ($i = 0; $i -lt $dnsList.Count; $i++) {
        $entry = $dnsList[$i]
        Write-Line ("[{0}/{1}] Applying {2} ..." -f ($i + 1), $dnsList.Count, $entry.Name) -Color Gray

        try {
            foreach ($a in $adapters) {
                Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $entry.DNS
            }
            ipconfig /flushdns | Out-Null
            Restart-Service -Name "Dnscache" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1

            $code = Get-HttpStatusCode -HostName $hostName
            if ($code -eq $null) { $label = "UNREACHABLE" }
            elseif ($code -ge 200 -and $code -lt 400) { $label = "OK ($code)" }
            elseif ($code -eq 403 -or $code -eq 401) { $label = "BLOCKED ($code)" }
            else { $label = "ERR ($code)" }

            $color = if ($code -ne $null -and $code -ge 200 -and $code -lt 400) { "Green" }
                     elseif ($code -eq $null) { "Red" }
                     else { "Yellow" }
            Write-Line ("   -> {0}" -f $label) -Color $color
            $results += [PSCustomObject]@{ Name = $entry.Name; DNS = ($entry.DNS -join ','); Result = $label }
        }
        catch {
            Write-Line ("   -> FAILED to apply: {0}" -f $_) -Color Red
        }
    }

    Write-Rule -Color DarkGray
    Write-Line "Restoring your original DNS settings..." -Color Gray
    foreach ($a in $adapters) {
        $prev = $saved[$a.InterfaceIndex]
        if ($prev -and $prev.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $prev
        }
        else {
            Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ResetServerAddresses
        }
    }
    ipconfig /flushdns | Out-Null
    Restart-Service -Name "Dnscache" -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Banner -Title "Scan Results"
    Write-Host ""
    Write-Host ("  {0,-16} {1,-26} {2}" -f "DNS Name", "Servers", "Result") -ForegroundColor DarkGray
    Write-Rule -Color DarkGray
    foreach ($r in $results) {
        $color = if ($r.Result -like "OK*") { "Green" }
                 elseif ($r.Result -like "UNREACHABLE*") { "Red" }
                 else { "Yellow" }
        Write-Host ("  {0,-16} {1,-26} {2}" -f $r.Name, $r.DNS, $r.Result) -ForegroundColor $color
    }
    Write-Host ""
    Write-Line "Your original DNS has been restored." -Color Green
    Pause
}

function Show-DnsSpeedTest {
    Clear-Host
    Write-Banner -Title "DNS Speed Test"
    Write-Host ""

    $dnsList = Read-DNSList
    if ($dnsList.Count -eq 0) {
        Write-Line "DNS list is empty." -Color Yellow
        Pause
        return
    }

    Write-Line "Measuring latency (querying google.com via each DNS)..." -Color Gray
    Write-Rule -Color DarkGray

    $results = @()
    foreach ($entry in $dnsList) {
        $server = if ($entry.DNS.Count -ge 1) { $entry.DNS[0] } else { $null }
        $ms = $null
        if ($server) {
            try {
                $m = Measure-Command { Resolve-DnsName -Server $server -Name "google.com" -ErrorAction Stop }
                $ms = [math]::Round($m.TotalMilliseconds)
            }
            catch { $ms = $null }
        }
        $results += [PSCustomObject]@{ Name = $entry.Name; DNS = $entry.DNS; Latency = $ms }
        $latStr = if ($ms -ne $null) { "$ms ms" } else { "timeout" }
        $color = if ($ms -ne $null) { "Green" } else { "Red" }
        Write-Line ("{0,-16} {1,-20} {2}" -f $entry.Name, ($entry.DNS -join ','), $latStr) -Color $color
    }
    Write-Rule -Color DarkGray

    $fastest = $results | Where-Object { $_.Latency -ne $null } | Sort-Object Latency | Select-Object -First 1
    if ($fastest) {
        Write-Line ("Fastest: {0}  ({1} ms)" -f $fastest.Name, $fastest.Latency) -Color Green
        $apply = Read-Host "`nApply the fastest DNS now? (y/n)"
        if ($apply -match '^[yY]') {
            Write-Host ""
            Write-Line "Setting DNS: $($fastest.Name)" -Color Cyan
            try {
                Apply-DnsServers -Servers $fastest.DNS -Label $fastest.Name
            }
            catch {
                Write-Line "Failed to set DNS." -Color Red
                Write-Line "Error: $_" -Color Red
            }
        }
    }
    else {
        Write-Line "All DNS servers timed out or failed to respond." -Color Red
    }
    Write-Host ""
    Pause
}

function Get-LatestRelease {
    $url = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    try {
        $r = Invoke-RestMethod -Uri $url -TimeoutSec 10 -ErrorAction Stop
        return [PSCustomObject]@{ Tag = "$($r.tag_name)"; HtmlUrl = "$($r.html_url)"; Name = "$($r.name)" }
    }
    catch { return $null }
}

function Test-NewVersionAvailable {
    param([string]$Current, [string]$Latest)
    try {
        $c = [version]($Current.TrimStart('v'))
        $l = [version]($Latest.TrimStart('v'))
        return ($l -gt $c)
    }
    catch { return $false }
}

function Show-UpdateCheck {
    Clear-Host
    Write-Banner -Title "Check for Updates v$ScriptVersion"
    Write-Host ""
    Write-Line "Current version : v$ScriptVersion" -Color Gray
    Write-Line "Checking GitHub for latest release..." -Color Gray
    $latest = Get-LatestRelease
    if ($null -eq $latest) {
        Write-Line "Could not check for updates (offline or no releases yet)." -Color Yellow
        Write-Host ""
        Pause
        return
    }
    Write-Line "Latest version  : $($latest.Tag)" -Color Gray
    Write-Rule -Color DarkGray
    if (Test-NewVersionAvailable -Current $ScriptVersion -Latest $latest.Tag) {
        Write-Line "New version available: $($latest.Tag) (you have v$ScriptVersion)" -Color Green
        $open = Read-Host "`nOpen release page in browser? (y/n)"
        if ($open -match '^[yY]') { Start-Process $latest.HtmlUrl }
    }
    else {
        Write-Line "You are up to date." -Color Green
    }
    Write-Host ""
    Pause
}

# ────────────────────────────────────────────────────────────
#  Main menu
# ────────────────────────────────────────────────────────────
function Show-MainMenu {
    Clear-Host
    Write-Banner -Title "DNS Manager v$ScriptVersion"
    Write-Host ""
    Show-CompactStatus
    Write-Host ""
    Write-Section -Label "Menu"
    $menu = @(
        @("1", "Select & Set DNS"),
        @("2", "Manage DNS List"),
        @("3", "Flush DNS"),
        @("4", "Reset DNS to Default"),
        @("5", "Test Connection"),
        @("6", "DNS Speed Test"),
        @("7", "Check for Updates"),
        @("0", "Exit")
    )
    foreach ($m in $menu) {
        $num = $m[0]; $label = $m[1]
        $numColor = if ($num -eq "0") { "Yellow" } else { "Cyan" }
        Write-Host "  [" -NoNewline -ForegroundColor DarkGray
        Write-Host $num -NoNewline -ForegroundColor $numColor
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host $label -ForegroundColor Gray
    }
}

:mainMenu do {
    Show-MainMenu
    $userInput = Read-Host "`nChoose an option"

    switch ($userInput) {
        "1" { Select-And-SetDNS }
        "2" { Manage-DnsList }
        "3" { Flush-DNS }
        "4" { Reset-DNSToDefault }
        "5" { Test-SiteConnectivity }
        "6" { Show-DnsSpeedTest }
        "7" { Show-UpdateCheck }
        "0" { break mainMenu }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
            Pause
        }
    }
} while ($true)

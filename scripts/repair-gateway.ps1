param(
    [Parameter(Mandatory = $true)][string]$GatewayCli,
    [Parameter(Mandatory = $true)][string]$DataDirectory,
    [string]$Python = "python.exe",
    [string]$ProxyRepairScript = "",
    [string]$LogPath = (Join-Path $PSScriptRoot "network-repair.log"),
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$mutex = New-Object Threading.Mutex($false, "Local\CodexMobileNetworkRepair")
$locked = $false

function Write-Log([string]$Message) {
    if ($Quiet -and $Message -notmatch "ERROR|restarted=True|addresses=") { return }
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
        Move-Item -LiteralPath $LogPath -Destination ($LogPath + ".previous") -Force
    }
    Add-Content -LiteralPath $LogPath -Value ((Get-Date -Format o) + " " + $Message) -Encoding UTF8
}

function Invoke-Gateway([string]$Action, [string]$Payload = "{}") {
    $output = $Payload | & $GatewayCli $Action --data-dir $DataDirectory
    $answer = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    if (-not $answer.ok) { throw ("Gateway " + $Action + ": " + $answer.error) }
    return $answer.result
}

try {
    try { $locked = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 0 }

    if ($ProxyRepairScript -and (Test-Path -LiteralPath $ProxyRepairScript)) {
        $messages = & $Python $ProxyRepairScript
        foreach ($message in $messages) { if ($message) { Write-Log $message } }
    }

    $physicalIfIndexes = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object Status -eq Up | Select-Object -ExpandProperty ifIndex)
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.AddressState -eq "Preferred" -and $_.IPAddress -notlike "169.254.*" -and
            (($_.InterfaceAlias -eq "Tailscale" -and $_.IPAddress -like "100.*") -or
             $_.InterfaceIndex -in $physicalIfIndexes)
        } | Select-Object -ExpandProperty IPAddress -Unique | Sort-Object)

    if (-not $addresses.Count) {
        Write-Log "No active physical or Tailscale address; will retry on next run"
        exit 0
    }

    $snapshot = Invoke-Gateway "snapshot"
    $before = @($snapshot.preferences.lanAddresses | Sort-Object)
    $changed = (($before -join ";") -cne ($addresses -join ";"))
    if ($changed -and $snapshot.runtime.running) {
        Start-Sleep -Seconds 3
        $confirmed = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.AddressState -eq "Preferred" -and $_.IPAddress -notlike "169.254.*" -and
                (($_.InterfaceAlias -eq "Tailscale" -and $_.IPAddress -like "100.*") -or
                 $_.InterfaceIndex -in $physicalIfIndexes)
            } | Select-Object -ExpandProperty IPAddress -Unique | Sort-Object)
        if (($addresses -join ";") -cne ($confirmed -join ";")) {
            Write-Log "Network still changing; deferring gateway rebind"
            exit 0
        }
        $null = Invoke-Gateway "stop"
    }

    if ($changed -or -not $snapshot.runtime.running) {
        $snapshot.preferences.lanAddresses = $addresses
        $snapshot.preferences.autoStart = $true
        $snapshot.preferences.tunnel = $false
        $codex = Get-CimInstance Win32_Process -Filter "name='codex.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -like "*OpenAI\Codex\bin\*" } | Select-Object -First 1
        if ($codex) { $snapshot.preferences.codexBin = $codex.ExecutablePath }
        $body = @{
            preferences = $snapshot.preferences
            auth = $snapshot.auth
            origins = $snapshot.origins
        } | ConvertTo-Json -Depth 30 -Compress
        $null = Invoke-Gateway "save" $body
    }

    $started = Invoke-Gateway "start"
    if ($changed -or $started.started) {
        Write-Log ("Gateway ready; addresses=" + ($addresses -join ",") +
            "; restarted=" + $started.started)
    }
}
catch {
    Write-Log ("ERROR " + $_.Exception.Message)
    exit 1
}
finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

# Codex Mobile Remote Access for Windows

Windows network-repair helpers for the upstream Codex Mobile Bridge. They keep a private phone connection available while Windows changes between Wi-Fi, campus networks, hotspots, and a Clash proxy.

The gateway and mobile app are not included. Install them from the upstream MIT-licensed project: https://github.com/try2love/codex-mobile-bridge

## Features

- Re-discovers active physical IPv4 addresses and the current Tailscale IPv4 address.
- Updates gateway LAN bindings after a network change and restarts its listener safely.
- Bypasses the Windows system proxy for Tailscale CGNAT addresses and *.ts.net.
- Adds Tailscale route exclusions to a running Clash-compatible controller, without changing proxy mode or credentials.
- Runs once per minute after the current Windows user signs in.

Use the Tailscale Serve HTTPS DNS name as the phone address. Serve remains private to the tailnet. Do not enable Tailscale Funnel or router port forwarding for this control gateway.

## Requirements

- Windows 10/11 and PowerShell 5.1 or newer.
- Codex Mobile Bridge installed, configured with a strong password, and its CLI available.
- Tailscale installed and signed into the same tailnet on the PC and phone, with MagicDNS enabled.
- Python 3 with PyYAML for the optional Clash repair helper.
- Administrator access may be needed to install software or adjust firewall rules. The scheduled repair task runs as the current Windows user.

## Install

1. Install Codex Mobile Bridge using its upstream documentation. Keep its data directory in a stable local folder.
2. Sign in to Tailscale on the computer and phone. In the Tailscale admin console, enable HTTPS certificates and Serve for the tailnet.
3. Start HTTPS forwarding to the local gateway once:

       tailscale serve --bg http://127.0.0.1:8787
       tailscale serve status

4. Copy this repository to a durable folder, for example C:\Tools\codex-mobile-remote.
5. Register a per-minute repair task in PowerShell as the Windows user who owns the gateway data. Set the variables to your install paths:

       $repo = 'C:\Tools\codex-mobile-remote'
       $gateway = "$env:LOCALAPPDATA\Programs\Codex Mobile Bridge\resources\gateway\codex-mobile-gateway.exe"
       $data = 'D:\CodexRemote\gateway'
       $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $repo + '\scripts\repair-gateway.ps1" -GatewayCli "' + $gateway + '" -DataDirectory "' + $data + '" -Python "python.exe" -ProxyRepairScript "' + $repo + '\scripts\repair-clash-tailscale.py" -Quiet')
       $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
       $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
       Register-ScheduledTask -TaskName 'CodexMobileNetworkRepair' -Action $action -Trigger $trigger -Settings $settings -Description 'Repair private Codex gateway routes after network changes' -Force
       Start-ScheduledTask -TaskName 'CodexMobileNetworkRepair'

6. In the phone app, enter the HTTPS name shown by tailscale serve status, without port 8787. Keep Tailscale connected on the phone.

If Clash is not installed, omit the ProxyRepairScript argument. For another Clash Verge config location, pass --clash-config PATH when running the Python helper manually.

## Verify and troubleshoot

       tailscale status
       tailscale serve status
       Get-ScheduledTaskInfo -TaskName CodexMobileNetworkRepair
       Get-Content .\scripts\network-repair.log -Tail 30

The gateway restarts only when its bound-address set changes or it is stopped. A brief disconnect during a network transition is expected. A campus captive portal still needs manual authentication. Windows logon tasks run after the configured user signs in.

## Security

- Use a unique gateway password; do not use credentials from example configurations.
- Keep Tailscale Serve tailnet-only. Avoid Funnel and router port forwarding.
- Serve terminates TLS inside Tailscale and forwards to loopback. Gateway password login remains enabled.
- The helper changes only proxy bypass and TUN route exclusions. It does not print Clash controller secrets.
- Review the upstream release notes before installing updates.

## License

MIT. The upstream Codex Mobile Bridge remains governed by its own license and is not redistributed here.

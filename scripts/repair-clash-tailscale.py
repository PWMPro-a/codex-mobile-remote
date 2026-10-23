"""Keep Tailscale private routes outside the Windows system proxy and Clash TUN."""
import argparse
import json
import os
import urllib.request
from pathlib import Path

import winreg
import yaml


CIDRS = ("100.64.0.0/10", "fd7a:115c:a1e0::/48")
BYPASS = tuple(f"100.{second}.*" for second in range(64, 128)) + ("*.ts.net",)
REGISTRY_KEY = r"SoftwareMicrosoftWindowsCurrentVersionInternet Settings"


def repair_windows_proxy():
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REGISTRY_KEY, 0,
                        winreg.KEY_READ | winreg.KEY_SET_VALUE) as registry:
        try:
            current = winreg.QueryValueEx(registry, "ProxyOverride")[0]
        except FileNotFoundError:
            current = ""
        entries = [item for item in current.split(";") if item]
        updated = entries + [item for item in BYPASS if item not in entries]
        if updated == entries:
            return False
        winreg.SetValueEx(registry, "ProxyOverride", 0, winreg.REG_SZ,
                          ";".join(updated))

    import ctypes
    ctypes.windll.wininet.InternetSetOptionW(0, 39, 0, 0)
    ctypes.windll.wininet.InternetSetOptionW(0, 37, 0, 0)
    return True


def repair_clash(config_path):
    if not config_path.is_file():
        return False
    try:
        config = yaml.safe_load(config_path.read_text(encoding="utf-8-sig")) or {}
        controller = config.get("external-controller", "")
        if not controller.startswith("127.0.0.1:"):
            return False
        url = f"http://{controller}/configs"
        headers = {"Authorization": "Bearer " + str(config.get("secret", "")),
                   "Content-Type": "application/json"}
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(urllib.request.Request(url, headers=headers), timeout=3) as response:
            live = json.load(response)
        current = live.get("tun", {}).get("route-exclude-address") or []
        updated = current + [cidr for cidr in CIDRS if cidr not in current]
        if updated == current:
            return False
        request = urllib.request.Request(
            url, data=json.dumps({"tun": {"route-exclude-address": updated}}).encode(),
            headers=headers, method="PATCH")
        with opener.open(request, timeout=5) as response:
            if response.status != 204:
                raise RuntimeError(f"Clash returned HTTP {response.status}")
        return True
    except (OSError, ValueError, KeyError, TypeError):
        # Clash can be stopped; the Windows Tailscale route remains usable.
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clash-config", type=Path,
                        default=Path(os.environ.get("APPDATA", str(Path.home() / "AppData/Roaming")))
                        / "io.github.clash-verge-rev.clash-verge-rev" / "config.yaml")
    args = parser.parse_args()
    if repair_windows_proxy():
        print("Restored Windows system-proxy bypass for Tailscale")
    if repair_clash(args.clash_config):
        print("Restored Clash TUN exclusions for Tailscale")


if __name__ == "__main__":
    main()

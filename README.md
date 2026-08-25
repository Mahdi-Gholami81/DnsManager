# 🌐 DNS Manager

A simple, menu-driven PowerShell tool to manage DNS settings on Windows — apply saved DNS servers, manage your server list, flush the cache, test connectivity, and benchmark DNS latency, all from a clean terminal interface.

---

<p align="center">
  <img src="./assets/demo.jpg" alt="DNS Manager Banner" width="100%">
</p>

## ✨ Features

- **Select & Set DNS** – Apply any saved DNS server to all active network adapters. The entry that is currently active is marked with a green `●` in the `STATUS` column.
- **Manage DNS List** – A single unified screen to **Add**, **Edit**, and **Delete** DNS entries (no separate screens):
  - `A` – add a new DNS (name + primary, optional secondary)
  - `E #` – edit entry `#` (rename or change servers, keeping the previous values as defaults)
  - `D #` – delete entry `#`
  - `0` – back
- **Flush DNS** – Clear the DNS resolver cache.
- **Reset DNS to Default** – Revert all adapters to automatic DNS (DHCP).
- **Test Connection** – Resolve a domain and perform a real HTTP request to check reachability, filtering, or errors. If a site is unreachable, you can scan every DNS server to find one that can reach it.
- **DNS Speed Test** – Measure the response latency of each DNS server (via `Resolve-DnsName`) and optionally apply the fastest one with a single confirmation.
- **Live network status** – Shows adapter type, IPv4, gateway, and current DNS 1 / DNS 2 for every active adapter.
- After any DNS change the network is refreshed automatically (DNS cache flush, `Dnscache` restart, IP release/renew) so the new settings actually take effect.

> ⚠️ **Administrator privileges required.** The script no longer auto-elevates (that opened a separate window). Run it from a terminal that is already launched **as Administrator**.

---

## 🚀 Usage

1. Open PowerShell **as Administrator** (right-click the terminal → *Run as Administrator*).
2. Run the script:
   ```powershell
   .\DnsManager.ps1
   ```
3. Choose an option from the menu.

---

## 📁 DNS List Format (`servers.ini`)

The list lives next to the script in `servers.ini`. Each line is `Name=IP1,IP2`:

```ini
Google=8.8.8.8,8.8.4.4
Cloudflare=1.1.1.1,1.0.0.1
Shecan=178.22.122.100,185.51.200.2
```

- You may list **one or two** (or more) comma-separated servers.
- A trailing comma is allowed and simply yields a single DNS entry.
- A single-server entry (e.g. `bertina=193.186.32.32`) is handled correctly.
- Entries can be edited manually **or** through the app (Option **2 → Manage DNS List**).

---

## ⚙️ Requirements

- Windows 10 / 11
- PowerShell 5.1+
- Administrator privileges

---

## 📜 License

MIT License — see [LICENSE](./LICENSE).

<p align="center">Made with ❤️ using PowerShell</p>

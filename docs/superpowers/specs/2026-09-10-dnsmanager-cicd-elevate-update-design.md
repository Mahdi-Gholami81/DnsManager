# DNS Manager v1.1.0 Design — CI/CD, Auto-Elevate, Update Check

Date: 2026-09-10
Repo: https://github.com/mahdi-gholami81/dns-manager
Base: main @ 0471806 (v1.0.0 tag at d746dbc + demo screenshot commit)

## 1. Goal
1. CI/CD: automatic validation on push + automatic GitHub Release ZIP on version tags.
2. Auto-elevate: non-admin launch re-launches itself as admin via UAC dialog; if user denies, show message and exit.
3. Check-for-updates: new menu option comparing local version against latest GitHub Release.
4. Ship v1.1.0: commit, tag `v1.1.0`, push (tag push triggers deploy).

## 2. Architecture
Single-script PowerShell app (`DnsManager.ps1` + `servers.ini`). No build step.
Additions:
- `version.txt` — single source of truth, content e.g. `1.1.0`.
- `$ScriptVersion` in `DnsManager.ps1` (read from `version.txt` at runtime with fallback constant).
- `.github/workflows/ci.yml` — runs on `push`/`pull_request` to `main`.
- `.github/workflows/release.yml` — runs on tag `v*.*.*`.

## 3. Components
### 3.1 ci.yml
- `windows-latest`, PowerShell 5.1 compatible steps:
  - Checkout.
  - Validate PowerShell syntax: parse `DnsManager.ps1` via `[Parser]`.
  - `PSScriptAnalyzer` with `PSGallery` install, severity Error/Warning.
  - Verify `version.txt` exists and matches semver.
  - Verify `version.txt` matches `$ScriptVersion` in ps1.

### 3.2 release.yml
- Trigger: `push.tags: v*.*.*`.
- Steps: checkout, read version from tag (`${GITHUB_REF_NAME#v}`) and `version.txt` (warn on mismatch, prefer tag), create staging dir, copy `DnsManager.ps1`, `servers.ini`, `README.md`, `LICENSE`, `version.txt`, `Compress-Archive` to `DnsManager-vX.Y.Z.zip`, `gh release create` (or `softprops/action-gh-release`) with generated notes + upload ZIP.
- Permissions: `contents: write`.

### 3.3 Auto-elevate (top of DnsManager.ps1)
Replace current exit-with-message block (lines 1-11) with:
```powershell
if (-not admin) {
  try { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit }
  catch { Write-Host "Administrator privileges are required... UAC was declined."; Pause; exit }
}
```
Preserves working dir via `$PSCommandPath` / `$PSScriptRoot`. Handles `powershell` vs `pwsh` (use same host if detectable).

### 3.4 Update check
- `version.txt` = `1.1.0`.
- `$ScriptVersion = "1.1.0"` + runtime override: if `version.txt` exists next to script, use its content.
- `Get-LatestRelease` → `Invoke-RestMethod https://api.github.com/repos/mahdi-gholami81/dns-manager/releases/latest` (short timeout, silent on offline).
- `Test-NewVersionAvailable` compares `[version]` objects (strip leading `v`).
- Menu `7. Check for Updates`; banner shows `DNS Manager vX.Y.Z`.
- On newer version: show current vs latest, prompt `Open release page? (y/n)` → `Start-Process <html_url>`.

## 4. Data flow
- Dev → push to `main` → ci.yml validates.
- Dev → `git tag v1.1.0` + `git push origin v1.1.0` → release.yml builds ZIP → GitHub Release `v1.1.0`.
- User runs `DnsManager.ps1` → elevate if needed → menu → option 7 → GET latest release → compare → prompt open browser.

## 5. Error handling
- Offline / API rate-limit: "Could not check for updates (offline?)" — never crash.
- No releases yet: treat as up-to-date.
- UAC denied: friendly message + exit code, no loop (elevated child exits early from check).
- Tag/version mismatch: CI fails fast; release prefers tag but logs warning.

## 6. Testing
- Local: run `powershell -NoProfile -Command` parser check on edited ps1.
- CI: PSScriptAnalyzer must pass.
- Manual: (a) run non-admin → UAC appears → admin window opens; (b) deny UAC → message; (c) menu 7 with mocked/network-off; (d) create test tag in fork or dry-run zip locally.
- Verify ZIP contains 5 files and version matches.

## 7. Out of scope (YAGNI)
- PowerShell Gallery publishing.
- Auto-download/install updater (only open browser).
- Auto-check on every startup (manual option only + version display; auto-check deferred to avoid startup delay).

## 8. Release plan v1.1.0
1. Implement files above.
2. Set `version.txt` = `1.1.0`.
3. Update README (admin note, features, usage with version check, releases badge).
4. Commit, `git tag v1.1.0`, `git push origin main --tags`.

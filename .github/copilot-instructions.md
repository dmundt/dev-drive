# GitHub Copilot Instructions: Generate a DLG‑Safe Dev Drive Automation Script

## Goal
Generate a **single PowerShell script** that fully automates Dev Drive setup on Windows 11 for a **DLG (Device Local Group) admin user with NO network access**.

The script must be **idempotent**, **offline‑safe**, and must NOT call any network resources.

---

## Script Requirements

### 1. Parameters
The script must define:

```powershell
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z]$')]
    [string]$DriveLetter,

    [switch]$CreateVHDX,

    [string]$VHDXPath = "C:\DevDrive.vhdx",

    [int]$SizeGB = 100
)
```

### 2. Admin Check
Abort with a clear message if not running as Administrator.

---

## 3. Dev Drive Creation (Offline‑Safe)

### If `-CreateVHDX` is used:
- Create a dynamic VHDX of `$SizeGB` at `$VHDXPath`.
- Mount it.
- Initialize disk as GPT if RAW.
- Create a single partition and assign `$DriveLetter`.

### If NOT using VHDX:
- Validate that `$DriveLetter` exists as a volume.

### Formatting:
- If not already ReFS Dev Drive:
  ```powershell
  Format-Volume -DriveLetter $DriveLetter -FileSystem ReFS -DevDrive -Force
  ```

---

## 4. Trust the Dev Drive
Use:

```powershell
fsutil devdrv query <DriveLetter>:
fsutil devdrv trust <DriveLetter>:
```

Idempotent: do nothing if already trusted.

---

## 5. Apply Dev Drive Filters
Ensure the following filters exist (skip silently if unsupported):

- Microsoft Defender  
- Windows Search  
- File History  

Use:

```powershell
fsutil devdrv queryfilters <DriveLetter>:
fsutil devdrv addfilter <DriveLetter>: "<FilterName>"
```

---

## 6. Permissions & Labeling
- Ensure current user has **FullControl** on the Dev Drive root.
- Apply ACL using `Get-Acl` / `Set-Acl`.
- Set Explorer label via registry:

```
HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\<DriveLetter>\DefaultLabel = "DevDrive"
```

---

## 7. Local Developer Cache Relocation (Offline Only)

Create:

```
<DriveLetter>:\DevCache\
    WinGet\
    npm\
    pip\
    cargo\
    go-build\
    gomod\
    gopath\
```

Set persistent **user‑level** environment variables:

- `WINGET_CACHE`
- `NPM_CACHE`
- `NPM_CONFIG_CACHE`
- `PIP_CACHE`
- `CARGO_HOME`
- `GOCACHE`
- `GOMODCACHE`
- `GOPATH`

### Migrate existing caches using robocopy:
- WinGet → `%LOCALAPPDATA%\Microsoft\WinGet\Cache`
- npm → `%APPDATA%\npm-cache` or `%LOCALAPPDATA%\npm-cache`
- pip → `%LOCALAPPDATA%\pip\Cache`
- cargo → `%USERPROFILE%\.cargo`
- Go build → `%LOCALAPPDATA%\go-build`
- Go mod → `%USERPROFILE%\go\pkg\mod`
- GOPATH → `%USERPROFILE%\go`

Use:

```
robocopy <source> <dest> /E /MOVE /NFL /NDL /NJH /NJS /NC /NS
```

Ignore robocopy exit codes.

---

## 8. No Network Usage
The script must NOT:
- Call winget install
- Call git or GitHub
- Call Invoke-WebRequest / curl
- Access any HTTP/HTTPS endpoints

Everything must work **offline**.

---

## 9. Summary Output
At the end, print:

- Dev Drive letter
- Trust state
- Cache paths
- Any skipped steps

---

## 10. Style Requirements
- Use helper functions: `Write-Info`, `Write-Warn`, `Write-Err`
- Clean, readable, production‑grade PowerShell
- No external dependencies
- Safe to re-run multiple times

---

## Task for Copilot
**Generate the complete PowerShell script implementing ALL requirements above in one file.**

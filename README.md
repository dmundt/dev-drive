# Dev Drive Setup Automation Script

<!-- markdownlint-disable MD013 MD040 MD060 -->

A production-grade PowerShell script that fully automates Dev Drive creation, configuration, and developer cache relocation on Windows 11. Designed for **DLG (Device Local Group) admin users with offline capability**.

## Features

✓ **Fully Automated** - One-command Dev Drive setup  
✓ **Offline-Safe** - No network requirements; works in isolated environments  
✓ **Idempotent** - Safe to run multiple times without conflicts  
✓ **VHDX Support** - Creates, mounts, and initializes virtual drives  
✓ **Dev Drive Optimization** - ReFS formatting, filtering, and trust configuration  
✓ **Cache Relocation** - Automatically migrates developer caches (npm, pip, cargo, go, etc.)  
✓ **Permissions Management** - Sets ACLs and Explorer labels  
✓ **Comprehensive Reporting** - Detailed summary of all operations  

## Requirements

- **Windows 11** (Dev Drive support)
- **Administrator privileges** (script auto-requests elevation via UAC if needed)
- **PowerShell 5.0+** (standard on Windows 11)
- **Virtual Disk Service (VDS)** enabled (for VHDX operations)

## Quick Hyper-V Setup (For -CreateVHDX)

If `New-VHD` is missing, install prerequisites in this order (offline-safe):

1. Confirm supported edition (Windows 11 Pro/Enterprise/Education):

  ```powershell
  Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion
  ```

2. Enable virtualization in BIOS/UEFI (Intel VT-x or AMD-V/SVM).

3. Enable Hyper-V feature and reboot:

  ```powershell
  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
  Restart-Computer
  ```

4. Verify cmdlets:

  ```powershell
  Import-Module Hyper-V
  Get-Command New-VHD
  ```

See [Troubleshooting](#troubleshooting) for detailed checks and recovery steps.

## Parameters

```powershell
-DriveLetter <char>
    The drive letter (A-Z) to assign to the Dev Drive. Mandatory.

-CreateVHDX
    Switch parameter. If specified, creates a dynamic VHDX file.
    Default: $false (uses existing volume)

-VHDXPath <string>
    Path where the VHDX file will be created.
  Default: C:\VHDX\DevDrive.vhdx

-SizeGB <int>
    Size of the VHDX in gigabytes.
    Default: 100

-NoPauseOnError
  Optional switch. When omitted, script waits for Enter before closing if errors occurred.
  Use this switch for unattended/non-interactive runs.
```

## Usage Examples

### 1. Create a New 150GB Dev Drive with VHDX

```powershell
.\Setup-DevDrive.ps1 -DriveLetter D -CreateVHDX -SizeGB 150
```

This will:

- Create a 150GB dynamic VHDX at `C:\VHDX\DevDrive.vhdx`
- Mount it as drive `D:`
- Initialize the disk as GPT
- Format as ReFS Dev Drive
- Configure all filters and caches
- Set environment variables for developers

### 2. Configure an Existing Volume as Dev Drive

```powershell
.\Setup-DevDrive.ps1 -DriveLetter E
```

Assumes drive `E:` already exists and will:

- Format (if needed)
- Trust the Dev Drive
- Apply filters
- Configure caches

### 3. Create VHDX with Custom Path

```powershell
.\Setup-DevDrive.ps1 -DriveLetter Z -CreateVHDX -VHDXPath "D:\Storage\MyDevDrive.vhdx" -SizeGB 250
```

### 4. Idempotent Re-configuration

Run the same command multiple times safely:

```powershell
.\Setup-DevDrive.ps1 -DriveLetter D -CreateVHDX -SizeGB 150
# Safe to run again without issues
.\Setup-DevDrive.ps1 -DriveLetter D -CreateVHDX -SizeGB 150
```

## What Gets Configured

### Drive Formatting

- **File System**: ReFS (Resilient File System)
- **Dev Drive Flag**: Enabled for performance optimization

### Trust & Filters

- **Trusted**: Dev Drive marked as trusted location
- **Filters Applied**:
  - Microsoft Defender
  - Windows Search
  - File History

### Permissions

- **User Access**: FullControl ACL for the current user
- **Label**: "DevDrive" appears in Windows Explorer

### Developer Caches

Automatic cache directory creation at `<Drive>:\Cache\`:

```
D:\Cache\
├── WinGet\          → WINGET_CACHE
├── npm\             → NPM_CACHE, NPM_CONFIG_CACHE
├── pip\             → PIP_CACHE
├── cargo\           → CARGO_HOME
├── go\
│   ├── build\       → GOCACHE
│   ├── mod\         → GOMODCACHE
│   └── path\        → GOPATH
└── docker\          → DOCKER_CONFIG
```

### Environment Variables (User-Level)

| Variable | Path |
|----------|------|
| `WINGET_CACHE` | `<Drive>:\Cache\WinGet` |
| `NPM_CACHE` | `<Drive>:\Cache\npm` |
| `NPM_CONFIG_CACHE` | `<Drive>:\Cache\npm` |
| `PIP_CACHE` | `<Drive>:\Cache\pip` |
| `CARGO_HOME` | `<Drive>:\Cache\cargo` |
| `GOCACHE` | `<Drive>:\Cache\go\build` |
| `GOMODCACHE` | `<Drive>:\Cache\go\mod` |
| `GOPATH` | `<Drive>:\Cache\go\path` |
| `DOCKER_CONFIG` | `<Drive>:\Cache\docker` |

### Cache Migration

Existing caches are automatically migrated if sources exist:

| Tool | Source | Destination |
|------|--------|-------------|
| WinGet | `%LOCALAPPDATA%\Microsoft\WinGet\Cache` | `<Drive>:\Cache\WinGet` |
| npm | `%APPDATA%\npm-cache` | `<Drive>:\Cache\npm` |
| pip | `%LOCALAPPDATA%\pip\Cache` | `<Drive>:\Cache\pip` |
| Cargo | `%USERPROFILE%\.cargo` | `<Drive>:\Cache\cargo` |
| Go Build | `%LOCALAPPDATA%\go-build` | `<Drive>:\Cache\go\build` |
| Go Modules | `%USERPROFILE%\go\pkg\mod` | `<Drive>:\Cache\go\mod` |
| GOPATH | `%USERPROFILE%\go` | `<Drive>:\Cache\go\path` |
| Docker Config | `%USERPROFILE%\.docker` | `<Drive>:\Cache\docker` |

## Running the Script

### Direct PowerShell (Recommended)

```powershell
powershell -ExecutionPolicy Bypass -File ".\Setup-DevDrive.ps1" -DriveLetter D -CreateVHDX -SizeGB 150
```

The script will automatically request elevation via UAC if not already running as admin.

### Persistent Execution Policy (Optional)

If you want to run scripts regularly without needing `-ExecutionPolicy Bypass`:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Then run scripts normally:

```powershell
.\Setup-DevDrive.ps1 -DriveLetter D -CreateVHDX -SizeGB 150
```

**Note**: This only affects the current user; administrators can set system-wide policy with `-Scope LocalMachine`.

### Scheduled Task (Optional)

Create a scheduled task with "Run with highest privileges" checked:

1. Open Task Scheduler
2. Create Basic Task
3. Set trigger (e.g., At logon)
4. Action: Start a program
   - Program: `powershell.exe`
   - Arguments: `-ExecutionPolicy Bypass -NoProfile -File "C:\path\to\Setup-DevDrive.ps1" -DriveLetter D -CreateVHDX -SizeGB 150`
5. Check "Run with highest privileges"

## Output Example

```
[SUCCESS] Running as Administrator
[INFO] Dev Drive Setup Script Started at 2026-05-18 14:30:22
[INFO] Target Drive: D:
[INFO] VHDX creation requested...
[INFO] Creating dynamic VHDX: C:\VHDX\DevDrive.vhdx (150 GB)
[SUCCESS] VHDX created: C:\VHDX\DevDrive.vhdx
[SUCCESS] Drive D: is valid
[INFO] Formatting D: as ReFS Dev Drive...
[SUCCESS] Volume formatted as ReFS Dev Drive
[INFO] Checking Dev Drive trust status for D:...
[SUCCESS] Dev Drive trusted successfully
[INFO] Applying Dev Drive filters for D:...
[SUCCESS] Filter 'Microsoft Defender' added successfully
[SUCCESS] Filter 'Windows Search' added successfully
[SUCCESS] Filter 'File History' added successfully
[INFO] Creating cache directory structure at D:\Cache...
[SUCCESS] Created cache directory: D:\Cache\WinGet
[SUCCESS] Created cache directory: D:\Cache\npm
... (more cache dirs) ...
[SUCCESS] Environment variable set: WINGET_CACHE=D:\Cache\WinGet
... (more env vars) ...

======================================================================
DEV DRIVE SETUP SUMMARY
======================================================================

Drive Configuration:
  Drive Letter: D:
  VHDX Created: C:\VHDX\DevDrive.vhdx
  VHDX Size: 150 GB
  Formatted as Dev Drive: True
  Dev Drive Trusted: True

Filters Applied:
  - Microsoft Defender
  - Windows Search
  - File History

Cache Directories Created:
  ✓ D:\Cache\WinGet
  ✓ D:\Cache\npm
  ✓ D:\Cache\pip
  ✓ D:\Cache\cargo
  ✓ D:\Cache\go\build
  ✓ D:\Cache\go\mod
  ✓ D:\Cache\go\path
  ✓ D:\Cache\docker

Environment Variables Set (User-Level):
  WINGET_CACHE = D:\Cache\WinGet
  NPM_CACHE = D:\Cache\npm
  NPM_CONFIG_CACHE = D:\Cache\npm
  PIP_CACHE = D:\Cache\pip
  CARGO_HOME = D:\Cache\cargo
  GOCACHE = D:\Cache\go\build
  GOMODCACHE = D:\Cache\go\mod
  GOPATH = D:\Cache\go\path
  DOCKER_CONFIG = D:\Cache\docker

Setup completed at 2026-05-18 14:30:45
======================================================================
```

## Troubleshooting

### Execution Policy Error

```
cannot be loaded because running scripts is disabled on this system
```

**Solution**: This means your PowerShell execution policy blocks script execution. Use one of these:

1. **Run PowerShell with policy bypass for this command only**:

   ```powershell
   powershell -ExecutionPolicy Bypass -File ".\Setup-DevDrive.ps1" -DriveLetter D -CreateVHDX -SizeGB 150
   ```

2. **Change execution policy permanently (user)**:

   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

### Window Closes Too Fast on Errors

By default, the script now pauses on error and shows:

```text
Press Enter to close this window
```

If you are running unattended automation, disable that pause:

```powershell
.\Setup-DevDrive.ps1 -DriveLetter D -CreateVHDX -NoPauseOnError
```

When the script self-elevates via UAC, the elevated window now also waits for Enter at the end of the run so you can review console output before it closes.

### Hyper-V Cmdlets Missing (New-VHD Not Recognized)

```
[ERROR] Failed to create VHDX: The term 'New-VHD' is not recognized...
```

**Why this happens**:

- Hyper-V PowerShell components are not enabled.
- You are on a Windows edition that does not include Hyper-V cmdlets.
- You are running in PowerShell 7 without Windows PowerShell compatibility import.
- Virtualization support is disabled in BIOS/UEFI.

**Check current state (run as Administrator)**:

```powershell
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All,Microsoft-Hyper-V,Microsoft-Hyper-V-Management-PowerShell
Get-Module -ListAvailable Hyper-V
```

**How to install Hyper-V prerequisites (offline-safe)**:

1. Confirm your Windows edition supports Hyper-V (Windows 11 Pro/Enterprise/Education).
2. Enable CPU virtualization in BIOS/UEFI (Intel VT-x or AMD-V/SVM).
3. Run the following in an elevated PowerShell session:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
Restart-Computer
```

4. After reboot, verify the cmdlets are available:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All,Microsoft-Hyper-V-Management-PowerShell
Import-Module Hyper-V
Get-Command New-VHD
```

5. If Hyper-V is still not starting, ensure the hypervisor launches at boot, then reboot:

```powershell
bcdedit /set hypervisorlaunchtype auto
Restart-Computer
```

If you are using PowerShell 7, run setup with Windows PowerShell 5.1:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Setup-DevDrive.ps1" -DriveLetter D -CreateVHDX
```

If your Windows edition does not support Hyper-V cmdlets, use an existing volume (omit `-CreateVHDX`) or upgrade to a supported edition.

### Drive Does Not Exist

```
[ERROR] Drive D: does not exist. Create the partition first or use -CreateVHDX.
```

**Solution**: Either specify `-CreateVHDX` or manually create the drive partition first

### VHDX Already Exists

```
[WARN] VHDX file already exists at C:\VHDX\DevDrive.vhdx. Skipping creation.
```

**Solution**: The existing VHDX will be used. To start fresh, delete it first or use a different `-VHDXPath`

### Filters Not Applied

```
[INFO] Filter 'Microsoft Defender' skipped (unsupported or already present)
```

**Solution**: This is normal if filters are already applied or system doesn't support them. Script continues gracefully.

## Idempotency

The script is fully idempotent and can be run multiple times safely:

- **VHDX**: Only created if it doesn't exist
- **Formatting**: Checked before formatting; skips if already ReFS
- **Trust**: Verified before trusting; skips if already trusted
- **Filters**: Checked before adding; skips if already present
- **Caches**: Directories created only if missing
- **Environment Variables**: Always set (overwrite safe)

## Offline Operation

This script is designed for **completely offline environments**:

- ✓ No `winget install` calls
- ✓ No Git or GitHub access
- ✓ No web downloads (`Invoke-WebRequest`, curl)
- ✓ No HTTP/HTTPS network requests
- ✓ Uses only built-in PowerShell and Windows utilities

## Notes

- **User-Level Environment Variables**: Set so they persist after script execution and apply to new shell instances
- **Robocopy Migration**: Ignores robocopy exit codes (0-16 are considered success)
- **Registry Label**: Applied via `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons`
- **Disk Initialization**: Evaluated whenever `-CreateVHDX` is used; initializes only when disk is RAW

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

## Support

For issues or enhancements, contact your system administrator.

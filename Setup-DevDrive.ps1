<#
.SYNOPSIS
    Automates Dev Drive setup on Windows 11 for DLG admin users with offline capability.

.DESCRIPTION
    This script fully automates Dev Drive creation, configuration, and developer cache
    relocation. It is idempotent, offline-safe, and requires no network access.

.PARAMETER DriveLetter
    The drive letter to assign to the Dev Drive (single letter A-Z). Mandatory.

.PARAMETER CreateVHDX
    If specified, creates and mounts a dynamic VHDX before setting up the Dev Drive.

.PARAMETER VHDXPath
    Path where the VHDX file will be created. Default: C:\VHDX\DevDrive.vhdx

.PARAMETER SizeGB
    Size of the VHDX in GB. Default: 100

.EXAMPLE
    .\Setup-DevDrive.ps1 -DriveLetter D -CreateVHDX -SizeGB 150
    Creates a 150GB VHDX at C:\VHDX\DevDrive.vhdx, mounts it as D:, and configures it as Dev Drive.

.EXAMPLE
    .\Setup-DevDrive.ps1 -DriveLetter E
    Configures an existing E: volume as a Dev Drive.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Z]$')]
    [string]$DriveLetter,

    [switch]$CreateVHDX,

    [string]$VHDXPath = "C:\VHDX\DevDrive.vhdx",

    [int]$SizeGB = 100,

    [switch]$NoPauseOnError,

    [string]$ElevationLogPath = ""
)

# ============================================================================
# Helper Functions for Output
# ============================================================================

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Wait-OnErrorClose {
    if (-not $NoPauseOnError -and [Environment]::UserInteractive) {
        try {
            Read-Host "Press Enter to close this window"
            $script:DidPauseForClose = $true
        }
        catch {
            # Ignore pause failures in non-interactive hosts.
        }
    }
}

function Wait-OnElevatedCompletionClose {
    if ($script:IsElevatedChildRun -and -not $script:DidPauseForClose -and [Environment]::UserInteractive) {
        try {
            Read-Host "Press Enter to close this elevated window"
            $script:DidPauseForClose = $true
        }
        catch {
            # Ignore pause failures in non-interactive hosts.
        }
    }
}

# ============================================================================
# Admin Check
# ============================================================================

function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    param(
        [string]$DriveLetter,
        [bool]$CreateVHDX,
        [string]$VHDXPath,
        [int]$SizeGB,
        [bool]$NoPauseOnError
    )
    
    Write-Warn "This script requires Administrator privileges."
    Write-Info "Requesting elevation..."
    
    # Launch elevated script directly and capture elevated output via transcript.
    $scriptPath = $PSCommandPath
    $elevatedLogPath = Join-Path -Path $env:TEMP -ChildPath ("Setup-DevDrive-elevated-{0}.log" -f [Guid]::NewGuid().ToString("N"))

    $elevatedArgs = @(
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", $scriptPath,
        "-DriveLetter", $DriveLetter,
        "-VHDXPath", $VHDXPath,
        "-SizeGB", $SizeGB,
        "-ElevationLogPath", $elevatedLogPath
    )

    if ($CreateVHDX) {
        $elevatedArgs += "-CreateVHDX"
    }

    if ($NoPauseOnError) {
        $elevatedArgs += "-NoPauseOnError"
    }
    
    try {
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $elevatedArgs -Verb RunAs -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Err "Elevated process exited with code $($process.ExitCode)."
            if (Test-Path $elevatedLogPath) {
                Write-Info "Elevated session log: $elevatedLogPath"
                Write-Host "`n----- Elevated Session Output -----" -ForegroundColor Yellow
                Get-Content -Path $elevatedLogPath -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
                Write-Host "----- End Elevated Session Output -----`n" -ForegroundColor Yellow
            }
            Wait-OnErrorClose
        }
        exit $process.ExitCode
    }
    catch {
        Write-Err "Failed to elevate privileges: $_"
        Wait-OnErrorClose
        exit 1
    }
}

# Request elevation if not already running as admin
if (-not (Test-IsAdmin)) {
    Request-Elevation -DriveLetter $DriveLetter -CreateVHDX $CreateVHDX -VHDXPath $VHDXPath -SizeGB $SizeGB -NoPauseOnError $NoPauseOnError
}

$script:TranscriptStarted = $false
$script:DidPauseForClose = $false
$script:IsElevatedChildRun = -not [string]::IsNullOrWhiteSpace($ElevationLogPath)
if (-not [string]::IsNullOrWhiteSpace($ElevationLogPath)) {
    try {
        Start-Transcript -Path $ElevationLogPath -Force | Out-Null
        $script:TranscriptStarted = $true
    }
    catch {
        Write-Warn "Could not start transcript at ${ElevationLogPath}: $($_.Exception.Message)"
    }
}

trap {
    Write-Err "Unhandled error: $($_.Exception.Message)"
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    Wait-OnErrorClose
    Wait-OnElevatedCompletionClose
    exit 1
}

Write-Success "Running as Administrator"

# ============================================================================
# Initialization
# ============================================================================

$drive = "$($DriveLetter):"
$devCacheRoot = "$drive\Cache"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$script:Summary = @{
    DriveLetter = $DriveLetter
    VHDXCreated = $false
    VHDXPath = $null
    FormattedAsDevDrive = $false
    IsTrusted = $false
    FiltersApplied = @()
    CacheDirectoriesCreated = @()
    CachesMigrated = @()
    EnvironmentVariablesSet = @()
    Errors = @()
}

Write-Info "Dev Drive Setup Script Started at $timestamp"
Write-Info "Target Drive: $drive"

# ============================================================================
# VHDX Creation (if requested)
# ============================================================================

if ($CreateVHDX) {
    Write-Info "VHDX creation requested..."
    $script:Summary.VHDXPath = $VHDXPath
    
    # Check if VHDX already exists
    if (Test-Path $VHDXPath) {
        Write-Warn "VHDX file already exists at $VHDXPath. Skipping creation."
    }
    else {
        try {
            Write-Info "Creating dynamic VHDX: $VHDXPath ($SizeGB GB)"
            
            # Create parent directory if needed
            $vhdxDir = Split-Path -Parent $VHDXPath
            if (-not (Test-Path $vhdxDir)) {
                New-Item -ItemType Directory -Path $vhdxDir -Force | Out-Null
            }
            
            # Create dynamic VHDX
            $vhdxSize = [int64]$SizeGB * 1GB
            New-VHD -Path $VHDXPath -SizeBytes $vhdxSize -Dynamic | Out-Null
            
            Write-Success "VHDX created: $VHDXPath"
            $script:Summary.VHDXCreated = $true
            $script:Summary.VHDXPath = $VHDXPath
        }
        catch {
            Write-Err "Failed to create VHDX: $_"
            $script:Summary.Errors += "VHDX creation failed: $_"
        }
    }
    
    # Mount VHDX if not already mounted
    Write-Info "Mounting VHDX..."
    $diskImage = Get-DiskImage -ImagePath $VHDXPath -ErrorAction SilentlyContinue
    if ($null -eq $diskImage -or $diskImage.Attached -eq $false) {
        try {
            Mount-DiskImage -ImagePath $VHDXPath -NoDriveLetter -ErrorAction Stop | Out-Null
            Write-Success "VHDX mounted successfully"
        }
        catch {
            Write-Warn "VHDX mount encountered an issue: $_"
        }
    }
    else {
        Write-Info "VHDX already mounted"
    }

    # Ensure disk is initialized and the requested drive letter is assigned.
    try {
        Write-Info "Ensuring VHDX disk is initialized and assigned to $drive..."

        $diskImage = Get-DiskImage -ImagePath $VHDXPath -ErrorAction Stop
        $disk = $diskImage | Get-Disk -ErrorAction Stop

        if ($disk.PartitionStyle -eq "RAW") {
            Write-Info "Disk is RAW. Initializing as GPT..."
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
            $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
            Write-Success "Disk initialized as GPT"
        }

        $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.Type -ne "Reserved" }

        if ($null -eq $partitions -or $partitions.Count -eq 0) {
            Write-Info "No usable partition found. Creating one..."
            New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter:$false -ErrorAction Stop | Out-Null
            $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
                Where-Object { $_.Type -ne "Reserved" }
            Write-Success "Partition created"
        }

        $targetPartition = $partitions |
            Sort-Object -Property Size -Descending |
            Select-Object -First 1

        if ($null -eq $targetPartition) {
            throw "No usable partition found on VHDX disk $($disk.Number)."
        }

        # Ensure the partition is formatted before assigning drive letter to avoid Shell format popups.
        Write-Info "Ensuring VHDX partition is formatted as ReFS Dev Drive..."
        try {
            $partitionVolume = Get-Volume -Partition $targetPartition -ErrorAction SilentlyContinue

            if ($null -eq $partitionVolume -or $partitionVolume.FileSystem -ne "ReFS") {
                Write-Info "Formatting VHDX partition as ReFS Dev Drive..."
                Format-Volume -Partition $targetPartition -FileSystem ReFS -DevDrive -Force -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Success "VHDX partition formatted as ReFS Dev Drive"
                $script:Summary.FormattedAsDevDrive = $true
            }
            else {
                Write-Info "VHDX partition is already formatted as ReFS"
            }
        }
        catch {
            Write-Warn "Initial format attempt encountered an issue: $_"
        }

        # Refresh partition metadata after potential format and assign requested drive letter.
        $targetPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $targetPartition.PartitionNumber -ErrorAction Stop
        $desiredPartition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue

        if ($null -ne $desiredPartition -and ($desiredPartition.DiskNumber -eq $disk.Number -and $desiredPartition.PartitionNumber -eq $targetPartition.PartitionNumber)) {
            Write-Info "Drive letter $drive is already assigned"
        }
        else {
            try {
                Set-Partition -DiskNumber $disk.Number -PartitionNumber $targetPartition.PartitionNumber -NewDriveLetter $DriveLetter -ErrorAction Stop
                Write-Success "Assigned drive letter $drive"
            }
            catch {
                $existingLetter = if ($targetPartition.DriveLetter) { "$($targetPartition.DriveLetter):" } else { "(none)" }
                Write-Warn "Failed to assign drive letter $drive (current letter: $existingLetter)."
                $script:Summary.Errors += "VHDX partition could not be assigned to $drive (current letter: $existingLetter)"
            }
        }
    }
    catch {
        Write-Err "Failed to initialize/assign VHDX disk: $_"
        $script:Summary.Errors += "VHDX disk setup failed: $_"
    }
}

# ============================================================================
# Validate Drive Exists (with retry for partition assignment latency)
# ============================================================================

Write-Info "Validating drive $drive exists..."

# Retry loop to wait for drive to appear (Windows needs time to register it)
$maxRetries = 20
$retryCount = 0
$driveExists = $false

while ($retryCount -lt $maxRetries) {
    if (Test-Path $drive) {
        $driveExists = $true
        break
    }
    
    $retryCount++
    if ($retryCount -lt $maxRetries) {
        Start-Sleep -Milliseconds 500
    }
}

if (-not $driveExists) {
    Write-Err "Drive $drive does not exist. Create the partition first or use -CreateVHDX."
    $script:Summary.Errors += "Drive does not exist: $drive"
    
    # Output summary and exit
    Write-Info "`n===== SETUP SUMMARY ====="
    Write-Host "Drive Letter: $($script:Summary.DriveLetter)"
    Write-Host "VHDX Created: $($script:Summary.VHDXCreated)"
    Write-Host "Errors: $($script:Summary.Errors.Count)"
    $script:Summary.Errors | ForEach-Object { Write-Err "  - $_" }
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    Wait-OnErrorClose
    exit 1
}

Write-Success "Drive $drive is valid"

# ============================================================================
# Dev Drive Formatting
# ============================================================================

Write-Info "Checking Dev Drive formatting on $drive..."

try {
    $volume = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    
    if ($null -eq $volume) {
        Write-Warn "Volume $drive not found. Skipping format step."
    }
    else {
        if ($volume.FileSystem -eq "ReFS" -and $volume.DriveType -eq "Fixed") {
            Write-Info "Volume is already formatted as ReFS"
            $script:Summary.FormattedAsDevDrive = $true
        }
        else {
            Write-Info "Formatting $drive as ReFS Dev Drive..."
            Format-Volume -DriveLetter $DriveLetter -FileSystem ReFS -DevDrive -Force -Confirm:$false
            Write-Success "Volume formatted as ReFS Dev Drive"
            $script:Summary.FormattedAsDevDrive = $true
        }
    }
}
catch {
    Write-Err "Failed to format volume: $_"
    $script:Summary.Errors += "Format failed: $_"
}

# ============================================================================
# Dev Drive Trust
# ============================================================================

Write-Info "Checking Dev Drive trust status for $drive..."

try {
    # Query current trust status
    & fsutil devdrv query "$($drive)" 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Dev Drive is already trusted"
        $script:Summary.IsTrusted = $true
    }
    else {
        Write-Info "Trusting Dev Drive $drive..."
        & fsutil devdrv trust "$($drive)" | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Dev Drive trusted successfully"
            $script:Summary.IsTrusted = $true
        }
        else {
            Write-Warn "Failed to trust Dev Drive (may already be trusted)"
        }
    }
}
catch {
    Write-Warn "Trust operation encountered an issue: $_"
}

# ============================================================================
# Dev Drive Filters
# ============================================================================

Write-Info "Applying Dev Drive filters for $drive..."

$filters = @(
    "Microsoft Defender",
    "Windows Search",
    "File History"
)

$queryFilters = @()
try {
    $queryFilters = & fsutil devdrv queryfilters "$($drive)" 2>&1
}
catch {
    $queryFilters = @()
}

foreach ($filter in $filters) {
    try {
        if ($queryFilters -like "*$filter*") {
            Write-Info "Filter '$filter' already applied"
        }
        else {
            Write-Info "Adding filter: $filter"
            & fsutil devdrv addfilter "$($drive)" "$filter" 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Filter '$filter' added successfully"
                $script:Summary.FiltersApplied += $filter
                $queryFilters += $filter
            }
            else {
                Write-Info "Filter '$filter' skipped (unsupported or already present)"
            }
        }
    }
    catch {
        Write-Info "Filter '$filter' skipped (unsupported in this environment)"
    }
}

# ============================================================================
# Permissions and Labels
# ============================================================================

Write-Info "Setting permissions and labels for $drive..."

try {
    # Get current user
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $userName = $currentUser.Translate([System.Security.Principal.NTAccount]).Value
    
    Write-Info "Setting FullControl permission for $userName on $drive..."
    
    # Get current ACL
    $acl = Get-Acl -Path $drive

    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    $accessType = [System.Security.AccessControl.AccessControlType]::Allow
    
    # Create new access rule with FullControl
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $userName,
        $rights,
        $inheritFlags,
        $propagationFlags,
        $accessType
    )
    
    # Add the rule
    $acl.SetAccessRule($rule)
    Set-Acl -Path $drive -AclObject $acl
    
    Write-Success "Permissions set for $userName on $drive"
}
catch {
    Write-Warn "Permission setting encountered an issue: $_"
}

# Set registry label
try {
    Write-Info "Setting Explorer label for $DriveLetter..."
    
    $regParent = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$DriveLetter"
    
    if (-not (Test-Path $regParent)) {
        New-Item -Path $regParent -Force | Out-Null
    }
    
    New-ItemProperty -Path $regParent -Name "DefaultLabel" -Value "DevDrive" -PropertyType String -Force | Out-Null
    
    Write-Success "Registry label set to 'DevDrive'"
}
catch {
    Write-Warn "Registry label setting encountered an issue: $_"
}

# ============================================================================
# Cache Directory Creation
# ============================================================================

Write-Info "Creating cache directory structure at $devCacheRoot..."

$cacheSubDirs = @(
    "WinGet",
    "npm",
    "pip",
    "cargo",
    "go",
    "go\build",
    "go\mod",
    "go\path",
    "docker"
)

foreach ($subDir in $cacheSubDirs) {
    $cacheDir = Join-Path -Path $devCacheRoot -ChildPath $subDir
    
    try {
        if (-not (Test-Path $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
            Write-Success "Created cache directory: $cacheDir"
            $script:Summary.CacheDirectoriesCreated += $cacheDir
        }
        else {
            Write-Info "Cache directory already exists: $cacheDir"
        }
    }
    catch {
        Write-Warn "Failed to create cache directory $cacheDir : $_"
    }
}

# ============================================================================
# Cache Migration and Environment Variables
# ============================================================================

Write-Info "Migrating existing caches and setting environment variables..."

# Define cache mappings: @{EnvVar, Source, Destination}
$cacheMappings = @(
    @{
        EnvVar = "WINGET_CACHE"
        Source = "$env:LOCALAPPDATA\Microsoft\WinGet\Cache"
        Dest = "$devCacheRoot\WinGet"
    },
    @{
        EnvVar = "NPM_CACHE"
        Source = "$env:APPDATA\npm-cache"
        Dest = "$devCacheRoot\npm"
    },
    @{
        EnvVar = "NPM_CONFIG_CACHE"
        Source = "$env:APPDATA\npm-cache"
        Dest = "$devCacheRoot\npm"
    },
    @{
        EnvVar = "PIP_CACHE"
        Source = "$env:LOCALAPPDATA\pip\Cache"
        Dest = "$devCacheRoot\pip"
    },
    @{
        EnvVar = "CARGO_HOME"
        Source = "$env:USERPROFILE\.cargo"
        Dest = "$devCacheRoot\cargo"
    },
    @{
        EnvVar = "GOCACHE"
        Source = "$env:LOCALAPPDATA\go-build"
        Dest = "$devCacheRoot\go\build"
    },
    @{
        EnvVar = "GOMODCACHE"
        Source = "$env:USERPROFILE\go\pkg\mod"
        Dest = "$devCacheRoot\go\mod"
    },
    @{
        EnvVar = "GOPATH"
        Source = "$env:USERPROFILE\go"
        Dest = "$devCacheRoot\go\path"
    },
    @{
        EnvVar = "DOCKER_CONFIG"
        Source = "$env:USERPROFILE\.docker"
        Dest = "$devCacheRoot\docker"
    }
)

foreach ($mapping in $cacheMappings) {
    $envVar = $mapping.EnvVar
    $source = $mapping.Source
    $dest = $mapping.Dest
    
    try {
        # Set environment variable (user-level)
        [Environment]::SetEnvironmentVariable($envVar, $dest, [EnvironmentVariableTarget]::User)
        Write-Success "Environment variable set: $envVar=$dest"
        $script:Summary.EnvironmentVariablesSet += "$envVar"
        
        # Migrate cache if source exists and destination is empty
        if ((Test-Path $source) -and (Get-ChildItem -Path $dest -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
            Write-Info "Migrating cache from $source to $dest..."
            
            try {
                # Use robocopy for reliable migration
                $robocopyArgs = @($source, $dest, "/E", "/MOVE", "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS")
                & robocopy @robocopyArgs | Out-Null
                
                # robocopy returns non-zero on success; we ignore exit code
                Write-Success "Cache migrated: $envVar"
                $script:Summary.CachesMigrated += $envVar
            }
            catch {
                Write-Warn "Robocopy migration for $envVar encountered an issue: $_"
            }
        }
        elseif ((Test-Path $source)) {
            Write-Info "Source cache exists at $source but destination not empty; skipping migration"
        }
        else {
            Write-Info "No existing cache found at $source for $envVar"
        }
    }
    catch {
        Write-Warn "Environment variable or cache migration for $envVar encountered an issue: $_"
        $script:Summary.Errors += "Cache setup for $envVar failed: $_"
    }
}

# ============================================================================
# Summary Report
# ============================================================================

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "DEV DRIVE SETUP SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

Write-Host ""
Write-Host "Drive Configuration:" -ForegroundColor Green
Write-Host "  Drive Letter: $($script:Summary.DriveLetter):"
if ($script:Summary.VHDXCreated) {
    Write-Host "  VHDX Created: $($script:Summary.VHDXPath)"
    Write-Host "  VHDX Size: $SizeGB GB"
}
Write-Host "  Formatted as Dev Drive: $($script:Summary.FormattedAsDevDrive)"
Write-Host "  Dev Drive Trusted: $($script:Summary.IsTrusted)"

Write-Host ""
Write-Host "Filters Applied:" -ForegroundColor Green
if ($script:Summary.FiltersApplied.Count -gt 0) {
    foreach ($filter in $script:Summary.FiltersApplied) {
        Write-Host "  - $filter"
    }
}
else {
    Write-Host "  (None applied or already present)"
}

Write-Host ""
Write-Host "Cache Directories Created:" -ForegroundColor Green
foreach ($cacheDir in $cacheSubDirs) {
    $fullPath = Join-Path -Path $devCacheRoot -ChildPath $cacheDir
    if (Test-Path $fullPath) {
        Write-Host "  [OK] $fullPath"
    }
}

Write-Host ""
Write-Host "Caches Migrated:" -ForegroundColor Green
if ($script:Summary.CachesMigrated.Count -gt 0) {
    foreach ($cacheName in $script:Summary.CachesMigrated) {
        Write-Host "  [OK] $cacheName"
    }
}
else {
    Write-Host "  (None migrated or sources were empty)"
}

Write-Host ""
Write-Host "Environment Variables Set (User-Level):" -ForegroundColor Green
foreach ($envName in $script:Summary.EnvironmentVariablesSet) {
    $value = [Environment]::GetEnvironmentVariable($envName, [EnvironmentVariableTarget]::User)
    Write-Host "  $envName = $value"
}

if ($script:Summary.Errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Errors/Warnings:" -ForegroundColor Yellow
    foreach ($err in $script:Summary.Errors) {
        Write-Host "  [WARN] $err"
    }
}

Write-Host ""
Write-Host "Setup completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host ""

# Exit with appropriate code
if ($script:Summary.Errors.Count -gt 0) {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    Wait-OnErrorClose
    Wait-OnElevatedCompletionClose
    exit 1
}
else {
    if ($script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    Wait-OnElevatedCompletionClose
    exit 0
}

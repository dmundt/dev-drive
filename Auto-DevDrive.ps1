<#
.SYNOPSIS
Creates or updates a logon scheduled task that mounts the Dev Drive VHDX.

.DESCRIPTION
Generates a mount script for the configured VHDX path and registers a scheduled
task to run it at user logon with optional delay.
#>

param(
  [string]$VHDXPath = '%USERPROFILE%\VMs\DevDrive.vhdx',
  [string]$ScriptPath = '%USERPROFILE%\Scripts\PowerShell\Mount-DevDrive.ps1',
  [string]$TaskName = "Mount Dev Drive",
  [ValidateRange(0, 3600)]
  [int]$LogonDelaySeconds = 5,
  [string]$OriginalUserProfile = "",
  [string]$OriginalUserId = ""
)

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-UserProfilePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$BaseUserProfile
  )

  $profileRoot = if ([string]::IsNullOrWhiteSpace($BaseUserProfile)) { $env:USERPROFILE } else { $BaseUserProfile }
  return ($Path -replace [regex]::Escape('$env:USERPROFILE'), $profileRoot -replace '\\', '\\') -replace '(?i)%USERPROFILE%', $profileRoot
}

function Resolve-EscapedPathForHereString {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  # Double quotes must be escaped inside the generated double-quoted here-string content.
  return $Path.Replace('"', '`"')
}

if (-not (Test-IsAdministrator)) {
  $scriptPath = $PSCommandPath
  $invokerProfile = $env:USERPROFILE
  $invokerIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

  $elevationArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $scriptPath,
    '-VHDXPath', $VHDXPath,
    '-ScriptPath', $ScriptPath,
    '-TaskName', $TaskName,
    '-LogonDelaySeconds', $LogonDelaySeconds,
    '-OriginalUserProfile', $invokerProfile,
    '-OriginalUserId', $invokerIdentity
  )

  try {
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $elevationArgs -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
  }
  catch {
    Write-Error "Elevation failed: $($_.Exception.Message)"
    exit 1
  }
}

$effectiveUserProfile = if ([string]::IsNullOrWhiteSpace($OriginalUserProfile)) { $env:USERPROFILE } else { $OriginalUserProfile }

$VHDXPath = Resolve-UserProfilePath -Path $VHDXPath -BaseUserProfile $effectiveUserProfile
$ScriptPath = Resolve-UserProfilePath -Path $ScriptPath -BaseUserProfile $effectiveUserProfile

# ==== Ensure script directory exists ====
$scriptDir = Split-Path $ScriptPath
if (!(Test-Path $scriptDir)) {
  New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
}

# ==== Create mount script ====
$scriptContent = @"
try {
  `$vhd = Get-VHD -Path "$(Resolve-EscapedPathForHereString -Path $VHDXPath)" -ErrorAction Stop
    if (-not `$vhd.Attached) {
    Mount-VHD -Path "$(Resolve-EscapedPathForHereString -Path $VHDXPath)"
    }
} catch {
  Mount-VHD -Path "$(Resolve-EscapedPathForHereString -Path $VHDXPath)"
}
"@

Set-Content -Path $ScriptPath -Value $scriptContent -Encoding UTF8 -Force

Write-Host "Mount script created at $ScriptPath"

# ==== Create scheduled task ====

$encodedTaskCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptContent))

# Action
$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -EncodedCommand $encodedTaskCommand"

# Trigger (at startup, delayed)
$trigger = New-ScheduledTaskTrigger -AtStartup
if ($LogonDelaySeconds -gt 0) {
  $trigger.Delay = "PT${LogonDelaySeconds}S"
}

# Principal (run as SYSTEM service account, highest privilege)
$principal = New-ScheduledTaskPrincipal `
  -UserId 'SYSTEM' `
  -LogonType ServiceAccount `
  -RunLevel Highest

# Settings
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable

# Register task
Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Principal $principal `
  -Settings $settings -Force

Write-Host "Scheduled task '$TaskName' created"
Write-Host "Dev Drive will now auto-mount at logon"
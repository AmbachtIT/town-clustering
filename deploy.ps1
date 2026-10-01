<#
.SYNOPSIS
Copies the mod into the Transport Fever 3 user mods or staging area folder.

.DESCRIPTION
Run after every edit, then restart the game - mods are read at startup.

Two destinations, and the difference matters:

  mods\          what the game loads for normal play. The default.
  staging_area\  what the in-game mod manager can publish from. Publishing
                 (Modhub.ModPublishHelper) only ever looks here, so a mod that
                 lives in mods\ cannot be uploaded.

.PARAMETER Staging
Deploy to staging_area\ instead of mods\, ready to publish.

.PARAMETER Validate
Deploy to staging_area\ and then run the game's own mod validator over it. The
validator grades PC and console separately and is what publishing runs anyway,
so it is the cheapest way to find packaging problems before uploading.

.EXAMPLE
.\deploy.ps1
.EXAMPLE
.\deploy.ps1 -Validate
#>
[CmdletBinding()]
param(
	[switch]$Staging,
	[switch]$Validate
)

$ErrorActionPreference = "Stop"

$ModId = "town_clustering_1"
$Source = Join-Path $PSScriptRoot "mod\$ModId"

if (-not (Test-Path $Source)) {
	throw "Mod source not found: $Source"
}

# Validating means publishing, which only reads the staging area.
if ($Validate) { $Staging = $true }
$Folder = if ($Staging) { "staging_area" } else { "mods" }

# Transport Fever 3 is Steam appid 3493540. The per-account userdata folder
# holds both destinations side by side.
$Local = Get-ChildItem "C:\Program Files (x86)\Steam\userdata\*\3493540\local" -Directory -ErrorAction SilentlyContinue |
	Select-Object -First 1

if (-not $Local) {
	throw "Could not find the TF3 userdata folder. Launch the game once, then retry."
}

$TargetRoot = Join-Path $Local.FullName $Folder
if (-not (Test-Path $TargetRoot)) {
	New-Item -ItemType Directory -Force $TargetRoot | Out-Null
}

$Target = Join-Path $TargetRoot $ModId
if (Test-Path $Target) { Remove-Item -Recurse -Force $Target -Confirm:$false }
Copy-Item -Recurse $Source $Target

Write-Host "Deployed to $Target"

$Log = Join-Path $Local.FullName "crash_dump\stdout.txt"
Write-Host "Log: $Log"
Write-Host "  the mod logs with the prefix [town-clustering]"

if ($Validate) {
	# The exe's CLI, from NOTES.md: --validate <source>,<modid> plus --and-cook.
	# Not yet exercised, so treat a non-zero exit as information rather than
	# proof the mod is broken - the in-game mod manager runs the same validator
	# and shows a readable report.
	$Exe = "C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 3\TransportFever3.exe"
	if (-not (Test-Path $Exe)) {
		Write-Warning "Game executable not found, skipping validation: $Exe"
		return
	}
	Write-Host "`nValidating..."
	& $Exe --validate "StagingArea,$ModId" --and-cook
	Write-Host "Validator exit code: $LASTEXITCODE"
	Write-Host "If that produced nothing useful, open the game's Mod Manager and"
	Write-Host "validate from the staging area entry instead - it reports per-file."
}

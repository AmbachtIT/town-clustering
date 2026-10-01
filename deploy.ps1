# Copies the mod into the Transport Fever 3 user mods folder.
# Run after every edit, then restart the game (mods are read at startup).
$ErrorActionPreference = "Stop"

$ModId  = "town_redistribution_1"
$Source = Join-Path $PSScriptRoot "mod\$ModId"

# Transport Fever 3 is Steam appid 3493540. User mods live under the Steam
# userdata folder for the logged-in account; staging_area is the alternative
# location the game's --validate CLI calls "StagingArea".
$UserData = Get-ChildItem "C:\Program Files (x86)\Steam\userdata\*\3493540\local\mods" -Directory -ErrorAction SilentlyContinue |
	Select-Object -First 1

if (-not $UserData) {
	throw "Could not find the TF3 user mods folder. Launch the game once, then retry."
}

$Target = Join-Path $UserData.FullName $ModId

if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
Copy-Item -Recurse $Source $Target

Write-Host "Deployed to $Target"

$Log = Join-Path (Split-Path $UserData.FullName) "crash_dump\stdout.txt"
Write-Host "Log: $Log"

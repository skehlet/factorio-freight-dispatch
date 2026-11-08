<#
Freight Dispatch dev helper (Windows PowerShell 5.1).

  .\tools\fd.ps1 test [-Ticks 7200]          Fresh map + tools\fd-test harness, prints FDTEST lines
  .\tools\fd.ps1 save [-Save <name.zip>] [-Ticks 1200]
                                             Copy of the user's save (newest by default) + tools\fd-debug,
                                             prints FDDUMP / FDSNAP lines
  .\tools\fd.ps1 install                     Copy freight-dispatch\ into the user's Factorio mods folder

Runs Factorio headless with its OWN write-data folder, so it works even while the user has
the game open (sharing the normal data folder fails with "Couldn't create lock file").
Full log: $env:TEMP\fd-work\data\factorio-current.log
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet("test", "save", "install")][string]$Mode,
  [string]$Save,
  [int]$Ticks = 0
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$exe = "D:\SteamLibrary\steamapps\common\Factorio\bin\x64\factorio.exe"
$userData = "$env:APPDATA\Factorio"
$work = "$env:TEMP\fd-work"

if ($Mode -eq "install") {
  Copy-Item "$root\freight-dispatch\*" "$userData\mods\freight-dispatch" -Recurse -Force
  (Select-String -Path "$userData\mods\freight-dispatch\info.json" -Pattern '"version"').Line.Trim()
  "Installed. The user must restart Factorio to load it."
  return
}

New-Item -ItemType Directory -Force "$work\data" | Out-Null
$ini = "$work\config.ini"
"[path]`r`nread-data=__PATH__executable__/../../data`r`nwrite-data=$work\data`r`n" | Set-Content $ini -Encoding ascii
$mods = "$work\mods-$Mode"
if (Test-Path $mods) { Remove-Item $mods -Recurse -Force }
New-Item -ItemType Directory -Force $mods | Out-Null
Copy-Item "$root\freight-dispatch" "$mods\freight-dispatch" -Recurse

if ($Mode -eq "test") {
  if ($Ticks -eq 0) { $Ticks = 7200 }
  Copy-Item "$root\tools\fd-test" "$mods\fd-test" -Recurse
  '{"mods":[{"name":"base","enabled":true},{"name":"freight-dispatch","enabled":true},{"name":"fd-test","enabled":true}]}' |
    Set-Content "$mods\mod-list.json" -Encoding ascii
  & $exe --config $ini --mod-directory $mods --create "$work\test.zip" | Out-Null
  & $exe --config $ini --mod-directory $mods --benchmark "$work\test.zip" --benchmark-ticks $Ticks --benchmark-runs 1 | Out-Null
  $pattern = "FDTEST|Error|error"
} else {
  if ($Ticks -eq 0) { $Ticks = 1200 }
  Copy-Item "$root\tools\fd-debug" "$mods\fd-debug" -Recurse
  Copy-Item "$userData\mods\*.zip" $mods   # the user's other mods (flib, EditorExtensions)
  '{"mods":[{"name":"base","enabled":true},{"name":"flib","enabled":true},{"name":"EditorExtensions","enabled":true},{"name":"freight-dispatch","enabled":true},{"name":"fd-debug","enabled":true}]}' |
    Set-Content "$mods\mod-list.json" -Encoding ascii
  if (-not $Save) { $Save = (Get-ChildItem "$userData\saves" -Filter *.zip | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name }
  "Inspecting save: $Save"
  Copy-Item "$userData\saves\$Save" "$work\usersave.zip" -Force
  & $exe --config $ini --mod-directory $mods --benchmark "$work\usersave.zip" --benchmark-ticks $Ticks --benchmark-runs 1 | Out-Null
  $pattern = "FDDUMP|FDSNAP|Error|error"
}
Get-Content "$work\data\factorio-current.log" | Where-Object { $_ -match $pattern }

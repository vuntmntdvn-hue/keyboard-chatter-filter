<#
.SYNOPSIS
  Sets up KeyboardChatterFilter.exe on this machine: starts it now and at every login.

.DESCRIPTION
  Run through install.cmd (double-click), or directly:
    powershell -ExecutionPolicy Bypass -File install.ps1 [-ThresholdMs 40] [-Keys E,L]
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall

  Re-running it with different options replaces the settings and restarts the filter.
  The filter runs from this folder, so move the folder before installing, not after.
#>
param(
    [ValidateRange(5, 500)][int]$ThresholdMs = 40,
    [string[]]$Keys = @(),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$exe = Join-Path $dir 'KeyboardChatterFilter.exe'
$log = Join-Path $dir 'chatter.log'
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Keyboard Chatter Filter.lnk'

function Stop-Filter {
    $running = @(Get-Process KeyboardChatterFilter -ErrorAction SilentlyContinue)
    if ($running.Count) {
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 500
        Write-Host "Stopped the running filter."
    }
}

if ($Uninstall) {
    Stop-Filter
    if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "Removed the startup shortcut." }
    Write-Host "Uninstalled. This folder was left as is; delete it yourself if you no longer need it." -ForegroundColor Green
    return
}

if (-not (Test-Path $exe)) { throw "KeyboardChatterFilter.exe is missing from $dir" }

# Files copied from the internet are blocked until unblocked; harmless if they are not.
Get-ChildItem $dir -File | Unblock-File

$arguments = "-ThresholdMs $ThresholdMs"
$keyList = @($Keys | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($keyList.Count) { $arguments += " -Keys " + ($keyList -join ',') }

Stop-Filter

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnk)
$shortcut.TargetPath = $exe
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $dir
$shortcut.Description = 'Per-key keyboard chatter filter'
$shortcut.Save()
Write-Host "Startup shortcut created: $lnk"

Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $dir
Start-Sleep -Seconds 2

if (Get-Process KeyboardChatterFilter -ErrorAction SilentlyContinue) {
    Write-Host "Filter is running ($arguments). It will start automatically at every login." -ForegroundColor Green
    Write-Host "Log: $log"
} else {
    Write-Host "The filter did not stay running. Last log lines:" -ForegroundColor Red
    if (Test-Path $log) { Get-Content $log -Tail 5 } else { Write-Host "(no log written - antivirus may have blocked the exe)" }
}

# Windows' own Bounce keys would stack with this filter.
$flags = [int](Get-ItemProperty 'HKCU:\Control Panel\Accessibility\Keyboard Response' -ErrorAction SilentlyContinue).Flags
if ($flags -band 1) {
    Write-Host "Note: Windows Filter keys / Bounce keys is ON. Turn it off in Settings > Accessibility > Keyboard." -ForegroundColor Yellow
}

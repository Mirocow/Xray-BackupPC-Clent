# uninstall.ps1 — удаление служб, программы и записи в PATH.
# Конфиги (C:\ProgramData\backuppc-client) остаются; -Purge удаляет и их.
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 [-Purge]
param([switch]$Purge)
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Нужны права администратора: запустите PowerShell от имени администратора.'
}

$dst = Join-Path $env:ProgramFiles 'backuppc-client'
$exe = Join-Path $dst 'backuppc-client.exe'
if (Test-Path $exe) {
    # остановка службы снимает маршруты TUN; адаптер Wintun удаляется вместе с процессом
    foreach ($mode in 'tun', 'socks') { & $exe service uninstall $mode }
}

# из каталога программы скрипт удалить себя не может — уходим из него
Set-Location $env:TEMP
Remove-Item -Recurse -Force $dst -ErrorAction SilentlyContinue

$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$rest = ($path -split ';') | Where-Object { $_ -and $_ -ne $dst }
[Environment]::SetEnvironmentVariable('Path', ($rest -join ';'), 'Machine')

if ($Purge) {
    Remove-Item -Recurse -Force (Join-Path $env:ProgramData 'backuppc-client') -ErrorAction SilentlyContinue
    Write-Host 'конфиги удалены'
}
Write-Host 'backuppc-client удалён'

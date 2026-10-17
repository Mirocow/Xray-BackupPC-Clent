# install.ps1 — установка backuppc-client в Program Files и в системный PATH.
# Запуск из распакованного архива, PowerShell «от имени администратора»:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
# Уже установленные службы останавливаются на время замены и запускаются снова.
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Нужны права администратора: запустите PowerShell от имени администратора.'
}

$src = $PSScriptRoot
$dst = Join-Path $env:ProgramFiles 'backuppc-client'

$running = @()
foreach ($mode in 'socks', 'tun') {
    $svc = Get-Service -Name "backuppc-client-$mode" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $svc.Name
        $running += $svc.Name
    }
}

New-Item -ItemType Directory -Force -Path $dst | Out-Null
foreach ($f in 'backuppc-client.exe', 'wintun.dll', 'wintun-LICENSE.txt', 'README.md', 'uninstall.ps1') {
    Copy-Item -Force (Join-Path $src $f) $dst
}
Get-ChildItem $dst | Unblock-File

$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (($path -split ';') -notcontains $dst) {
    [Environment]::SetEnvironmentVariable('Path', ($path.TrimEnd(';') + ';' + $dst), 'Machine')
    Write-Host "добавлено в PATH: $dst (откройте новую консоль)"
}

foreach ($name in $running) {
    Start-Service -Name $name
    Write-Host "служба $name запущена снова"
}

& (Join-Path $dst 'backuppc-client.exe') version
Write-Host "дальше (в консоли администратора):"
Write-Host "  backuppc-client import 'backuppc://…'"
Write-Host "  backuppc-client service install tun"

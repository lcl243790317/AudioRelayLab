param([switch]$Stop)
$ErrorActionPreference = 'Stop'
$privateRoot = Join-Path $PSScriptRoot '.private'
$pidFile = Join-Path $privateRoot 'server-process.json'
$listenerPIDFile = Join-Path $privateRoot 'listener-pid.txt'
if ($Stop) {
    if (Test-Path -LiteralPath $pidFile) {
        $saved = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
        $process = Get-Process -Id $saved.processID -ErrorAction SilentlyContinue
        if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$saved.startTicks) { Stop-Process -Id $process.Id }
        Remove-Item -LiteralPath $pidFile
        if (Test-Path -LiteralPath $listenerPIDFile) { Remove-Item -LiteralPath $listenerPIDFile }
    }
    Write-Output '本项目 AI 服务已停止。'
    exit
}
$privatePython = Join-Path $PSScriptRoot '.venv/Scripts/python.exe'
if (!(Test-Path -LiteralPath $privatePython)) { throw '请先运行 server/setup.ps1' }
$logRoot = Join-Path $PSScriptRoot '.logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
if (Test-Path -LiteralPath $pidFile) {
    $saved = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
    $existing = Get-Process -Id $saved.processID -ErrorAction SilentlyContinue
    if ($existing -and $existing.StartTime.ToUniversalTime().Ticks -eq [long]$saved.startTicks) {
        Write-Output '服务已运行。连接信息见 server/CONNECTION-ZH.txt。'
        exit
    }
}
$appPath = Join-Path $PSScriptRoot 'app.py'
if (Test-Path -LiteralPath $listenerPIDFile) { Remove-Item -LiteralPath $listenerPIDFile }
$process = Start-Process -FilePath $privatePython -ArgumentList ('-u -X utf8 "' + $appPath + '"') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logRoot 'service.log') -RedirectStandardError (Join-Path $logRoot 'service-error.log')
for ($i=0; $i -lt 30; $i++) {
    if (Test-Path -LiteralPath $listenerPIDFile) { break }
    $process.Refresh()
    if ($process.HasExited) { throw '服务启动失败，请查看 server/.logs/service-error.log' }
    Start-Sleep -Milliseconds 100
}
if (!(Test-Path -LiteralPath $listenerPIDFile)) { throw '服务没有成功绑定端口，请查看 server/.logs/service-error.log' }
# Windows venv python.exe can be a launcher; save the listener's PID, not the launcher.
$listenerProcessID = [int](Get-Content -LiteralPath $listenerPIDFile -Raw)
$listenerProcess = Get-Process -Id $listenerProcessID
@{ processID=$listenerProcess.Id; startTicks=$listenerProcess.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json | Set-Content -LiteralPath $pidFile -Encoding utf8
$connection = Get-Content -LiteralPath (Join-Path $privateRoot 'connection.json') -Raw | ConvertFrom-Json
$addresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and $_.AddressState -eq 'Preferred' }
$lines = @('AudioRelayLab 电脑 AI 连接', '手机与电脑连接同一 Wi-Fi。', '在 App 的变声页选择电脑 AI，并输入以下信息：')
foreach ($address in $addresses) { $lines += ('电脑地址：http://' + $address.IPAddress + ':7867') }
$lines += ('连接密钥：' + $connection.token)
$lines += '若无法连接，请确认 Windows 防火墙允许此 Python 在专用网络接收连接。'
$lines | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'CONNECTION-ZH.txt') -Encoding utf8
Write-Output 'AI 服务已启动。连接信息见 server/CONNECTION-ZH.txt；首次生成会加载模型。'

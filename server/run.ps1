param([switch]$Stop, [switch]$Restart)
$ErrorActionPreference = 'Stop'
$privateRoot = Join-Path $PSScriptRoot '.private'
$workerFile = Join-Path $privateRoot 'server-process.json'
$supervisorFile = Join-Path $privateRoot 'supervisor-process.json'
$listenerPIDFile = Join-Path $privateRoot 'listener-pid.txt'

function Get-OwnedProcess($identityPath) {
    if (!(Test-Path -LiteralPath $identityPath)) { return $null }
    $savedIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $ownedProcess = Get-Process -Id $savedIdentity.processID -ErrorAction SilentlyContinue
    if ($ownedProcess -and $ownedProcess.StartTime.ToUniversalTime().Ticks -eq [long]$savedIdentity.startTicks) { return $ownedProcess }
    return $null
}
if ($Stop -or $Restart) {
    foreach ($identityPath in @($supervisorFile, $workerFile)) {
        $ownedProcess = Get-OwnedProcess $identityPath
        if ($ownedProcess) { Stop-Process -Id $ownedProcess.Id }
        if (Test-Path -LiteralPath $identityPath) { Remove-Item -LiteralPath $identityPath }
    }
    if (Test-Path -LiteralPath $listenerPIDFile) { Remove-Item -LiteralPath $listenerPIDFile }
    if ($Stop) { Write-Output '本项目 AI 服务已停止。'; return }
}
$privatePython = Join-Path $PSScriptRoot '.venv/Scripts/python.exe'
if (!(Test-Path -LiteralPath $privatePython)) { throw '请先运行 server/setup.ps1' }
New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot '.logs') -Force | Out-Null
$existingSupervisor = Get-OwnedProcess $supervisorFile
if (!$existingSupervisor) {
    $existingWorker = Get-OwnedProcess $workerFile
    if ($existingWorker) { Stop-Process -Id $existingWorker.Id }
    foreach ($identityPath in @($supervisorFile, $workerFile, $listenerPIDFile)) {
        if (Test-Path -LiteralPath $identityPath) { Remove-Item -LiteralPath $identityPath }
    }
    $supervisorPath = Join-Path $PSScriptRoot 'supervisor.py'
    # Create the hidden service independently of this temporary shell's process job.
    # No scheduled task, administrator account or automatic login trigger is installed.
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow=[uint16]0 }
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine=('"'+$privatePython+'" -u -X utf8 "'+$supervisorPath+'"')
        CurrentDirectory=$PSScriptRoot
        ProcessStartupInformation=$startup
    }
    if ($created.ReturnValue -ne 0) { throw ('Windows 未能启动本项目服务，返回码：' + $created.ReturnValue) }
}
for ($attempt=0; $attempt -lt 80; $attempt++) {
    if (Get-OwnedProcess $workerFile) { break }
    Start-Sleep -Milliseconds 100
}
if (!(Get-OwnedProcess $workerFile)) { throw '服务未能绑定端口，请查看 server/.logs/supervisor.log 和 service-error.log' }
$connection = Get-Content -LiteralPath (Join-Path $privateRoot 'connection.json') -Raw | ConvertFrom-Json
$addresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and $_.AddressState -eq 'Preferred' }
$lines = @('AudioRelayLab 电脑 AI 连接', '手机与电脑连接同一 Wi-Fi；电脑保持唤醒。', '在 App 的变声页选择电脑 AI，并输入以下信息：')
foreach ($address in $addresses) { $lines += ('电脑地址：http://' + $address.IPAddress + ':7867') }
$lines += ('连接密钥：' + $connection.token)
$lines += '若无法连接，请确认 Windows 防火墙允许此 Python 在专用网络接收连接，且 iPhone 设置允许本 App 使用本地网络。'
$lines += '此窗口关闭后服务继续运行；异常退出会自动重启。电脑重启后请重新运行 run.ps1。'
$lines | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'CONNECTION-ZH.txt') -Encoding utf8
Write-Output 'AI 服务已运行；连接信息见 server/CONNECTION-ZH.txt。停止使用 run.ps1 -Stop，更新后使用 run.ps1 -Restart。'

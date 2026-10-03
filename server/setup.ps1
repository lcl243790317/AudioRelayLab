param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$runtimeRoot = Join-Path $PSScriptRoot '.runtime'
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'upstream-lock.json') -Raw | ConvertFrom-Json
$zip = Join-Path $runtimeRoot 'seed-vc-source.zip'
$source = Join-Path $runtimeRoot ('seed-vc-' + $lock.revision)
if (!(Test-Path -LiteralPath $zip)) {
    Invoke-WebRequest -Uri ('https://codeload.github.com/Plachtaa/seed-vc/zip/' + $lock.revision) -OutFile $zip
}
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower() -ne $lock.sourceZipSHA256) {
    throw 'AI 源码校验失败，请检查下载文件。'
}
if (!(Test-Path -LiteralPath $source)) { Expand-Archive -LiteralPath $zip -DestinationPath $runtimeRoot }
$venv = Join-Path $PSScriptRoot '.venv'
if (!(Test-Path -LiteralPath $venv)) {
    & $Python -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw '请安装 Python 3.12，或通过 -Python 指定 python.exe。' }
}
$privatePython = Join-Path $venv 'Scripts/python.exe'
& $privatePython -m pip install torch==2.5.1 torchaudio==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu124
if ($LASTEXITCODE -ne 0) { throw 'PyTorch 安装失败' }
& $privatePython -m pip install -r (Join-Path $PSScriptRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw '推理依赖安装失败' }
if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot '.private/voices.json'))) { & (Join-Path $PSScriptRoot 'generate-references.ps1') }
& $privatePython (Join-Path $PSScriptRoot 'configure-references.py')
if ($LASTEXITCODE -ne 0) { throw '参考音色配置失败' }
Write-Output '安装完成。运行 server/run.ps1 启动；首次生成会下载官方模型。'

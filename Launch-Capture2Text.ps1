$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Join-Path $baseDir 'tools\Capture2Text\Capture2Text_463\Capture2Text'
$exePath = Join-Path $appDir 'Capture2Text.exe'

if (-not (Test-Path $exePath)) {
    Write-Error "Capture2Text.exe not found at $exePath"
    exit 1
}

Start-Process -FilePath $exePath -WorkingDirectory $appDir

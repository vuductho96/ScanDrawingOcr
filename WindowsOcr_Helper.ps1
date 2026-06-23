param(
    [Parameter(Mandatory=$true)]
    [string]$ImagePath,

    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine,Windows.Media.Ocr,ContentType=WindowsRuntime] | Out-Null

$taskType = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethod } |
    Select-Object -First 1

function Await($asyncOp,$type){
    $generic = $taskType.MakeGenericMethod($type)
    $task = $generic.Invoke($null,@($asyncOp))
    $task.Wait()
    return $task.Result
}

function Get-WindowsOcrResult($path){
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    if(!$file){ return $null }

    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    if(!$stream){ return $null }

    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    if(!$decoder){ return $null }

    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    if(!$bitmap){ return $null }

    $bitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert(
        $bitmap,
        [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8
    )

    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if(!$engine){ return $null }

    return (Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult]))
}

if(!(Test-Path -LiteralPath $ImagePath)){
    throw "Image not found: $ImagePath"
}

$result = Get-WindowsOcrResult (Resolve-Path -LiteralPath $ImagePath).Path
if(!$result){
    [PSCustomObject]@{
        Text = ''
        Lines = @()
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}

$lines = @()
if($Detailed){
    foreach($line in @($result.Lines)){
        $words = @()
        $left = [double]::PositiveInfinity
        $top = [double]::PositiveInfinity
        $right = [double]::NegativeInfinity
        $bottom = [double]::NegativeInfinity

        foreach($word in @($line.Words)){
            $wordText = [string]$word.Text
            if([string]::IsNullOrWhiteSpace($wordText)){ continue }

            $rect = $word.BoundingRect
            $words += $wordText
            $left = [Math]::Min($left,[double]$rect.X)
            $top = [Math]::Min($top,[double]$rect.Y)
            $right = [Math]::Max($right,([double]$rect.X + [double]$rect.Width))
            $bottom = [Math]::Max($bottom,([double]$rect.Y + [double]$rect.Height))
        }

        if($words.Count -le 0){ continue }

        $lines += [PSCustomObject]@{
            Text = ($words -join ' ')
            Rect = [PSCustomObject]@{
                X = [double]$left
                Y = [double]$top
                Width = [double][Math]::Max(1.0,($right - $left))
                Height = [double][Math]::Max(1.0,($bottom - $top))
            }
        }
    }
}

[PSCustomObject]@{
    Text = [string]$result.Text
    Lines = @($lines)
} | ConvertTo-Json -Depth 6 -Compress

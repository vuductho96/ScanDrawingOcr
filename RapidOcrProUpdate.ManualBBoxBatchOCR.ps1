Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:PdfiumPath = Join-Path $script:AppRoot 'PdfiumViewer.dll'
$script:PdfiumNativePath = Join-Path $script:AppRoot 'x64'
$script:WindowsOcrHelperPath = Join-Path $script:AppRoot 'WindowsOcr_Helper.ps1'
$script:RapidOcrNetEngine = $null
$script:RapidOcrNetLoaded = $false
$script:RapidOcrNetUnavailable = $false
$script:PaddleOcrOnnxEngine = $null
$script:PaddleOcrOnnxLoaded = $false
$script:PaddleOcrOnnxUnavailable = $false
$script:SessionStoreDir = Join-Path $script:AppRoot 'ocrtool-pdfscan-sessions'
$script:RenderCacheRoot = Join-Path $script:AppRoot 'ocrtool-pdfscan-render-cache'
$script:ManualBBoxAppStatePath = Join-Path $script:AppRoot 'ocrtool-manualbbox-app-state.clixml'
$script:CurrentDocumentPath = $null
$script:CurrentDocumentType = $null
$script:CurrentSourceFingerprint = $null
$script:CurrentSessionFilePath = $null
$script:CurrentPdfDocument = $null
$script:CurrentRenderCacheDir = $null
$script:RenderedPagePaths = @()
$script:PdfTextLayerCache = @{}
$script:CurrentPageIndex = 0
$script:PageCount = 0
$script:PageBitmapCache = @{}
$script:BBoxes = New-Object System.Collections.ArrayList
$script:HoveredBboxId = $null
$script:Zoom = 1.0
$script:PanX = 0.0
$script:PanY = 0.0
$script:DragMode = $null
$script:DragStartCanvasPoint = $null
$script:DragTargetIds = @()
$script:CreateStartImagePoint = $null
$script:ActiveResizeAnchor = $null
$script:IsRestoringSession = $false
$script:StatusText = 'Open PDF or image to begin.'

function Export-ClixmlSafe {
    param($Path,$InputObject)
    if([string]::IsNullOrWhiteSpace([string]$Path)){ return $false }
    try{
        $dir = Split-Path -Parent $Path
        if($dir -and -not (Test-Path -LiteralPath $dir)){
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
        Export-Clixml -LiteralPath $Path -InputObject $InputObject -Force
        return $true
    }
    catch{
        return $false
    }
}

function Import-ClixmlSafe {
    param($Path)
    if([string]::IsNullOrWhiteSpace([string]$Path)){ return $null }
    if(-not (Test-Path -LiteralPath $Path)){ return $null }
    try{
        return Import-Clixml -LiteralPath $Path
    }
    catch{
        return $null
    }
}

function Get-SafeSessionLabel {
    param([string]$SourcePath)
    if([string]::IsNullOrWhiteSpace($SourcePath)){ return 'session' }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    if([string]::IsNullOrWhiteSpace($baseName)){ $baseName = 'session' }
    $safeName = [System.Text.RegularExpressions.Regex]::Replace($baseName,'[\\/:*?"<>|]+','_')
    $safeName = [System.Text.RegularExpressions.Regex]::Replace($safeName,'\s+',' ').Trim()
    if([string]::IsNullOrWhiteSpace($safeName)){ return 'session' }
    return $safeName
}

function Get-SourceFingerprint {
    param([string]$SourcePath)
    if([string]::IsNullOrWhiteSpace($SourcePath)){ return $null }
    if(-not (Test-Path -LiteralPath $SourcePath)){ return $null }
    $stream = $null
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try{
        $stream = [System.IO.File]::OpenRead($SourcePath)
        $hashBytes = $sha1.ComputeHash($stream)
        return (([System.BitConverter]::ToString($hashBytes)).Replace('-','')).ToLowerInvariant()
    }
    finally{
        if($stream){ $stream.Dispose() }
        $sha1.Dispose()
    }
}

function Get-RenderCacheDirectoryPath {
    param([string]$SourcePath)
    if([string]::IsNullOrWhiteSpace($SourcePath)){ return $null }
    $fingerprint = Get-SourceFingerprint $SourcePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }
    $sourceLabel = Get-SafeSessionLabel $SourcePath
    return Join-Path $script:RenderCacheRoot ($sourceLabel + '__' + $fingerprint + '__backup')
}

function Get-ManualBBoxSessionFilePath {
    param([string]$SourcePath)
    if([string]::IsNullOrWhiteSpace($SourcePath)){ return $null }
    $fingerprint = Get-SourceFingerprint $SourcePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }
    $sessionLabel = Get-SafeSessionLabel $SourcePath
    return Join-Path $script:SessionStoreDir ($sessionLabel + '__' + $fingerprint + '__manualbbox.clixml')
}

function Get-CurrentManualBBoxSessionState {
    $items = @()
    foreach($bbox in @($script:BBoxes | Sort-Object Step, PageIndex)){
        $items += [ordered]@{
            Id = [string]$bbox.Id
            Step = [int]$bbox.Step
            PageIndex = [int]$bbox.PageIndex
            X = [int]$bbox.Rect.X
            Y = [int]$bbox.Rect.Y
            W = [int]$bbox.Rect.Width
            H = [int]$bbox.Rect.Height
            RawText = [string]$bbox.RawText
            Nominal = [string]$bbox.Nominal
            TolMinus = [string]$bbox.TolMinus
            TolPlus = [string]$bbox.TolPlus
            Status = [string]$bbox.Status
        }
    }
    return [ordered]@{
        Version = 1
        Mode = 'ManualBBoxBatchOCR'
        SourcePath = [string]$script:CurrentDocumentPath
        SourceFingerprint = [string]$script:CurrentSourceFingerprint
        DocumentType = [string]$script:CurrentDocumentType
        PageCount = [int]$script:PageCount
        CurrentPageIndex = [int]$script:CurrentPageIndex
        ViewState = [ordered]@{
            Zoom = [double]$script:Zoom
            PanX = [double]$script:PanX
            PanY = [double]$script:PanY
        }
        BBoxes = $items
    }
}

function Save-ManualBBoxSessionState {
    if($script:IsRestoringSession){ return }
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentDocumentPath)){ return }
    $sessionFilePath = if($script:CurrentSessionFilePath){ $script:CurrentSessionFilePath } else { Get-ManualBBoxSessionFilePath $script:CurrentDocumentPath }
    if([string]::IsNullOrWhiteSpace($sessionFilePath)){ return }
    $script:CurrentSessionFilePath = $sessionFilePath
    $state = Get-CurrentManualBBoxSessionState
    [void](Export-ClixmlSafe $sessionFilePath $state)
    $appState = [ordered]@{
        LastSourcePath = [string]$script:CurrentDocumentPath
        LastSessionFilePath = [string]$sessionFilePath
    }
    [void](Export-ClixmlSafe $script:ManualBBoxAppStatePath $appState)
}

function Restore-ManualBBoxSessionState {
    param([string]$SourcePath)
    if([string]::IsNullOrWhiteSpace($SourcePath)){ return $false }
    $sessionFilePath = Get-ManualBBoxSessionFilePath $SourcePath
    if([string]::IsNullOrWhiteSpace($sessionFilePath) -or -not (Test-Path -LiteralPath $sessionFilePath)){
        return $false
    }
    $state = Import-ClixmlSafe $sessionFilePath
    if(-not $state){ return $false }
    $script:IsRestoringSession = $true
    try{
        $script:CurrentSessionFilePath = $sessionFilePath
        $script:BBoxes.Clear()
        foreach($item in @($state.BBoxes)){
            $pageIndex = [int]$item.PageIndex
            if($pageIndex -lt 0 -or $pageIndex -ge $script:PageCount){ continue }
            $bmp = if($pageIndex -eq $script:CurrentPageIndex){ Get-CurrentBitmap } else { Get-PageBitmap $pageIndex }
            if(-not $bmp){ continue }
            $rect = Clamp-RectToBitmap ([System.Drawing.Rectangle]::new([int]$item.X,[int]$item.Y,[Math]::Max(2,[int]$item.W),[Math]::Max(2,[int]$item.H))) $bmp
            $bbox = New-BBoxObject -PageIndex $pageIndex -Rect $rect
            $bbox.Step = [int]$item.Step
            $bbox.RawText = [string]$item.RawText
            $bbox.Nominal = [string]$item.Nominal
            $bbox.TolMinus = [string]$item.TolMinus
            $bbox.TolPlus = [string]$item.TolPlus
            $bbox.Status = if([string]::IsNullOrWhiteSpace([string]$item.Status)){ 'PENDING' } else { [string]$item.Status }
            [void]$script:BBoxes.Add($bbox)
        }
        Renumber-BBoxes
        if($state.ViewState){
            $script:Zoom = [Math]::Max(0.08,[double]$state.ViewState.Zoom)
            $script:PanX = [double]$state.ViewState.PanX
            $script:PanY = [double]$state.ViewState.PanY
        }
        else{
            Reset-View
        }
        if($null -ne $state.CurrentPageIndex){
            $script:CurrentPageIndex = [Math]::Max(0,[Math]::Min(($script:PageCount - 1),[int]$state.CurrentPageIndex))
        }
        Update-PageLabel
        Refresh-BBoxTable
        Update-Status ('Session restored: ' + [System.IO.Path]::GetFileName($sessionFilePath))
        return $true
    }
    finally{
        $script:IsRestoringSession = $false
    }
}

function Restore-LastManualBBoxSession {
    $appState = Import-ClixmlSafe $script:ManualBBoxAppStatePath
    if(-not $appState){ return }
    $lastSourcePath = [string]$appState.LastSourcePath
    if([string]::IsNullOrWhiteSpace($lastSourcePath)){ return }
    if(-not (Test-Path -LiteralPath $lastSourcePath)){ return }
    Open-DocumentPath -Path $lastSourcePath -RestoreLastSession
}

function Ensure-PdfiumRuntime {
    if($script:PdfiumLoaded){ return $true }
    if(Test-Path -LiteralPath $script:PdfiumNativePath){
        $env:PATH = $script:PdfiumNativePath + ';' + $env:PATH
    }
    if(-not (Test-Path -LiteralPath $script:PdfiumPath)){ return $false }
    [void][System.Reflection.Assembly]::LoadFrom($script:PdfiumPath)
    $script:PdfiumLoaded = $true
    return $true
}

function Get-WindowsOcrTextFromImagePath {
    param([string]$ImagePath)
    if(-not (Test-Path -LiteralPath $script:WindowsOcrHelperPath)){ return '' }
    if(-not (Test-Path -LiteralPath $ImagePath)){ return '' }
    try{
        $json = & powershell -ExecutionPolicy Bypass -File $script:WindowsOcrHelperPath -ImagePath $ImagePath 2>$null
        if([string]::IsNullOrWhiteSpace([string]$json)){ return '' }
        $result = $json | ConvertFrom-Json -ErrorAction Stop
        if($result -and $result.Text){ return [string]$result.Text }
        return ''
    }
    catch{
        return ''
    }
}

function Initialize-RapidOcrNetEngine {
    if($script:RapidOcrNetLoaded -and $script:RapidOcrNetEngine){ return $true }
    if($script:RapidOcrNetUnavailable){ return $false }
    if($PSVersionTable.PSEdition -ne 'Core'){
        $script:RapidOcrNetUnavailable = $true
        return $false
    }
    try{
        $ocrRoot = Join-Path $script:AppRoot 'lib\OcrAi'
        $nativeRoot = Join-Path $ocrRoot 'Microsoft.ML.OnnxRuntime.1.24.3\runtimes\win-x64\native'
        $skiaNativeRoot = Join-Path $ocrRoot 'SkiaSharp.NativeAssets.Win32\runtimes\win-x64\native'
        $modelRoot = Join-Path $ocrRoot 'RapidOcrNet\models\v5'
        $requiredFiles = @(
            (Join-Path $nativeRoot 'onnxruntime.dll'),
            (Join-Path $nativeRoot 'onnxruntime_providers_shared.dll'),
            (Join-Path $skiaNativeRoot 'libSkiaSharp.dll'),
            (Join-Path $ocrRoot 'System.Numerics.Tensors\lib\net9.0\System.Numerics.Tensors.dll'),
            (Join-Path $ocrRoot 'Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll'),
            (Join-Path $ocrRoot 'SkiaSharp\lib\net8.0\SkiaSharp.dll'),
            (Join-Path $ocrRoot 'Clipper2\lib\netstandard2.0\Clipper2Lib.dll'),
            (Join-Path $ocrRoot 'RapidOcrNet\lib\net8.0\RapidOcrNet.dll'),
            (Join-Path $modelRoot 'ch_PP-OCRv5_mobile_det.onnx'),
            (Join-Path $modelRoot 'ch_ppocr_mobile_v2.0_cls_infer.onnx'),
            (Join-Path $modelRoot 'latin_PP-OCRv5_rec_mobile_infer.onnx'),
            (Join-Path $modelRoot 'ppocrv5_latin_dict.txt')
        )
        foreach($file in $requiredFiles){ if(-not (Test-Path $file)){ $script:RapidOcrNetUnavailable = $true; return $false } }
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot 'onnxruntime_providers_shared.dll')) | Out-Null
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot 'onnxruntime.dll')) | Out-Null
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $skiaNativeRoot 'libSkiaSharp.dll')) | Out-Null
        foreach($assemblyPath in @(
            (Join-Path $ocrRoot 'System.Numerics.Tensors\lib\net9.0\System.Numerics.Tensors.dll'),
            (Join-Path $ocrRoot 'Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll'),
            (Join-Path $ocrRoot 'SkiaSharp\lib\net8.0\SkiaSharp.dll'),
            (Join-Path $ocrRoot 'Clipper2\lib\netstandard2.0\Clipper2Lib.dll'),
            (Join-Path $ocrRoot 'RapidOcrNet\lib\net8.0\RapidOcrNet.dll')
        )){
            Add-Type -Path $assemblyPath -ErrorAction SilentlyContinue
        }
        $engine = [RapidOcrNet.RapidOcr]::new()
        $engine.InitModels(
            (Join-Path $modelRoot 'ch_PP-OCRv5_mobile_det.onnx'),
            (Join-Path $modelRoot 'ch_ppocr_mobile_v2.0_cls_infer.onnx'),
            (Join-Path $modelRoot 'latin_PP-OCRv5_rec_mobile_infer.onnx'),
            (Join-Path $modelRoot 'ppocrv5_latin_dict.txt'),
            0
        )
        $script:RapidOcrNetEngine = $engine
        $script:RapidOcrNetLoaded = $true
        return $true
    }
    catch{
        $script:RapidOcrNetEngine = $null
        $script:RapidOcrNetUnavailable = $true
        return $false
    }
}

function Initialize-PaddleOcrOnnxEngine {
    if($script:PaddleOcrOnnxLoaded -and $script:PaddleOcrOnnxEngine){ return $true }
    if($script:PaddleOcrOnnxUnavailable){ return $false }
    try{
        $ocrRoot = Join-Path $script:AppRoot 'lib\OcrAi'
        $nativeRoot = Join-Path $ocrRoot 'Microsoft.ML.OnnxRuntime.1.24.3\runtimes\win-x64\native'
        $modelRoot = Join-Path $ocrRoot 'PaddleOCR.Onnx\build\Models\inference'
        $emguNativeRoot = Join-Path $ocrRoot 'Emgu.CV.runtime.windows\build\x64'
        $requiredFiles = @(
            (Join-Path $nativeRoot 'onnxruntime.dll'),
            (Join-Path $nativeRoot 'onnxruntime_providers_shared.dll'),
            (Join-Path $ocrRoot 'Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll'),
            (Join-Path $ocrRoot 'Emgu.CV\lib\netstandard2.0\Emgu.CV.Platform.NetStandard.dll'),
            (Join-Path $emguNativeRoot 'cvextern.dll'),
            (Join-Path $ocrRoot 'clipper_standard\lib\netstandard2.0\clipper.dll'),
            (Join-Path $ocrRoot 'PaddleOCR.Onnx\lib\net6.0\PaddleOCR.Onnx.dll'),
            (Join-Path $modelRoot 'ch_PP-OCRv3_det_infer.onnx'),
            (Join-Path $modelRoot 'ch_ppocr_mobile_v2.0_cls_infer.onnx'),
            (Join-Path $modelRoot 'ch_PP-OCRv3_rec_infer.onnx'),
            (Join-Path $modelRoot 'ppocr_keys.txt')
        )
        foreach($file in $requiredFiles){ if(-not (Test-Path $file)){ $script:PaddleOcrOnnxUnavailable = $true; return $false } }
        if($env:PATH -notlike ('*' + $emguNativeRoot + '*')){ $env:PATH = $emguNativeRoot + ';' + $env:PATH }
        if($env:PATH -notlike ('*' + $nativeRoot + '*')){ $env:PATH = $nativeRoot + ';' + $env:PATH }
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot 'onnxruntime_providers_shared.dll')) | Out-Null
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot 'onnxruntime.dll')) | Out-Null
        foreach($assemblyPath in @(
            (Join-Path $ocrRoot 'Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll'),
            (Join-Path $ocrRoot 'Emgu.CV\lib\netstandard2.0\Emgu.CV.Platform.NetStandard.dll'),
            (Join-Path $ocrRoot 'clipper_standard\lib\netstandard2.0\clipper.dll'),
            (Join-Path $ocrRoot 'PaddleOCR.Onnx\lib\net6.0\PaddleOCR.Onnx.dll')
        )){
            Add-Type -Path $assemblyPath -ErrorAction SilentlyContinue
        }
        $config = [PaddleOCR.Onnx.OCRModelConfig]::new()
        $config.det_infer = Join-Path $modelRoot 'ch_PP-OCRv3_det_infer.onnx'
        $config.cls_infer = Join-Path $modelRoot 'ch_ppocr_mobile_v2.0_cls_infer.onnx'
        $config.rec_infer = Join-Path $modelRoot 'ch_PP-OCRv3_rec_infer.onnx'
        $config.keys = Join-Path $modelRoot 'ppocr_keys.txt'
        $parameter = [PaddleOCR.Onnx.OCRParameter]::new()
        $parameter.use_custom_model = $true
        $parameter.DoAngle = $true
        $parameter.MostAngle = $true
        $parameter.BoxThresh = 0.18
        $parameter.BoxScoreThresh = 0.25
        $parameter.UnClipRatio = 1.8
        $script:PaddleOcrOnnxEngine = [PaddleOCR.Onnx.PaddleOCREngine]::new($config,$parameter)
        $script:PaddleOcrOnnxLoaded = $true
        return $true
    }
    catch{
        $script:PaddleOcrOnnxEngine = $null
        $script:PaddleOcrOnnxUnavailable = $true
        return $false
    }
}

function Get-RapidOcrTextFromImagePath {
    param([string]$ImagePath)
    if([string]::IsNullOrWhiteSpace($ImagePath) -or -not (Test-Path $ImagePath)){ return '' }
    if(-not (Initialize-RapidOcrNetEngine)){ return '' }
    try{
        $options = [RapidOcrNet.RapidOcrOptions]::Default
        $result = $script:RapidOcrNetEngine.Detect($ImagePath,$options)
        if(-not $result -or -not $result.StrRes){ return '' }
        return ([string]$result.StrRes).Trim()
    }
    catch{
        return ''
    }
}

function Get-PaddleOcrTextFromImagePath {
    param([string]$ImagePath)
    if([string]::IsNullOrWhiteSpace($ImagePath) -or -not (Test-Path $ImagePath)){ return '' }
    if(-not (Initialize-PaddleOcrOnnxEngine)){ return '' }
    try{
        $result = $script:PaddleOcrOnnxEngine.DetectText($ImagePath)
        if($result -is [string]){ return ([string]$result).Trim() }
        return ([string]$result).Trim()
    }
    catch{
        return ''
    }
}

function Normalize-PdfTextLayerText {
    param([string]$Text)
    $value = Normalize-Text $Text
    $value = $value.Replace('&amp;','&').Replace('&quot;','"').Replace('&apos;',"'").Replace('&lt;','<').Replace('&gt;','>')
    return $value
}

function Convert-PdfRectToImageRectForBitmap {
    param(
        $PdfRect,
        [double]$PageWidth,
        [double]$PageHeight,
        [System.Drawing.Bitmap]$Bitmap
    )
    if(-not $PdfRect -or -not $Bitmap){ return $null }
    if($PageWidth -le 0 -or $PageHeight -le 0){ return $null }
    $scaleX = [double]$Bitmap.Width / [double]$PageWidth
    $scaleY = [double]$Bitmap.Height / [double]$PageHeight
    $pad = 8.0
    $left = [int][Math]::Floor(($PdfRect.XMin * $scaleX) - $pad)
    $top = [int][Math]::Floor(($PdfRect.YMin * $scaleY) - $pad)
    $right = [int][Math]::Ceiling(($PdfRect.XMax * $scaleX) + $pad)
    $bottom = [int][Math]::Ceiling(($PdfRect.YMax * $scaleY) + $pad)
    $left = [Math]::Max(0,$left)
    $top = [Math]::Max(0,$top)
    $right = [Math]::Min($Bitmap.Width,$right)
    $bottom = [Math]::Min($Bitmap.Height,$bottom)
    return [System.Drawing.Rectangle]::new($left,$top,[Math]::Max(1,($right - $left)),[Math]::Max(1,($bottom - $top)))
}

function Get-RectangleIntersectionArea {
    param(
        [System.Drawing.Rectangle]$A,
        [System.Drawing.Rectangle]$B
    )
    $left = [Math]::Max($A.Left,$B.Left)
    $top = [Math]::Max($A.Top,$B.Top)
    $right = [Math]::Min($A.Right,$B.Right)
    $bottom = [Math]::Min($A.Bottom,$B.Bottom)
    if($right -le $left -or $bottom -le $top){ return 0.0 }
    return [double](($right - $left) * ($bottom - $top))
}

function Get-PdfTextLayerBlocksSimple {
    param(
        [string]$PdfPath,
        [int]$PageNumber
    )
    if([string]::IsNullOrWhiteSpace($PdfPath) -or -not (Test-Path -LiteralPath $PdfPath)){ return @() }
    $cacheKey = ([string]$PdfPath + '|' + [string]$PageNumber)
    if($script:PdfTextLayerCache.ContainsKey($cacheKey)){
        return @($script:PdfTextLayerCache[$cacheKey])
    }
    $pdftotext = Get-Command pdftotext -ErrorAction SilentlyContinue
    if(-not $pdftotext){ return @() }
    $tempPath = Join-Path $env:TEMP ("rapidocr_manual_bbox_{0}.html" -f ([guid]::NewGuid().ToString('N')))
    try{
        & $pdftotext.Source -f $PageNumber -l $PageNumber -bbox-layout $PdfPath $tempPath 2>$null
        if(-not (Test-Path -LiteralPath $tempPath)){ return @() }
        $content = [System.IO.File]::ReadAllText($tempPath,[System.Text.Encoding]::UTF8)
        $pageMatch = [regex]::Match($content,'<page\s+width="(?<w>[-0-9.]+)"\s+height="(?<h>[-0-9.]+)"','IgnoreCase')
        if(-not $pageMatch.Success){ return @() }
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $pageWidth = [double]::Parse($pageMatch.Groups['w'].Value,$culture)
        $pageHeight = [double]::Parse($pageMatch.Groups['h'].Value,$culture)
        $blocks = New-Object System.Collections.ArrayList
        foreach($blockMatch in [regex]::Matches($content,'<block\s+(?<attrs>[^>]*)>(?<body>.*?)</block>','Singleline')){
            $attrs = $blockMatch.Groups['attrs'].Value
            $body = $blockMatch.Groups['body'].Value
            $attrMatch = [regex]::Match($attrs,'xMin="(?<x1>[-0-9.]+)"\s+yMin="(?<y1>[-0-9.]+)"\s+xMax="(?<x2>[-0-9.]+)"\s+yMax="(?<y2>[-0-9.]+)"')
            if(-not $attrMatch.Success){ continue }
            $words = New-Object System.Collections.ArrayList
            foreach($wordMatch in [regex]::Matches($body,'<word\s+(?<attrs>[^>]*)>(?<text>.*?)</word>','Singleline')){
                $wordAttrs = $wordMatch.Groups['attrs'].Value
                $wordRectMatch = [regex]::Match($wordAttrs,'xMin="(?<x1>[-0-9.]+)"\s+yMin="(?<y1>[-0-9.]+)"\s+xMax="(?<x2>[-0-9.]+)"\s+yMax="(?<y2>[-0-9.]+)"')
                if(-not $wordRectMatch.Success){ continue }
                $wordText = Normalize-PdfTextLayerText $wordMatch.Groups['text'].Value
                if([string]::IsNullOrWhiteSpace($wordText)){ continue }
                [void]$words.Add($wordText)
            }
            if($words.Count -le 0){ continue }
            $text = Normalize-PdfTextLayerText (($words -join ' '))
            if([string]::IsNullOrWhiteSpace($text)){ continue }
            [void]$blocks.Add([PSCustomObject]@{
                Text = $text
                Rect = [PSCustomObject]@{
                    XMin = [double]::Parse($attrMatch.Groups['x1'].Value,$culture)
                    YMin = [double]::Parse($attrMatch.Groups['y1'].Value,$culture)
                    XMax = [double]::Parse($attrMatch.Groups['x2'].Value,$culture)
                    YMax = [double]::Parse($attrMatch.Groups['y2'].Value,$culture)
                }
                PageWidth = $pageWidth
                PageHeight = $pageHeight
            })
        }
        $script:PdfTextLayerCache[$cacheKey] = @($blocks)
        return @($blocks)
    }
    finally{
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-TextLayerMatchForBBox {
    param($BBox)
    if($script:CurrentDocumentType -ne 'Pdf'){ return $null }
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentDocumentPath)){ return $null }
    $bitmap = if($BBox.PageIndex -eq $script:CurrentPageIndex){ Get-CurrentBitmap } else { Get-PageBitmap $BBox.PageIndex }
    if(-not $bitmap){ return $null }
    $blocks = @(Get-PdfTextLayerBlocksSimple -PdfPath $script:CurrentDocumentPath -PageNumber ($BBox.PageIndex + 1))
    if($blocks.Count -le 0){ return $null }
    $best = $null
    $bestScore = 0.0
    foreach($block in $blocks){
        $imageRect = Convert-PdfRectToImageRectForBitmap -PdfRect $block.Rect -PageWidth $block.PageWidth -PageHeight $block.PageHeight -Bitmap $bitmap
        if(-not $imageRect){ continue }
        $area = Get-RectangleIntersectionArea -A $BBox.Rect -B $imageRect
        if($area -le 0){ continue }
        $coverage = $area / [double]([Math]::Max(1,($BBox.Rect.Width * $BBox.Rect.Height)))
        if($coverage -gt $bestScore){
            $bestScore = $coverage
            $best = [PSCustomObject]@{
                Text = [string]$block.Text
                Rect = $imageRect
                Coverage = $coverage
            }
        }
    }
    if($best -and $best.Coverage -ge 0.15){ return $best }
    return $null
}

function Normalize-Text {
    param([string]$Text)
    if($null -eq $Text){ return '' }
    $value = [string]$Text
    $value = $value.Replace("`r",' ').Replace("`n",' ')
    $value = $value -replace '\s+',' '
    $value = $value.Trim()
    $value = $value.Replace('Φ','Ø').Replace('⌀','Ø').Replace('∅','Ø').Replace('º','°')
    return $value
}

function Clean-OcrText {
    param([string]$Text)
    $value = Normalize-Text $Text
    $value = $value -replace '[,;_]+',' '
    $value = $value -replace '\s+',' '
    return $value.Trim()
}

function Normalize-MechanicalOcrTextLite {
    param([string]$Text)
    $value = Clean-OcrText $Text
    if([string]::IsNullOrWhiteSpace($value)){ return '' }
    $value = $value -replace '(?<=[0-9])[oO](?=[0-9])','0'
    $value = $value -replace '(?<=[RCØ])[oO](?=[0-9])','0'
    $value = $value -replace '(?<=[0-9])[,](?=[0-9])','.'
    $value = $value -replace '\s+',' '
    return $value.Trim()
}

function Resolve-NominalFromOcrVariants {
    param([string[]]$Texts)
    foreach($text in @($Texts)){
        $parsed = Parse-Nominal $text
        if(-not [string]::IsNullOrWhiteSpace($parsed)){ return $parsed }
    }
    return ''
}

function Parse-Nominal {
    param([string]$Text)
    $raw = Clean-OcrText $Text
    if([string]::IsNullOrWhiteSpace($raw)){ return '' }
    $toleranceIndex = $raw.Length
    $match = [regex]::Match($raw,'[±]|(?<!^)[+\-]\s*(?:\d+|\d*\.\d+)')
    if($match.Success){ $toleranceIndex = $match.Index }
    $nominalRegion = $raw.Substring(0,$toleranceIndex).Trim()
    if([string]::IsNullOrWhiteSpace($nominalRegion)){ $nominalRegion = $raw }
    $pattern = '(?i)(?:Ø|R|C)?\s*\d+(?:\.\d+)?(?:°)?'
    $nominalMatch = [regex]::Matches($nominalRegion,$pattern) | Select-Object -First 1
    if($nominalMatch){
        return (($nominalMatch.Value -replace '\s+','').Trim())
    }
    return ''
}

function Parse-Tolerance {
    param(
        [string]$Text,
        [string]$Nominal
    )
    $raw = Clean-OcrText $Text
    $tolMinus = ''
    $tolPlus = ''
    $pmMatch = [regex]::Match($raw,'±\s*(\d*\.\d+|\d+)')
    if($pmMatch.Success){
        $value = [double]$pmMatch.Groups[1].Value
        return [PSCustomObject]@{
            TolMinus = ('-{0}' -f $value.ToString([System.Globalization.CultureInfo]::InvariantCulture))
            TolPlus = ('+{0}' -f $value.ToString([System.Globalization.CultureInfo]::InvariantCulture))
            HasExplicit = $true
        }
    }
    $signedMatches = [regex]::Matches($raw,'([+\-])\s*(\d*\.\d+|\d+)')
    foreach($m in @($signedMatches)){
        $sign = [string]$m.Groups[1].Value
        $num = [string]$m.Groups[2].Value
        if($sign -eq '-'){ $tolMinus = ('-{0}' -f $num) }
        elseif($sign -eq '+'){ $tolPlus = ('+{0}' -f $num) }
    }
    return [PSCustomObject]@{
        TolMinus = $tolMinus
        TolPlus = $tolPlus
        HasExplicit = ($signedMatches.Count -gt 0)
    }
}

function Convert-TextToDouble {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){ return $null }
    $value = 0.0
    if([double]::TryParse(([string]$Text).Replace('+',''),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$value)){
        return [double]$value
    }
    return $null
}

function Get-OcrStatus {
    param(
        [string]$RawText,
        [string]$Nominal,
        [string]$TolMinus,
        [string]$TolPlus
    )
    if([string]::IsNullOrWhiteSpace($Nominal)){ return 'FAIL' }
    $nominalNumericText = ($Nominal -replace '(?i)[^0-9\.\-]','')
    $nominalValue = Convert-TextToDouble $nominalNumericText
    $minusValue = Convert-TextToDouble $TolMinus
    $plusValue = Convert-TextToDouble $TolPlus
    if($nominalValue -ne $null){
        $maxTol = 0.0
        if($minusValue -ne $null){ $maxTol = [Math]::Max($maxTol,[Math]::Abs($minusValue)) }
        if($plusValue -ne $null){ $maxTol = [Math]::Max($maxTol,[Math]::Abs($plusValue)) }
        if($maxTol -gt 0 -and $nominalValue -le $maxTol){ return 'FAIL' }
    }
    $raw = Clean-OcrText $RawText
    if(($raw -match '[±+\-]') -and [string]::IsNullOrWhiteSpace($TolMinus) -and [string]::IsNullOrWhiteSpace($TolPlus)){ return 'WARN' }
    if($raw.Length -lt 2){ return 'WARN' }
    return 'OK'
}

function New-BBoxObject {
    param(
        [int]$PageIndex,
        [System.Drawing.Rectangle]$Rect
    )
    return [PSCustomObject]@{
        Id = [guid]::NewGuid().ToString('N')
        Step = 0
        PageIndex = $PageIndex
        Rect = $Rect
        Nominal = ''
        TolMinus = ''
        TolPlus = ''
        RawText = ''
        Status = 'PENDING'
    }
}

function Renumber-BBoxes {
    $index = 1
    foreach($bbox in @($script:BBoxes | Sort-Object PageIndex, Step, @{ Expression = { $_.Rect.Y } }, @{ Expression = { $_.Rect.X } })){
        $bbox.Step = $index
        $index++
    }
}

function Clear-BBoxSelection {
    foreach($bbox in @($script:BBoxes)){
        if($bbox.PSObject.Properties.Name -notcontains 'Selected'){
            $bbox | Add-Member -NotePropertyName Selected -NotePropertyValue $false -Force
        }
        $bbox.Selected = $false
    }
}

function Get-SelectedBBoxes { return @($script:BBoxes | Where-Object { $_.Selected }) }

function Select-BBox {
    param(
        [string]$Id,
        [switch]$Toggle,
        [switch]$Add
    )
    if(-not $Add -and -not $Toggle){ Clear-BBoxSelection }
    foreach($bbox in @($script:BBoxes)){
        if($bbox.Id -eq $Id){
            if($Toggle){ $bbox.Selected = -not [bool]$bbox.Selected } else { $bbox.Selected = $true }
            break
        }
    }
}

function Get-BBoxById {
    param([string]$Id)
    return @($script:BBoxes | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)[0]
}

function Get-CurrentBitmap {
    if($script:PageBitmapCache.ContainsKey($script:CurrentPageIndex)){
        return $script:PageBitmapCache[$script:CurrentPageIndex]
    }
    return $null
}

function Dispose-Document {
    foreach($bmp in @($script:PageBitmapCache.Values)){
        try{ if($bmp){ $bmp.Dispose() } } catch{}
    }
    $script:PageBitmapCache.Clear()
    if($script:CurrentPdfDocument){
        try{ $script:CurrentPdfDocument.Dispose() } catch{}
    }
    $script:CurrentPdfDocument = $null
    $script:CurrentRenderCacheDir = $null
    $script:RenderedPagePaths = @()
    $script:CurrentSourceFingerprint = $null
    $script:CurrentSessionFilePath = $null
    $script:PdfTextLayerCache = @{}
    $script:PageCount = 0
    $script:CurrentPageIndex = 0
}

function Load-ImageDocument {
    param([string]$Path)
    Dispose-Document
    $loaded = [System.Drawing.Bitmap]::FromFile($Path)
    $script:PageBitmapCache[0] = New-Object System.Drawing.Bitmap $loaded
    $loaded.Dispose()
    $script:CurrentDocumentPath = $Path
    $script:CurrentDocumentType = 'Image'
    $script:CurrentSourceFingerprint = Get-SourceFingerprint $Path
    $script:CurrentSessionFilePath = Get-ManualBBoxSessionFilePath $Path
    $script:PageCount = 1
    $script:CurrentPageIndex = 0
    $script:CurrentRenderCacheDir = $null
    $script:RenderedPagePaths = @()
}

function Load-PdfDocument {
    param([string]$Path)
    Dispose-Document
    if(-not (Ensure-PdfiumRuntime)){ throw 'PdfiumViewer.dll not found.' }
    $script:CurrentPdfDocument = [PdfiumViewer.PdfDocument]::Load($Path)
    $script:CurrentDocumentPath = $Path
    $script:CurrentDocumentType = 'Pdf'
    $script:CurrentSourceFingerprint = Get-SourceFingerprint $Path
    $script:CurrentSessionFilePath = Get-ManualBBoxSessionFilePath $Path
    $script:CurrentRenderCacheDir = Get-RenderCacheDirectoryPath $Path
    if($script:CurrentRenderCacheDir -and -not (Test-Path -LiteralPath $script:CurrentRenderCacheDir)){
        New-Item -Path $script:CurrentRenderCacheDir -ItemType Directory -Force | Out-Null
    }
    $script:PageCount = $script:CurrentPdfDocument.PageSizes.Count
    $script:CurrentPageIndex = 0
    $script:RenderedPagePaths = @()
    for($pageIndex = 0; $pageIndex -lt $script:PageCount; $pageIndex++){
        if($script:CurrentRenderCacheDir){
            $script:RenderedPagePaths += (Join-Path $script:CurrentRenderCacheDir ('page-{0:d3}.jpg' -f ($pageIndex + 1)))
        }
        else{
            $script:RenderedPagePaths += $null
        }
    }
    [void](Get-PageBitmap 0)
}

function Get-PageBitmap {
    param([int]$PageIndex)
    if($script:PageBitmapCache.ContainsKey($PageIndex)){
        return $script:PageBitmapCache[$PageIndex]
    }
    if($script:CurrentDocumentType -ne 'Pdf' -or -not $script:CurrentPdfDocument){
        return $null
    }
    $cachedImagePath = $null
    if($script:RenderedPagePaths -and $PageIndex -ge 0 -and $PageIndex -lt $script:RenderedPagePaths.Count){
        $cachedImagePath = [string]$script:RenderedPagePaths[$PageIndex]
    }
    if(-not [string]::IsNullOrWhiteSpace($cachedImagePath) -and (Test-Path -LiteralPath $cachedImagePath)){
        $loaded = [System.Drawing.Bitmap]::FromFile($cachedImagePath)
        try{
            $bmp = New-Object System.Drawing.Bitmap $loaded
        }
        finally{
            $loaded.Dispose()
        }
        $script:PageBitmapCache[$PageIndex] = $bmp
        return $bmp
    }
    $pageSize = $script:CurrentPdfDocument.PageSizes[$PageIndex]
    $dpi = 300.0
    $width = [Math]::Max(1,[int]([Math]::Round(($pageSize.Width / 72.0) * $dpi)))
    $height = [Math]::Max(1,[int]([Math]::Round(($pageSize.Height / 72.0) * $dpi)))
    $flags = [PdfiumViewer.PdfRenderFlags]::Annotations
    $rendered = $script:CurrentPdfDocument.Render($PageIndex,$width,$height,$dpi,$dpi,$flags)
    $bmp = New-Object System.Drawing.Bitmap $rendered
    $rendered.Dispose()
    if(-not [string]::IsNullOrWhiteSpace($cachedImagePath)){
        try{
            $bmp.Save($cachedImagePath,[System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        catch{}
    }
    $script:PageBitmapCache[$PageIndex] = $bmp
    return $bmp
}

function Reset-View {
    $script:Zoom = 1.0
    $script:PanX = 12
    $script:PanY = 12
}

function Get-CanvasImageRectangle {
    param([System.Drawing.Bitmap]$Bitmap)
    if(-not $Bitmap){ return [System.Drawing.RectangleF]::Empty }
    return [System.Drawing.RectangleF]::new([single]$script:PanX,[single]$script:PanY,[single]($Bitmap.Width * $script:Zoom),[single]($Bitmap.Height * $script:Zoom))
}

function Convert-ImageToCanvasRect {
    param([System.Drawing.Rectangle]$Rect)
    return [System.Drawing.RectangleF]::new([single]($script:PanX + ($Rect.X * $script:Zoom)),[single]($script:PanY + ($Rect.Y * $script:Zoom)),[single]($Rect.Width * $script:Zoom),[single]($Rect.Height * $script:Zoom))
}

function Convert-CanvasPointToImagePoint {
    param([System.Drawing.Point]$Point)
    return New-Object System.Drawing.PointF([single](($Point.X - $script:PanX) / $script:Zoom),[single](($Point.Y - $script:PanY) / $script:Zoom))
}

function Clamp-RectToBitmap {
    param(
        [System.Drawing.Rectangle]$Rect,
        [System.Drawing.Bitmap]$Bitmap
    )
    if(-not $Bitmap){ return $Rect }
    $left = [Math]::Max(0,[Math]::Min($Bitmap.Width - 2,$Rect.X))
    $top = [Math]::Max(0,[Math]::Min($Bitmap.Height - 2,$Rect.Y))
    $right = [Math]::Max($left + 2,[Math]::Min($Bitmap.Width,$Rect.Right))
    $bottom = [Math]::Max($top + 2,[Math]::Min($Bitmap.Height,$Rect.Bottom))
    return New-Object System.Drawing.Rectangle($left,$top,($right - $left),($bottom - $top))
}

function Get-NormalizedRect {
    param(
        [System.Drawing.PointF]$A,
        [System.Drawing.PointF]$B
    )
    $left = [int][Math]::Floor([Math]::Min($A.X,$B.X))
    $top = [int][Math]::Floor([Math]::Min($A.Y,$B.Y))
    $right = [int][Math]::Ceiling([Math]::Max($A.X,$B.X))
    $bottom = [int][Math]::Ceiling([Math]::Max($A.Y,$B.Y))
    return New-Object System.Drawing.Rectangle($left,$top,($right - $left),($bottom - $top))
}

function Get-CurrentPageBBoxes {
    return @($script:BBoxes | Where-Object { $_.PageIndex -eq $script:CurrentPageIndex } | Sort-Object Step)
}

function Remove-SelectedBBoxes {
    $selected = @(Get-SelectedBBoxes)
    if($selected.Count -le 0){ return }
    foreach($bbox in $selected){ [void]$script:BBoxes.Remove($bbox) }
    Renumber-BBoxes
    Save-ManualBBoxSessionState
}

function Remove-BBoxById {
    param([string]$Id)
    if([string]::IsNullOrWhiteSpace($Id)){ return $false }
    $bbox = Get-BBoxById $Id
    if(-not $bbox){ return $false }
    [void]$script:BBoxes.Remove($bbox)
    Renumber-BBoxes
    Refresh-BBoxTable
    Update-Status ('Deleted bbox step ' + [string]$bbox.Step)
    Save-ManualBBoxSessionState
    return $true
}

function Undo-LastBBox {
    $ordered = @($script:BBoxes | Sort-Object Step)
    if($ordered.Count -le 0){
        Update-Status 'No bbox to undo.'
        return
    }
    $last = $ordered[-1]
    [void]$script:BBoxes.Remove($last)
    Renumber-BBoxes
    Refresh-BBoxTable
    Update-Status ('Undo last bbox: step ' + [string]$last.Step)
    Save-ManualBBoxSessionState
}

function Cancel-CurrentDraftBBox {
    if($script:DragMode -ne 'Create' -or -not $script:CreateStartImagePoint){ return }
    $script:DragMode = $null
    $script:CreateStartImagePoint = $null
    $script:DragStartCanvasPoint = $null
    $script:DragTargetIds = @()
    $script:ActiveResizeAnchor = $null
    $canvas.Cursor = [System.Windows.Forms.Cursors]::Default
    $canvas.Invalidate()
    Update-Status 'Canceled draft bbox.'
}

function Duplicate-SelectedBBoxes {
    $selected = @(Get-SelectedBBoxes | Sort-Object Step)
    if($selected.Count -le 0){ return }
    Clear-BBoxSelection
    $currentBitmap = Get-CurrentBitmap
    foreach($bbox in $selected){
        $newRect = New-Object System.Drawing.Rectangle($bbox.Rect.X + 18,$bbox.Rect.Y + 18,$bbox.Rect.Width,$bbox.Rect.Height)
        if($currentBitmap){ $newRect = Clamp-RectToBitmap $newRect $currentBitmap }
        $clone = New-BBoxObject -PageIndex $bbox.PageIndex -Rect $newRect
        [void]$script:BBoxes.Add($clone)
        $clone | Add-Member -NotePropertyName Selected -NotePropertyValue $true -Force
    }
    Renumber-BBoxes
    Save-ManualBBoxSessionState
}

function Move-SelectedStep {
    param([int]$Direction)
    $selected = @(Get-SelectedBBoxes | Sort-Object Step)
    if($selected.Count -ne 1){ return }
    $target = $selected[0]
    $ordered = @($script:BBoxes | Sort-Object Step)
    $index = [Array]::IndexOf($ordered,$target)
    if($index -lt 0){ return }
    $swapIndex = $index + $Direction
    if($swapIndex -lt 0 -or $swapIndex -ge $ordered.Count){ return }
    $other = $ordered[$swapIndex]
    $tmp = $target.Step
    $target.Step = $other.Step
    $other.Step = $tmp
    Renumber-BBoxes
    Save-ManualBBoxSessionState
}

function Prepare-CropBitmap {
    param([System.Drawing.Bitmap]$Bitmap)
    $prepared = New-Object System.Drawing.Bitmap $Bitmap.Width,$Bitmap.Height
    $g = [System.Drawing.Graphics]::FromImage($prepared)
    $g.Clear([System.Drawing.Color]::White)
    $attributes = New-Object System.Drawing.Imaging.ImageAttributes
    $matrix = New-Object System.Drawing.Imaging.ColorMatrix
    $matrix.Matrix00 = 1.4
    $matrix.Matrix11 = 1.4
    $matrix.Matrix22 = 1.4
    $matrix.Matrix40 = -0.1
    $matrix.Matrix41 = -0.1
    $matrix.Matrix42 = -0.1
    $attributes.SetColorMatrix($matrix)
    $g.DrawImage($Bitmap,(New-Object System.Drawing.Rectangle(0,0,$prepared.Width,$prepared.Height)),0,0,$Bitmap.Width,$Bitmap.Height,[System.Drawing.GraphicsUnit]::Pixel,$attributes)
    $g.Dispose()
    $attributes.Dispose()
    return $prepared
}

function Prepare-InvertedCropBitmap {
    param([System.Drawing.Bitmap]$Bitmap)
    $prepared = New-Object System.Drawing.Bitmap $Bitmap.Width,$Bitmap.Height
    $g = [System.Drawing.Graphics]::FromImage($prepared)
    $attributes = New-Object System.Drawing.Imaging.ImageAttributes
    $matrix = New-Object System.Drawing.Imaging.ColorMatrix
    $matrix.Matrix00 = -1
    $matrix.Matrix11 = -1
    $matrix.Matrix22 = -1
    $matrix.Matrix40 = 1
    $matrix.Matrix41 = 1
    $matrix.Matrix42 = 1
    $attributes.SetColorMatrix($matrix)
    $g.DrawImage($Bitmap,(New-Object System.Drawing.Rectangle(0,0,$prepared.Width,$prepared.Height)),0,0,$Bitmap.Width,$Bitmap.Height,[System.Drawing.GraphicsUnit]::Pixel,$attributes)
    $g.Dispose()
    $attributes.Dispose()
    return $prepared
}

function Rotate-Bitmap90 {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Mode
    )
    $clone = New-Object System.Drawing.Bitmap $Bitmap
    switch($Mode){
        '90' { $clone.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
        '270' { $clone.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
    }
    return $clone
}

function Run-OcrOnRectangle {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [System.Drawing.Rectangle]$Rect,
        [switch]$Aggressive
    )
    $cropRect = Clamp-RectToBitmap $Rect $Bitmap
    $crop = $Bitmap.Clone($cropRect,$Bitmap.PixelFormat)
    try{
        $bestText = ''
        $bestScore = [double]::NegativeInfinity
        $vertical = ($cropRect.Height -gt ($cropRect.Width * 1.25))
        $scales = if($Aggressive){ @(2,3,4,6,8) } else { @(3,4,6) }
        $scaleBitmaps = New-Object System.Collections.ArrayList
        try{
            foreach($scale in $scales){
                $scaled = New-Object System.Drawing.Bitmap ([Math]::Max(1,$crop.Width * $scale)),([Math]::Max(1,$crop.Height * $scale))
                $g = [System.Drawing.Graphics]::FromImage($scaled)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($crop,0,0,$scaled.Width,$scaled.Height)
                $g.Dispose()
                [void]$scaleBitmaps.Add([PSCustomObject]@{ Bitmap = $scaled; Label = ('raw-' + $scale) })
                $prepared = Prepare-CropBitmap $scaled
                [void]$scaleBitmaps.Add([PSCustomObject]@{ Bitmap = $prepared; Label = ('prep-' + $scale) })
                if($Aggressive){
                    $inverted = Prepare-InvertedCropBitmap $scaled
                    [void]$scaleBitmaps.Add([PSCustomObject]@{ Bitmap = $inverted; Label = ('invert-' + $scale) })
                }
            }

            $candidates = New-Object System.Collections.ArrayList
            foreach($entry in @($scaleBitmaps)){
                [void]$candidates.Add($entry)
                if($vertical){
                    [void]$candidates.Add([PSCustomObject]@{ Bitmap = (Rotate-Bitmap90 $entry.Bitmap '90'); Label = ($entry.Label + '-90') })
                    [void]$candidates.Add([PSCustomObject]@{ Bitmap = (Rotate-Bitmap90 $entry.Bitmap '270'); Label = ($entry.Label + '-270') })
                }
            }

            foreach($candidate in @($candidates)){
                $tempPath = Join-Path $env:TEMP ('rapidocr_manual_bbox_' + [guid]::NewGuid().ToString('N') + '.png')
                try{
                    $candidate.Bitmap.Save($tempPath,[System.Drawing.Imaging.ImageFormat]::Png)
                    $engineTexts = @(
                        [PSCustomObject]@{ Engine = 'WindowsOCR'; Text = (Get-WindowsOcrTextFromImagePath $tempPath) },
                        [PSCustomObject]@{ Engine = 'RapidOCR'; Text = (Get-RapidOcrTextFromImagePath $tempPath) },
                        [PSCustomObject]@{ Engine = 'PaddleOCR'; Text = (Get-PaddleOcrTextFromImagePath $tempPath) }
                    )
                    foreach($engineResult in @($engineTexts)){
                        $ocrText = [string]$engineResult.Text
                        if([string]::IsNullOrWhiteSpace($ocrText)){ continue }
                        $score = 0
                        $clean = Clean-OcrText $ocrText
                        $mechanical = Normalize-MechanicalOcrTextLite $ocrText
                        if($clean -match '\d'){ $score += 8 }
                        if($clean -match '\d+\.\d+'){ $score += 8 }
                        if($clean -match '[±+\-]'){ $score += 6 }
                        if($clean -match '(?i)[RCØ]'){ $score += 4 }
                        if($clean -match '\d+\.\d+\s*[+\-±]'){ $score += 4 }
                        if($mechanical -match '\d+\.\d+'){ $score += 3 }
                        if($engineResult.Engine -eq 'RapidOCR'){ $score += 2 }
                        if($engineResult.Engine -eq 'PaddleOCR'){ $score += 1 }
                        if($Aggressive -and $candidate.Label -match '^invert-'){ $score += 1 }
                        if($clean.Length -gt 0){ $score += [Math]::Min(24,$clean.Length) }
                        if($candidate.Label -match '^prep-'){ $score += 1 }
                        if($candidate.Label -match '-6'){ $score += 1 }
                        if($candidate.Label -match '-8'){ $score += 1 }
                        if($score -gt $bestScore){
                            $bestScore = $score
                            $bestText = if([string]::IsNullOrWhiteSpace($mechanical)){ $clean } else { $mechanical }
                        }
                    }
                }
                finally{
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                }
            }

            foreach($candidate in @($candidates)){
                try{ if($candidate.Bitmap){ $candidate.Bitmap.Dispose() } } catch{}
            }
        }
        finally{
            foreach($entry in @($scaleBitmaps)){
                try{ if($entry.Bitmap){ $entry.Bitmap.Dispose() } } catch{}
            }
        }

        $nominal = Resolve-NominalFromOcrVariants @($bestText,(Normalize-MechanicalOcrTextLite $bestText),(Clean-OcrText $bestText))
        $tolerance = Parse-Tolerance $bestText $nominal
        $status = Get-OcrStatus $bestText $nominal $tolerance.TolMinus $tolerance.TolPlus
        return [PSCustomObject]@{
            RawText = $bestText
            Nominal = $nominal
            TolMinus = [string]$tolerance.TolMinus
            TolPlus = [string]$tolerance.TolPlus
            Status = $status
        }
    }
    finally{
        $crop.Dispose()
    }
}

function Run-BBoxOcr {
    param(
        $BBox,
        [switch]$Aggressive
    )
    $textLayerMatch = Get-TextLayerMatchForBBox $BBox
    if($textLayerMatch){
        $nominal = Parse-Nominal $textLayerMatch.Text
        $tolerance = Parse-Tolerance $textLayerMatch.Text $nominal
        $BBox.RawText = [string]$textLayerMatch.Text
        $BBox.Nominal = [string]$nominal
        $BBox.TolMinus = [string]$tolerance.TolMinus
        $BBox.TolPlus = [string]$tolerance.TolPlus
        $BBox.Status = [string](Get-OcrStatus $textLayerMatch.Text $nominal $tolerance.TolMinus $tolerance.TolPlus)
        Save-ManualBBoxSessionState
        return
    }
    $bitmap = if($BBox.PageIndex -eq $script:CurrentPageIndex){ Get-CurrentBitmap } else { Get-PageBitmap $BBox.PageIndex }
    if(-not $bitmap){ return }
    $result = Run-OcrOnRectangle -Bitmap $bitmap -Rect $BBox.Rect -Aggressive:$Aggressive
    $BBox.RawText = [string]$result.RawText
    $BBox.Nominal = [string]$result.Nominal
    $BBox.TolMinus = [string]$result.TolMinus
    $BBox.TolPlus = [string]$result.TolPlus
    $BBox.Status = [string]$result.Status
    Save-ManualBBoxSessionState
}

function Run-SelectedOcr {
    $selected = @(Get-SelectedBBoxes | Sort-Object Step)
    if($selected.Count -le 0){ Update-Status 'No bbox selected.'; return }
    foreach($bbox in $selected){
        Update-Status ('Running OCR step ' + $bbox.Step + ' ...')
        [System.Windows.Forms.Application]::DoEvents()
        Run-BBoxOcr $bbox
        $txtDebug.Text = ('Step ' + $bbox.Step + [Environment]::NewLine + 'Raw: ' + $bbox.RawText + [Environment]::NewLine + 'Nominal: ' + $bbox.Nominal + [Environment]::NewLine + 'Tol: ' + $bbox.TolMinus + ' / ' + $bbox.TolPlus)
    }
    Refresh-BBoxTable
    Update-Status ('Run Selected done. ' + $selected.Count + ' bbox processed.')
}

function Rescan-SelectedOcr {
    $selected = @(Get-SelectedBBoxes | Sort-Object Step)
    if($selected.Count -le 0){ Update-Status 'No bbox selected.'; return }
    foreach($bbox in $selected){
        Update-Status ('Rescanning step ' + $bbox.Step + ' ...')
        [System.Windows.Forms.Application]::DoEvents()
        Run-BBoxOcr $bbox -Aggressive
        $txtDebug.Text = ('Rescan step ' + $bbox.Step + [Environment]::NewLine + 'Raw: ' + $bbox.RawText + [Environment]::NewLine + 'Nominal: ' + $bbox.Nominal + [Environment]::NewLine + 'Tol: ' + $bbox.TolMinus + ' / ' + $bbox.TolPlus)
    }
    Refresh-BBoxTable
    Update-Status ('Rescan Selected done. ' + $selected.Count + ' bbox processed.')
}

function Run-AllOcr {
    $all = @($script:BBoxes | Sort-Object PageIndex, Step)
    if($all.Count -le 0){ Update-Status 'No bbox to OCR.'; return }
    foreach($bbox in $all){
        Update-Status ('Running OCR step ' + $bbox.Step + ' / page ' + ($bbox.PageIndex + 1) + ' ...')
        [System.Windows.Forms.Application]::DoEvents()
        Run-BBoxOcr $bbox
    }
    if($all.Count -gt 0){
        $last = $all[-1]
        $txtDebug.Text = ('Last step: ' + $last.Step + [Environment]::NewLine + 'Raw: ' + $last.RawText + [Environment]::NewLine + 'Nominal: ' + $last.Nominal + [Environment]::NewLine + 'Tol: ' + $last.TolMinus + ' / ' + $last.TolPlus)
    }
    Refresh-BBoxTable
    Update-Status ('Run All done. ' + $all.Count + ' bbox processed.')
}

function Rescan-AllProblematicOcr {
    $targets = @($script:BBoxes | Where-Object { $_.Status -in @('WARN','FAIL','PENDING') } | Sort-Object PageIndex, Step)
    if($targets.Count -le 0){ Update-Status 'No WARN/FAIL bbox to rescan.'; return }
    foreach($bbox in $targets){
        Update-Status ('Rescanning step ' + $bbox.Step + ' / page ' + ($bbox.PageIndex + 1) + ' ...')
        [System.Windows.Forms.Application]::DoEvents()
        Run-BBoxOcr $bbox -Aggressive
    }
    if($targets.Count -gt 0){
        $last = $targets[-1]
        $txtDebug.Text = ('Last rescan step: ' + $last.Step + [Environment]::NewLine + 'Raw: ' + $last.RawText + [Environment]::NewLine + 'Nominal: ' + $last.Nominal + [Environment]::NewLine + 'Tol: ' + $last.TolMinus + ' / ' + $last.TolPlus)
    }
    Refresh-BBoxTable
    Update-Status ('Rescan problematic done. ' + $targets.Count + ' bbox processed.')
}

function Focus-SelectedBbox {
    $selected = @(Get-SelectedBBoxes | Sort-Object Step | Select-Object -First 1)
    if($selected.Count -le 0){ return }
    $bbox = $selected[0]
    if($bbox.PageIndex -ne $script:CurrentPageIndex){
        $script:CurrentPageIndex = $bbox.PageIndex
        [void](Get-PageBitmap $script:CurrentPageIndex)
    }
    $canvasRect = Convert-ImageToCanvasRect $bbox.Rect
    $viewport = $canvas.ClientRectangle
    $script:PanX += ($viewport.Width / 2.0) - ($canvasRect.X + ($canvasRect.Width / 2.0))
    $script:PanY += ($viewport.Height / 2.0) - ($canvasRect.Y + ($canvasRect.Height / 2.0))
    $canvas.Invalidate()
}

function Select-NextBbox {
    $ordered = @($script:BBoxes | Sort-Object Step)
    if($ordered.Count -le 0){ return }
    $selected = @(Get-SelectedBBoxes | Sort-Object Step | Select-Object -First 1)
    $next = $ordered[0]
    if($selected.Count -gt 0){
        $index = [Array]::IndexOf($ordered,$selected[0])
        if($index -ge 0){ $next = $ordered[(($index + 1) % $ordered.Count)] }
    }
    Clear-BBoxSelection
    $next.Selected = $true
    Select-GridRowByBBoxes
    Focus-SelectedBbox
}

function Save-BBoxTemplate {
    if($script:BBoxes.Count -le 0){
        [System.Windows.Forms.MessageBox]::Show('No bbox to save.')
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'JSON Template|*.json'
    $dialog.FileName = if($script:CurrentDocumentPath){ ([System.IO.Path]::GetFileNameWithoutExtension($script:CurrentDocumentPath) + '.bbox-template.json') } else { 'bbox-template.json' }
    if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return }
    $items = @()
    foreach($bbox in @($script:BBoxes | Sort-Object Step)){
        $bmp = if($bbox.PageIndex -eq $script:CurrentPageIndex){ Get-CurrentBitmap } else { Get-PageBitmap $bbox.PageIndex }
        if(-not $bmp){ continue }
        $items += [ordered]@{
            step = [int]$bbox.Step
            pageIndex = [int]$bbox.PageIndex
            x = [int]$bbox.Rect.X
            y = [int]$bbox.Rect.Y
            w = [int]$bbox.Rect.Width
            h = [int]$bbox.Rect.Height
            nx = [math]::Round(($bbox.Rect.X / [double]$bmp.Width),6)
            ny = [math]::Round(($bbox.Rect.Y / [double]$bmp.Height),6)
            nw = [math]::Round(($bbox.Rect.Width / [double]$bmp.Width),6)
            nh = [math]::Round(($bbox.Rect.Height / [double]$bmp.Height),6)
        }
    }
    $payload = [ordered]@{
        version = 1
        mode = 'ManualBBoxBatchOCR'
        sourcePath = $script:CurrentDocumentPath
        pageCount = $script:PageCount
        items = $items
    }
    [System.IO.File]::WriteAllText($dialog.FileName,($payload | ConvertTo-Json -Depth 6),[System.Text.Encoding]::UTF8)
    Update-Status ('Template saved: ' + $dialog.FileName)
}

function Load-BBoxTemplate {
    if(-not (Get-CurrentBitmap)){
        [System.Windows.Forms.MessageBox]::Show('Open a PDF or image first.')
        return
    }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'JSON Template|*.json'
    if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return }
    $payload = Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json
    if(-not $payload.items){
        [System.Windows.Forms.MessageBox]::Show('Template is empty.')
        return
    }
    foreach($item in @($payload.items)){
        $pageIndex = [int]$item.pageIndex
        if($pageIndex -ge $script:PageCount){ continue }
        $bmp = if($pageIndex -eq $script:CurrentPageIndex){ Get-CurrentBitmap } else { Get-PageBitmap $pageIndex }
        if(-not $bmp){ continue }
        $x = if($item.PSObject.Properties.Name -contains 'nx'){ [int][Math]::Round(([double]$item.nx * $bmp.Width)) } else { [int]$item.x }
        $y = if($item.PSObject.Properties.Name -contains 'ny'){ [int][Math]::Round(([double]$item.ny * $bmp.Height)) } else { [int]$item.y }
        $w = if($item.PSObject.Properties.Name -contains 'nw'){ [int][Math]::Round(([double]$item.nw * $bmp.Width)) } else { [int]$item.w }
        $h = if($item.PSObject.Properties.Name -contains 'nh'){ [int][Math]::Round(([double]$item.nh * $bmp.Height)) } else { [int]$item.h }
        $rect = Clamp-RectToBitmap (New-Object System.Drawing.Rectangle($x,$y,[Math]::Max(2,$w),[Math]::Max(2,$h))) $bmp
        [void]$script:BBoxes.Add((New-BBoxObject -PageIndex $pageIndex -Rect $rect))
    }
    Renumber-BBoxes
    Refresh-BBoxTable
    Update-Status ('Template loaded: ' + $dialog.FileName)
    Save-ManualBBoxSessionState
}

function Update-Status {
    param([string]$Text)
    $script:StatusText = $Text
    $lblStatus.Text = $Text
}

function Update-PageLabel {
    $lblPage.Text = ('Page ' + ($script:CurrentPageIndex + 1) + ' / ' + [Math]::Max(1,$script:PageCount))
}

function Open-DocumentPath {
    param(
        [string]$Path,
        [switch]$RestoreLastSession
    )
    if([string]::IsNullOrWhiteSpace($Path)){ return }
    if($script:CurrentDocumentPath){
        Save-ManualBBoxSessionState
    }
    if([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.pdf'){ Load-PdfDocument $Path } else { Load-ImageDocument $Path }
    $script:BBoxes.Clear()
    Reset-View
    Refresh-BBoxTable
    Update-PageLabel
    $restored = Restore-ManualBBoxSessionState $Path
    if(-not $restored){
        Update-Status ('Loaded: ' + [System.IO.Path]::GetFileName($Path))
        Save-ManualBBoxSessionState
    }
    elseif($RestoreLastSession){
        Update-Status ('Restored last session: ' + [System.IO.Path]::GetFileName($Path))
    }
}

function Open-Document {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'PDF or Image|*.pdf;*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff|PDF|*.pdf|Image|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff'
    if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return }
    Open-DocumentPath -Path $dialog.FileName
}

function Change-Page {
    param([int]$Delta)
    if($script:PageCount -le 0){ return }
    $newIndex = [Math]::Max(0,[Math]::Min(($script:PageCount - 1),($script:CurrentPageIndex + $Delta)))
    if($newIndex -eq $script:CurrentPageIndex){ return }
    $script:CurrentPageIndex = $newIndex
    [void](Get-PageBitmap $script:CurrentPageIndex)
    Update-PageLabel
    Save-ManualBBoxSessionState
    $canvas.Invalidate()
}

function Refresh-BBoxTable {
    $grid.Rows.Clear()
    foreach($bbox in @($script:BBoxes | Sort-Object Step)){
        $rowIndex = $grid.Rows.Add([string]$bbox.Step,[string]($bbox.PageIndex + 1),[string]$bbox.Rect.X,[string]$bbox.Rect.Y,[string]$bbox.Rect.Width,[string]$bbox.Rect.Height,[string]$bbox.Nominal,[string]$bbox.TolMinus,[string]$bbox.TolPlus,[string]$bbox.Status)
        $row = $grid.Rows[$rowIndex]
        $row.Tag = $bbox.Id
        switch([string]$bbox.Status){
            'OK' { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(220,245,220) }
            'WARN' { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255,244,204) }
            'FAIL' { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(248,215,218) }
            default { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::White }
        }
        if($bbox.Selected){ $row.Selected = $true }
    }
    $lblCount.Text = ('BBox: ' + $script:BBoxes.Count)
    $canvas.Invalidate()
}

function Sync-SelectionFromGrid {
    Clear-BBoxSelection
    foreach($row in @($grid.SelectedRows)){
        $bbox = Get-BBoxById ([string]$row.Tag)
        if($bbox){ $bbox.Selected = $true }
    }
    $canvas.Invalidate()
}

function Select-GridRowByBBoxes {
    $grid.ClearSelection()
    $selectedIds = @((Get-SelectedBBoxes).Id)
    foreach($row in @($grid.Rows)){
        if($selectedIds -contains [string]$row.Tag){ $row.Selected = $true }
    }
}

function Get-BBoxHit {
    param([System.Drawing.Point]$CanvasPoint)
    foreach($bbox in @((Get-CurrentPageBBoxes) | Sort-Object Step -Descending)){
        $canvasRect = Convert-ImageToCanvasRect $bbox.Rect
        $handleRect = [System.Drawing.RectangleF]::new([single]($canvasRect.Right - 10),[single]($canvasRect.Bottom - 10),[single]12,[single]12)
        if($handleRect.Contains([single]$CanvasPoint.X,[single]$CanvasPoint.Y)){
            return [PSCustomObject]@{ BBox = $bbox; Part = 'Resize' }
        }
        if($canvasRect.Contains([single]$CanvasPoint.X,[single]$CanvasPoint.Y)){
            return [PSCustomObject]@{ BBox = $bbox; Part = 'Move' }
        }
    }
    return $null
}

function Draw-BBoxOverlay {
    param(
        [System.Drawing.Graphics]$Graphics,
        $BBox
    )
    $rect = Convert-ImageToCanvasRect $BBox.Rect
    $isSelected = [bool]$BBox.Selected
    $isHovered = ($script:HoveredBboxId -eq $BBox.Id)
    switch([string]$BBox.Status){
        'OK' { $color = [System.Drawing.Color]::LimeGreen }
        'WARN' { $color = [System.Drawing.Color]::Goldenrod }
        'FAIL' { $color = [System.Drawing.Color]::Tomato }
        default { $color = [System.Drawing.Color]::DodgerBlue }
    }
    $penWidth = if($isSelected){ 3 } elseif($isHovered){ 2 } else { 1.5 }
    $pen = New-Object System.Drawing.Pen $color,$penWidth
    $Graphics.DrawRectangle($pen,$rect.X,$rect.Y,$rect.Width,$rect.Height)
    $pen.Dispose()

    $label = [string]$BBox.Step
    if(-not [string]::IsNullOrWhiteSpace([string]$BBox.Nominal)){ $label += ('  ' + [string]$BBox.Nominal) }
    $font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $size = $Graphics.MeasureString($label,$font)
    $labelRect = [System.Drawing.RectangleF]::new([single]$rect.X,[single][Math]::Max(0,($rect.Y - $size.Height - 2)),[single]($size.Width + 8),[single]($size.Height + 2))
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220,$color))
    $Graphics.FillRectangle($brush,$labelRect)
    $Graphics.DrawString($label,$font,[System.Drawing.Brushes]::White,$labelRect.X + 4,$labelRect.Y + 1)
    $brush.Dispose()
    $font.Dispose()

    if($isSelected){
        $handleBrush = New-Object System.Drawing.SolidBrush $color
        $Graphics.FillRectangle($handleBrush,($rect.Right - 8),($rect.Bottom - 8),10,10)
        $handleBrush.Dispose()
    }
}

function Enable-DoubleBufferControl {
    param($Control)
    if(-not $Control){ return }
    try{
        $property = $Control.GetType().GetProperty('DoubleBuffered',[System.Reflection.BindingFlags]'Instance,NonPublic')
        if($property){
            $property.SetValue($Control,$true,$null)
        }
    }
    catch{}
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'RapidOCR Manual BBox Batch OCR - Prototype'
$form.Width = [Math]::Min(1480,[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width)
$form.Height = [Math]::Min(920,[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height)
$form.MinimumSize = [System.Drawing.Size]::new(1100,700)
$form.WindowState = 'Maximized'
$form.StartPosition = 'CenterScreen'
$form.KeyPreview = $true
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$toolStrip = New-Object System.Windows.Forms.ToolStrip
$toolStrip.Dock = 'Top'
$toolStrip.GripStyle = 'Hidden'
$btnOpen = New-Object System.Windows.Forms.ToolStripButton 'Open PDF/Image'
$btnPrev = New-Object System.Windows.Forms.ToolStripButton 'Prev'
$btnNext = New-Object System.Windows.Forms.ToolStripButton 'Next'
$btnRunSelected = New-Object System.Windows.Forms.ToolStripButton 'Run Selected'
$btnRunAll = New-Object System.Windows.Forms.ToolStripButton 'Run All'
$btnRescanSelected = New-Object System.Windows.Forms.ToolStripButton 'Rescan Selected'
$btnRescanBad = New-Object System.Windows.Forms.ToolStripButton 'Rescan Warn/Fail'
$btnDeleteSelected = New-Object System.Windows.Forms.ToolStripButton 'Delete Selected'
$btnSaveTemplate = New-Object System.Windows.Forms.ToolStripButton 'Save Template'
$btnLoadTemplate = New-Object System.Windows.Forms.ToolStripButton 'Load Template'
$btnMoveUp = New-Object System.Windows.Forms.ToolStripButton 'Move Up'
$btnMoveDown = New-Object System.Windows.Forms.ToolStripButton 'Move Down'
$lblPage = New-Object System.Windows.Forms.ToolStripLabel 'Page 0 / 0'
$lblCount = New-Object System.Windows.Forms.ToolStripLabel 'BBox: 0'
$toolStrip.Items.AddRange(@($btnOpen,$btnPrev,$btnNext,(New-Object System.Windows.Forms.ToolStripSeparator),$btnRunSelected,$btnRunAll,$btnRescanSelected,$btnRescanBad,$btnDeleteSelected,(New-Object System.Windows.Forms.ToolStripSeparator),$btnSaveTemplate,$btnLoadTemplate,(New-Object System.Windows.Forms.ToolStripSeparator),$btnMoveUp,$btnMoveDown,(New-Object System.Windows.Forms.ToolStripSeparator),$lblPage,$lblCount))
$form.Controls.Add($toolStrip)

$bboxContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miRunSelected = New-Object System.Windows.Forms.ToolStripMenuItem 'Run Selected OCR'
$miRescanSelected = New-Object System.Windows.Forms.ToolStripMenuItem 'Rescan Selected'
$miDeleteSelected = New-Object System.Windows.Forms.ToolStripMenuItem 'Delete Selected'
$bboxContextMenu.Items.AddRange(@($miRunSelected,$miRescanSelected,(New-Object System.Windows.Forms.ToolStripSeparator),$miDeleteSelected))

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.SplitterDistance = [Math]::Max(720,($form.Width - 380))
$form.Controls.Add($split)

$canvas = New-Object System.Windows.Forms.Panel
$canvas.Dock = 'Fill'
$canvas.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
Enable-DoubleBufferControl $canvas
$split.Panel1.Controls.Add($canvas)

$rightPanel = New-Object System.Windows.Forms.TableLayoutPanel
$rightPanel.Dock = 'Fill'
$rightPanel.RowCount = 3
$rightPanel.ColumnCount = 1
$rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,120)))
$rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100)))
$rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,140)))
$split.Panel2.Controls.Add($rightPanel)

$txtHelp = New-Object System.Windows.Forms.TextBox
$txtHelp.Multiline = $true
$txtHelp.ReadOnly = $true
$txtHelp.Dock = 'Fill'
$txtHelp.Font = New-Object System.Drawing.Font('Consolas',10)
$txtHelp.Text = @"
Manual BBox Batch OCR Mode

Ctrl + D     duplicate bbox
Enter        OCR selected
Shift+Enter  OCR all
Ctrl+R       rescan selected
Delete       delete selected
Right click  selected menu / blank undo last
Middle drag  pan drawing
Esc          cancel draft bbox
Tab          next bbox
Ctrl+Up/Down reorder
Mouse drag   create / move bbox
Resize       drag bottom-right handle
Wheel        zoom
Shift+click  multi select
Auto restore last source/session
"@
$rightPanel.Controls.Add($txtHelp,0,0)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'Fill'
$null = $grid.Columns.Add('Step','Step')
$null = $grid.Columns.Add('Page','Page')
$null = $grid.Columns.Add('X','X')
$null = $grid.Columns.Add('Y','Y')
$null = $grid.Columns.Add('W','W')
$null = $grid.Columns.Add('H','H')
$null = $grid.Columns.Add('Nominal','Nominal')
$null = $grid.Columns.Add('TolMinus','Tol -')
$null = $grid.Columns.Add('TolPlus','Tol +')
$null = $grid.Columns.Add('Status','Status')
$grid.Columns['Step'].FillWeight = 12
$grid.Columns['Page'].FillWeight = 10
$grid.Columns['X'].Visible = $false
$grid.Columns['Y'].Visible = $false
$grid.Columns['W'].Visible = $false
$grid.Columns['H'].Visible = $false
$grid.Columns['Nominal'].FillWeight = 42
$grid.Columns['TolMinus'].FillWeight = 16
$grid.Columns['TolPlus'].FillWeight = 16
$grid.Columns['Status'].FillWeight = 16
$rightPanel.Controls.Add($grid,0,1)

$bottomPanel = New-Object System.Windows.Forms.Panel
$bottomPanel.Dock = 'Fill'
$rightPanel.Controls.Add($bottomPanel,0,2)

$txtDebug = New-Object System.Windows.Forms.TextBox
$txtDebug.Multiline = $true
$txtDebug.ReadOnly = $true
$txtDebug.Dock = 'Fill'
$txtDebug.ScrollBars = 'Vertical'
$bottomPanel.Controls.Add($txtDebug)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel $script:StatusText
$statusStrip.Items.Add($lblStatus) | Out-Null
$form.Controls.Add($statusStrip)

$btnOpen.Add_Click({ Open-Document; $canvas.Focus() })
$btnPrev.Add_Click({ Change-Page -1; $canvas.Focus() })
$btnNext.Add_Click({ Change-Page 1; $canvas.Focus() })
$btnRunSelected.Add_Click({ Run-SelectedOcr; $canvas.Focus() })
$btnRunAll.Add_Click({ Run-AllOcr; $canvas.Focus() })
$btnRescanSelected.Add_Click({ Rescan-SelectedOcr; $canvas.Focus() })
$btnRescanBad.Add_Click({ Rescan-AllProblematicOcr; $canvas.Focus() })
$btnDeleteSelected.Add_Click({ Remove-SelectedBBoxes; Refresh-BBoxTable; $canvas.Focus() })
$btnSaveTemplate.Add_Click({ Save-BBoxTemplate; $canvas.Focus() })
$btnLoadTemplate.Add_Click({ Load-BBoxTemplate; $canvas.Focus() })
$btnMoveUp.Add_Click({ Move-SelectedStep -1; Refresh-BBoxTable; $canvas.Focus() })
$btnMoveDown.Add_Click({ Move-SelectedStep 1; Refresh-BBoxTable; $canvas.Focus() })
$miRunSelected.Add_Click({ Run-SelectedOcr; $canvas.Focus() })
$miRescanSelected.Add_Click({ Rescan-SelectedOcr; $canvas.Focus() })
$miDeleteSelected.Add_Click({ Remove-SelectedBBoxes; Refresh-BBoxTable; $canvas.Focus() })

$grid.Add_SelectionChanged({ Sync-SelectionFromGrid })
$grid.Add_CellDoubleClick({ Focus-SelectedBbox })

$canvas.Add_Paint({
    $bmp = Get-CurrentBitmap
    $_.Graphics.Clear([System.Drawing.Color]::FromArgb(30,30,30))
    if(-not $bmp){ return }
    $imageRect = Get-CanvasImageRectangle $bmp
    $_.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $_.Graphics.DrawImage($bmp,$imageRect)
    foreach($bbox in @(Get-CurrentPageBBoxes)){ Draw-BBoxOverlay -Graphics $_.Graphics -BBox $bbox }
    if($script:DragMode -eq 'Create' -and $script:CreateStartImagePoint -and $script:LastMouseCanvasPoint){
        $currentImagePoint = Convert-CanvasPointToImagePoint $script:LastMouseCanvasPoint
        $rect = Get-NormalizedRect $script:CreateStartImagePoint $currentImagePoint
        $canvasRect = Convert-ImageToCanvasRect $rect
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Cyan),1.5
        $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
        $_.Graphics.DrawRectangle($pen,$canvasRect.X,$canvasRect.Y,$canvasRect.Width,$canvasRect.Height)
        $pen.Dispose()
    }
})

$canvas.Add_MouseWheel({
    if(-not (Get-CurrentBitmap)){ return }
    if($_.Delta -gt 0){ $script:Zoom = [Math]::Min(10.0,($script:Zoom * 1.12)) } else { $script:Zoom = [Math]::Max(0.08,($script:Zoom / 1.12)) }
    $before = Convert-CanvasPointToImagePoint $_.Location
    $script:PanX = $_.Location.X - ($before.X * $script:Zoom)
    $script:PanY = $_.Location.Y - ($before.Y * $script:Zoom)
    $canvas.Invalidate()
})

$canvas.Add_MouseDown({
    $canvas.Focus()
    $script:LastMouseCanvasPoint = $_.Location
    if(-not (Get-CurrentBitmap)){ return }
    $hit = Get-BBoxHit $_.Location
    if($_.Button -eq [System.Windows.Forms.MouseButtons]::Middle){
        $script:DragMode = 'Pan'
        $script:DragStartCanvasPoint = $_.Location
        $canvas.Cursor = [System.Windows.Forms.Cursors]::Hand
        return
    }
    if($_.Button -eq [System.Windows.Forms.MouseButtons]::Right){
        if($script:DragMode -eq 'Create' -and $script:CreateStartImagePoint){
            Cancel-CurrentDraftBBox
            return
        }
        if($hit -and $hit.BBox){
            if(-not $hit.BBox.Selected){
                Select-BBox -Id $hit.BBox.Id
                Select-GridRowByBBoxes
                $canvas.Invalidate()
            }
            $bboxContextMenu.Show($canvas,$_.Location)
            return
        }
        Undo-LastBBox
        return
    }
    if($hit){
        if(([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -eq [System.Windows.Forms.Keys]::Shift){
            Select-BBox -Id $hit.BBox.Id -Toggle
        }
        else{
            if(-not $hit.BBox.Selected){ Select-BBox -Id $hit.BBox.Id }
        }
        Select-GridRowByBBoxes
        $script:DragStartCanvasPoint = $_.Location
        $script:DragTargetIds = @((Get-SelectedBBoxes).Id)
        if($hit.Part -eq 'Resize'){
            $script:DragMode = 'Resize'
            $script:ActiveResizeAnchor = $hit.BBox.Id
        }
        else{
            $script:DragMode = 'Move'
        }
        $canvas.Invalidate()
        return
    }
    Clear-BBoxSelection
    Select-GridRowByBBoxes
    $script:CreateStartImagePoint = Convert-CanvasPointToImagePoint $_.Location
    $script:DragMode = 'Create'
    $canvas.Invalidate()
})

$canvas.Add_MouseMove({
    $script:LastMouseCanvasPoint = $_.Location
    if($script:DragMode -eq 'Pan' -and $script:DragStartCanvasPoint){
        $script:PanX += ($_.Location.X - $script:DragStartCanvasPoint.X)
        $script:PanY += ($_.Location.Y - $script:DragStartCanvasPoint.Y)
        $script:DragStartCanvasPoint = $_.Location
        $canvas.Cursor = [System.Windows.Forms.Cursors]::Hand
        $canvas.Invalidate()
        return
    }
    $hit = Get-BBoxHit $_.Location
    $script:HoveredBboxId = if($hit){ $hit.BBox.Id } else { $null }
    if($script:DragMode -eq 'Move' -and $script:DragStartCanvasPoint){
        $dx = [int][Math]::Round(($_.Location.X - $script:DragStartCanvasPoint.X) / $script:Zoom)
        $dy = [int][Math]::Round(($_.Location.Y - $script:DragStartCanvasPoint.Y) / $script:Zoom)
        $bmp = Get-CurrentBitmap
        foreach($id in @($script:DragTargetIds)){
            $bbox = Get-BBoxById $id
            if($bbox -and $bbox.PageIndex -eq $script:CurrentPageIndex){
                $newRect = New-Object System.Drawing.Rectangle(($bbox.Rect.X + $dx),($bbox.Rect.Y + $dy),$bbox.Rect.Width,$bbox.Rect.Height)
                $bbox.Rect = Clamp-RectToBitmap $newRect $bmp
            }
        }
        $script:DragStartCanvasPoint = $_.Location
        Refresh-BBoxTable
        return
    }
    if($script:DragMode -eq 'Resize' -and $script:ActiveResizeAnchor){
        $bbox = Get-BBoxById $script:ActiveResizeAnchor
        if($bbox){
            $bmp = Get-CurrentBitmap
            $imagePoint = Convert-CanvasPointToImagePoint $_.Location
            $right = [int][Math]::Round($imagePoint.X)
            $bottom = [int][Math]::Round($imagePoint.Y)
            $newRect = New-Object System.Drawing.Rectangle($bbox.Rect.X,$bbox.Rect.Y,[Math]::Max(2,($right - $bbox.Rect.X)),[Math]::Max(2,($bottom - $bbox.Rect.Y)))
            $bbox.Rect = Clamp-RectToBitmap $newRect $bmp
            Refresh-BBoxTable
            return
        }
    }
    $canvas.Invalidate()
})

$canvas.Add_MouseUp({
    if($script:DragMode -eq 'Pan'){
        $script:DragMode = $null
        $script:DragStartCanvasPoint = $null
        $canvas.Cursor = [System.Windows.Forms.Cursors]::Default
        Save-ManualBBoxSessionState
        return
    }
    if($script:DragMode -eq 'Create' -and $script:CreateStartImagePoint){
        $bmp = Get-CurrentBitmap
        $endPoint = Convert-CanvasPointToImagePoint $_.Location
        $rect = Get-NormalizedRect $script:CreateStartImagePoint $endPoint
        $rect = Clamp-RectToBitmap $rect $bmp
        if($rect.Width -gt 6 -and $rect.Height -gt 6){
            $bbox = New-BBoxObject -PageIndex $script:CurrentPageIndex -Rect $rect
            $bbox | Add-Member -NotePropertyName Selected -NotePropertyValue $true -Force
            [void]$script:BBoxes.Add($bbox)
            Renumber-BBoxes
            Refresh-BBoxTable
            Select-GridRowByBBoxes
            Update-Status ('BBox created on page ' + ($script:CurrentPageIndex + 1))
        }
    }
    else{
        Refresh-BBoxTable
        Select-GridRowByBBoxes
    }
    Save-ManualBBoxSessionState
    $script:DragMode = $null
    $script:CreateStartImagePoint = $null
    $script:DragStartCanvasPoint = $null
    $script:DragTargetIds = @()
    $script:ActiveResizeAnchor = $null
    $canvas.Cursor = [System.Windows.Forms.Cursors]::Default
    $canvas.Invalidate()
})

$form.Add_KeyDown({
    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){
        Cancel-CurrentDraftBBox
        $_.SuppressKeyPress = $true
        return
    }
    if($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::R){
        Rescan-SelectedOcr
        $_.SuppressKeyPress = $true
        return
    }
    if($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::D){
        Duplicate-SelectedBBoxes
        Refresh-BBoxTable
        Select-GridRowByBBoxes
        $_.SuppressKeyPress = $true
        return
    }
    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Delete){
        Remove-SelectedBBoxes
        Refresh-BBoxTable
        $_.SuppressKeyPress = $true
        return
    }
    if($_.Shift -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Enter){
        Run-AllOcr
        $_.SuppressKeyPress = $true
        return
    }
    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter){
        Run-SelectedOcr
        $_.SuppressKeyPress = $true
        return
    }
    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Tab){
        Select-NextBbox
        Select-GridRowByBBoxes
        $_.SuppressKeyPress = $true
        return
    }
    if($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Up){
        Move-SelectedStep -1
        Refresh-BBoxTable
        $_.SuppressKeyPress = $true
        return
    }
    if($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Down){
        Move-SelectedStep 1
        Refresh-BBoxTable
        $_.SuppressKeyPress = $true
        return
    }
})

$form.Add_Shown({
    try{ Restore-LastManualBBoxSession } catch{}
})

$form.Add_FormClosing({
    try{ Save-ManualBBoxSessionState } catch{}
    Dispose-Document
})

Reset-View
Update-PageLabel
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)

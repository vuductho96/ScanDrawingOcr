Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RenderCacheRoot = Join-Path $script:AppRoot "ai-drawing-render-cache"
$script:ChromeAiUrl = "https://www.google.com/search?q=&sourceid=chrome&ie=UTF-8&udm=50&aep=48&cud=0&source=chrome.crn.obic"
$script:PdfiumAvailable = $false
$script:JpegCodecInfo = $null
$script:CurrentSourcePath = $null
$script:DocumentPages = @()
$script:CurrentPageIndex = 0
$script:StepCounter = 0
$script:IsBusy = $false
$script:ChromeProcessId = $null
$script:SourceFingerprintCache = @{}
$script:AutoSendWholePageOnOpen = $true

if(!(Test-Path $script:RenderCacheRoot)){
    New-Item -Path $script:RenderCacheRoot -ItemType Directory -Force | Out-Null
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AiDrawingWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@

function Write-Status([string]$message){
    if($script:txtStatus){
        $script:txtStatus.AppendText(([DateTime]::Now.ToString("HH:mm:ss") + " " + $message + [Environment]::NewLine))
        $script:txtStatus.SelectionStart = $script:txtStatus.TextLength
        $script:txtStatus.ScrollToCaret()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Busy($busy,[string]$message = ""){
    $script:IsBusy = [bool]$busy
    foreach($control in @($script:btnOpen,$script:btnExtract,$script:btnExportExcel,$script:btnExportPdf)){
        if($control){ $control.Enabled = -not $busy }
    }
    if($script:btnResetChrome){ $script:btnResetChrome.Enabled = $true }
    if($script:lblState){ $script:lblState.Text = if($busy){ $message } else { "Ready" } }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-SourceFingerprint($sourcePath){
    if([string]::IsNullOrWhiteSpace($sourcePath) -or !(Test-Path -LiteralPath $sourcePath)){ return $null }
    $item = Get-Item -LiteralPath $sourcePath -ErrorAction SilentlyContinue
    if(!$item){ return $null }
    $cacheKey = ([string]$item.FullName).ToUpperInvariant()
    $stamp = ([string]$item.Length) + "|" + ([string]$item.LastWriteTimeUtc.Ticks)
    if($script:SourceFingerprintCache.ContainsKey($cacheKey)){
        $cached = $script:SourceFingerprintCache[$cacheKey]
        if($cached -and [string]$cached.Stamp -eq $stamp){ return [string]$cached.Fingerprint }
    }
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $stream = $null
    try{
        $stream = [System.IO.File]::OpenRead($sourcePath)
        $bytes = $sha1.ComputeHash($stream)
        $fingerprint = ([System.BitConverter]::ToString($bytes)).Replace("-","").ToLowerInvariant()
        $script:SourceFingerprintCache[$cacheKey] = [PSCustomObject]@{ Stamp = $stamp; Fingerprint = $fingerprint }
        return $fingerprint
    }
    finally{
        if($stream){ $stream.Dispose() }
        $sha1.Dispose()
    }
}

function Get-SafeCacheLabel($path){
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$path)
    if([string]::IsNullOrWhiteSpace($baseName)){ $baseName = "document" }
    return ([regex]::Replace($baseName,'[\\/:*?"<>|]+','_')).Trim()
}

function Initialize-PdfiumRuntime{
    if($script:PdfiumAvailable){ return $true }
    $pdfiumDll = Join-Path $script:AppRoot "PdfiumViewer.dll"
    if(!(Test-Path -LiteralPath $pdfiumDll)){ return $false }
    $env:PATH = $script:AppRoot + ";" + $env:PATH
    try{
        [void][System.Reflection.Assembly]::LoadFrom($pdfiumDll)
        $script:PdfiumAvailable = $true
        return $true
    }
    catch{
        Write-Status ("Pdfium load failed: " + $_.Exception.Message)
        return $false
    }
}

function Convert-PdfToImages($pdfPath){
    if(-not (Initialize-PdfiumRuntime)){ throw "Pdfium runtime unavailable." }
    $fingerprint = Get-SourceFingerprint $pdfPath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ throw "Cannot fingerprint source." }
    $cacheDir = Join-Path $script:RenderCacheRoot ((Get-SafeCacheLabel $pdfPath) + "__" + $fingerprint)
    if(!(Test-Path $cacheDir)){ New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }
    $cached = @(Get-ChildItem -LiteralPath $cacheDir -Filter "page-*.jpg" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if($cached.Count -gt 0){ return @($cached.FullName) }

    $pagePaths = New-Object System.Collections.Generic.List[string]
    $doc = $null
    try{
        $doc = [PdfiumViewer.PdfDocument]::Load($pdfPath)
        for($pageIndex = 0; $pageIndex -lt $doc.PageSizes.Count; $pageIndex++){
            $pageSize = $doc.PageSizes[$pageIndex]
            $dpi = 220.0
            $width = [Math]::Max(1,[int][Math]::Round(($pageSize.Width / 72.0) * $dpi))
            $height = [Math]::Max(1,[int][Math]::Round(($pageSize.Height / 72.0) * $dpi))
            $image = $doc.Render($pageIndex,$width,$height,$dpi,$dpi,[PdfiumViewer.PdfRenderFlags]::Annotations)
            $outPath = Join-Path $cacheDir ("page-{0:d3}.jpg" -f ($pageIndex + 1))
            try{
                $image.Save($outPath,[System.Drawing.Imaging.ImageFormat]::Jpeg)
                [void]$pagePaths.Add($outPath)
            }
            finally{
                $image.Dispose()
            }
        }
    }
    finally{
        if($doc){ $doc.Dispose() }
    }
    return @($pagePaths)
}

function New-PageRecord($sourcePath,$pageNumber,$imagePath){
    $loaded = $null
    try{
        $loaded = [System.Drawing.Bitmap]::FromFile($imagePath)
        $bitmap = New-Object System.Drawing.Bitmap $loaded
        return [PSCustomObject]@{
            SourcePath = $sourcePath
            PageNumber = $pageNumber
            ImagePath = $imagePath
            Bitmap = $bitmap
            Entries = New-Object System.Collections.Generic.List[object]
        }
    }
    finally{
        if($loaded){ $loaded.Dispose() }
    }
}

function Clear-DocumentPages{
    foreach($page in @($script:DocumentPages)){
        try{ if($page.Bitmap){ $page.Bitmap.Dispose() } } catch{}
    }
    $script:DocumentPages = @()
    if($script:pageList){ $script:pageList.Items.Clear() }
}

function Load-SourceFile($path){
    Clear-DocumentPages
    $script:CurrentSourcePath = $path
    $script:CurrentPageIndex = 0
    $script:StepCounter = 0
    $script:grid.Rows.Clear()
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    $pagePaths = if($ext -eq ".pdf"){ @(Convert-PdfToImages $path) } else { @($path) }
    $records = New-Object System.Collections.Generic.List[object]
    $pageNo = 1
    foreach($pagePath in $pagePaths){
        [void]$records.Add((New-PageRecord $path $pageNo $pagePath))
        [void]$script:pageList.Items.Add(("Page " + $pageNo))
        $pageNo++
    }
    $script:DocumentPages = @($records)
    if($script:pageList.Items.Count -gt 0){ $script:pageList.SelectedIndex = 0 }
    Write-Status ("Loaded " + $script:DocumentPages.Count + " page(s).")
}

function Get-CurrentPage{
    if($script:CurrentPageIndex -lt 0 -or $script:CurrentPageIndex -ge $script:DocumentPages.Count){ return $null }
    return $script:DocumentPages[$script:CurrentPageIndex]
}

function Get-DisplayRect($bitmapWidth,$bitmapHeight,$clientWidth,$clientHeight){
    if($bitmapWidth -le 0 -or $bitmapHeight -le 0){ return [Drawing.RectangleF]::Empty }
    $zoom = [Math]::Min(($clientWidth / [double]$bitmapWidth),($clientHeight / [double]$bitmapHeight))
    $drawWidth = $bitmapWidth * $zoom
    $drawHeight = $bitmapHeight * $zoom
    return [Drawing.RectangleF]::new([float](($clientWidth - $drawWidth) / 2.0),[float](($clientHeight - $drawHeight) / 2.0),[float]$drawWidth,[float]$drawHeight)
}

function Refresh-Preview{
    if($script:picture){ $script:picture.Invalidate() }
}

function Test-DarkPixel($color){
    $brightness = (($color.R * 0.299) + ($color.G * 0.587) + ($color.B * 0.114))
    return ($brightness -lt 190)
}

function Merge-Rectangles($rects,[int]$padX = 12,[int]$padY = 8){
    $list = New-Object System.Collections.Generic.List[System.Drawing.Rectangle]
    foreach($rect in @($rects)){
        if(!$rect){ continue }
        $candidate = New-Object System.Drawing.Rectangle ([Math]::Max(0,$rect.X - $padX)),([Math]::Max(0,$rect.Y - $padY)),($rect.Width + ($padX * 2)),($rect.Height + ($padY * 2))
        $merged = $false
        for($i = 0; $i -lt $list.Count; $i++){
            $existing = $list[$i]
            if($existing.IntersectsWith($candidate) -or [Math]::Abs($existing.Right - $candidate.X) -lt $padX -or [Math]::Abs($candidate.Right - $existing.X) -lt $padX){
                $list[$i] = [System.Drawing.Rectangle]::Union($existing,$candidate)
                $merged = $true
                break
            }
        }
        if(-not $merged){ [void]$list.Add($candidate) }
    }
    $changed = $true
    while($changed){
        $changed = $false
        for($i = 0; $i -lt $list.Count; $i++){
            for($j = $i + 1; $j -lt $list.Count; $j++){
                if($list[$i].IntersectsWith($list[$j])){
                    $list[$i] = [System.Drawing.Rectangle]::Union($list[$i],$list[$j])
                    $list.RemoveAt($j)
                    $changed = $true
                    break
                }
            }
            if($changed){ break }
        }
    }
    return @($list)
}

function Get-CandidateRectsFromBitmap($bitmap){
    $rowBands = New-Object System.Collections.Generic.List[object]
    $stepX = [Math]::Max(1,[int][Math]::Round($bitmap.Width / 900.0))
    $stepY = [Math]::Max(1,[int][Math]::Round($bitmap.Height / 1200.0))
    for($y = 0; $y -lt $bitmap.Height; $y += $stepY){
        $minX = $bitmap.Width
        $maxX = -1
        $darkCount = 0
        for($x = 0; $x -lt $bitmap.Width; $x += $stepX){
            if(Test-DarkPixel ($bitmap.GetPixel($x,$y))){
                $darkCount++
                if($x -lt $minX){ $minX = $x }
                if($x -gt $maxX){ $maxX = $x }
            }
        }
        if($darkCount -lt 6){ continue }
        $rowBands.Add([PSCustomObject]@{ Y = $y; MinX = $minX; MaxX = $maxX }) | Out-Null
    }

    $rects = New-Object System.Collections.Generic.List[System.Drawing.Rectangle]
    $active = $null
    foreach($band in @($rowBands | Sort-Object Y)){
        if(!$active){
            $active = [PSCustomObject]@{ MinX = $band.MinX; MaxX = $band.MaxX; Top = $band.Y; Bottom = $band.Y }
            continue
        }
        $xOverlap = -not (($band.MaxX + 30) -lt $active.MinX -or ($band.MinX - 30) -gt $active.MaxX)
        $yClose = (($band.Y - $active.Bottom) -le ([Math]::Max(12,$stepY * 3)))
        if($xOverlap -and $yClose){
            if($band.MinX -lt $active.MinX){ $active.MinX = $band.MinX }
            if($band.MaxX -gt $active.MaxX){ $active.MaxX = $band.MaxX }
            $active.Bottom = $band.Y
        }
        else{
            $rects.Add(([System.Drawing.Rectangle]::new(
                [Math]::Max(0,$active.MinX - 14),
                [Math]::Max(0,$active.Top - 10),
                [Math]::Min($bitmap.Width - [Math]::Max(0,$active.MinX - 14),($active.MaxX - $active.MinX) + 28),
                [Math]::Min($bitmap.Height - [Math]::Max(0,$active.Top - 10),($active.Bottom - $active.Top) + ([Math]::Max(24,$stepY * 4)))
            ))) | Out-Null
            $active = [PSCustomObject]@{ MinX = $band.MinX; MaxX = $band.MaxX; Top = $band.Y; Bottom = $band.Y }
        }
    }
    if($active){
        $rects.Add(([System.Drawing.Rectangle]::new(
            [Math]::Max(0,$active.MinX - 14),
            [Math]::Max(0,$active.Top - 10),
            [Math]::Min($bitmap.Width - [Math]::Max(0,$active.MinX - 14),($active.MaxX - $active.MinX) + 28),
            [Math]::Min($bitmap.Height - [Math]::Max(0,$active.Top - 10),($active.Bottom - $active.Top) + ([Math]::Max(24,$stepY * 4)))
        ))) | Out-Null
    }

    $filtered = @(
        $rects |
        Where-Object {
            $_.Width -ge 40 -and $_.Height -ge 14 -and
            $_.Width -le ($bitmap.Width * 0.75) -and
            $_.Height -le ($bitmap.Height * 0.20)
        }
    )
    return @(Merge-Rectangles $filtered 10 8 | Sort-Object Y,X)
}

function Save-CropBitmapToTemp($bitmap,$rect){
    $safeRect = [System.Drawing.Rectangle]::Intersect(([System.Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height)),$rect)
    if($safeRect.Width -le 2 -or $safeRect.Height -le 2){ return $null }
    $crop = $null
    try{
        $crop = $bitmap.Clone($safeRect,$bitmap.PixelFormat)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-drawing-crop-" + [guid]::NewGuid().ToString("N") + ".png")
        $crop.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
        return $path
    }
    finally{
        if($crop){ $crop.Dispose() }
    }
}

function Get-ChromeExecutablePath{
    foreach($candidate in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
        "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
    )){
        if(Test-Path -LiteralPath $candidate){ return $candidate }
    }
    $command = Get-Command chrome -ErrorAction SilentlyContinue
    if($command){ return $command.Source }
    return $null
}

function Get-ChromeProcessWindow{
    $processes = @(Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if($script:ChromeProcessId){
        $hit = @($processes | Where-Object { $_.Id -eq $script:ChromeProcessId } | Select-Object -First 1)
        if($hit.Count -gt 0){ return $hit[0] }
    }
    return @($processes | Select-Object -First 1)[0]
}

function Activate-ChromeWindow([int]$waitMs = 4000){
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while($sw.ElapsedMilliseconds -lt $waitMs){
        $process = Get-ChromeProcessWindow
        if($process -and $process.MainWindowHandle -ne 0){
            [AiDrawingWin32]::ShowWindowAsync([intptr]$process.MainWindowHandle,5) | Out-Null
            Start-Sleep -Milliseconds 80
            if([AiDrawingWin32]::SetForegroundWindow([intptr]$process.MainWindowHandle)){
                Start-Sleep -Milliseconds 350
                return $true
            }
        }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

function Reset-ChromeSession{
    try{
        if($script:ChromeProcessId){ Stop-Process -Id $script:ChromeProcessId -Force -ErrorAction SilentlyContinue }
    } catch{}
    $script:ChromeProcessId = $null
}

function Open-ChromeAiPage{
    $chrome = Get-ChromeExecutablePath
    if(!$chrome){ throw "Chrome not found." }
    if((Get-ChromeProcessWindow) -and (Activate-ChromeWindow 2200)){ return }
    $started = Start-Process -FilePath $chrome -ArgumentList '--new-window',$script:ChromeAiUrl -PassThru
    if($started){ $script:ChromeProcessId = [int]$started.Id }
    Start-Sleep -Milliseconds 2200
    if(-not (Activate-ChromeWindow 5000)){ throw "Could not activate Chrome." }
}

function Set-ClipboardImageFromPath($imagePath){
    $bitmap = $null
    $clone = $null
    try{
        $bitmap = [System.Drawing.Bitmap]::FromFile($imagePath)
        $clone = New-Object System.Drawing.Bitmap $bitmap
        [System.Windows.Forms.Clipboard]::SetImage($clone)
        return $true
    } catch {
        return $false
    } finally {
        if($clone){ $clone.Dispose() }
        if($bitmap){ $bitmap.Dispose() }
    }
}

function Set-ClipboardTextSafe([string]$text){
    try{ [System.Windows.Forms.Clipboard]::SetText([string]$text); return $true } catch { return $false }
}

function Get-ClipboardTextSafe{
    try{ if([System.Windows.Forms.Clipboard]::ContainsText()){ return [string][System.Windows.Forms.Clipboard]::GetText() } } catch {}
    return ""
}

function Send-KeysWithPause([string]$keys,[int]$pauseMs = 300){
    [System.Windows.Forms.SendKeys]::SendWait($keys)
    Start-Sleep -Milliseconds $pauseMs
}

function Get-GoogleDimensionPrompt{
    return @"
Read one cropped mechanical drawing region.
If this crop does not contain a single dimension / fit callout / nominal, reply exactly:
SKIP

If it does contain one dimension, reply exactly one line:
FINAL: Nominal=<value> Tol+=<value> Tol-=<value>

Rules:
- Keep mechanical prefixes/symbols in Nominal when present: R, C, Ø, Φ, °, A, B, MAX, MIN.
- Use engineering judgment to infer the most likely correct reading.
- Keep the original signs exactly.
- If no tolerance is shown, use Tol+=0 Tol-=0.
- No explanation.
"@
}

function Parse-GoogleDimensionResult($text){
    $result = [PSCustomObject]@{ Success = $false; Skip = $false; Raw = ""; Nominal = ""; TolPlus = ""; TolMinus = "" }
    if([string]::IsNullOrWhiteSpace([string]$text)){ return $result }
    $clean = (($text -replace '\s+',' ').Trim())
    if($clean -match '^\s*SKIP\s*$'){ $result.Skip = $true; return $result }
    $match = [regex]::Match($clean,'FINAL\s*:\s*Nominal\s*=\s*(.+?)\s+Tol\+\s*=\s*([+\-]?\d+(?:\.\d+)?)\s+Tol-\s*=\s*([+\-]?\d+(?:\.\d+)?)','IgnoreCase')
    if(!$match.Success){ return $result }
    $result.Success = $true
    $result.Raw = ("FINAL: Nominal=" + $match.Groups[1].Value.Trim() + " Tol+=" + $match.Groups[2].Value + " Tol-=" + $match.Groups[3].Value)
    $result.Nominal = $match.Groups[1].Value.Trim()
    $result.TolPlus = $match.Groups[2].Value
    $result.TolMinus = $match.Groups[3].Value
    return $result
}

function Invoke-GoogleAiForImage($imagePath){
    if(-not (Set-ClipboardImageFromPath $imagePath)){ throw "Cannot copy image to clipboard." }
    Open-ChromeAiPage
    Send-KeysWithPause '{TAB}' 180
    Send-KeysWithPause '+{TAB}' 180
    Send-KeysWithPause '^v' 1200
    if(-not (Set-ClipboardTextSafe (Get-GoogleDimensionPrompt))){ throw "Cannot copy prompt." }
    Send-KeysWithPause '^v' 400
    Send-KeysWithPause '{ENTER}' 1400

    $lastText = ""
    for($i = 0; $i -lt 10; $i++){
        Start-Sleep -Milliseconds 1500
        Send-KeysWithPause '^a' 120
        Send-KeysWithPause '^c' 220
        $lastText = Get-ClipboardTextSafe
        $parsed = Parse-GoogleDimensionResult $lastText
        if($parsed.Success -or $parsed.Skip){ return $parsed }
    }
    throw ("Google AI did not return FINAL/SKIP. Clipboard=" + (($lastText -replace '\s+',' ').Trim()))
}

function Get-GoogleWholeDrawingPrompt{
    return @"
Read this whole mechanical drawing page.
List all dimensions / callouts you can clearly identify.
Keep mechanical symbols such as R, C, Ø, Φ, °, A, B.
Return concise plain text only. No markdown table.
"@
}

function Send-CurrentPageToGoogleAi{
    $page = Get-CurrentPage
    if(!$page -or [string]::IsNullOrWhiteSpace([string]$page.ImagePath) -or !(Test-Path -LiteralPath $page.ImagePath)){
        throw "Current page image not available."
    }
    if(-not (Set-ClipboardImageFromPath $page.ImagePath)){ throw "Cannot copy page image to clipboard." }
    Open-ChromeAiPage
    Send-KeysWithPause '{TAB}' 180
    Send-KeysWithPause '+{TAB}' 180
    Send-KeysWithPause '^v' 1300
    if(-not (Set-ClipboardTextSafe (Get-GoogleWholeDrawingPrompt))){ throw "Cannot copy whole drawing prompt." }
    Send-KeysWithPause '^v' 420
    Write-Status ("Sent full page " + $page.PageNumber + " to Google AI.")
}

function Test-EntryDuplicate($page,$rect,$nominal){
    foreach($entry in @($page.Entries)){
        if([string]$entry.Nominal -ne [string]$nominal){ continue }
        $intersection = [System.Drawing.Rectangle]::Intersect($entry.Rect,$rect)
        if($intersection.Width -gt 0 -and $intersection.Height -gt 0){ return $true }
    }
    return $false
}

function Add-EntryToPage($pageIndex,$rect,$result){
    $script:StepCounter++
    $entry = [PSCustomObject]@{
        Step = $script:StepCounter
        PageIndex = $pageIndex
        Rect = $rect
        Nominal = [string]$result.Nominal
        TolMinus = [string]$result.TolMinus
        TolPlus = [string]$result.TolPlus
        Raw = [string]$result.Raw
        Source = "Google AI"
    }
    $page = $script:DocumentPages[$pageIndex]
    [void]$page.Entries.Add($entry)
    [void]$script:grid.Rows.Add($entry.Step,($pageIndex + 1),$entry.Nominal,$entry.TolMinus,$entry.TolPlus,$entry.Source)
}

function Auto-ExtractAll{
    if($script:DocumentPages.Count -le 0){ return }
    Set-Busy $true "Auto extracting with Google AI..."
    try{
        $script:grid.Rows.Clear()
        $script:StepCounter = 0
        foreach($page in @($script:DocumentPages)){ $page.Entries.Clear() }

        for($pageIndex = 0; $pageIndex -lt $script:DocumentPages.Count; $pageIndex++){
            $page = $script:DocumentPages[$pageIndex]
            $script:CurrentPageIndex = $pageIndex
            if($script:pageList.SelectedIndex -ne $pageIndex){ $script:pageList.SelectedIndex = $pageIndex }
            Write-Status ("Scanning page " + ($pageIndex + 1) + "...")
            $candidateRects = @(Get-CandidateRectsFromBitmap $page.Bitmap)
            Write-Status ("Found " + $candidateRects.Count + " candidate regions.")
            $candidateNumber = 0
            foreach($rect in $candidateRects){
                $candidateNumber++
                $tempPath = Save-CropBitmapToTemp $page.Bitmap $rect
                if([string]::IsNullOrWhiteSpace([string]$tempPath)){ continue }
                try{
                    Write-Status ("Page " + ($pageIndex + 1) + " / candidate " + $candidateNumber + "...")
                    $result = Invoke-GoogleAiForImage $tempPath
                    if($result.Skip -or -not $result.Success){ continue }
                    if(Test-EntryDuplicate $page $rect $result.Nominal){ continue }
                    Add-EntryToPage $pageIndex $rect $result
                    Refresh-Preview
                }
                catch{
                    Write-Status ("Candidate failed: " + $_.Exception.Message)
                }
                finally{
                    try{ Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } catch{}
                }
            }
        }
        Write-Status ("Done. Extracted " + $script:StepCounter + " step(s).")
    }
    finally{
        Set-Busy $false
        Refresh-Preview
    }
}

function Get-AllEntries{
    $all = New-Object System.Collections.Generic.List[object]
    foreach($page in @($script:DocumentPages)){
        foreach($entry in @($page.Entries)){ [void]$all.Add($entry) }
    }
    return @($all | Sort-Object Step)
}

function Export-ToExcel{
    $entries = @(Get-AllEntries)
    if($entries.Count -le 0){ throw "No extracted rows." }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "Excel Workbook|*.xlsx"
    $dialog.FileName = "AI Drawing Extractor.xlsx"
    if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return }
    $excel = $null; $wb = $null; $ws = $null
    try{
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $wb = $excel.Workbooks.Add()
        $ws = $wb.Worksheets.Item(1)
        $headers = @("Step","Page","Nominal","Tol-","Tol+","Source","Raw")
        for($i = 0; $i -lt $headers.Count; $i++){
            $ws.Cells.Item(1,$i + 1) = $headers[$i]
            $ws.Cells.Item(1,$i + 1).Font.Bold = $true
        }
        $row = 2
        foreach($entry in $entries){
            $ws.Cells.Item($row,1) = [int]$entry.Step
            $ws.Cells.Item($row,2) = [int]$entry.PageIndex + 1
            $ws.Cells.Item($row,3) = [string]$entry.Nominal
            $ws.Cells.Item($row,4) = [string]$entry.TolMinus
            $ws.Cells.Item($row,5) = [string]$entry.TolPlus
            $ws.Cells.Item($row,6) = [string]$entry.Source
            $ws.Cells.Item($row,7) = [string]$entry.Raw
            $row++
        }
        $ws.Columns.AutoFit() | Out-Null
        $wb.SaveAs($dialog.FileName,51)
        Write-Status ("Saved Excel: " + $dialog.FileName)
    }
    finally{
        if($wb){ $wb.Close($true) | Out-Null }
        if($excel){ $excel.Quit() }
        foreach($com in @($ws,$wb,$excel)){
            try{ if($com){ [System.Runtime.InteropServices.Marshal]::ReleaseComObject($com) | Out-Null } } catch{}
        }
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
    }
}

function Get-JpegCodecInfo{
    if($script:JpegCodecInfo){ return $script:JpegCodecInfo }
    $script:JpegCodecInfo = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    return $script:JpegCodecInfo
}

function Get-JpegBytesFromBitmap($bitmap,[long]$quality = 82L){
    $stream = New-Object System.IO.MemoryStream
    $encoderParams = $null
    try{
        $codec = Get-JpegCodecInfo
        if($codec){
            $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality,$quality)
            $bitmap.Save($stream,$codec,$encoderParams)
        } else {
            $bitmap.Save($stream,[System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        return $stream.ToArray()
    }
    finally{
        if($encoderParams){ $encoderParams.Dispose() }
        $stream.Dispose()
    }
}

function Get-AsciiBytes([string]$text){
    return [System.Text.Encoding]::ASCII.GetBytes([string]$text)
}

function Format-Decimal([double]$value){
    return $value.ToString("0.###",[System.Globalization.CultureInfo]::InvariantCulture)
}

function New-AnnotatedPageBitmap($page){
    $bmp = New-Object System.Drawing.Bitmap $page.Bitmap
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Red,3)
    $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220,255,245,160))
    $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
    try{
        foreach($entry in @($page.Entries)){
            $g.DrawRectangle($pen,$entry.Rect)
            $balloon = [System.Drawing.Rectangle]::new([Math]::Max(0,$entry.Rect.X + $entry.Rect.Width - 24),[Math]::Max(0,$entry.Rect.Y - 26),28,28)
            $g.FillEllipse($fill,$balloon)
            $g.DrawEllipse($pen,$balloon)
            $font = New-Object System.Drawing.Font("Arial",12,[System.Drawing.FontStyle]::Bold)
            try{ $g.DrawString([string]$entry.Step,$font,$textBrush,[float]$balloon.X + 4,[float]$balloon.Y + 3) } finally { $font.Dispose() }
        }
        return $bmp
    }
    finally{
        $pen.Dispose(); $fill.Dispose(); $textBrush.Dispose(); $g.Dispose()
    }
}

function Export-ToPdf{
    $entries = @(Get-AllEntries)
    if($entries.Count -le 0){ throw "No extracted rows." }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "PDF|*.pdf"
    $dialog.FileName = "AI Drawing Extractor.pdf"
    if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return }
    $stream = $null
    $pageInfos = @()
    $nextObjectId = 1
    foreach($page in @($script:DocumentPages)){
        $pageInfos += [PSCustomObject]@{ ImageObjectId = $nextObjectId; ContentObjectId = $nextObjectId + 1; PageObjectId = $nextObjectId + 2; Page = $page }
        $nextObjectId += 3
    }
    $pagesObjectId = $nextObjectId
    $catalogObjectId = $nextObjectId + 1
    try{
        $stream = [System.IO.File]::Open($dialog.FileName,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        $stream.Write((Get-AsciiBytes "%PDF-1.4`n"),0,9)
        $stream.Write([byte[]](37,226,227,207,211,10),0,6)
        $offsets = @{}
        foreach($pageInfo in $pageInfos){
            $bmp = $null
            try{
                $bmp = New-AnnotatedPageBitmap $pageInfo.Page
                $imageBytes = Get-JpegBytesFromBitmap $bmp 82L
                $offsets[$pageInfo.ImageObjectId] = [int64]$stream.Position
                $imageHeader = Get-AsciiBytes ("{0} 0 obj`n<<`n/Type /XObject`n/Subtype /Image`n/Width {1}`n/Height {2}`n/ColorSpace /DeviceRGB`n/BitsPerComponent 8`n/Filter /DCTDecode`n/Length {3}`n>>`nstream`n" -f $pageInfo.ImageObjectId,$bmp.Width,$bmp.Height,$imageBytes.Length)
                $stream.Write($imageHeader,0,$imageHeader.Length)
                $stream.Write($imageBytes,0,$imageBytes.Length)
                $stream.Write((Get-AsciiBytes "`nendstream`nendobj`n"),0,18)

                $content = @("q",("{0} 0 0 {1} 0 0 cm" -f (Format-Decimal $bmp.Width),(Format-Decimal $bmp.Height)),"/Im0 Do","Q") -join [Environment]::NewLine
                $contentBytes = Get-AsciiBytes ($content + [Environment]::NewLine)
                $offsets[$pageInfo.ContentObjectId] = [int64]$stream.Position
                $contentHeader = Get-AsciiBytes ("{0} 0 obj`n<<`n/Length {1}`n>>`nstream`n" -f $pageInfo.ContentObjectId,$contentBytes.Length)
                $stream.Write($contentHeader,0,$contentHeader.Length)
                $stream.Write($contentBytes,0,$contentBytes.Length)
                $stream.Write((Get-AsciiBytes "endstream`nendobj`n"),0,17)

                $offsets[$pageInfo.PageObjectId] = [int64]$stream.Position
                $pageObj = @(
                    ("{0} 0 obj" -f $pageInfo.PageObjectId),"<<","/Type /Page","/Parent $pagesObjectId 0 R",
                    ("/MediaBox [0 0 {0} {1}]" -f (Format-Decimal $bmp.Width),(Format-Decimal $bmp.Height)),
                    "/Resources << /XObject << /Im0 $($pageInfo.ImageObjectId) 0 R >> >>",
                    "/Contents $($pageInfo.ContentObjectId) 0 R",">>","endobj"
                ) -join [Environment]::NewLine
                $pageBytes = Get-AsciiBytes ($pageObj + [Environment]::NewLine)
                $stream.Write($pageBytes,0,$pageBytes.Length)
            }
            finally{
                if($bmp){ $bmp.Dispose() }
            }
        }
        $kids = (($pageInfos | ForEach-Object { "$($_.PageObjectId) 0 R" }) -join " ")
        $offsets[$pagesObjectId] = [int64]$stream.Position
        $pagesObj = Get-AsciiBytes (("$pagesObjectId 0 obj`n<<`n/Type /Pages`n/Count {0}`n/Kids [ {1} ]`n>>`nendobj`n" -f $pageInfos.Count,$kids))
        $stream.Write($pagesObj,0,$pagesObj.Length)
        $offsets[$catalogObjectId] = [int64]$stream.Position
        $catalogObj = Get-AsciiBytes (("$catalogObjectId 0 obj`n<<`n/Type /Catalog`n/Pages $pagesObjectId 0 R`n>>`nendobj`n"))
        $stream.Write($catalogObj,0,$catalogObj.Length)
        $xrefStart = [int64]$stream.Position
        $maxObjectId = $catalogObjectId
        $xref = Get-AsciiBytes ("xref`n0 {0}`n0000000000 65535 f `n" -f ($maxObjectId + 1))
        $stream.Write($xref,0,$xref.Length)
        for($id = 1; $id -le $maxObjectId; $id++){
            $offset = if($offsets.ContainsKey($id)){ [int64]$offsets[$id] } else { 0 }
            $line = Get-AsciiBytes (("{0:0000000000} 00000 n `n" -f $offset))
            $stream.Write($line,0,$line.Length)
        }
        $trailer = Get-AsciiBytes (("trailer`n<<`n/Size {0}`n/Root {1} 0 R`n>>`nstartxref`n{2}`n%%EOF" -f ($maxObjectId + 1),$catalogObjectId,$xrefStart))
        $stream.Write($trailer,0,$trailer.Length)
        Write-Status ("Saved PDF: " + $dialog.FileName)
    }
    finally{
        if($stream){ $stream.Dispose() }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "AI Drawing Extractor"
$form.Width = 1360
$form.Height = 860
$form.StartPosition = "CenterScreen"

$script:btnOpen = New-Object System.Windows.Forms.Button
$script:btnOpen.Text = "Open PDF/Image"
$script:btnOpen.Location = New-Object System.Drawing.Point(12,12)
$script:btnOpen.Size = New-Object System.Drawing.Size(120,34)
$form.Controls.Add($script:btnOpen)

$script:btnExtract = New-Object System.Windows.Forms.Button
$script:btnExtract.Text = "Auto Extract"
$script:btnExtract.Location = New-Object System.Drawing.Point(142,12)
$script:btnExtract.Size = New-Object System.Drawing.Size(110,34)
$form.Controls.Add($script:btnExtract)

$script:btnExportExcel = New-Object System.Windows.Forms.Button
$script:btnExportExcel.Text = "Export Excel"
$script:btnExportExcel.Location = New-Object System.Drawing.Point(262,12)
$script:btnExportExcel.Size = New-Object System.Drawing.Size(110,34)
$form.Controls.Add($script:btnExportExcel)

$script:btnExportPdf = New-Object System.Windows.Forms.Button
$script:btnExportPdf.Text = "Export PDF"
$script:btnExportPdf.Location = New-Object System.Drawing.Point(382,12)
$script:btnExportPdf.Size = New-Object System.Drawing.Size(100,34)
$form.Controls.Add($script:btnExportPdf)

$script:btnResetChrome = New-Object System.Windows.Forms.Button
$script:btnResetChrome.Text = "Reset Chrome"
$script:btnResetChrome.Location = New-Object System.Drawing.Point(492,12)
$script:btnResetChrome.Size = New-Object System.Drawing.Size(110,34)
$form.Controls.Add($script:btnResetChrome)

$script:btnSendPage = New-Object System.Windows.Forms.Button
$script:btnSendPage.Text = "Send Page AI"
$script:btnSendPage.Location = New-Object System.Drawing.Point(612,12)
$script:btnSendPage.Size = New-Object System.Drawing.Size(110,34)
$form.Controls.Add($script:btnSendPage)

$script:lblState = New-Object System.Windows.Forms.Label
$script:lblState.Text = "Ready"
$script:lblState.Location = New-Object System.Drawing.Point(740,18)
$script:lblState.Size = New-Object System.Drawing.Size(380,22)
$form.Controls.Add($script:lblState)

$script:pageList = New-Object System.Windows.Forms.ListBox
$script:pageList.Location = New-Object System.Drawing.Point(12,60)
$script:pageList.Size = New-Object System.Drawing.Size(120,250)
$form.Controls.Add($script:pageList)

$script:picture = New-Object System.Windows.Forms.PictureBox
$script:picture.Location = New-Object System.Drawing.Point(142,60)
$script:picture.Size = New-Object System.Drawing.Size(760,740)
$script:picture.BorderStyle = "FixedSingle"
$script:picture.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($script:picture)

$script:grid = New-Object System.Windows.Forms.DataGridView
$script:grid.Location = New-Object System.Drawing.Point(912,60)
$script:grid.Size = New-Object System.Drawing.Size(420,500)
$script:grid.AllowUserToAddRows = $false
$script:grid.RowHeadersVisible = $false
$script:grid.SelectionMode = "FullRowSelect"
$script:grid.AutoSizeColumnsMode = "Fill"
[void]$script:grid.Columns.Add("Step","Step")
[void]$script:grid.Columns.Add("Page","Page")
[void]$script:grid.Columns.Add("Nominal","Nominal")
[void]$script:grid.Columns.Add("TolMinus","Tol-")
[void]$script:grid.Columns.Add("TolPlus","Tol+")
[void]$script:grid.Columns.Add("Source","Source")
$form.Controls.Add($script:grid)

$script:txtStatus = New-Object System.Windows.Forms.TextBox
$script:txtStatus.Location = New-Object System.Drawing.Point(912,570)
$script:txtStatus.Size = New-Object System.Drawing.Size(420,230)
$script:txtStatus.Multiline = $true
$script:txtStatus.ScrollBars = "Vertical"
$script:txtStatus.ReadOnly = $true
$form.Controls.Add($script:txtStatus)

$script:pageList.Add_SelectedIndexChanged({
    if($script:pageList.SelectedIndex -ge 0){
        $script:CurrentPageIndex = $script:pageList.SelectedIndex
        Refresh-Preview
    }
})

$script:picture.Add_Paint({
    try{
        $page = Get-CurrentPage
        if(!$page -or !$page.Bitmap){ return }
        $displayRect = Get-DisplayRect $page.Bitmap.Width $page.Bitmap.Height $script:picture.ClientSize.Width $script:picture.ClientSize.Height
        $_.Graphics.Clear([System.Drawing.Color]::White)
        $_.Graphics.DrawImage($page.Bitmap,$displayRect)
        $scaleX = $displayRect.Width / [double]$page.Bitmap.Width
        $scaleY = $displayRect.Height / [double]$page.Bitmap.Height
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Red,2)
        $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220,255,245,160))
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
        try{
            foreach($entry in @($page.Entries)){
                $rect = $entry.Rect
                $drawRect = [System.Drawing.RectangleF]::new([float]($displayRect.X + ($rect.X * $scaleX)),[float]($displayRect.Y + ($rect.Y * $scaleY)),[float]($rect.Width * $scaleX),[float]($rect.Height * $scaleY))
                $_.Graphics.DrawRectangle($pen,$drawRect.X,$drawRect.Y,$drawRect.Width,$drawRect.Height)
                $balloon = [System.Drawing.RectangleF]::new([float]($drawRect.Right - 18),[float]($drawRect.Top - 22),26,26)
                $_.Graphics.FillEllipse($fill,$balloon)
                $_.Graphics.DrawEllipse($pen,$balloon)
                $font = New-Object System.Drawing.Font("Arial",10,[System.Drawing.FontStyle]::Bold)
                try{ $_.Graphics.DrawString([string]$entry.Step,$font,$textBrush,[float]$balloon.X + 5,[float]$balloon.Y + 4) } finally { $font.Dispose() }
            }
        }
        finally{
            $pen.Dispose(); $fill.Dispose(); $textBrush.Dispose()
        }
    }
    catch{
        Write-Status ("Preview draw failed: " + $_.Exception.Message)
    }
})

$script:btnOpen.Add_Click({
    if($script:IsBusy){ return }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "PDF/Image|*.pdf;*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff"
    if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return }
    try{
        Set-Busy $true "Opening source..."
        Load-SourceFile $dialog.FileName
        try{ Refresh-Preview } catch { Write-Status ("Preview refresh failed: " + $_.Exception.Message) }
        if($script:AutoSendWholePageOnOpen){
            Set-Busy $true "Opening source and sending page to Google AI..."
            Send-CurrentPageToGoogleAi
        }
    }
    catch{
        [System.Windows.Forms.MessageBox]::Show("Open failed: " + $_.Exception.Message)
    }
    finally{
        Set-Busy $false
    }
})

$script:btnSendPage.Add_Click({
    try{
        Send-CurrentPageToGoogleAi
    }
    catch{
        [System.Windows.Forms.MessageBox]::Show("Send page failed: " + $_.Exception.Message)
    }
})

$script:btnExtract.Add_Click({
    try{ Auto-ExtractAll } catch { [System.Windows.Forms.MessageBox]::Show("Auto extract failed: " + $_.Exception.Message); Set-Busy $false }
})

$script:btnExportExcel.Add_Click({
    try{ Export-ToExcel } catch { [System.Windows.Forms.MessageBox]::Show("Export Excel failed: " + $_.Exception.Message) }
})

$script:btnExportPdf.Add_Click({
    try{ Export-ToPdf } catch { [System.Windows.Forms.MessageBox]::Show("Export PDF failed: " + $_.Exception.Message) }
})

$script:btnResetChrome.Add_Click({
    Reset-ChromeSession
    Write-Status "Chrome session reset."
})

$form.Add_FormClosing({
    Reset-ChromeSession
    Clear-DocumentPages
})

[void]$form.ShowDialog()

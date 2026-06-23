Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
$script:AppRoot = $PSScriptRoot
if([string]::IsNullOrWhiteSpace($script:AppRoot)){
    try{
        $script:AppRoot = [System.AppDomain]::CurrentDomain.BaseDirectory
    }
    catch{}
}
if([string]::IsNullOrWhiteSpace($script:AppRoot)){
    try{
        $script:AppRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }
    catch{}
}
if([string]::IsNullOrWhiteSpace($script:AppRoot)){
    $script:AppRoot = (Get-Location).Path
}

$script:StartupSplashForm = $null
$script:StartupSplashStatusLabel = $null
$script:StartupUiReady = $false
$script:StartupReadyTimer = $null
$script:ImportantStepSaveTimer = $null

function Show-StartupSplash{

    if($script:StartupSplashForm){ return }

    $form = New-Object Windows.Forms.Form
    $form.Text = "RapidOCR"
    $form.Size = New-Object Drawing.Size(430,150)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::White
    $form.ShowInTaskbar = $true

    $title = New-Object Windows.Forms.Label
    $title.Text = "RapidOCR PDF Scan Tool"
    $title.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(22,24)
    $form.Controls.Add($title)

    $status = New-Object Windows.Forms.Label
    $status.Text = "Loading..."
    $status.Font = New-Object System.Drawing.Font("Segoe UI",10)
    $status.AutoSize = $true
    $status.Location = New-Object Drawing.Point(24,72)
    $form.Controls.Add($status)

    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progress.MarqueeAnimationSpeed = 28
    $progress.Location = New-Object Drawing.Point(24,98)
    $progress.Size = New-Object Drawing.Size(380,18)
    $form.Controls.Add($progress)

    $script:StartupSplashForm = $form
    $script:StartupSplashStatusLabel = $status
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-StartupSplashStatus([string]$text){
    if($script:StartupSplashStatusLabel){
        $script:StartupSplashStatusLabel.Text = if([string]::IsNullOrWhiteSpace([string]$text)){ "Loading..." } else { [string]$text }
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Close-StartupSplash{
    if($script:StartupSplashForm){
        try{ $script:StartupSplashForm.Close() } catch{}
        try{ $script:StartupSplashForm.Dispose() } catch{}
    }
    $script:StartupSplashForm = $null
    $script:StartupSplashStatusLabel = $null
}

function Close-ExternalStartupSplash{
    try{
        $splashPath = Join-Path $script:AppRoot "RapidOcrStartupSplash.hta"
        $escapedSplashPath = [regex]::Escape($splashPath)

        $candidates = @(
            Get-CimInstance Win32_Process -Filter "Name = 'mshta.exe'" -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.CommandLine -match $escapedSplashPath }
        )

        foreach($proc in $candidates){
            try{
                [void](Invoke-CimMethod -InputObject $proc -MethodName Terminate -Arguments @{} -ErrorAction Stop)
            }
            catch{}
        }
    }
    catch{}
}

Show-StartupSplash
Update-StartupSplashStatus "Loading core modules..."

$pdfiumViewerAssemblyPath = Join-Path $script:AppRoot "PdfiumViewer.dll"
$pdfiumDependencyPaths = @(
    $pdfiumViewerAssemblyPath,
    (Join-Path $script:AppRoot "x64\pdfium.dll"),
    (Join-Path $script:AppRoot "x86\pdfium.dll")
)
$script:PdfiumAvailable = $false
$script:PdfiumRuntimeInitialized = $false
$script:ShowPdfTextZones = $false
$script:PdfTextLayerZones = @()
$script:TextZoneCacheKey = $null
$script:TextZoneCacheResolved = $false
$script:SelectedTextZoneIndex = -1
$script:IsDraggingTextZone = $false
$script:TextZoneDragMode = $null
$script:TextZoneDragStartPoint = $null
$script:TextZoneDragStartRect = $null
$script:ImageOcrAutoCacheKey = $null
$script:ImageOcrAutoCandidates = @()
$script:ImageOcrAutoZones = @()
$script:HiddenTextZoneHoverIndex = -1
$script:HiddenTextZoneHoverCandidate = $null
$script:HiddenTextZoneMinScore = 12.0
$script:SuppressedTextZoneRects = @()

function Initialize-PdfiumRuntime{
    if($script:PdfiumRuntimeInitialized){ return $script:PdfiumAvailable }

    foreach($path in @($pdfiumDependencyPaths)){
        if(Test-Path $path){
            try{
                Unblock-File -Path $path -ErrorAction Stop
            }
            catch{}
        }
    }

    if(Test-Path $pdfiumViewerAssemblyPath){
        try{
            [void][System.Reflection.Assembly]::LoadFrom($pdfiumViewerAssemblyPath)
            $script:PdfiumAvailable = $true
        }
        catch{
            $script:PdfiumAvailable = $false
        }
    }

    $script:PdfiumRuntimeInitialized = $true
    return $script:PdfiumAvailable
}


function Initialize-WindowsOcrRuntime{
    if($script:WindowsOcrRuntimeAvailable){ return $true }
    if($script:WindowsOcrRuntimeUnavailable){ return $false }

    try{
        try{ Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop } catch{}
        [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
        [Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime] | Out-Null
        [Windows.Graphics.Imaging.SoftwareBitmap,Windows.Graphics.Imaging,ContentType=WindowsRuntime] | Out-Null
        [Windows.Media.Ocr.OcrEngine,Windows.Media.Ocr,ContentType=WindowsRuntime] | Out-Null

        $script:WinRtAsTaskGenericMethod = @(
            [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.IsGenericMethodDefinition -and
                $_.GetParameters().Count -eq 1
            }
        )[0]

        if(!$script:WinRtAsTaskGenericMethod){ throw 'WinRT AsTask<T> method not found' }

        $script:WindowsOcrRuntimeAvailable = $true
        return $true
    }
    catch{
        $script:WindowsOcrRuntimeUnavailable = $true
        $script:WindowsOcrRuntimeAvailable = $false
        return $false
    }
}

function Await($asyncOp,$type){
    if(!$asyncOp){ return $null }
    if(-not (Initialize-WindowsOcrRuntime)){ return $null }

    $generic = $script:WinRtAsTaskGenericMethod.MakeGenericMethod($type)
    $task = $generic.Invoke($null,@($asyncOp))
    $task.Wait()
    return $task.Result
}

function Get-WindowsOcrResultFromImagePath($imagePath){
    if([string]::IsNullOrWhiteSpace([string]$imagePath) -or !(Test-Path -LiteralPath $imagePath)){ return $null }
    if(-not (Initialize-WindowsOcrRuntime)){ return $null }

    $stream = $null
    $bitmap = $null
    try{
        $resolvedPath = (Resolve-Path -LiteralPath $imagePath).Path
        $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($resolvedPath)) ([Windows.Storage.StorageFile])
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
    catch{
        return $null
    }
    finally{
        try{ if($stream){ $stream.Dispose() } } catch{}
    }
}

function Invoke-WindowsOcrHelperFromImagePath($imagePath,[switch]$Detailed){
    $emptyResult = [PSCustomObject]@{ Text = ""; Lines = @() }
    if([string]::IsNullOrWhiteSpace([string]$imagePath) -or !(Test-Path -LiteralPath $imagePath)){ return $emptyResult }

    $helperPath = Join-Path $script:AppRoot "WindowsOcr_Helper.ps1"
    if(!(Test-Path -LiteralPath $helperPath)){
        $helperPath = Join-Path (Get-Location).Path "WindowsOcr_Helper.ps1"
    }
    if(!(Test-Path -LiteralPath $helperPath)){ return $emptyResult }

    $powershell51 = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    if(!(Test-Path -LiteralPath $powershell51)){ return $emptyResult }

    try{
        $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$helperPath,"-ImagePath",(Resolve-Path -LiteralPath $imagePath).Path)
        if($Detailed){ $args += "-Detailed" }
        $json = & $powershell51 @args 2>$null
        $jsonText = ($json | Out-String).Trim()
        if([string]::IsNullOrWhiteSpace($jsonText)){ return $emptyResult }
        $parsed = $jsonText | ConvertFrom-Json
        if(!$parsed){ return $emptyResult }
        return $parsed
    }
    catch{
        return $emptyResult
    }
}

function Run-WindowsOcrTextFromImagePath($imagePath){
    $result = Get-WindowsOcrResultFromImagePath $imagePath
    if($result -and $result.Text){ return ([string]$result.Text).Trim() }

    $helperResult = Invoke-WindowsOcrHelperFromImagePath $imagePath
    if($helperResult -and $helperResult.Text){ return ([string]$helperResult.Text).Trim() }
    return ""
}

function Run-WindowsOcrDetailedFromImagePath($imagePath){
    $emptyResult = [PSCustomObject]@{
        Text = ""
        Lines = @()
    }

    $result = Get-WindowsOcrResultFromImagePath $imagePath
    if(!$result){
        $helperResult = Invoke-WindowsOcrHelperFromImagePath $imagePath -Detailed
        if($helperResult -and -not [string]::IsNullOrWhiteSpace([string]$helperResult.Text)){
            return $helperResult
        }
        return $emptyResult
    }

    $lines = @()
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
            Rect = (New-Object Drawing.RectangleF(
                [float]$left,
                [float]$top,
                [float][Math]::Max(1.0,($right - $left)),
                [float][Math]::Max(1.0,($bottom - $top))
            ))
        }
    }

    return [PSCustomObject]@{
        Text = [string]$result.Text
        Lines = @($lines)
    }
}

function Enable-DoubleBuffer($control){

    if(!$control){ return }

    try{
        $doubleBufferedProperty = $control.GetType().GetProperty(
            "DoubleBuffered",
            [System.Reflection.BindingFlags]("Instance,NonPublic")
        )

        if($doubleBufferedProperty){
            $doubleBufferedProperty.SetValue($control,$true,$null)
        }
    }
    catch{}
}

function Write-TextFileSafe($path,$content){

    if([string]::IsNullOrWhiteSpace($path)){ return $false }

    $directory = [System.IO.Path]::GetDirectoryName($path)
    if(-not [string]::IsNullOrWhiteSpace($directory) -and !(Test-Path $directory)){
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)

    for($attempt = 0; $attempt -lt 5; $attempt++){
        try{
            [System.IO.File]::WriteAllText($path,$content,$encoding)
            return $true
        }
        catch [System.IO.IOException]{
            Start-Sleep -Milliseconds (40 * ($attempt + 1))
        }
        catch{
            return $false
        }
    }

    return $false
}

function Format-InvariantDecimal($value,$format = "0.###"){

    return ([double]$value).ToString($format,[System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-InvariantSignedTolerance($value){

    return ([double]$value).ToString("+0.###;-0.###;0",[System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DirectorySizeBytes($path){
    if([string]::IsNullOrWhiteSpace($path) -or !(Test-Path $path)){ return 0L }
    $total = 0L
    foreach($file in Get-ChildItem -Path $path -File -Recurse -ErrorAction SilentlyContinue){
        $total += [int64]$file.Length
    }
    return $total
}

function Remove-PathQuietly($path){
    if([string]::IsNullOrWhiteSpace($path) -or !(Test-Path $path)){ return }
    try{ Remove-Item -Path $path -Recurse -Force -ErrorAction Stop } catch{}
}

function Get-CacheFingerprintFromPath($cachePath){

    if([string]::IsNullOrWhiteSpace($cachePath)){ return $null }

    $name = [System.IO.Path]::GetFileName($cachePath)
    if([string]::IsNullOrWhiteSpace($name)){ return $null }

    $normalizedName = [System.Text.RegularExpressions.Regex]::Replace($name,'(?i)__backup$','')
    $separatorIndex = $normalizedName.LastIndexOf("__",[System.StringComparison]::Ordinal)
    if($separatorIndex -lt 0){ return $null }

    $fingerprint = $normalizedName.Substring($separatorIndex + 2).Trim()
    if($fingerprint -match '^[0-9a-fA-F]{40}$'){
        return $fingerprint.ToLowerInvariant()
    }

    return $null
}

function Invoke-CacheCleanup{
    if(!(Test-Path $script:SessionStoreDir)){ New-Item -Path $script:SessionStoreDir -ItemType Directory -Force | Out-Null }
    if(!(Test-Path $script:RenderCacheRoot)){ New-Item -Path $script:RenderCacheRoot -ItemType Directory -Force | Out-Null }
}

function Get-RenderCacheBackupDirectoryPath($cacheDir){

    if([string]::IsNullOrWhiteSpace($cacheDir)){ return $null }
    if($cacheDir -match '(?i)__backup$'){
        return $cacheDir
    }
    return ($cacheDir + "__backup")
}

function Backup-RenderCacheDirectory($cacheDir){

    if([string]::IsNullOrWhiteSpace($cacheDir) -or !(Test-Path $cacheDir)){ return }

    $backupDir = Get-RenderCacheBackupDirectoryPath $cacheDir
    if([string]::IsNullOrWhiteSpace($backupDir)){ return }

    try{
        if([string]::Equals($cacheDir,$backupDir,[System.StringComparison]::OrdinalIgnoreCase)){
            return
        }

        Remove-PathQuietly $backupDir
        Copy-Item -Path $cacheDir -Destination $backupDir -Recurse -Force -ErrorAction Stop
        Remove-PathQuietly $cacheDir
    }
    catch{}
}

function Export-ClixmlSafe($path,$inputObject){

    if([string]::IsNullOrWhiteSpace($path)){ return $false }

    $directory = [System.IO.Path]::GetDirectoryName($path)
    if(-not [string]::IsNullOrWhiteSpace($directory) -and !(Test-Path $directory)){
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    for($attempt = 0; $attempt -lt 5; $attempt++){
        try{
            Export-Clixml -Path $path -InputObject $inputObject -Depth 8 -Force
            return $true
        }
        catch [System.IO.IOException]{
            Start-Sleep -Milliseconds (40 * ($attempt + 1))
        }
        catch{
            return $false
        }
    }

    return $false
}

function Import-ClixmlSafe($path){

    if([string]::IsNullOrWhiteSpace($path) -or !(Test-Path $path)){ return $null }

    try{
        return Import-Clixml -Path $path
    }
    catch{
        return $null
    }
}

function ConvertFrom-ClixmlElement($element,[hashtable]$refMap){

    if($null -eq $element){ return $null }

    $name = [string]$element.LocalName
    switch($name){
        "Nil" { return $null }
        "S" { return [string]$element.InnerText }
        "I32" { return [int]$element.InnerText }
        "Db" { return [double]$element.InnerText }
        "B" { return [bool]::Parse($element.InnerText) }
        "Ref" {
            $refId = [string]$element.RefId
            if($refMap.ContainsKey($refId)){ return $refMap[$refId] }
            return $null
        }
        "Obj" {
            $refId = [string]$element.RefId
            $result = $null

            $dictNode = $null
            $listNode = $null
            foreach($child in @($element.ChildNodes)){
                if($child.NodeType -ne [System.Xml.XmlNodeType]::Element){ continue }
                if($child.LocalName -eq "DCT"){ $dictNode = $child; break }
                if($child.LocalName -eq "LST"){ $listNode = $child }
            }

            if($dictNode){
                $result = [ordered]@{}
                if($refId){ $refMap[$refId] = $result }
                foreach($entry in @($dictNode.ChildNodes)){
                    if($entry.NodeType -ne [System.Xml.XmlNodeType]::Element -or $entry.LocalName -ne "En"){ continue }
                    $keyNode = $null
                    $valueNode = $null
                    foreach($entryChild in @($entry.ChildNodes)){
                        if($entryChild.NodeType -ne [System.Xml.XmlNodeType]::Element){ continue }
                        if([string]$entryChild.N -eq "Key"){ $keyNode = $entryChild; continue }
                        if([string]$entryChild.N -eq "Value"){ $valueNode = $entryChild; continue }
                    }
                    $key = ConvertFrom-ClixmlElement $keyNode $refMap
                    $value = ConvertFrom-ClixmlElement $valueNode $refMap
                    if($null -ne $key){ $result[$key] = $value }
                }
                return $result
            }

            if($listNode){
                $result = @()
                if($refId){ $refMap[$refId] = $result }
                foreach($item in @($listNode.ChildNodes)){
                    if($item.NodeType -ne [System.Xml.XmlNodeType]::Element){ continue }
                    $result += ,(ConvertFrom-ClixmlElement $item $refMap)
                }
                return $result
            }

            $result = [ordered]@{}
            if($refId){ $refMap[$refId] = $result }
            return $result
        }
    }

    return [string]$element.InnerText
}

function Import-SessionStateFromClixmlXml($path){

    if([string]::IsNullOrWhiteSpace($path) -or !(Test-Path $path)){ return $null }

    try{
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($path)
        $rootObject = $null
        foreach($child in @($xml.DocumentElement.ChildNodes)){
            if($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -eq "Obj"){
                $rootObject = $child
                break
            }
        }
        if(!$rootObject){ return $null }
        $refMap = @{}
        return ConvertFrom-ClixmlElement $rootObject $refMap
    }
    catch{
        return $null
    }
}

function Get-SessionEntryCount($state){

    if(!$state){ return 0 }

    $total = 0
    $stateDocumentPages = Get-StatePropertyValue $state "DocumentPages"
    foreach($savedPage in @(Convert-SessionValueToList $stateDocumentPages)){
        $pageRows = Get-StatePropertyValue $savedPage "Rows"
        $total += @(Convert-SessionValueToList $pageRows).Count
    }

    if($total -gt 0){ return $total }

    $stateRows = Get-StatePropertyValue $state "Rows"
    return @(Convert-SessionValueToList $stateRows).Count
}

function Get-StateDocumentRowCount($state){

    if(!$state){ return 0 }

    $total = 0
    $stateDocumentPages = Get-StatePropertyValue $state "DocumentPages"
    foreach($savedPage in @(Convert-SessionValueToList $stateDocumentPages)){
        $pageRows = Get-StatePropertyValue $savedPage "Rows"
        $total += @(Convert-SessionValueToList $pageRows).Count
    }

    return $total
}

function Convert-SessionValueToList($value){

    if($null -eq $value){ return @() }

    if($value -is [System.Collections.IDictionary]){
        $keys = @($value.Keys)
        $rowLikeKeys = @("RowIndex","Step","Nominal","TolMinus","TolPlus","Result","ImportantStep","Position","Rect","Mark","Index","X","Y","Width","Height")
        foreach($key in $rowLikeKeys){
            if($keys -contains $key){
                return @($value)
            }
        }
    }

    if($value -is [System.Array]){
        return @($value)
    }

    if($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])){
        return @($value)
    }

    return @($value)
}

function Backup-SessionFile($sessionFilePath){

    if([string]::IsNullOrWhiteSpace($sessionFilePath) -or !(Test-Path $sessionFilePath)){ return }

    $sessionDirectory = [System.IO.Path]::GetDirectoryName($sessionFilePath)
    $sessionName = [System.IO.Path]::GetFileNameWithoutExtension($sessionFilePath)
    $backupPath = Join-Path $sessionDirectory ($sessionName + "__backup.clixml")
    $escapedSessionName = [System.Text.RegularExpressions.Regex]::Escape($sessionName)

    try{
        foreach($existingBackup in @(
            Get-ChildItem -Path $sessionDirectory -Filter "*.clixml" -File -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.BaseName -match ("^" + $escapedSessionName + "__backup(?:$|_)")) -and
                ($_.FullName -ne $backupPath)
            }
        )){
            Remove-Item -Path $existingBackup.FullName -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path $sessionFilePath -Destination $backupPath -Force
    }
    catch{}
}

$uiBootstrapPath = Join-Path $script:AppRoot "RapidOcrProUpdate.UI.ps1"
if(!(Test-Path -LiteralPath $uiBootstrapPath)){
    throw "UI bootstrap file not found: $uiBootstrapPath"
}
Update-StartupSplashStatus "Loading interface..."
. $uiBootstrapPath

$trainingBootstrapPath = Join-Path $script:AppRoot "RapidOcrProUpdate.Training.ps1"
if(!(Test-Path -LiteralPath $trainingBootstrapPath)){
    throw "Training bootstrap file not found: $trainingBootstrapPath"
}
Update-StartupSplashStatus "Loading training module..."
. $trainingBootstrapPath

function Apply-TableSearchFilter{

    if($script:IsApplyingTableSearch){ return }
    try{
        if($script:IsOcrTableEditing -or ($table -and $table.IsCurrentCellInEditMode)){
            return
        }
    }
    catch{}
    $script:IsApplyingTableSearch = $true

    try{

        $searchText = ""
        if($txtTableSearch){
            $searchText = ([string]$txtTableSearch.Text).Trim()
        }

        $selectedRowIndex = -1
        if($table.SelectedRows.Count -gt 0){
            $selectedRowIndex = $table.SelectedRows[0].Index
        }

        $firstVisibleRowIndex = -1

        try{
            if($table.CurrentCell){
                $table.CurrentCell = $null
            }
        }
        catch{}

        for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
            $stepText = [string]$table.Rows[$rowIndex].Cells[0].Value
            $nominalText = [string]$table.Rows[$rowIndex].Cells[1].Value

            $isMatch = (
                [string]::IsNullOrWhiteSpace($searchText) -or
                $stepText.IndexOf($searchText,[System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $nominalText.IndexOf($searchText,[System.StringComparison]::OrdinalIgnoreCase) -ge 0
            )

            $table.Rows[$rowIndex].Visible = $isMatch

            if($isMatch -and $firstVisibleRowIndex -lt 0){
                $firstVisibleRowIndex = $rowIndex
            }
        }

        if($firstVisibleRowIndex -lt 0){
            $table.ClearSelection()
            try{ $table.CurrentCell = $null } catch{}
            return
        }

        $targetRowIndex = $firstVisibleRowIndex
        if(
            $selectedRowIndex -ge 0 -and
            $selectedRowIndex -lt $table.Rows.Count -and
            $table.Rows[$selectedRowIndex].Visible
        ){
            $targetRowIndex = $selectedRowIndex
        }

        $table.ClearSelection()
        $table.Rows[$targetRowIndex].Selected = $true
        try{
            if($table.IsHandleCreated){
                $targetCell = $table.Rows[$targetRowIndex].Cells[0]
                $targetRowIndexCopy = $targetRowIndex
                $null = $table.BeginInvoke([System.Windows.Forms.MethodInvoker]{
                    try{
                        if($table.Rows.Count -gt $targetRowIndexCopy -and $table.Rows[$targetRowIndexCopy].Visible){
                            $table.CurrentCell = $targetCell
                            $table.FirstDisplayedScrollingRowIndex = $targetRowIndexCopy
                        }
                    }
                    catch{}
                })
            }
        }
        catch{}
    }
    finally{
        $script:IsApplyingTableSearch = $false
    }
}

function Set-DrawSidePanelControlsVisible($visible){
    $visibleFlag = [bool]$visible
    foreach($control in @(
        $btnLoad,$btnExcel,$btnAdvance,$grpOcrDebug,$lblTableSearch,$txtTableSearch,
        $btnResultsView,$table,$lblPreviewTitle,$preview,$grpDefaultTol,$grpPreset,
        $grpTolMode,$grpAiVision
    )){
        try{
            if($control -and $control -ne $btnToggleSidePanel){
                $control.Visible = $visibleFlag
            }
        }
        catch{}
    }
}

function Update-SidePanelToggleUi{
    $collapsed = [bool]$script:IsDrawSidePanelCollapsed
    if($btnToggleSidePanel){
        $btnToggleSidePanel.Text = if($collapsed){ "<" } else { ">" }
        $btnToggleSidePanel.BackColor = if($collapsed){ [System.Drawing.Color]::FromArgb(250,250,250) } else { [System.Drawing.Color]::FromArgb(248,248,248) }
        $btnToggleSidePanel.Visible = $true
    }
    if($miAdvanceToggleSidePanel){
        $miAdvanceToggleSidePanel.Text = if($collapsed){ "Show Side Panel" } else { "Hide Side Panel" }
        $miAdvanceToggleSidePanel.Checked = $collapsed
    }
}

function Set-DrawSidePanelCollapsed($collapsed){
    $script:IsDrawSidePanelCollapsed = [bool]$collapsed
    Set-DrawSidePanelControlsVisible (-not $script:IsDrawSidePanelCollapsed)
    Update-SidePanelToggleUi
    Update-UiLayout
    Request-CanvasRedraw
}

function Toggle-DrawSidePanel{
    Set-DrawSidePanelCollapsed (-not [bool]$script:IsDrawSidePanelCollapsed)
}

function Update-UiLayout{
    $commercialLayout = Get-Command Update-CommercialLayoutEnhancements -ErrorAction SilentlyContinue
    if($commercialLayout){
        Update-CommercialLayoutEnhancements
        return
    }

    $margin = 12
    $buttonHeight = 36
    $compactButtonHeight = 28
    $toolRowHeight = 26
    $headerHeight = 0
    if($tabDraw.ClientSize.Width -le 0){
        return
    }

    $drawContentTop = $headerHeight + $margin
    $sidePanelCollapsed = [bool]$script:IsDrawSidePanelCollapsed
    Update-SidePanelToggleUi

    if($sidePanelCollapsed){
        Set-DrawSidePanelControlsVisible $false
        $drawViewerWidth = [Math]::Max(320,($tabDraw.ClientSize.Width - ($margin * 2)))
        $pageNavVisible = ($script:DocumentPages.Count -gt 1)
        $pageNavHeight = if($pageNavVisible){ 30 } else { 0 }
        $topStripHeight = [Math]::Max($buttonHeight,$pageNavHeight)
        $viewerTop = $drawContentTop + $topStripHeight + 8
        $viewerHeight = [Math]::Max(260,($tabDraw.ClientSize.Height - $viewerTop - $margin))

        $toggleIconSize = 28
        $btnToggleSidePanel.Location = New-Object Drawing.Point(($tabDraw.ClientSize.Width - $margin - $toggleIconSize),($drawContentTop + 4))
        $btnToggleSidePanel.Size = New-Object Drawing.Size($toggleIconSize,$toggleIconSize)
        $btnToggleSidePanel.BringToFront()

        $btnPrevPage.Visible = $pageNavVisible
        $lblPageInfo.Visible = $pageNavVisible
        $btnNextPage.Visible = $pageNavVisible
        if($pageNavVisible){
            $pageNavButtonWidth = 90
            $pageNavLabelWidth = 100
            $pageNavGapX = 8
            $pageNavTotalWidth = ($pageNavButtonWidth * 2) + $pageNavLabelWidth + ($pageNavGapX * 2)
            $pageNavLeft = $margin + [Math]::Max(0,[int](($drawViewerWidth - $pageNavTotalWidth) / 2))
            $btnPrevPage.Location = New-Object Drawing.Point($pageNavLeft,$drawContentTop)
            $btnPrevPage.Size = New-Object Drawing.Size($pageNavButtonWidth,$pageNavHeight)
            $lblPageInfo.Location = New-Object Drawing.Point(($btnPrevPage.Right + $pageNavGapX),$drawContentTop)
            $lblPageInfo.Size = New-Object Drawing.Size($pageNavLabelWidth,$pageNavHeight)
            $btnNextPage.Location = New-Object Drawing.Point(($lblPageInfo.Right + $pageNavGapX),$drawContentTop)
            $btnNextPage.Size = New-Object Drawing.Size($pageNavButtonWidth,$pageNavHeight)
        }

        $pageList.Location = New-Object Drawing.Point(-2000,-2000)
        $pageList.Size = New-Object Drawing.Size(1,1)
        $viewer.Location = New-Object Drawing.Point($margin,$viewerTop)
        $viewer.Size = New-Object Drawing.Size($drawViewerWidth,$viewerHeight)
        $tabDraw.AutoScrollMinSize = New-Object Drawing.Size(0,($viewer.Bottom + $margin))
        return
    }

    Set-DrawSidePanelControlsVisible $true
    $drawSidebarWidth = [Math]::Max(340,[Math]::Min(430,[int]($tabDraw.ClientSize.Width * 0.33)))
    $maxSidebarWidth = $tabDraw.ClientSize.Width - ($margin * 3) - 340
    if($drawSidebarWidth -gt $maxSidebarWidth){
        $drawSidebarWidth = [Math]::Max(300,$maxSidebarWidth)
    }

    $drawViewerWidth = [Math]::Max(320,$tabDraw.ClientSize.Width - $drawSidebarWidth - ($margin * 3))
    $drawViewerHeight = [Math]::Max(260,$tabDraw.ClientSize.Height - $drawContentTop - $margin)
    $drawSidebarX = $margin + $drawViewerWidth + $margin
    $pageNavVisible = ($script:DocumentPages.Count -gt 1)
    $pageNavHeight = if($pageNavVisible){ 30 } else { 0 }
    $pageNavGap = if($pageNavVisible){ 8 } else { 0 }
    $viewerTop = $drawContentTop + $pageNavHeight + $pageNavGap
    $viewerHeight = [Math]::Max(260,($drawViewerHeight - $pageNavHeight - $pageNavGap))
    $pageNavButtonWidth = 90
    $pageNavLabelWidth = 100
    $pageNavGapX = 8
    $pageNavTotalWidth = ($pageNavButtonWidth * 2) + $pageNavLabelWidth + ($pageNavGapX * 2)
    $pageNavLeft = $margin + [Math]::Max(0,[int](($drawViewerWidth - $pageNavTotalWidth) / 2))

    $pageList.Location = New-Object Drawing.Point(-2000,-2000)
    $pageList.Size = New-Object Drawing.Size(1,1)

    $btnPrevPage.Visible = $pageNavVisible
    $lblPageInfo.Visible = $pageNavVisible
    $btnNextPage.Visible = $pageNavVisible

    if($pageNavVisible){
        $btnPrevPage.Location = New-Object Drawing.Point($pageNavLeft,$drawContentTop)
        $btnPrevPage.Size = New-Object Drawing.Size($pageNavButtonWidth,$pageNavHeight)
        $lblPageInfo.Location = New-Object Drawing.Point(($btnPrevPage.Right + $pageNavGapX),$drawContentTop)
        $lblPageInfo.Size = New-Object Drawing.Size($pageNavLabelWidth,$pageNavHeight)
        $btnNextPage.Location = New-Object Drawing.Point(($lblPageInfo.Right + $pageNavGapX),$drawContentTop)
        $btnNextPage.Size = New-Object Drawing.Size($pageNavButtonWidth,$pageNavHeight)
    }

    $viewer.Location = New-Object Drawing.Point($margin,$viewerTop)
    $viewer.Size = New-Object Drawing.Size($drawViewerWidth,$viewerHeight)

    $toolGap = 8
    $togglePanelWidth = 28
    $topButtonAreaWidth = [Math]::Max(240,($drawSidebarWidth - $togglePanelWidth - ($toolGap * 3)))
    $topButtonWidth = [Math]::Max(66,[int]($topButtonAreaWidth / 3))
    $topLastButtonWidth = [Math]::Max(72,($topButtonAreaWidth - ($topButtonWidth * 2) - ($toolGap * 2)))

    $btnLoad.Location = New-Object Drawing.Point($drawSidebarX,$drawContentTop)
    $btnLoad.Size = New-Object Drawing.Size($topButtonWidth,$buttonHeight)
    $btnExcel.Location = New-Object Drawing.Point(($btnLoad.Right + $toolGap),$drawContentTop)
    $btnExcel.Size = New-Object Drawing.Size($topButtonWidth,$buttonHeight)
    $btnAdvance.Location = New-Object Drawing.Point(($btnExcel.Right + $toolGap),$drawContentTop)
    $btnAdvance.Size = New-Object Drawing.Size($topLastButtonWidth,$buttonHeight)
    $btnToggleSidePanel.Location = New-Object Drawing.Point(($drawSidebarX + $drawSidebarWidth - $togglePanelWidth),($drawContentTop + 4))
    $btnToggleSidePanel.Size = New-Object Drawing.Size($togglePanelWidth,28)
    $btnToggleSidePanel.BringToFront()

    $btnYellowPen.Visible = $false
    $btnEraser.Visible = $false
    $btnYellowPen.Location = New-Object Drawing.Point(-2000,-2000)
    $btnEraser.Location = New-Object Drawing.Point(-2000,-2000)
    $btnYellowPen.Size = New-Object Drawing.Size(1,1)
    $btnEraser.Size = New-Object Drawing.Size(1,1)

    $infoRowTop = $btnLoad.Bottom + 8
    $txtCopiedUi.Location = New-Object Drawing.Point(-2000,-2000)
    $txtCopiedUi.Size = New-Object Drawing.Size(1,1)
    $txtCopiedUi.Visible = $false

    $sidebarAvailableHeight = [Math]::Max(420,($tabDraw.ClientSize.Height - $infoRowTop - $margin))
    $debugTopHeight = [Math]::Max(58,[Math]::Min(74,[int]($sidebarAvailableHeight * 0.10)))
    $grpOcrDebug.Location = New-Object Drawing.Point($drawSidebarX,$infoRowTop)
    $grpOcrDebug.Size = New-Object Drawing.Size($drawSidebarWidth,$debugTopHeight)
    $txtOcrDebug.Location = New-Object Drawing.Point(10,22)
    $txtOcrDebug.Size = New-Object Drawing.Size(($grpOcrDebug.ClientSize.Width - 20),($grpOcrDebug.ClientSize.Height - 30))

    $searchRowTop = $grpOcrDebug.Bottom + 6
    $searchLabelWidth = [Math]::Max(74,($lblTableSearch.PreferredWidth + 4))
$lblTableSearch.Location = New-Object Drawing.Point($drawSidebarX,($searchRowTop + 4))
$txtTableSearch.Location = New-Object Drawing.Point(($lblTableSearch.Right + 6),$searchRowTop)
$resultsButtonWidth = 96
if($btnResultsView){
    $btnResultsView.Location = New-Object Drawing.Point(($drawSidebarX + $drawSidebarWidth - $resultsButtonWidth),$searchRowTop)
    $btnResultsView.Size = New-Object Drawing.Size($resultsButtonWidth,$toolRowHeight)
}
$searchRight = if($btnResultsView){ $btnResultsView.Left - 6 } else { $drawSidebarX + $drawSidebarWidth }
$txtTableSearch.Size = New-Object Drawing.Size([Math]::Max(90,($searchRight - $txtTableSearch.Location.X)),$toolRowHeight)

    $tableTop = $txtTableSearch.Bottom + 8

    $previewHeight = [Math]::Max(88,[Math]::Min(98,[int]($sidebarAvailableHeight * 0.13)))
    $tolModeHeight = [Math]::Max(88,[Math]::Min(108,[int]($sidebarAvailableHeight * 0.14)))
    $reservedBottomHeight = $previewHeight + 12 + 148 + 12 + $tolModeHeight
    $tableHeight = [Math]::Max(118,[Math]::Min(170,($sidebarAvailableHeight - $debugTopHeight - 6 - $toolRowHeight - 8 - $reservedBottomHeight)))
    $table.Location = New-Object Drawing.Point($drawSidebarX,$tableTop)
    $table.Size = New-Object Drawing.Size($drawSidebarWidth,$tableHeight)

    $sideGap = 8
    $previewWidth = [int](($drawSidebarWidth - $sideGap) / 2)
    $defaultTolWidth = $drawSidebarWidth - $previewWidth - $sideGap

    $previewTop = $table.Bottom + 12
    $lblPreviewTitle.Location = New-Object Drawing.Point($drawSidebarX,$previewTop)
    $preview.Location = New-Object Drawing.Point($drawSidebarX,$previewTop)
    $preview.Size = New-Object Drawing.Size($previewWidth,$previewHeight)

    $grpDefaultTol.Location = New-Object Drawing.Point(($drawSidebarX + $previewWidth + $sideGap),($previewTop - 4))
    $grpDefaultTol.Size = New-Object Drawing.Size($defaultTolWidth,($preview.Bottom - ($previewTop - 4)))

    $tolInnerWidth = $grpDefaultTol.ClientSize.Width
    $tolLeft = 10
    $tolTop = 18
    $tolRowGap = 18
    $tolLabelWidth = 52
    $tolFieldGap = 6
    $tolFieldWidth = [Math]::Max(34,[Math]::Min(42,($tolInnerWidth - $tolLeft - $tolLabelWidth - 12 - $tolFieldGap)))
    $tolFieldX = $tolLeft + $tolLabelWidth + $tolFieldGap

    $lblTol0.Location = New-Object Drawing.Point($tolLeft,$tolTop)
    $txtTol0.Location = New-Object Drawing.Point($tolFieldX,($tolTop - 3))
    $lblTol1.Location = New-Object Drawing.Point($tolLeft,($tolTop + $tolRowGap))
    $txtTol1.Location = New-Object Drawing.Point($tolFieldX,($tolTop + $tolRowGap - 3))
    $lblTol2.Location = New-Object Drawing.Point($tolLeft,($tolTop + ($tolRowGap * 2)))
    $txtTol2.Location = New-Object Drawing.Point($tolFieldX,($tolTop + ($tolRowGap * 2) - 3))
    $lblTol3.Location = New-Object Drawing.Point($tolLeft,($tolTop + ($tolRowGap * 3)))
    $txtTol3.Location = New-Object Drawing.Point($tolFieldX,($tolTop + ($tolRowGap * 3) - 3))
    $txtTol0.Width = $tolFieldWidth
    $txtTol1.Width = $tolFieldWidth
    $txtTol2.Width = $tolFieldWidth
    $txtTol3.Width = $tolFieldWidth

    $previewRowBottom = [Math]::Max($preview.Bottom,$grpDefaultTol.Bottom)
    $grpAiVision.Location = New-Object Drawing.Point(-3000,-3000)
    $grpAiVision.Size = New-Object Drawing.Size(1,1)
    $debugRowTop = $previewRowBottom + 12
    $presetWidth = $drawSidebarWidth
    $presetHeight = [Math]::Max(148,[Math]::Min(176,($tabDraw.ClientSize.Height - $debugRowTop - 12 - $tolModeHeight - $margin)))

    $grpPreset.Location = New-Object Drawing.Point($drawSidebarX,$debugRowTop)
    $grpPreset.Size = New-Object Drawing.Size($presetWidth,$presetHeight)

    $presetButtons = @(
        @($grpPreset.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] })
    )
    if($presetButtons.Count -gt 0){
        $presetInnerWidth = [Math]::Max(220,($grpPreset.ClientSize.Width - 20))
        $presetInnerHeight = [Math]::Max(120,($grpPreset.ClientSize.Height - 34))
        $presetCols = 4
        $presetRows = [Math]::Ceiling($presetButtons.Count / [double]$presetCols)
        $presetGapX = 6
        $presetGapY = 6
        $presetButtonWidth = [Math]::Max(50,[int](($presetInnerWidth - (($presetCols - 1) * $presetGapX)) / $presetCols))
        $presetButtonHeight = [Math]::Max(24,[int](($presetInnerHeight - (($presetRows - 1) * $presetGapY)) / $presetRows))

        for($presetIndex = 0; $presetIndex -lt $presetButtons.Count; $presetIndex++){
            $presetButton = $presetButtons[$presetIndex]
            $presetCol = ($presetIndex % $presetCols)
            $presetRow = [int][Math]::Floor($presetIndex / $presetCols)
            $presetButton.Location = New-Object Drawing.Point(
                (10 + ($presetCol * ($presetButtonWidth + $presetGapX))),
                (28 + ($presetRow * ($presetButtonHeight + $presetGapY)))
            )
            $presetButton.Size = New-Object Drawing.Size($presetButtonWidth,$presetButtonHeight)
        }
    }

    $grpTolMode.Location = New-Object Drawing.Point($drawSidebarX,($grpPreset.Bottom + 12))
    $grpTolMode.Size = New-Object Drawing.Size($drawSidebarWidth,$tolModeHeight)

    $contentBottom = [Math]::Max($viewer.Bottom,$grpTolMode.Bottom) + $margin
    $tabDraw.AutoScrollMinSize = New-Object Drawing.Size(0,$contentBottom)
}


$form.Add_Shown({
    Update-UiLayout
    Update-TrainingReadinessUi
    Update-CopyViewButton
    Update-PdfTextZonesButton
    Update-TranslateLensButton
    Update-ZoomStatus
    Update-CanvasCursor

    if(-not $script:StartupUiReady -and $script:StartupReadyTimer){
        $script:StartupReadyTimer.Stop()
        $script:StartupReadyTimer.Start()
    }
})
$form.Add_Resize({
    Update-UiLayout
    if(-not $script:AllowApplicationExit -and -not $script:IsHiddenToTray -and $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized){
        Hide-MainFormToTray
    }
})
$mainSplit.Add_Resize({ Update-UiLayout })
$viewer.Add_Resize({ Sync-ViewToViewport })
$mainSplit.Add_SplitterMoved({
    Save-SessionState
    Update-UiLayout
})

function Test-OcrTableEditing{
    try{
        return ($script:IsOcrTableEditing -or ($table -and $table.IsCurrentCellInEditMode))
    }
    catch{
        return [bool]$script:IsOcrTableEditing
    }
}

function Queue-PostOcrTableEditRefresh($rowIndex,$colIndex){
    if(-not $form -or $form.IsDisposed){ return }
    $rowIndexCopy = [int]$rowIndex
    $colIndexCopy = [int]$colIndex
    try{
        [void]$form.BeginInvoke([System.Windows.Forms.MethodInvoker]{
            try{
                if(Test-OcrTableEditing){ return }
                if($rowIndexCopy -lt 0 -or $colIndexCopy -lt 0){ return }
                Sync-MarkStepTextZonesFromTable
                Refresh-DuplicateState
                Save-CurrentPageState
                Queue-SessionStateSave
                Apply-TableSearchFilter
                Request-CanvasRedraw
            }
            catch{}
        })
    }
    catch{}
}

$table.Add_DataError({
    param($sender,$e)
    $e.ThrowException = $false
})
$table.Add_CellDoubleClick({
    $rowIndex = $_.RowIndex
    $colIndex = $_.ColumnIndex
    if($rowIndex -lt 0 -or $colIndex -lt 0){ return }
    if($colIndex -ge $table.Columns.Count){ return }
    if($table.Columns[$colIndex].ReadOnly){ return }
    if(-not $table.Rows[$rowIndex].Visible){ return }
    try{
        $table.CurrentCell = $table.Rows[$rowIndex].Cells[$colIndex]
        [void]$table.BeginEdit($true)
    }
    catch{}
})
$table.Add_CellBeginEdit({
    $rowIndex = $_.RowIndex
    $colIndex = $_.ColumnIndex
    if($rowIndex -lt 0 -or $colIndex -lt 0){ return }
    $script:IsOcrTableEditing = $true
    foreach($pendingTimer in @($script:SessionStateSaveTimer,$script:ImportantStepSaveTimer,$script:ViewStateSaveTimer)){
        try{
            if($pendingTimer -and $pendingTimer.Enabled){ $pendingTimer.Stop() }
        }
        catch{}
    }
    $baselineKey = "$rowIndex`:$colIndex"
    $script:CellEditBaseline[$baselineKey] = [string]$table.Rows[$rowIndex].Cells[$colIndex].Value
})
$table.Add_CurrentCellDirtyStateChanged({
    if(
        $table.IsCurrentCellDirty -and
        $table.CurrentCell -and
        $table.CurrentCell.ColumnIndex -ge 0 -and
        $table.Columns[$table.CurrentCell.ColumnIndex].Name -eq "Important"
    ){
        $table.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})
$table.Add_CellEndEdit({
    $rowIndex = $_.RowIndex
    $colIndex = $_.ColumnIndex
    try{
        $baselineKey = "$rowIndex`:$colIndex"
        $oldValue = ""
        if($script:CellEditBaseline.ContainsKey($baselineKey)){
            $oldValue = [string]$script:CellEditBaseline[$baselineKey]
            [void]$script:CellEditBaseline.Remove($baselineKey)
        }
        $newValue = ""
        if($rowIndex -ge 0 -and $rowIndex -lt $table.Rows.Count -and $colIndex -ge 0 -and $colIndex -lt $table.Columns.Count){
            $newValue = [string]$table.Rows[$rowIndex].Cells[$colIndex].Value
        }
        $trainingRect = $null
        if($script:StepRects.ContainsKey($rowIndex)){
            $trainingRect = $script:StepRects[$rowIndex]
        }
        if($oldValue -ne $newValue){
            switch($colIndex){
                1 { Register-TrainingSignal "nominal_edit" @{ Row = $rowIndex; Before = $oldValue; After = $newValue; Rect = $trainingRect } }
                2 { Register-TrainingSignal "tolerance_edit" @{ Row = $rowIndex; Field = "TolMinus"; Before = $oldValue; After = $newValue; Rect = $trainingRect } }
                3 { Register-TrainingSignal "tolerance_edit" @{ Row = $rowIndex; Field = "TolPlus"; Before = $oldValue; After = $newValue; Rect = $trainingRect } }
                4 { Register-TrainingSignal "tool_edit" @{ Row = $rowIndex; Before = $oldValue; After = $newValue; Rect = $trainingRect } }
                5 { Register-TrainingSignal "result_edit" @{ Row = $rowIndex; Before = $oldValue; After = $newValue; Rect = $trainingRect } }
            }
        }
    }
    finally{
        $script:IsOcrTableEditing = $false
    }

    if($colIndex -eq 8){
        Request-CanvasRedraw
        Queue-ImportantStepSave
        return
    }

    Queue-PostOcrTableEditRefresh $rowIndex $colIndex
})
$table.Add_CellValueChanged({
    $rowIndex = $_.RowIndex
    $colIndex = $_.ColumnIndex
    if($rowIndex -lt 0 -or $colIndex -lt 0){ return }
    if($table.Columns[$colIndex].Name -ne "Important"){ return }

    $trainingRect = $null
    if($script:StepRects.ContainsKey($rowIndex)){
        $trainingRect = $script:StepRects[$rowIndex]
    }

    Register-TrainingSignal "important_step_toggle" @{
        Row = $rowIndex
        After = (Convert-ToStepImportantFlag $table.Rows[$rowIndex].Cells[$colIndex].Value)
        Rect = $trainingRect
    }
    Update-CurrentPageEntryCellFast $rowIndex $colIndex $table.Rows[$rowIndex].Cells[$colIndex].Value
    Request-CanvasRedraw
    Queue-ImportantStepSave
})
$table.Add_SelectionChanged({
    if($table.SelectedRows.Count -gt 0){
        Select-OriginalMark $table.SelectedRows[0].Index $false
    }
    elseif($script:SelectedMarkKind -eq "Original"){
        Clear-SelectedMark
    }
    Refresh-DuplicateState
    Request-CanvasRedraw
})
$table.Add_Sorted({
    Refresh-DuplicateState
    Apply-TableSearchFilter
})
$txtTableSearch.Add_TextChanged({
    Apply-TableSearchFilter
})
function Convert-MeasurementNumber($value){
    $text = ([string]$value).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return $null }
    $text = $text -replace ',','.'
    $match = [regex]::Match($text,'[-+]?\d+(?:\.\d+)?')
    if(-not $match.Success){ return $null }
    $number = 0.0
    if([double]::TryParse($match.Value,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$number)){
        return [double]$number
    }
    return $null
}

function Get-MeasurementResult($nominalText,$tolMinusText,$tolPlusText,$actualText){
    $actual = Convert-MeasurementNumber $actualText
    if($null -eq $actual){ return "" }

    $nominal = Convert-MeasurementNumber $nominalText
    if($null -eq $nominal){ return "INVALID" }

    $tolMinus = Convert-MeasurementNumber $tolMinusText
    $tolPlus = Convert-MeasurementNumber $tolPlusText
    if($null -eq $tolMinus){ $tolMinus = 0.0 }
    if($null -eq $tolPlus){ $tolPlus = 0.0 }

    $lower = [double]$nominal + [double]$tolMinus
    $upper = [double]$nominal + [double]$tolPlus
    if($lower -gt $upper){
        $tmp = $lower
        $lower = $upper
        $upper = $tmp
    }

    if([double]$actual -ge $lower -and [double]$actual -le $upper){ return "OK" }
    return "NG"
}

function Get-MeasurementOverrideForStep($step){
    $stepKey = [string]$step
    if([string]::IsNullOrWhiteSpace($stepKey)){ return $null }
    if(-not $script:MeasurementResults.ContainsKey($stepKey)){ return $null }

    $record = $script:MeasurementResults[$stepKey]
    if(!$record){ return $null }
    $actual = [string]$record.Actual
    if([string]::IsNullOrWhiteSpace($actual)){ return $null }

    return [PSCustomObject]@{
        Actual = $actual
        Result = [string]$record.Result
    }
}

function Focus-StepFromResultsView($row){
    if(!$row -or !$table){ return }

    $mainRowIndex = -1
    try{ $mainRowIndex = [int]$row.Tag } catch{ $mainRowIndex = -1 }
    if($mainRowIndex -lt 0 -or $mainRowIndex -ge $table.Rows.Count){ return }

    if($txtTableSearch -and -not $table.Rows[$mainRowIndex].Visible){
        $txtTableSearch.Text = ""
        Apply-TableSearchFilter
    }

    try{
        Select-OriginalMark $mainRowIndex $true
    }
    catch{
        try{
            $table.ClearSelection()
            $table.Rows[$mainRowIndex].Selected = $true
            $table.CurrentCell = $table.Rows[$mainRowIndex].Cells[0]
            if($table.Rows[$mainRowIndex].Visible){
                $table.FirstDisplayedScrollingRowIndex = $mainRowIndex
            }
        }
        catch{}
    }

    if($script:StepRects.ContainsKey($mainRowIndex)){
        $rect = $script:StepRects[$mainRowIndex]
        $script:selectionRect = $rect
        Update-PreviewFromSelectionRect $rect
        Focus-OnRect $rect
    }
    else{
        Request-CanvasRedraw
    }

    if($txtOcrDebug){
        $txtOcrDebug.Text = "Results View selected step " + [string]$table.Rows[$mainRowIndex].Cells[0].Value
    }
}

function Show-ResultsViewWindow{
    if(!$table){ return }

    $formResults = New-Object Windows.Forms.Form
    $formResults.Text = "Results View"
    $formResults.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $formResults.Size = New-Object Drawing.Size(760,520)
    $formResults.MinimizeBox = $true
    $formResults.MaximizeBox = $true

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::CellSelect
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.Font = New-Object Drawing.Font("Segoe UI",10)
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font("Segoe UI",10,[Drawing.FontStyle]::Bold)

    [void]$grid.Columns.Add("Step","Step")
    [void]$grid.Columns.Add("Nominal","Nominal")
    [void]$grid.Columns.Add("TolMinus","Tol -")
    [void]$grid.Columns.Add("TolPlus","Tol +")
    [void]$grid.Columns.Add("Actual","Actual")
    [void]$grid.Columns.Add("Result","Result")

    foreach($colName in @("Step","Nominal","TolMinus","TolPlus","Result")){
        $grid.Columns[$colName].ReadOnly = $true
    }
    $grid.Columns["Actual"].ReadOnly = $false

    $grid.Columns["Step"].FillWeight = 12
    $grid.Columns["Nominal"].FillWeight = 28
    $grid.Columns["TolMinus"].FillWeight = 16
    $grid.Columns["TolPlus"].FillWeight = 16
    $grid.Columns["Actual"].FillWeight = 18
    $grid.Columns["Result"].FillWeight = 14

    for($rowIndex=0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
        $step = [string]$table.Rows[$rowIndex].Cells[0].Value
        if([string]::IsNullOrWhiteSpace($step)){ continue }
        $nominal = [string]$table.Rows[$rowIndex].Cells[1].Value
        $tolMinus = [string]$table.Rows[$rowIndex].Cells[2].Value
        $tolPlus = [string]$table.Rows[$rowIndex].Cells[3].Value
        $actual = ""
        if($script:MeasurementResults.ContainsKey($step)){
            $actual = [string]$script:MeasurementResults[$step].Actual
        }
        $resultText = Get-MeasurementResult $nominal $tolMinus $tolPlus $actual
        $newRowIndex = $grid.Rows.Add($step,$nominal,$tolMinus,$tolPlus,$actual,$resultText)
        $grid.Rows[$newRowIndex].Tag = $rowIndex
        Update-MeasurementGridRowStyle $grid.Rows[$newRowIndex]
    }

    $grid.Add_CellEndEdit({
        param($sender,$e)
        if($e.RowIndex -lt 0){ return }
        if($sender.Columns[$e.ColumnIndex].Name -ne "Actual"){ return }
        Update-MeasurementGridRow $sender.Rows[$e.RowIndex]
    })

    $grid.Add_CellClick({
        param($sender,$e)
        if($e.RowIndex -lt 0){ return }
        Focus-StepFromResultsView $sender.Rows[$e.RowIndex]
    })

    $grid.Add_RowEnter({
        param($sender,$e)
        if($e.RowIndex -lt 0){ return }
        Focus-StepFromResultsView $sender.Rows[$e.RowIndex]
    })

    $grid.Add_KeyDown({
        param($sender,$e)
        if($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter){
            $e.SuppressKeyPress = $true
            if($sender.CurrentCell -and $sender.CurrentCell.RowIndex -lt ($sender.Rows.Count - 1)){
                $sender.CurrentCell = $sender.Rows[$sender.CurrentCell.RowIndex + 1].Cells["Actual"]
                $sender.BeginEdit($true)
            }
        }
    })

    $formResults.Controls.Add($grid)
    [void]$formResults.Show($form)
}

function Update-MeasurementGridRow($row){
    if(!$row){ return }
    $step = [string]$row.Cells["Step"].Value
    $actual = [string]$row.Cells["Actual"].Value
    $resultText = Get-MeasurementResult $row.Cells["Nominal"].Value $row.Cells["TolMinus"].Value $row.Cells["TolPlus"].Value $actual
    $row.Cells["Result"].Value = $resultText
    if(-not [string]::IsNullOrWhiteSpace($step)){
        $script:MeasurementResults[$step] = [PSCustomObject]@{
            Actual = $actual
            Result = $resultText
            UpdatedAt = Get-Date
        }
        Queue-SessionStateSave
    }
    Update-MeasurementGridRowStyle $row
}

function Update-MeasurementGridRowStyle($row){
    if(!$row){ return }
    $resultText = ([string]$row.Cells["Result"].Value).Trim().ToUpperInvariant()
    switch($resultText){
        "OK" { $row.DefaultCellStyle.BackColor = [Drawing.Color]::Honeydew }
        "NG" { $row.DefaultCellStyle.BackColor = [Drawing.Color]::MistyRose }
        "INVALID" { $row.DefaultCellStyle.BackColor = [Drawing.Color]::LemonChiffon }
        default { $row.DefaultCellStyle.BackColor = [Drawing.Color]::White }
    }
}

if($btnResultsView){
    $btnResultsView.Add_Click({
        Show-ResultsViewWindow
    })
}
$pageList.Add_SelectedIndexChanged({
    if($script:IsRestoringState){ return }
    Bind-SelectedPage
})
$btnPrevPage.Add_Click({
    Show-PageByIndex ($script:SelectedPageIndex - 1)
})
$btnNextPage.Add_Click({
    Show-PageByIndex ($script:SelectedPageIndex + 1)
})
$btnYellowPen.Add_Click({
    if($script:AnnotationToolMode -eq "Highlight"){ Set-AnnotationToolMode "OCR" }
    else{ Set-AnnotationToolMode "Highlight" }
})
$btnEraser.Add_Click({
    if($script:AnnotationToolMode -eq "Eraser"){ Set-AnnotationToolMode "OCR" }
    else{ Set-AnnotationToolMode "Eraser" }
})
if($miAdvanceYellowPen){
    $miAdvanceYellowPen.Add_Click({
        if($script:AnnotationToolMode -eq "Highlight"){ Set-AnnotationToolMode "OCR" }
        else{ Set-AnnotationToolMode "Highlight" }
    })
}
if($miAdvanceEraser){
    $miAdvanceEraser.Add_Click({
        if($script:AnnotationToolMode -eq "Eraser"){ Set-AnnotationToolMode "OCR" }
        else{ Set-AnnotationToolMode "Eraser" }
    })
}
if($miAdvanceTrainingExport){
    $miAdvanceTrainingExport.Add_Click({
        Set-TrainingSaveExportEnabled (-not [bool]$script:TrainingSaveExportEnabled)
    })
}
if($miAdvanceBalloonWhite){ $miAdvanceBalloonWhite.Add_Click({ Set-BalloonColorPreset "White" }) }
if($miAdvanceBalloonYellow){ $miAdvanceBalloonYellow.Add_Click({ Set-BalloonColorPreset "Yellow" }) }
if($miAdvanceBalloonBlue){ $miAdvanceBalloonBlue.Add_Click({ Set-BalloonColorPreset "Blue" }) }
if($miAdvanceBalloonGreen){ $miAdvanceBalloonGreen.Add_Click({ Set-BalloonColorPreset "Green" }) }
if($miAdvanceBalloonOrange){ $miAdvanceBalloonOrange.Add_Click({ Set-BalloonColorPreset "Orange" }) }

$form.Add_FormClosing({
    param($sender,$e)

    if(-not $script:AllowApplicationExit -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing){
        $e.Cancel = $true
        if($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized){
            $script:LastVisibleWindowState = $form.WindowState
        }
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        return
    }

    Save-SessionState

    try{
        if($script:TrayNotifyIcon){
            $script:TrayNotifyIcon.Visible = $false
            $script:TrayNotifyIcon.Dispose()
            $script:TrayNotifyIcon = $null
        }
    }
    catch{}
    Dispose-DocumentPages
})
# =========================
# VARIABLES
# =========================

$script:sourceBitmap = $null
$script:zoom = 1.0
$script:panX = 0.0
$script:panY = 0.0
$script:maxZoom = 8.0
$script:zoomStep = 1.08
$script:FitMode = "FitScreen"
$script:PreserveZoomOnLoad = $true
$script:dragging = $false
$script:startPoint = $null
$script:endPoint = $null
$script:selectionRect = $null
$script:marks = @()
$script:StepRects = @{}
$script:MeasurementResults = @{}
$script:dragMarkIndex = -1
$script:isDraggingMark = $false
$script:draggingMarkKind = $null
$script:UiCopiedMarks = @()
$script:NextUiCopiedMarkId = 1
$script:CopyViewOnly = $false
$script:BalloonColorPreset = "White"
$script:TrainingSaveExportEnabled = $true
$script:AdvancePanelVisible = $false
$script:LastTextInsertTarget = $null
$script:SelectedMarkKind = $null
$script:SelectedMarkRowIndex = -1
$script:SelectedUiCopyId = $null
$script:ClipboardMarkTemplate = $null
$script:LastImageMousePoint = $null
$script:dragOffset = $null
$script:DuplicateStepMap = @{}
$script:SelectedDuplicateSteps = @{}
$script:SelectedDuplicateAnchorStep = $null
$script:HiddenDuplicateOriginalRect = $null
$script:HiddenDuplicateGhostRect = $null
$script:DuplicateDeclinedRects = @()
$script:PendingManualDuplicateCandidate = $null
$script:IsRefreshingDuplicateState = $false
$script:isPanning = $false
$script:isSpacePressed = $false
$script:panStartPoint = $null
$script:panStartX = 0.0
$script:panStartY = 0.0
$script:IsInteractiveCanvasUpdate = $false
$script:PendingPreviewRect = $null
$script:LastPreviewRect = $null
$script:JobName = $null
$script:JobFolder = $null
$script:PartNo = $null
$script:MoldName = $null
$script:PartQuantity = $null
$script:PartMaterial = $null
$script:PartHrc = $null
$script:PartUser = $null
$script:CurrentSourcePath = $null
$script:CurrentSessionFilePath = $null
$script:DocumentPages = @()
$script:SelectedPageIndex = -1
$script:IsBindingPage = $false
$script:IsApplyingTableSearch = $false
$script:IsOcrTableEditing = $false
$script:IsDrawSidePanelCollapsed = $false
$script:CellEditBaseline = @{}
$script:TranslateLensEnabled = $false
$script:TranslateLensPixelWidth = 250
$script:TranslateLensPixelHeight = 80
$script:TranslateLensRect = $null
$script:TranslateLensPendingRect = $null
$script:AiVisionResult = $null
$script:AiVisionBusy = $false
$script:AiTestOnlyEnabled = $false
$script:AiRecoveryChromeProcessId = 0
$script:AiRecoveryTurboMode = $true
$script:AiRecoverySilentMode = $false
$script:AiRecoveryKeepChromeWarm = $false
$script:AiRecoveryChromeWarmed = $false
$script:GeminiVisionBaseUrl = "https://generativelanguage.googleapis.com/v1beta"
$script:AiRecoveryChromeUrl = "https://www.google.com/search?q=&sourceid=chrome&ie=UTF-8&udm=50&aep=48&cud=0&qsubts=1780709407592&source=chrome.crn.obic"
$script:OllamaVisionBaseUrl = "http://localhost:11434"
$script:OllamaVisionKeepAlive = -1
$script:TranslateLensResult = $null
$script:TranslateLensPoint = $null
$script:TranslateLensCache = @{}
$script:TranslateLensTranslationCache = @{}
$script:AnnotationToolMode = "OCR"
$script:HighlightStrokes = @()
$script:IsDrawingHighlightStroke = $false
$script:CurrentHighlightStroke = $null
$script:HighlightStrokeBaseWidth = 22.0
$script:EraserRadius = 18.0
$script:TrayNotifyIcon = $null
$script:TrayMenuOpenItem = $null
$script:TrayMenuExitItem = $null
$script:AllowApplicationExit = $false
$script:LastVisibleWindowState = $form.WindowState
$script:IsHiddenToTray = $false
$script:JudgeOkAutoFillEnabled = $false
$script:InspectionSampleAutoFillEnabled = $true

function Hide-MainFormToTray{
    if($script:IsHiddenToTray){ return }
    if($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized){
        $script:LastVisibleWindowState = $form.WindowState
    }
    elseif($script:LastVisibleWindowState -eq [System.Windows.Forms.FormWindowState]::Minimized){
        $script:LastVisibleWindowState = [System.Windows.Forms.FormWindowState]::Normal
    }

    $form.Hide()
    $form.ShowInTaskbar = $false
    $script:IsHiddenToTray = $true
    if($script:TrayNotifyIcon){
        $script:TrayNotifyIcon.Visible = $true
    }
}

function Show-MainFormFromTray{
    $restoreState = $script:LastVisibleWindowState
    if($restoreState -eq [System.Windows.Forms.FormWindowState]::Minimized){
        $restoreState = [System.Windows.Forms.FormWindowState]::Normal
    }
    if($restoreState -eq $null){
        $restoreState = [System.Windows.Forms.FormWindowState]::Normal
    }

    $form.ShowInTaskbar = $true
    $form.Show()
    $script:IsHiddenToTray = $false
    $form.WindowState = $restoreState
    $form.BringToFront()
    $form.Activate()
}

function Exit-ApplicationFromTray{
    $script:AllowApplicationExit = $true
    try{
        if($script:TrayNotifyIcon){
            $script:TrayNotifyIcon.Visible = $false
        }
    }
    catch{}
    $form.Close()
}

function Initialize-TrayBehavior{
    if($script:TrayNotifyIcon){ return }

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:TrayMenuOpenItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open")
    $script:TrayMenuExitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
    [void]$trayMenu.Items.Add($script:TrayMenuOpenItem)
    [void]$trayMenu.Items.Add($script:TrayMenuExitItem)

    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $trayIcon.Text = "RapidOCR PDF Scan Tool"
    $trayIcon.ContextMenuStrip = $trayMenu
    $trayIcon.Visible = $true

    $iconPath = Join-Path $script:AppRoot "RapidOcrProUpdateIcon.exe"
    try{
        if(Test-Path -LiteralPath $iconPath){
            $trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
        }
        else{
            $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
        }
    }
    catch{
        $trayIcon.Icon = [System.Drawing.SystemIcons]::Application
    }

    $script:TrayMenuOpenItem.Add_Click({ Show-MainFormFromTray })
    $script:TrayMenuExitItem.Add_Click({ Exit-ApplicationFromTray })
    $trayIcon.Add_DoubleClick({ Show-MainFormFromTray })

    $script:TrayNotifyIcon = $trayIcon
}
$script:TranslateLensLastRectKey = ""
$script:TranslateLensPendingRectKey = ""
$script:TranslateLensBusy = $false
$script:RenderedPdfTempDir = $null
$script:AppStateFilePath = Join-Path $script:AppRoot "ocrtool-pdfscan-app-state.clixml"
$script:SessionStoreDir = Join-Path $script:AppRoot "ocrtool-pdfscan-sessions"
$script:RenderCacheRoot = Join-Path $script:AppRoot "ocrtool-pdfscan-render-cache"
$script:TrainingDatasetRoot = Join-Path $script:AppRoot "TrainingDataset"
$script:TrainingMetricsPath = Join-Path $script:TrainingDatasetRoot "training-metrics.clixml"
$script:TrainingEventsPath = Join-Path $script:TrainingDatasetRoot "training-events.jsonl"
$script:TrainingManifestPath = Join-Path $script:TrainingDatasetRoot "manifest.json"
$script:TrainingLabelsCsvPath = Join-Path $script:TrainingDatasetRoot "labels.csv"
$script:DetectorDatasetRoot = Join-Path $script:TrainingDatasetRoot "detector"
$script:DetectorAnnotationsPath = Join-Path $script:DetectorDatasetRoot "annotations.jsonl"
$script:TrainingMetrics = $null
$script:TrainingHardNegativeCache = @{}
$script:DetectorAnnotationCache = @{}
$script:DetectorPageImageCache = @{}
$script:SourceFingerprintCache = @{}
$script:DuplicateSessionMetadataCache = @{}
$script:PdfExportJpegQualityDefault = 92L
$script:PdfExportJpegQualityFast = 76L
$script:PendingDetectorAnnotationJsonLines = New-Object System.Collections.Generic.List[string]
$script:AdaptiveDetectorStats = @{}
$script:PreviewUpdateTimer = New-Object Windows.Forms.Timer
$script:PreviewUpdateTimer.Interval = 60
$script:PreviewUpdateTimer.Add_Tick({
    $script:PreviewUpdateTimer.Stop()

    if(!$script:PendingPreviewRect){
        return
    }

    Update-PreviewFromSelectionRect $script:PendingPreviewRect
})
$script:TranslateLensTimer = New-Object Windows.Forms.Timer
$script:TranslateLensTimer.Interval = 450
$script:TranslateLensTimer.Add_Tick({
    $script:TranslateLensTimer.Stop()
    if(-not $script:TranslateLensEnabled){ return }
    if(-not $script:TranslateLensPendingRect){ return }
    if($script:TranslateLensBusy){ return }
    $script:TranslateLensBusy = $true
    try{
    Update-TranslateLensFromRect $script:TranslateLensPendingRect
    }
    finally{
        $script:TranslateLensBusy = $false
    }
})
$script:SessionStateSaveTimer = New-Object Windows.Forms.Timer
$script:SessionStateSaveTimer.Interval = 1200
$script:SessionStateSaveTimer.Add_Tick({
    $script:SessionStateSaveTimer.Stop()
    Save-SessionState
})
$script:ImportantStepSaveTimer = New-Object Windows.Forms.Timer
$script:ImportantStepSaveTimer.Interval = 500
$script:ImportantStepSaveTimer.Add_Tick({
    $script:ImportantStepSaveTimer.Stop()
    Save-SessionState
})
$script:AcceptSuggestionPostUpdateTimer = New-Object Windows.Forms.Timer
$script:AcceptSuggestionPostUpdateTimer.Interval = 80
$script:AcceptSuggestionPostUpdateTimer.Add_Tick({
    $script:AcceptSuggestionPostUpdateTimer.Stop()
    Save-CurrentPageState
    Queue-SessionStateSave
    Refresh-DuplicateState
    if($txtTableSearch -and -not [string]::IsNullOrWhiteSpace(([string]$txtTableSearch.Text).Trim())){
        Apply-TableSearchFilter
    }
})
$script:ViewStateSaveTimer = New-Object Windows.Forms.Timer
$script:ViewStateSaveTimer.Interval = 400
$script:ViewStateSaveTimer.Add_Tick({
    $script:ViewStateSaveTimer.Stop()
    Save-SessionState
})
$script:InteractiveRenderResetTimer = New-Object Windows.Forms.Timer
$script:InteractiveRenderResetTimer.Interval = 60
$script:InteractiveRenderResetTimer.Add_Tick({
    $script:InteractiveRenderResetTimer.Stop()
    Set-InteractiveCanvasMode $false
    Request-CanvasRedraw
})
$script:DeferredTextZoneWarmupTimer = New-Object Windows.Forms.Timer
$script:DeferredTextZoneWarmupTimer.Interval = 120
$script:PendingTextZoneWarmupPageIndex = -1
$script:PendingTextZoneWarmupStage = ""
$script:PendingTextZoneWarmupMapRect = $null
$script:PendingTextZoneWarmupImageCandidates = @()
$script:IsDeferredTextZoneWarmupRunning = $false
$script:DeferredTextZoneWarmupTimer.Add_Tick({
    Invoke-DeferredTextZoneWarmup
})
$script:MaxSessionCount = 12
$script:MaxRenderCacheBytes = 2147483648
$script:IsRestoringState = $false
$script:IsLoadingSource = $false
$script:IsExportInProgress = $false
$script:DeletedSteps = @()
$script:MarkBaseRadius = 16.3
$script:MarkBaseFontSize = 16.3
$script:MarkBaseOutlineWidth = 1.5
$script:ExportMarkSizeScale = 2.0

function Get-MarkImageRadius{
    return [float]($script:MarkBaseRadius * $script:ExportMarkSizeScale)
}

function Normalize-MarkScale($scale){
    $scaleValue = 1.0
    if(-not [double]::TryParse(([string]$scale),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$scaleValue)){
        $scaleValue = 1.0
    }
    return [double][Math]::Max(0.5,[Math]::Min(3.0,$scaleValue))
}

function Get-MarkScale($mark){
    if(!$mark){ return 1.0 }
    if($mark.PSObject.Properties.Name -contains 'Scale'){
        return (Normalize-MarkScale $mark.Scale)
    }
    return 1.0
}

function Get-CurrentPageBalloonScale{
    $selectedMark = $null
    if($script:SelectedMarkKind -eq "Copy"){
        $selectedMark = Get-UiCopiedMarkById $script:SelectedUiCopyId
    }
    elseif(
        $script:SelectedMarkKind -eq "Original" -and
        $script:SelectedMarkRowIndex -ge 0 -and
        $script:SelectedMarkRowIndex -lt $script:marks.Count
    ){
        $selectedMark = $script:marks[$script:SelectedMarkRowIndex]
    }
    if($selectedMark){
        return (Get-MarkScale $selectedMark)
    }

    foreach($mark in @($script:marks)){
        if($mark){ return (Get-MarkScale $mark) }
    }
    foreach($mark in @($script:UiCopiedMarks)){
        if($mark){ return (Get-MarkScale $mark) }
    }

    return 1.0
}

function Get-MarkLayoutMetrics($renderScale){

    $effectiveScale = [Math]::Max([double]$renderScale,0.0001)

    # UI and export both use the same balloon geometry; UI is just export geometry under zoom.
    $geometryScale = $script:ExportMarkSizeScale * $effectiveScale

    return [ordered]@{
        Radius = [float]($script:MarkBaseRadius * $geometryScale)
        Diameter = [float](($script:MarkBaseRadius * 2.0) * $geometryScale)
        FontSize = [float]($script:MarkBaseFontSize * $geometryScale)
        OutlineWidth = [float]($script:MarkBaseOutlineWidth * $geometryScale)
    }
}

function Get-MarkAtPoint($mouseX,$mouseY){

    foreach($m in $script:marks){
        if(!$m){ continue }

        $dx = $m.X - $mouseX
        $dy = $m.Y - $mouseY

        $hitRadius = (Get-MarkImageRadius) * (Get-MarkScale $m)

        if([math]::Sqrt($dx*$dx + $dy*$dy) -lt $hitRadius){
            return $m
        }
    }

    return $null
}

function Get-UiCopiedMarkById($copyId){

    foreach($mark in @($script:UiCopiedMarks)){
        if($mark -and $mark.Id -eq $copyId){
            return $mark
        }
    }

    return $null
}

function Get-UiCopiedMarkAtPoint($mouseX,$mouseY){

    for($i = $script:UiCopiedMarks.Count - 1; $i -ge 0; $i--){
        $m = $script:UiCopiedMarks[$i]
        if(!$m){ continue }

        $dx = $m.X - $mouseX
        $dy = $m.Y - $mouseY

        if([math]::Sqrt($dx*$dx + $dy*$dy) -lt ((Get-MarkImageRadius) * (Get-MarkScale $m))){
            return $m
        }
    }

    return $null
}

function Clear-SelectedMark{

    $script:SelectedMarkKind = $null
    $script:SelectedMarkRowIndex = -1
    $script:SelectedUiCopyId = $null
}

function Select-OriginalMark($rowIndex,$syncTableSelection = $true){

    Clear-SelectedMark
    $script:SelectedMarkKind = "Original"
    $script:SelectedMarkRowIndex = [int]$rowIndex

    if(
        $syncTableSelection -and
        $rowIndex -ge 0 -and
        $rowIndex -lt $table.Rows.Count
    ){
        $table.ClearSelection()
        $table.Rows[$rowIndex].Selected = $true
        $table.CurrentCell = $table.Rows[$rowIndex].Cells[0]
        if($table.Rows[$rowIndex].Visible){
            $table.FirstDisplayedScrollingRowIndex = $rowIndex
        }
    }
}

function Select-UiCopiedMark($copyId){

    Clear-SelectedMark
    $script:SelectedMarkKind = "Copy"
    $script:SelectedUiCopyId = [int]$copyId
}

function Adjust-AllCurrentMarkScales($scaleFactor){
    if([Math]::Abs([double]$scaleFactor) -lt 0.0001){ return $false }

    $changed = $false

    foreach($mark in @($script:marks)){
        if(!$mark){ continue }
        $currentScale = Get-MarkScale $mark
        $nextScale = Normalize-MarkScale ($currentScale * $scaleFactor)
        if([Math]::Abs($nextScale - $currentScale) -lt 0.001){ continue }
        $mark | Add-Member -NotePropertyName Scale -NotePropertyValue $nextScale -Force
        $changed = $true
    }

    foreach($mark in @($script:UiCopiedMarks)){
        if(!$mark){ continue }
        $currentScale = Get-MarkScale $mark
        $nextScale = Normalize-MarkScale ($currentScale * $scaleFactor)
        if([Math]::Abs($nextScale - $currentScale) -lt 0.001){ continue }
        $mark | Add-Member -NotePropertyName Scale -NotePropertyValue $nextScale -Force
        $changed = $true
    }

    if(-not $changed){ return $false }

    Request-CanvasRedraw
    Save-CurrentPageState
    Queue-SessionStateSave
    return $true
}

function Test-TextInputActive{
    $activeControl = $form.ActiveControl
    if($activeControl -is [System.Windows.Forms.TextBoxBase]){
        return $true
    }
    if($activeControl -eq $table){
        $editingControl = $table.EditingControl
        if($editingControl -is [System.Windows.Forms.TextBoxBase]){
            return $true
        }
    }
    return $false
}

function Update-CopiedUiNote{

    if(!$txtCopiedUi){ return }

    $copiedSteps = @(
        foreach($mark in @($script:UiCopiedMarks)){
            if(!$mark){ continue }
            [string]$mark.Index
        }
    )

    $txtCopiedUi.Text = if($copiedSteps.Count -gt 0){
        ("CoppyUI:" + ($copiedSteps -join ","))
    }
    else{
        "CoppyUI:"
    }
}

function Update-CopyViewButton{

    if(!$btnCopyView){ return }

    if($script:CopyViewOnly){
        $btnCopyView.Text = "Copy View On"
        $btnCopyView.BackColor = [System.Drawing.Color]::FromArgb(214,238,255)
        if($miAdvanceCopyView){
            $miAdvanceCopyView.Text = "Copy View On"
            $miAdvanceCopyView.Checked = $true
        }
    }
    else{
        $btnCopyView.Text = "Copy View Off"
        $btnCopyView.BackColor = [System.Drawing.SystemColors]::Control
        if($miAdvanceCopyView){
            $miAdvanceCopyView.Text = "Copy View Off"
            $miAdvanceCopyView.Checked = $false
        }
    }
}

function Update-AdvancePanelButton{

    if(!$btnAdvance){ return }
    $btnAdvance.BackColor = [System.Drawing.SystemColors]::Control
    if($advanceMenu){
        $btnAdvance.ContextMenuStrip = $advanceMenu
    }
}

function Update-PdfTextZonesButton{

    if(!$btnPdfTextZones){ return }

    if($script:ShowPdfTextZones){
        $btnPdfTextZones.Text = "Text Zones On"
        $btnPdfTextZones.BackColor = [System.Drawing.Color]::FromArgb(214,238,255)
        if($miAdvancePdfTextZones){
            $miAdvancePdfTextZones.Text = "Text Zones On"
            $miAdvancePdfTextZones.Checked = $true
        }
    }
    else{
        $btnPdfTextZones.Text = "Text Zones Off"
        $btnPdfTextZones.BackColor = [System.Drawing.SystemColors]::Control
        if($miAdvancePdfTextZones){
            $miAdvancePdfTextZones.Text = "Text Zones Off"
            $miAdvancePdfTextZones.Checked = $false
        }
    }
}

function Update-InspectionSampleAutoFillButton{

    if($miAdvanceSampleAutoFill){
        if($script:InspectionSampleAutoFillEnabled){
            $miAdvanceSampleAutoFill.Text = "Sample Auto Fill On"
            $miAdvanceSampleAutoFill.Checked = $true
        }
        else{
            $miAdvanceSampleAutoFill.Text = "Sample Auto Fill Off"
            $miAdvanceSampleAutoFill.Checked = $false
        }
    }
}

function Update-TranslateLensButton{
    if(!$btnTranslateLens){ return }
    $btnTranslateLens.Text = "Translator"
    $btnTranslateLens.BackColor = [System.Drawing.SystemColors]::Control
    if($miAdvanceTranslate){
        if($script:TranslateLensEnabled){
            $miAdvanceTranslate.Text = "Translate On"
            $miAdvanceTranslate.Checked = $true
        }
        else{
            $miAdvanceTranslate.Text = "Translate"
            $miAdvanceTranslate.Checked = $false
        }
    }
}

function Clear-TranslateLensResult{
    $script:TranslateLensRect = $null
    $script:TranslateLensPendingRect = $null
    $script:TranslateLensResult = $null
    $script:TranslateLensPoint = $null
    $script:TranslateLensLastRectKey = ""
    $script:TranslateLensPendingRectKey = ""
    if($script:TranslateLensTimer){ $script:TranslateLensTimer.Stop() }
}

function Start-WindowTranslator{
    $launcherPath = Join-Path $PSScriptRoot 'Launch-WindowTranslator.ps1'
    $exePath = Join-Path $PSScriptRoot 'tools\WindowTranslator\WindowTranslator-full-0.9.21\WindowTranslator.exe'

    try{
        if(Test-Path $launcherPath){
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $PSScriptRoot -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcherPath) | Out-Null
            Write-OcrDebug "WindowTranslator launched."
            return $true
        }

        if(Test-Path $exePath){
            Start-Process -FilePath $exePath -WorkingDirectory (Split-Path -Parent $exePath) | Out-Null
            Write-OcrDebug "WindowTranslator launched."
            return $true
        }
    }
    catch{
        Write-OcrDebug ("WindowTranslator launch failed: " + $_.Exception.Message)
        return $false
    }

    Write-OcrDebug "WindowTranslator not found."
    return $false
}

function Set-TranslateLensEnabled([bool]$enabled){
    $script:TranslateLensEnabled = $enabled
    if($enabled){
        if($script:selectionRect){
            $script:selectionRect = $null
            Clear-PreviewImage
        }
        if($script:CurrentSourcePath -and $script:sourceBitmap){
            try{ Ensure-HiddenTextZonesLoaded | Out-Null } catch{}
        }
        if($txtOcrDebug){
            $txtOcrDebug.Text = "Translate lens ready. Hover only the small area you want to translate."
        }
    }
    else{
        Clear-TranslateLensResult
        if($txtOcrDebug){
            $txtOcrDebug.Text = "Translate lens off."
        }
    }
    Update-TranslateLensButton
    Update-CanvasCursor
    Request-CanvasRedraw
}

function Update-AnnotationToolButtons{
    if($btnYellowPen){
        $isOn = ($script:AnnotationToolMode -eq "Highlight")
        $btnYellowPen.Text = if($isOn){ "Yellow Pen On" } else { "Yellow Pen Off" }
        $btnYellowPen.BackColor = if($isOn){ [Drawing.Color]::FromArgb(255,255,240,140) } else { [Drawing.SystemColors]::Control }
    }
    if($miAdvanceYellowPen){
        $isOn = ($script:AnnotationToolMode -eq "Highlight")
        $miAdvanceYellowPen.Text = if($isOn){ "Yellow Pen On" } else { "Yellow Pen Off" }
        $miAdvanceYellowPen.Checked = $isOn
    }
    if($btnEraser){
        $isOn = ($script:AnnotationToolMode -eq "Eraser")
        $btnEraser.Text = if($isOn){ "Eraser On" } else { "Eraser Off" }
        $btnEraser.BackColor = if($isOn){ [Drawing.Color]::FromArgb(255,235,235,235) } else { [Drawing.SystemColors]::Control }
    }
    if($miAdvanceEraser){
        $isOn = ($script:AnnotationToolMode -eq "Eraser")
        $miAdvanceEraser.Text = if($isOn){ "Eraser On" } else { "Eraser Off" }
        $miAdvanceEraser.Checked = $isOn
    }
}

function Get-BalloonStrokeColor{
    switch([string]$script:BalloonColorPreset){
        "Yellow" { return [Drawing.Color]::FromArgb(255,210,150,0) }
        "Blue" { return [Drawing.Color]::FromArgb(255,45,112,210) }
        "Green" { return [Drawing.Color]::FromArgb(255,28,150,72) }
        "Orange" { return [Drawing.Color]::FromArgb(255,224,92,18) }
        default { return [Drawing.Color]::Red }
    }
}

function Update-BalloonColorMenuState{
    if($miAdvanceBalloonColor){
        $miAdvanceBalloonColor.Text = "Balloon Color: $($script:BalloonColorPreset)"
    }

    foreach($itemInfo in @(
        @{ Item = $miAdvanceBalloonWhite; Preset = "White" },
        @{ Item = $miAdvanceBalloonYellow; Preset = "Yellow" },
        @{ Item = $miAdvanceBalloonBlue; Preset = "Blue" },
        @{ Item = $miAdvanceBalloonGreen; Preset = "Green" },
        @{ Item = $miAdvanceBalloonOrange; Preset = "Orange" }
    )){
        if($itemInfo.Item){
            $itemInfo.Item.Checked = ([string]$script:BalloonColorPreset -eq [string]$itemInfo.Preset)
        }
    }
}

function Set-BalloonColorPreset($preset){
    $allowed = @("White","Yellow","Blue","Green","Orange")
    $normalized = [string]$preset
    if($allowed -notcontains $normalized){ $normalized = "White" }

    $script:BalloonColorPreset = $normalized
    Update-BalloonColorMenuState
    Request-CanvasRedraw
    Save-SessionState
}

function Update-TrainingSaveExportMenuState{
    if(!$miAdvanceTrainingExport){ return }
    if($script:TrainingSaveExportEnabled){
        $miAdvanceTrainingExport.Text = "Training Save/Export On"
        $miAdvanceTrainingExport.Checked = $true
    }
    else{
        $miAdvanceTrainingExport.Text = "Training Save/Export Off"
        $miAdvanceTrainingExport.Checked = $false
    }
}

function Set-TrainingSaveExportEnabled([bool]$enabled){
    $script:TrainingSaveExportEnabled = [bool]$enabled
    Update-TrainingSaveExportMenuState
    Save-SessionState
    if($txtOcrDebug){
        $txtOcrDebug.Text = if($script:TrainingSaveExportEnabled){ "Training save/export enabled." } else { "Training save/export disabled." }
    }
}

function Update-JudgeOkMenuItem{
    $script:JudgeOkAutoFillEnabled = $false
}

function Request-QuantityUpdate($defaultQty = $null,$title = "QTY Update",$prompt = "QTY update bằng bao nhiêu?"){
    if([string]::IsNullOrWhiteSpace([string]$defaultQty)){
        $defaultQty = if([string]::IsNullOrWhiteSpace([string]$script:PartQuantity)){ "1" } else { [string]$script:PartQuantity }
    }
    else{
        $defaultQty = [string]$defaultQty
    }
    $qtyValue = [Microsoft.VisualBasic.Interaction]::InputBox($prompt,$title,$defaultQty)
    if($qtyValue -eq $null){ return $null }

    $qtyText = Normalize-DrawingMetadataText $qtyValue
    if([string]::IsNullOrWhiteSpace($qtyText)){ return $null }

    $parsedQty = 0
    if(-not [int]::TryParse($qtyText,[ref]$parsedQty) -or $parsedQty -le 0){
        [System.Windows.Forms.MessageBox]::Show("QTY must be a positive integer.",$title,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $null
    }

    return [string]$parsedQty
}

function Update-SessionQuantity($sessionFilePath,$quantity){
    if([string]::IsNullOrWhiteSpace([string]$sessionFilePath) -or !(Test-Path $sessionFilePath)){ return $false }
    if([string]::IsNullOrWhiteSpace([string]$quantity)){ return $false }

    $state = Import-SessionStateFromClixmlXml $sessionFilePath
    if(!$state){ $state = Import-ClixmlSafe $sessionFilePath }
    if(!$state){ return $false }

    Set-StatePropertyValue $state "PartQuantity" ([string]$quantity)
    return (Export-ClixmlSafe $sessionFilePath $state)
}

function Request-QuantityUpdateForDuplicateDrawing($metadata,$matches){
    if(!$metadata){ return $null }

    $defaultQty = if(-not [string]::IsNullOrWhiteSpace([string]$metadata.Quantity)){ [string]$metadata.Quantity } else { [string]$script:PartQuantity }
    $qty = Request-QuantityUpdate $defaultQty "Duplicate Drawing QTY Update" "Bản vẽ trùng. QTY update bằng bao nhiêu?"
    if([string]::IsNullOrWhiteSpace([string]$qty)){ return $null }

    foreach($match in @($matches)){
        if(!$match){ continue }
        Update-SessionQuantity $match.SessionPath $qty | Out-Null
    }

    $targetKey = Get-DrawingIdentityKey $metadata.PartNo $metadata.MoldName
    $currentKey = Get-DrawingIdentityKey $script:PartNo $script:MoldName
    if(-not [string]::IsNullOrWhiteSpace($targetKey) -and $targetKey -eq $currentKey){
        $script:PartQuantity = [string]$qty
    }

    return [string]$qty
}

function Set-AnnotationToolMode([string]$mode){
    $normalizedMode = if([string]::IsNullOrWhiteSpace([string]$mode)){ "OCR" } else { [string]$mode }
    if($normalizedMode -ne "Highlight" -and $normalizedMode -ne "Eraser"){
        $normalizedMode = "OCR"
    }
    $script:AnnotationToolMode = $normalizedMode
    if($normalizedMode -ne "OCR"){
        $script:dragging = $false
        $script:selectionRect = $null
        Clear-PreviewImage
    }
    if($normalizedMode -ne "Highlight"){
        $script:IsDrawingHighlightStroke = $false
        $script:CurrentHighlightStroke = $null
    }
    Update-AnnotationToolButtons
    Update-CanvasCursor
    Request-CanvasRedraw
}

function Get-TranslateLensRectAtPoint($imagePoint){
    if(!$script:sourceBitmap -or !$imagePoint){ return $null }
    $zoomSafe = [Math]::Max($script:zoom,0.0001)
    $imageWidth = [double]$script:TranslateLensPixelWidth / $zoomSafe
    $imageHeight = [double]$script:TranslateLensPixelHeight / $zoomSafe
    $x = [double]$imagePoint.X - ($imageWidth / 2.0)
    $y = [double]$imagePoint.Y - ($imageHeight / 2.0)
    $x = [Math]::Max(0,[Math]::Min(($script:sourceBitmap.Width - $imageWidth),$x))
    $y = [Math]::Max(0,[Math]::Min(($script:sourceBitmap.Height - $imageHeight),$y))
    return New-Object Drawing.RectangleF([float]$x,[float]$y,[float]$imageWidth,[float]$imageHeight)
}

function Get-TranslateLensRectKey($rect){
    if(!$rect){ return "" }
    return ("{0}:{1}:{2}:{3}:{4}" -f [Math]::Round($rect.X,1),[Math]::Round($rect.Y,1),[Math]::Round($rect.Width,1),[Math]::Round($rect.Height,1),$script:SelectedPageIndex)
}

function Request-TranslateLensRefresh($imagePoint){
    if(-not $script:TranslateLensEnabled -or !$script:sourceBitmap){ return }
    $rect = Get-TranslateLensRectAtPoint $imagePoint
    if(!$rect){ return }

    $rectKey = Get-TranslateLensRectKey $rect
    $script:TranslateLensPoint = $imagePoint

    if($script:TranslateLensResult -and $script:TranslateLensRect){
        try{
            if($script:TranslateLensRect.Contains([int]$imagePoint.X,[int]$imagePoint.Y)){
                return
            }
        }
        catch{}
    }

    if(
        $rectKey -eq $script:TranslateLensLastRectKey -or
        $rectKey -eq $script:TranslateLensPendingRectKey
    ){
        return
    }

    $script:TranslateLensRect = $rect
    $script:TranslateLensPendingRect = $rect
    $script:TranslateLensPendingRectKey = $rectKey
    if($script:TranslateLensTimer){
        $script:TranslateLensTimer.Stop()
        $script:TranslateLensTimer.Start()
    }
    Request-CanvasRedraw
}

function Normalize-TranslateLensSourceText($text){
    if([string]::IsNullOrWhiteSpace([string]$text)){ return "" }
    $value = [string]$text
    $value = $value -replace "\r\n?","`n"
    $value = $value -replace "[`t ]{2,}"," "
    $value = $value -replace " ?`n ?","`n"
    return $value.Trim()
}

function Get-TranslateLensDictionary{
    if($script:TranslateLensDictionary){ return $script:TranslateLensDictionary }
    $script:TranslateLensDictionary = [ordered]@{
        "バリ無きこと" = "Khong duoc co ba via"
        "バリなし" = "Khong co ba via"
        "バリ" = "Ba via"
        "面取り" = "Vat mep"
        "テーパー" = "Con / taper"
        "アンダーカット" = "Undercut"
        "ストレート部" = "Phan thang"
        "品番" = "Ma hang"
        "個数" = "So luong"
        "尺度" = "Ty le"
        "詳細" = "Chi tiet"
        "参考" = "Tham khao"
        "コーナー" = "Goc"
        "NO BURR" = "Khong duoc co ba via"
        "REMOVE BURRS" = "Loai bo ba via"
        "BREAK SHARP EDGES" = "Pha canh sac"
        "CHAMFER" = "Vat mep"
        "UNDERCUT" = "Undercut"
        "TAPER" = "Con"
        "DETAIL" = "Chi tiet"
        "SCALE" = "Ty le"
        "PART NO" = "Ma hang"
        "QTY" = "So luong"
        "MATERIAL" = "Vat lieu"
        "SURFACE ROUGHNESS" = "Do nham be mat"
        "TOLERANCE" = "Dung sai"
        "REFERENCE" = "Tham khao"
        "MAX" = "Lon nhat"
        "MIN" = "Nho nhat"
        "CONTROLLED" = "Kiem soat"
        "INTERNAL USE" = "Noi bo"
        "ORIGINAL" = "Ban goc"
        "INSPECTION REPORT" = "Bao cao kiem tra"
    }
    return $script:TranslateLensDictionary
}

function Normalize-DrawingMetadataText($value){
    if($null -eq $value){ return "" }
    return (([string]$value) -replace '\s+',' ').Trim()
}

function Get-DrawingIdentityKey($partNo,$moldName){
    $part = (Normalize-DrawingMetadataText $partNo).ToUpperInvariant()
    $mold = (Normalize-DrawingMetadataText $moldName).ToUpperInvariant()
    if([string]::IsNullOrWhiteSpace($part) -and [string]::IsNullOrWhiteSpace($mold)){ return "" }
    return ($part + [char]31 + $mold)
}

function Get-AdaptiveDetectorSourceName($item){
    if(!$item){ return "" }
    if($item.PSObject.Properties.Name -contains "OriginalZoneSource" -and -not [string]::IsNullOrWhiteSpace([string]$item.OriginalZoneSource)){
        return [string]$item.OriginalZoneSource
    }
    if($item.PSObject.Properties.Name -contains "Source" -and -not [string]::IsNullOrWhiteSpace([string]$item.Source)){
        return [string]$item.Source
    }
    return ""
}

function Get-AdaptiveDetectorRectBucket($rect){
    if(!$rect){ return "none" }
    $w = [double][Math]::Max(1,$rect.Width)
    $h = [double][Math]::Max(1,$rect.Height)
    $area = $w * $h
    $orientation = if($h -gt ($w * 1.25)){ "v" } elseif($w -gt ($h * 1.25)){ "h" } else { "s" }
    $size = if($area -lt 4000){ "xs" } elseif($area -lt 14000){ "sm" } elseif($area -lt 38000){ "md" } else { "lg" }
    return ($orientation + ":" + $size)
}

function Get-AdaptiveDetectorKey($item){
    if(!$item -or !$item.Rect){ return "" }
    $source = (Get-AdaptiveDetectorSourceName $item)
    if([string]::IsNullOrWhiteSpace($source)){ $source = "unknown" }
    return ($source + "|" + (Get-AdaptiveDetectorRectBucket $item.Rect))
}

function Get-AdaptiveDetectorBias($item){
    $key = Get-AdaptiveDetectorKey $item
    if([string]::IsNullOrWhiteSpace($key)){ return 0.0 }
    if(-not $script:AdaptiveDetectorStats.ContainsKey($key)){ return 0.0 }

    $stat = $script:AdaptiveDetectorStats[$key]
    $accept = if($stat.PSObject.Properties.Name -contains "Accept"){ [double]$stat.Accept } else { 0.0 }
    $link = if($stat.PSObject.Properties.Name -contains "Link"){ [double]$stat.Link } else { 0.0 }
    $keepNew = if($stat.PSObject.Properties.Name -contains "KeepNew"){ [double]$stat.KeepNew } else { 0.0 }
    $decline = if($stat.PSObject.Properties.Name -contains "Decline"){ [double]$stat.Decline } else { 0.0 }

    $score = ($accept * 1.8) + ($link * 1.2) + ($keepNew * 0.8) - ($decline * 1.6)
    return [double][Math]::Max(-8.0,[Math]::Min(8.0,$score))
}

function Record-AdaptiveDetectorFeedback($item,$outcome){
    $key = Get-AdaptiveDetectorKey $item
    if([string]::IsNullOrWhiteSpace($key)){ return }

    if(-not $script:AdaptiveDetectorStats.ContainsKey($key)){
        $script:AdaptiveDetectorStats[$key] = [PSCustomObject]@{
            Accept = 0
            Link = 0
            KeepNew = 0
            Decline = 0
        }
    }

    $stat = $script:AdaptiveDetectorStats[$key]
    switch([string]$outcome){
        "accept" { $stat.Accept = [int]$stat.Accept + 1 }
        "link" { $stat.Link = [int]$stat.Link + 1 }
        "keep_new" { $stat.KeepNew = [int]$stat.KeepNew + 1 }
        "decline" { $stat.Decline = [int]$stat.Decline + 1 }
    }
}

function Get-PreferredJobName{
    $nameParts = @()
    $partNo = Normalize-DrawingMetadataText $script:PartNo
    $moldName = Normalize-DrawingMetadataText $script:MoldName

    if(-not [string]::IsNullOrWhiteSpace($partNo)){ $nameParts += $partNo }
    if(-not [string]::IsNullOrWhiteSpace($moldName)){ $nameParts += $moldName }

    $preferred = (($nameParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "-").Trim()
    if(-not [string]::IsNullOrWhiteSpace($preferred)){ return $preferred }
    if(-not [string]::IsNullOrWhiteSpace([string]$script:JobName)){ return (Normalize-DrawingMetadataText $script:JobName) }
    if($script:CurrentSourcePath){ return [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentSourcePath) }
    return "InspectionJob"
}

function Get-PreferredExportJobName{
    $preferredMetadataName = Get-PreferredJobName
    if(-not [string]::IsNullOrWhiteSpace([string]$preferredMetadataName)){
        return $preferredMetadataName
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){
        $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$script:CurrentSourcePath)
        $sourceBaseName = Normalize-DrawingMetadataText $sourceBaseName
        if(-not [string]::IsNullOrWhiteSpace($sourceBaseName)){
            return $sourceBaseName
        }
    }
    return "InspectionJob"
}

function Get-SafeWindowsPathComponent($text,$fallback = "InspectionJob"){
    $value = [string]$text
    $value = $value -replace '[\\/:*?""<>|]',''
    $value = $value.Trim()
    $value = $value.TrimEnd(@([char]' ',[char]'.'))
    if([string]::IsNullOrWhiteSpace($value)){
        return $fallback
    }
    return $value
}

function Get-DrawingMetadataFromState($state){
    $jobName = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "JobName")
    $partNo = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "PartNo")
    $moldName = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "MoldName")
    if(([string]::IsNullOrWhiteSpace($partNo) -or [string]::IsNullOrWhiteSpace($moldName)) -and -not [string]::IsNullOrWhiteSpace($jobName)){
        $nameParts = @($jobName -split '-')
        if($nameParts.Count -ge 2){
            if([string]::IsNullOrWhiteSpace($partNo)){ $partNo = Normalize-DrawingMetadataText ($nameParts[0..($nameParts.Count - 2)] -join "-") }
            if([string]::IsNullOrWhiteSpace($moldName)){ $moldName = Normalize-DrawingMetadataText $nameParts[-1] }
        }
        elseif([string]::IsNullOrWhiteSpace($partNo)){
            $partNo = $jobName
        }
    }

    return [PSCustomObject]@{
        PartNo = $partNo
        MoldName = $moldName
        Quantity = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "PartQuantity")
        Material = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "PartMaterial")
        Hrc = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "PartHrc")
        User = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "PartUser")
        JobName = $jobName
    }
}

function Get-DefaultDrawingMetadata($filePath,$state = $null){
    $metadata = Get-DrawingMetadataFromState $state
    $baseName = if($filePath){ [System.IO.Path]::GetFileNameWithoutExtension($filePath) } else { "" }

    if(
        -not [string]::IsNullOrWhiteSpace($baseName) -and
        [string]::IsNullOrWhiteSpace([string]$metadata.PartNo) -and
        [string]::IsNullOrWhiteSpace([string]$metadata.MoldName)
    ){
        $parts = @($baseName -split '-')
        if($parts.Count -ge 2){
            $metadata.PartNo = Normalize-DrawingMetadataText ($parts[0..($parts.Count - 2)] -join "-")
            $metadata.MoldName = Normalize-DrawingMetadataText $parts[-1]
        }
        else{
            $metadata.PartNo = Normalize-DrawingMetadataText $baseName
        }
    }

    if([string]::IsNullOrWhiteSpace($metadata.Quantity)){
        $metadata.Quantity = "1"
    }
    if($null -eq $metadata.Material){ $metadata.Material = "" }
    if($null -eq $metadata.Hrc){ $metadata.Hrc = "" }
    if([string]::IsNullOrWhiteSpace([string]$metadata.User)){ $metadata.User = "7139" }

    if([string]::IsNullOrWhiteSpace($metadata.JobName)){
        $nameParts = @()
        if(-not [string]::IsNullOrWhiteSpace($metadata.PartNo)){ $nameParts += $metadata.PartNo }
        if(-not [string]::IsNullOrWhiteSpace($metadata.MoldName)){ $nameParts += $metadata.MoldName }
        $metadata.JobName = (($nameParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "-").Trim()
        if([string]::IsNullOrWhiteSpace($metadata.JobName)){ $metadata.JobName = Normalize-DrawingMetadataText $baseName }
    }

    return $metadata
}

function Show-DrawingMetadataDialog($filePath,$state = $null){
    $defaults = Get-DefaultDrawingMetadata $filePath $state

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Drawing Information"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(430,291)
    $dialog.TopMost = $true

    $font = New-Object System.Drawing.Font("Segoe UI",9)

    $labels = @(
        @{ Text = "Part No"; Y = 18 },
        @{ Text = "Mold Name"; Y = 54 },
        @{ Text = "Qty"; Y = 90 },
        @{ Text = "Material"; Y = 126 },
        @{ Text = "HRC"; Y = 162 },
        @{ Text = "User"; Y = 198 }
    )
    foreach($item in $labels){
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $item.Text
        $lbl.Location = New-Object System.Drawing.Point(16,$item.Y)
        $lbl.Size = New-Object System.Drawing.Size(92,24)
        $lbl.Font = $font
        $dialog.Controls.Add($lbl)
    }

    $txtPartNo = New-Object System.Windows.Forms.TextBox
    $txtPartNo.Location = New-Object System.Drawing.Point(116,16)
    $txtPartNo.Size = New-Object System.Drawing.Size(296,24)
    $txtPartNo.Font = $font
    $txtPartNo.Text = [string]$defaults.PartNo
    $dialog.Controls.Add($txtPartNo)

    $txtMoldName = New-Object System.Windows.Forms.TextBox
    $txtMoldName.Location = New-Object System.Drawing.Point(116,52)
    $txtMoldName.Size = New-Object System.Drawing.Size(296,24)
    $txtMoldName.Font = $font
    $txtMoldName.Text = [string]$defaults.MoldName
    $dialog.Controls.Add($txtMoldName)

    $txtQty = New-Object System.Windows.Forms.TextBox
    $txtQty.Location = New-Object System.Drawing.Point(116,88)
    $txtQty.Size = New-Object System.Drawing.Size(120,24)
    $txtQty.Font = $font
    $txtQty.Text = [string]$defaults.Quantity
    $dialog.Controls.Add($txtQty)

    $txtMaterial = New-Object System.Windows.Forms.TextBox
    $txtMaterial.Location = New-Object System.Drawing.Point(116,124)
    $txtMaterial.Size = New-Object System.Drawing.Size(296,24)
    $txtMaterial.Font = $font
    $txtMaterial.Text = [string]$defaults.Material
    $dialog.Controls.Add($txtMaterial)

    $txtHrc = New-Object System.Windows.Forms.TextBox
    $txtHrc.Location = New-Object System.Drawing.Point(116,160)
    $txtHrc.Size = New-Object System.Drawing.Size(120,24)
    $txtHrc.Font = $font
    $txtHrc.Text = [string]$defaults.Hrc
    $dialog.Controls.Add($txtHrc)

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(116,196)
    $txtUser.Size = New-Object System.Drawing.Size(120,24)
    $txtUser.Font = $font
    $txtUser.Text = [string]$defaults.User
    $dialog.Controls.Add($txtUser)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Thong tin nay duoc dung de canh bao trung ban ve truoc khi danh so."
    $lblHint.Location = New-Object System.Drawing.Point(16,232)
    $lblHint.Size = New-Object System.Drawing.Size(396,24)
    $lblHint.Font = $font
    $dialog.Controls.Add($lblHint)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Location = New-Object System.Drawing.Point(246,256)
    $btnOk.Size = New-Object System.Drawing.Size(80,26)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Add_Click({
        $partNoValue = Normalize-DrawingMetadataText $txtPartNo.Text
        $moldNameValue = Normalize-DrawingMetadataText $txtMoldName.Text
        $quantityValue = Normalize-DrawingMetadataText $txtQty.Text

        if([string]::IsNullOrWhiteSpace($partNoValue)){
            [System.Windows.Forms.MessageBox]::Show($dialog,"Part No is required.","Drawing Information",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::None
            $txtPartNo.Focus()
            return
        }
        if([string]::IsNullOrWhiteSpace($moldNameValue)){
            [System.Windows.Forms.MessageBox]::Show($dialog,"Mold Name is required.","Drawing Information",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::None
            $txtMoldName.Focus()
            return
        }
        if([string]::IsNullOrWhiteSpace($quantityValue)){
            [System.Windows.Forms.MessageBox]::Show($dialog,"Qty is required.","Drawing Information",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::None
            $txtQty.Focus()
            return
        }
    })
    $dialog.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(332,256)
    $btnCancel.Size = New-Object System.Drawing.Size(80,26)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($btnCancel)

    $dialog.AcceptButton = $btnOk
    $dialog.CancelButton = $btnCancel

    if($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK){
        $dialog.Dispose()
        return $null
    }

    $partNo = Normalize-DrawingMetadataText $txtPartNo.Text
    $moldName = Normalize-DrawingMetadataText $txtMoldName.Text
    $quantity = Normalize-DrawingMetadataText $txtQty.Text
    $material = Normalize-DrawingMetadataText $txtMaterial.Text
    $hrc = Normalize-DrawingMetadataText $txtHrc.Text
    $user = Normalize-DrawingMetadataText $txtUser.Text

    $dialog.Dispose()

    if([string]::IsNullOrWhiteSpace($partNo)){
        [System.Windows.Forms.MessageBox]::Show("Part No is required.")
        return $null
    }
    if([string]::IsNullOrWhiteSpace($moldName)){
        [System.Windows.Forms.MessageBox]::Show("Mold Name is required.")
        return $null
    }
    if([string]::IsNullOrWhiteSpace($quantity)){
        [System.Windows.Forms.MessageBox]::Show("Qty is required.")
        return $null
    }

    $jobName = ((@($partNo,$moldName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "-").Trim()
    if([string]::IsNullOrWhiteSpace($jobName)){ $jobName = $partNo }

    return [PSCustomObject]@{
        PartNo = $partNo
        MoldName = $moldName
        Quantity = $quantity
        Material = $material
        Hrc = $hrc
        User = $user
        JobName = $jobName
    }
}

function Find-DuplicateMarkedSessionsByMetadata($partNo,$moldName,$excludeFingerprint = $null){
    $matches = [System.Collections.Generic.List[object]]::new()
    $seenKeys = @{}
    $targetKey = Get-DrawingIdentityKey $partNo $moldName
    if([string]::IsNullOrWhiteSpace($targetKey)){ return @($matches) }
    if(!(Test-Path $script:SessionStoreDir)){ return @($matches) }

    foreach($sessionFile in @(Get-ChildItem -Path $script:SessionStoreDir -Filter "*.clixml" -File -ErrorAction SilentlyContinue)){
        $fastMeta = Get-DrawingMetadataFromFingerprintedLabel $sessionFile.FullName
        $fastKey = Get-DrawingIdentityKey $fastMeta.PartNo $fastMeta.MoldName
        if(
            -not [string]::IsNullOrWhiteSpace($fastKey) -and
            $fastKey -ne $targetKey
        ){
            continue
        }

        $cacheKey = ([string]$sessionFile.FullName).ToUpperInvariant()
        $cacheStamp = ([string]$sessionFile.Length) + "|" + ([string]$sessionFile.LastWriteTimeUtc.Ticks)
        $cached = $null
        if($script:DuplicateSessionMetadataCache.ContainsKey($cacheKey)){
            $candidate = $script:DuplicateSessionMetadataCache[$cacheKey]
            if(
                $candidate -and
                $candidate.PSObject.Properties.Name -contains "Stamp" -and
                [string]$candidate.Stamp -eq $cacheStamp
            ){
                $cached = $candidate
            }
        }

        if(-not $cached){
            $state = Import-SessionStateFromClixmlXml $sessionFile.FullName
            if(!$state){ $state = Import-ClixmlSafe $sessionFile.FullName }
            if(!$state){ continue }

            $stateMeta = Get-DrawingMetadataFromState $state
            if([string]::IsNullOrWhiteSpace([string]$stateMeta.PartNo)){ $stateMeta.PartNo = [string]$fastMeta.PartNo }
            if([string]::IsNullOrWhiteSpace([string]$stateMeta.MoldName)){ $stateMeta.MoldName = [string]$fastMeta.MoldName }
            if([string]::IsNullOrWhiteSpace([string]$stateMeta.JobName)){ $stateMeta.JobName = [string]$fastMeta.JobName }
            $entryCount = Get-SessionEntryCount $state
            $fingerprint = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "SourceFingerprint")
            if([string]::IsNullOrWhiteSpace($fingerprint)){
                $fingerprint = Normalize-DrawingMetadataText (Get-SessionFingerprintFromPath $sessionFile.FullName)
            }
            $sourcePath = Normalize-DrawingMetadataText (Get-StatePropertyValue $state "SourcePath")
            $cached = [PSCustomObject]@{
                Stamp = [string]$cacheStamp
                PartNo = [string]$stateMeta.PartNo
                MoldName = [string]$stateMeta.MoldName
                Quantity = [string]$stateMeta.Quantity
                EntryCount = [int]$entryCount
                Fingerprint = [string]$fingerprint
                SourcePath = [string]$sourcePath
            }
            $script:DuplicateSessionMetadataCache[$cacheKey] = $cached
        }

        $stateKey = Get-DrawingIdentityKey $cached.PartNo $cached.MoldName
        if($stateKey -ne $targetKey){ continue }

        $entryCount = [int]$cached.EntryCount
        if($entryCount -le 0){ continue }

        $fingerprint = [string]$cached.Fingerprint
        if(-not [string]::IsNullOrWhiteSpace($excludeFingerprint) -and [string]::Equals($fingerprint,$excludeFingerprint,[System.StringComparison]::OrdinalIgnoreCase)){
            continue
        }

        $sourcePath = [string]$cached.SourcePath
        $label = if(-not [string]::IsNullOrWhiteSpace($sourcePath)){ [System.IO.Path]::GetFileName($sourcePath) } else { [System.IO.Path]::GetFileNameWithoutExtension($sessionFile.Name) }
        $dedupeKey = $null
        if(-not [string]::IsNullOrWhiteSpace($fingerprint)){
            $dedupeKey = "fp:" + $fingerprint.ToUpperInvariant()
        } elseif(-not [string]::IsNullOrWhiteSpace($sourcePath)){
            $dedupeKey = "src:" + $sourcePath.ToUpperInvariant()
        } elseif(-not [string]::IsNullOrWhiteSpace($label)){
            $dedupeKey = "label:" + $label.ToUpperInvariant()
        } else {
            $dedupeKey = "session:" + $sessionFile.FullName.ToUpperInvariant()
        }
        if($seenKeys.ContainsKey($dedupeKey)){ continue }
        $seenKeys[$dedupeKey] = $true

        [void]$matches.Add([PSCustomObject]@{
            SessionPath = $sessionFile.FullName
            SourcePath = $sourcePath
            SourceFingerprint = $fingerprint
            Label = $label
            EntryCount = [int]$entryCount
            PartNo = [string]$cached.PartNo
            MoldName = [string]$cached.MoldName
            Quantity = [string]$cached.Quantity
        })
    }

    return @($matches)
}

function Confirm-LoadSourceWithDuplicateWarning($filePath,$metadata){
    if(!$metadata){ return $false }

    $matches = @(Find-DuplicateMarkedSessionsByMetadata $metadata.PartNo $metadata.MoldName)
    if($matches.Count -le 0){ return $true }
    $updatedQty = Request-QuantityUpdateForDuplicateDrawing $metadata $matches
    $qtyUpdateLine = if(-not [string]::IsNullOrWhiteSpace([string]$updatedQty)){ "QTY updated to: " + [string]$updatedQty } else { "QTY update canceled." }

    $lines = @(
        "Duplicate drawing already exists.",
        ("Part No: " + [string]$metadata.PartNo),
        ("Mold Name: " + [string]$metadata.MoldName),
        "",
        $qtyUpdateLine,
        "",
        "A drawing with the same Part No and Mold Name already exists in session/cache.",
        "Load is blocked immediately to avoid duplicate numbering."
    )
    [System.Windows.Forms.MessageBox]::Show(($lines -join [Environment]::NewLine),"Duplicate Drawing Locked",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    return $false
}

function Open-DuplicateDrawingSession($match){
    if(!$match -or [string]::IsNullOrWhiteSpace([string]$match.SessionPath) -or !(Test-Path $match.SessionPath)){ return $false }

    $state = Import-SessionStateFromClixmlXml $match.SessionPath
    if(!$state){ $state = Import-ClixmlSafe $match.SessionPath }
    if(!$state){ return $false }

    $stateMetadata = Get-DrawingMetadataFromState $state
    $updatedQty = Request-QuantityUpdate $stateMetadata.Quantity "Existing Drawing QTY Update" "Đã có bản vẽ cũ. QTY update bằng bao nhiêu?"
    if([string]::IsNullOrWhiteSpace([string]$updatedQty)){ return $false }

    Set-StatePropertyValue $state "PartQuantity" ([string]$updatedQty)
    if(-not (Restore-SessionFromCacheState $state $match.SessionPath)){
        [System.Windows.Forms.MessageBox]::Show("Không mở lại được session cũ từ render cache.")
        return $false
    }

    $script:PartQuantity = [string]$updatedQty
    Save-SessionState
    return $true
}

function Get-TranslateLensLanguage($text){
    if([string]::IsNullOrWhiteSpace([string]$text)){ return "Unknown" }
    if($text -match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]'){ return "Japanese" }
    if($text -match '[A-Za-z]'){ return "English" }
    return "Unknown"
}

function Get-TranslateLensTranslation($text){
    $sourceText = Normalize-TranslateLensSourceText $text
    if([string]::IsNullOrWhiteSpace($sourceText)){ return "" }
    if($script:TranslateLensTranslationCache.ContainsKey($sourceText)){
        return [string]$script:TranslateLensTranslationCache[$sourceText]
    }

    $dictionary = Get-TranslateLensDictionary
    $translated = $sourceText
    $changed = $false

    foreach($entry in @($dictionary.GetEnumerator() | Sort-Object { $_.Key.Length } -Descending)){
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        if($translated.Contains($key)){
            $translated = $translated.Replace($key,$value)
            $changed = $true
            continue
        }
        if($translated.ToUpperInvariant().Contains($key.ToUpperInvariant())){
            $translated = ([regex]::new([regex]::Escape($key),[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Replace($translated,$value)
            $changed = $true
        }
    }

    if(-not $changed){
        $translated = $sourceText
    }
    $script:TranslateLensTranslationCache[$sourceText] = $translated
    return $translated
}

function Get-TranslateLensRectIntersectionArea($a,$b){
    if(!$a -or !$b){ return 0.0 }
    $left = [Math]::Max([double]$a.Left,[double]$b.Left)
    $top = [Math]::Max([double]$a.Top,[double]$b.Top)
    $right = [Math]::Min([double]$a.Right,[double]$b.Right)
    $bottom = [Math]::Min([double]$a.Bottom,[double]$b.Bottom)
    if($right -le $left -or $bottom -le $top){ return 0.0 }
    return [double](($right - $left) * ($bottom - $top))
}

function Get-TranslateLensZoneAtPoint($point){
    if(!$point){ return $null }
    try{ Ensure-HiddenTextZonesLoaded | Out-Null } catch{}
    if(!$script:PdfTextLayerZones -or @($script:PdfTextLayerZones).Count -le 0){ return $null }
    $hits = @()
    foreach($zone in @($script:PdfTextLayerZones)){
        if(!$zone -or !$zone.Rect){ continue }
        $isDimension = $false
        if($zone.PSObject.Properties.Name -contains "IsDimension"){
            $isDimension = [bool]$zone.IsDimension
        }
        $text = ""
        if((-not $isDimension) -and $zone.PSObject.Properties.Name -contains "Text" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Text)){
            $text = [string]$zone.Text
        }
        elseif($zone.PSObject.Properties.Name -contains "RawText" -and -not [string]::IsNullOrWhiteSpace([string]$zone.RawText)){
            $text = [string]$zone.RawText
        }
        elseif($zone.PSObject.Properties.Name -contains "Text"){
            $text = [string]$zone.Text
        }
        $text = Normalize-TranslateLensSourceText $text
        if([string]::IsNullOrWhiteSpace($text)){ continue }

        $containsPoint = $zone.Rect.Contains([int]$point.X,[int]$point.Y)
        $centerX = [double]$zone.Rect.X + ([double]$zone.Rect.Width / 2.0)
        $centerY = [double]$zone.Rect.Y + ([double]$zone.Rect.Height / 2.0)
        $dx = ($centerX - [double]$point.X)
        $dy = ($centerY - [double]$point.Y)
        $distance = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
        if(-not $containsPoint){
            $distanceThreshold = [Math]::Max(18.0,(40.0 / [Math]::Max($script:zoom,0.0001)))
            if($distance -gt $distanceThreshold){ continue }
        }

        $area = [double]([Math]::Max(1,$zone.Rect.Width) * [Math]::Max(1,$zone.Rect.Height))
        $source = if($zone.PSObject.Properties.Name -contains "Source"){ [string]$zone.Source } else { "" }
        $hits += [PSCustomObject]@{
            Zone = $zone
            Text = $text
            Contains = $containsPoint
            Distance = [double]$distance
            Area = $area
            Source = $source
            IsDimension = $isDimension
        }
    }
    if($hits.Count -le 0){ return $null }
    return @(
        $hits |
        Sort-Object `
            @{ Expression = { if($_.Contains){ 0 } else { 1 } }; Descending = $false }, `
            @{ Expression = { if($_.IsDimension){ 0 } else { 1 } }; Descending = $false }, `
            @{ Expression = { $_.Distance }; Descending = $false }, `
            @{ Expression = { $_.Area }; Descending = $false }
    )[0]
}

function Get-TranslateLensOcrTextFromRect($rect){
    if(!$script:sourceBitmap -or !$rect){ return "" }
    $realRect = Convert-ToImageRect $rect
    if(!$realRect -or $realRect.Width -le 2 -or $realRect.Height -le 2){ return "" }

    $padX = [Math]::Max(6,[int][Math]::Round($realRect.Width * 0.18))
    $padY = [Math]::Max(6,[int][Math]::Round($realRect.Height * 0.18))
    $left = [Math]::Max(0,($realRect.X - $padX))
    $top = [Math]::Max(0,($realRect.Y - $padY))
    $right = [Math]::Min($script:sourceBitmap.Width,($realRect.Right + $padX))
    $bottom = [Math]::Min($script:sourceBitmap.Height,($realRect.Bottom + $padY))
    $expandedRect = New-Object Drawing.Rectangle($left,$top,[Math]::Max(1,($right - $left)),[Math]::Max(1,($bottom - $top)))

    $crop = $null
    $prepared = $null
    $scaledBitmaps = @()
    try{
        $crop = $script:sourceBitmap.Clone($expandedRect,$script:sourceBitmap.PixelFormat)

        foreach($scale in @(4,6,8)){
            $scaled = New-Object Drawing.Bitmap ([Math]::Max(1,($crop.Width * $scale))),([Math]::Max(1,($crop.Height * $scale)))
            $graphics = [Drawing.Graphics]::FromImage($scaled)
            try{
                $graphics.Clear([Drawing.Color]::White)
                $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($crop,0,0,$scaled.Width,$scaled.Height)
            }
            finally{
                $graphics.Dispose()
            }
            $scaledBitmaps += [PSCustomObject]@{
                Bitmap = $scaled
                Scale = $scale
            }
        }

        $bestText = ""
        $bestScore = [double]::NegativeInfinity
        foreach($scaledEntry in @($scaledBitmaps)){
            $candidateVariants = @(
                [PSCustomObject]@{ Bitmap = $scaledEntry.Bitmap; Label = ("raw-{0}" -f $scaledEntry.Scale) }
            )

            $prepared = Prepare-FastOcrCropBitmap $scaledEntry.Bitmap
            if($prepared -is [System.Drawing.Bitmap]){
                $candidateVariants += [PSCustomObject]@{ Bitmap = $prepared; Label = ("prepared-{0}" -f $scaledEntry.Scale) }
            }

            foreach($candidate in $candidateVariants){
                $texts = @()

                $detail = Run-OCRDetailed $candidate.Bitmap
                if($detail -and @($detail.Lines).Count -gt 0){
                    $texts += ((@($detail.Lines) | ForEach-Object { ([string]$_.Text).Trim() } | Where-Object { $_ }) -join [Environment]::NewLine)
                }
                elseif($detail){
                    $texts += [string]$detail.Text
                }

                $texts += (Run-OCR $candidate.Bitmap)

                foreach($candidateText in @($texts)){
                    $text = Normalize-TranslateLensSourceText $candidateText
                    if([string]::IsNullOrWhiteSpace($text)){ continue }

                    $compact = ($text -replace '\s','')
                    $score = $compact.Length
                    if($text -match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]'){ $score += 18 }
                    if($text -match '[A-Za-z]{2,}'){ $score += 8 }
                    if($candidate.Label -like 'prepared-*'){ $score += 3 }
                    if($candidate.Label -like 'raw-8' -or $candidate.Label -like 'prepared-8'){ $score += 2 }
                    if($compact -match '^(品番|個数|尺度|詳細|参考|材料|数量)$'){ $score += 40 }

                    if($score -gt $bestScore){
                        $bestScore = $score
                        $bestText = $text
                    }
                }

                if($candidate.Label -like 'prepared-*' -and $prepared){
                    try{ $prepared.Dispose() } catch{}
                    $prepared = $null
                }
            }
        }
        return $bestText
    }
    finally{
        if($prepared -is [System.IDisposable]){ $prepared.Dispose() }
        foreach($scaledEntry in @($scaledBitmaps)){
            try{ if($scaledEntry.Bitmap){ $scaledEntry.Bitmap.Dispose() } } catch{}
        }
        if($crop){ $crop.Dispose() }
    }
}

function Update-TranslateLensFromRect($rect){
    if(-not $script:TranslateLensEnabled -or !$rect){ return }
    $targetRect = $rect
    $zoneHit = $null
    if($script:TranslateLensPoint){
        $zoneHit = Get-TranslateLensZoneAtPoint $script:TranslateLensPoint
        if($zoneHit -and $zoneHit.Zone -and $zoneHit.Zone.Rect){
            $targetRect = $zoneHit.Zone.Rect
        }
    }

    $rectKey = Get-TranslateLensRectKey $targetRect
    if($script:TranslateLensCache.ContainsKey($rectKey)){
        $script:TranslateLensRect = $targetRect
        $script:TranslateLensResult = $script:TranslateLensCache[$rectKey]
        $script:TranslateLensLastRectKey = $rectKey
        Request-CanvasRedraw
        return
    }

    $sourceText = ""
    $sourceKind = "OCR"
    if($zoneHit){
        $sourceText = Normalize-TranslateLensSourceText $zoneHit.Text
        $sourceKind = if([string]::IsNullOrWhiteSpace([string]$zoneHit.Source)){ "Zone" } else { [string]$zoneHit.Source }
    }
    if([string]::IsNullOrWhiteSpace($sourceText)){
        $sourceText = Get-TranslateLensOcrTextFromRect $targetRect
        $sourceKind = "OCR"
    }
    $sourceText = Normalize-TranslateLensSourceText $sourceText
    $translation = Get-TranslateLensTranslation $sourceText
    $language = Get-TranslateLensLanguage $sourceText
    $result = [PSCustomObject]@{
        Rect = $rect
        Original = $sourceText
        Translation = $translation
        Language = $language
        Source = $sourceKind
    }
    $script:TranslateLensRect = $targetRect
    $script:TranslateLensResult = $result
    $script:TranslateLensCache[$rectKey] = $result
    $script:TranslateLensLastRectKey = $rectKey
    $script:TranslateLensPendingRectKey = ""
    Request-CanvasRedraw
}

function Draw-TranslateLensOverlay($graphics){
    if(!$graphics -or -not $script:TranslateLensEnabled -or !$script:sourceBitmap){ return }
    if(!$script:TranslateLensRect){ return }

    $topLeft = Convert-ImagePointToScreenPoint $script:TranslateLensRect.X $script:TranslateLensRect.Y
    $bottomRight = Convert-ImagePointToScreenPoint ($script:TranslateLensRect.X + $script:TranslateLensRect.Width) ($script:TranslateLensRect.Y + $script:TranslateLensRect.Height)
    $screenRect = New-Object Drawing.RectangleF(
        [float]$topLeft.X,
        [float]$topLeft.Y,
        [float]([Math]::Max(1.0,($bottomRight.X - $topLeft.X))),
        [float]([Math]::Max(1.0,($bottomRight.Y - $topLeft.Y)))
    )

    $lensFill = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(26,40,180,120))
    $lensPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(220,35,150,95),2.0)
    $popupBack = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(236,255,255,245))
    $popupBorder = New-Object Drawing.Pen([Drawing.Color]::FromArgb(210,35,150,95),1.3)
    $titleBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(220,20,80,55))
    $textBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(230,40,40,40))
    $smallBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(180,80,80,80))
    $titleFont = New-Object Drawing.Font("Segoe UI",9,[Drawing.FontStyle]::Bold)
    $textFont = New-Object Drawing.Font("Segoe UI",8.5,[Drawing.FontStyle]::Regular)

    try{
        $graphics.FillRectangle($lensFill,$screenRect)
        $graphics.DrawRectangle($lensPen,$screenRect.X,$screenRect.Y,$screenRect.Width,$screenRect.Height)

        $result = $script:TranslateLensResult
        $popupWidth = [float][Math]::Min(300,[Math]::Max(220,($picture.ClientSize.Width * 0.32)))
        $popupHeight = 108.0
        $popupX = [float]($screenRect.Right + 10)
        $popupY = [float]$screenRect.Top
        if(($popupX + $popupWidth) -gt ($picture.ClientSize.Width - 8)){
            $popupX = [float][Math]::Max(8,($screenRect.Left - $popupWidth - 10))
        }
        if(($popupY + $popupHeight) -gt ($picture.ClientSize.Height - 8)){
            $popupY = [float][Math]::Max(8,($picture.ClientSize.Height - $popupHeight - 8))
        }

        $popupRect = New-Object Drawing.RectangleF($popupX,$popupY,$popupWidth,$popupHeight)
        $graphics.FillRectangle($popupBack,$popupRect)
        $graphics.DrawRectangle($popupBorder,$popupRect.X,$popupRect.Y,$popupRect.Width,$popupRect.Height)

        $title = "Translate Lens"
        $meta = "Scanning..."
        $original = ""
        $translated = ""
        if($result){
            $meta = ("{0} / {1}" -f [string]$result.Source,[string]$result.Language)
            $original = if([string]::IsNullOrWhiteSpace([string]$result.Original)){ "(no text)" } else { [string]$result.Original }
            $translated = if([string]::IsNullOrWhiteSpace([string]$result.Translation)){ $original } else { [string]$result.Translation }
            $original = (($original -replace "\r\n?","`n").Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 2) -join " / "
            $translated = (($translated -replace "\r\n?","`n").Split("`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 2) -join " / "
            if($original.Length -gt 54){ $original = $original.Substring(0,54) + "..." }
            if($translated.Length -gt 54){ $translated = $translated.Substring(0,54) + "..." }
        }

        $graphics.DrawString($title,$titleFont,$titleBrush,[float]($popupRect.X + 8),[float]($popupRect.Y + 6))
        $graphics.DrawString($meta,$textFont,$smallBrush,[float]($popupRect.X + 120),[float]($popupRect.Y + 7))
        $graphics.DrawString("Original",$titleFont,$titleBrush,[float]($popupRect.X + 8),[float]($popupRect.Y + 28))
        $graphics.DrawString($original,$textFont,$textBrush,(New-Object Drawing.RectangleF([float]($popupRect.X + 8),[float]($popupRect.Y + 46),[float]($popupRect.Width - 16),24.0)))
        $graphics.DrawString("VI",$titleFont,$titleBrush,[float]($popupRect.X + 8),[float]($popupRect.Y + 68))
        $graphics.DrawString($translated,$textFont,$textBrush,(New-Object Drawing.RectangleF([float]($popupRect.X + 34),[float]($popupRect.Y + 68),[float]($popupRect.Width - 42),30.0)))
    }
    finally{
        foreach($d in @($lensFill,$lensPen,$popupBack,$popupBorder,$titleBrush,$textBrush,$smallBrush,$titleFont,$textFont)){
            if($d){ $d.Dispose() }
        }
    }
}

function Clear-UiCopiedMarks{

    $script:UiCopiedMarks = @()
    $script:NextUiCopiedMarkId = 1
    if($script:SelectedMarkKind -eq "Copy"){
        Clear-SelectedMark
    }
    Update-CopiedUiNote
}

function Remove-SelectedUiCopiedMark{

    if($script:SelectedMarkKind -ne "Copy" -or $null -eq $script:SelectedUiCopyId){
        return $false
    }

    $remainingMarks = @()
    $removed = $false

    foreach($mark in @($script:UiCopiedMarks)){
        if(!$removed -and $mark -and $mark.Id -eq $script:SelectedUiCopyId){
            $removed = $true
            continue
        }

        if($mark){
            $remainingMarks += $mark
        }
    }

    if($removed){
        $script:UiCopiedMarks = $remainingMarks
        Clear-SelectedMark
        Update-CopiedUiNote
        Request-CanvasRedraw
    }

    return $removed
}

function Get-SelectedMarkCopyTemplate{

    $sourceMark = $null
    $sourceRect = $null
    $sourceStep = $null

    if($script:SelectedMarkKind -eq "Copy"){
        $sourceMark = Get-UiCopiedMarkById $script:SelectedUiCopyId
        if($sourceMark){
            $sourceRect = $sourceMark.SourceRect
            $sourceStep = $sourceMark.SourceStep
        }
    }
    elseif(
        $script:SelectedMarkKind -eq "Original" -and
        $script:SelectedMarkRowIndex -ge 0 -and
        $script:SelectedMarkRowIndex -lt $script:marks.Count
    ){
        $sourceMark = $script:marks[$script:SelectedMarkRowIndex]
        if($script:StepRects.ContainsKey($script:SelectedMarkRowIndex)){
            $rect = $script:StepRects[$script:SelectedMarkRowIndex]
            $sourceRect = New-Object Drawing.Rectangle($rect.X,$rect.Y,$rect.Width,$rect.Height)
        }
        $sourceStep = [string]$sourceMark.Index
    }

    if(!$sourceMark){ return $null }

    return [PSCustomObject]@{
        Index = [string]$sourceMark.Index
        X = [double]$sourceMark.X
        Y = [double]$sourceMark.Y
        Scale = (Get-MarkScale $sourceMark)
        SourceStep = $sourceStep
        SourceRect = $sourceRect
    }
}

function Copy-SelectedMarkToClipboard{

    $template = Get-SelectedMarkCopyTemplate
    if(!$template){ return $false }

    $script:ClipboardMarkTemplate = $template

    try{
        $clipboardText = [string]$template.Index
        if(-not [string]::IsNullOrWhiteSpace([string]$template.SourceStep)){
            $clipboardText = [string]$template.SourceStep
        }
        [System.Windows.Forms.Clipboard]::SetText($clipboardText)
    }
    catch{}

    return $true
}

function Add-UiCopiedMarkFromTemplate($template,$pastePoint = $null){

    if(!$template){ return $false }

    $sourceRect = $template.SourceRect
    $sourceStep = $template.SourceStep
    if([string]::IsNullOrWhiteSpace([string]$sourceStep)){
        $sourceStep = [string]$template.Index
    }

    $offset = [Math]::Max(18.0,(Get-MarkImageRadius * 0.9))
    $copyX = [double]($template.X + $offset)
    $copyY = [double]($template.Y + $offset)
    if($pastePoint){
        $copyX = [double]$pastePoint.X
        $copyY = [double]$pastePoint.Y
    }

    $newCopy = [PSCustomObject]@{
        Id = [int]$script:NextUiCopiedMarkId
        Index = [string]$template.Index
        X = $copyX
        Y = $copyY
        Scale = (Normalize-MarkScale $template.Scale)
        SourceStep = $sourceStep
        SourceRect = $sourceRect
    }

    $script:NextUiCopiedMarkId++
    $script:UiCopiedMarks += $newCopy
    Select-UiCopiedMark $newCopy.Id
    Update-CopiedUiNote
    Request-CanvasRedraw
    Save-SessionState

    return $true
}

function Add-UiCopiedMarkFromSelection{
    return (Add-UiCopiedMarkFromTemplate (Get-SelectedMarkCopyTemplate))
}

function Paste-ClipboardMark{
    if(!$script:ClipboardMarkTemplate){ return $false }
    return (Add-UiCopiedMarkFromTemplate $script:ClipboardMarkTemplate (Get-CurrentCrosshairImagePoint))
}

function Get-TableCellText($rowIndex,$columnIndex){

    if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){
        return ""
    }

    if($columnIndex -lt 0 -or $columnIndex -ge $table.Columns.Count){
        return ""
    }

    $value = $table.Rows[$rowIndex].Cells[$columnIndex].Value
    if($null -eq $value){
        return ""
    }

    return ([string]$value).Trim()
}

function Get-DuplicateGroupKey($rowIndex){

    $nominal = Get-TableCellText $rowIndex 1
    $tolMinus = Get-TableCellText $rowIndex 2
    $tolPlus = Get-TableCellText $rowIndex 3

    if(
        [string]::IsNullOrWhiteSpace($nominal) -or
        [string]::IsNullOrWhiteSpace($tolMinus) -or
        [string]::IsNullOrWhiteSpace($tolPlus)
    ){
        return $null
    }

    return ($nominal + [char]31 + $tolMinus + [char]31 + $tolPlus)
}

function Convert-MechanicalNumberToDouble($value,[ref]$number){
    $number.Value = 0.0
    if($null -eq $value){ return $false }

    $text = ([string]$value).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return $false }

    $text = $text -replace '，','.'
    $text = $text -replace '[°º]',''
    $text = $text -replace '^[CRØΦ]+',''
    $text = $text -replace '[^0-9\.\+\-]',''
    if([string]::IsNullOrWhiteSpace($text)){ return $false }

    $parsed = 0.0
    if([double]::TryParse($text,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){
        $number.Value = $parsed
        return $true
    }
    return $false
}

function Get-InspectionResultDecimalPlaces($text){
    if([string]::IsNullOrWhiteSpace([string]$text)){ return 0 }
    $value = ([string]$text).Trim() -replace ',', '.'
    $match = [regex]::Match($value,'(?<!\d)([-+]?\d+)\.(\d+)')
    if($match.Success){
        return [int]$match.Groups[2].Value.Length
    }
    return 0
}

function Get-InspectionDisplayDecimalPlaces($nominalText,$tolMinusText = "",$tolPlusText = ""){
    $decimals = Get-InspectionResultDecimalPlaces $nominalText
    $tolMinusDecimals = Get-InspectionResultDecimalPlaces ([string]$tolMinusText)
    $tolPlusDecimals = Get-InspectionResultDecimalPlaces ([string]$tolPlusText)
    return [Math]::Max([int]$decimals,[Math]::Max([int]$tolMinusDecimals,[int]$tolPlusDecimals))
}

function Convert-AngleDmsTextToDouble($text,[ref]$number){
    $number.Value = 0.0
    $angleDms = Try-ParseAngleDmsText $text
    if(!$angleDms){ return $false }

    $degValue = 0.0
    if(-not [double]::TryParse(([string]$angleDms.Degrees),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$degValue)){
        return $false
    }

    $sign = 1.0
    if($degValue -lt 0){
        $sign = -1.0
        $degValue = [Math]::Abs($degValue)
    }

    $minValue = 0.0
    $secValue = 0.0
    if(-not [string]::IsNullOrWhiteSpace([string]$angleDms.Minutes)){
        [void][double]::TryParse(([string]$angleDms.Minutes),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$minValue)
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$angleDms.Seconds)){
        [void][double]::TryParse(([string]$angleDms.Seconds),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$secValue)
    }

    $number.Value = $sign * ($degValue + ($minValue / 60.0) + ($secValue / 3600.0))
    return $true
}

function Format-AngleDmsInspectionResultValue($value,$nominalText){
    $angleDms = Try-ParseAngleDmsText $nominalText
    if(!$angleDms){ return $null }

    $absValue = [Math]::Abs([double]$value)
    $signText = if([double]$value -lt 0){ "-" } else { "" }
    $degrees = [int][Math]::Floor($absValue)
    $minutesTotal = ($absValue - $degrees) * 60.0
    $minutes = [int][Math]::Floor($minutesTotal)
    $seconds = [int][Math]::Round(($minutesTotal - $minutes) * 60.0,0,[System.MidpointRounding]::AwayFromZero)

    if($seconds -ge 60){
        $seconds = 0
        $minutes++
    }
    if($minutes -ge 60){
        $minutes = 0
        $degrees++
    }

    if(-not [string]::IsNullOrWhiteSpace([string]$angleDms.Seconds)){
        return ('{0}{1}°{2:00}''{3:00}"' -f $signText,$degrees,$minutes,$seconds)
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$angleDms.Minutes)){
        return ('{0}{1}°{2:00}''' -f $signText,$degrees,$minutes)
    }

    $degreeDecimals = Get-InspectionResultDecimalPlaces ([string]$angleDms.Degrees)
    $formattedDegrees = ([double]$value).ToString(("0." + ("0" * $degreeDecimals)).TrimEnd('.'),[System.Globalization.CultureInfo]::InvariantCulture)
    return ($formattedDegrees + "°")
}

function Format-InspectionResultValue($value,$nominalText){
    return (Format-InspectionResultValueWithDecimals $value $nominalText (Get-InspectionResultDecimalPlaces $nominalText))
}

function Format-InspectionResultValueWithDecimals($value,$nominalText,$decimals){
    $nominal = [string]$nominalText
    if([string]::IsNullOrWhiteSpace($nominal)){
        $fallbackFormat = if([int]$decimals -gt 0){ "0." + ("0" * [int]$decimals) } else { "0.####" }
        return ([double]$value).ToString($fallbackFormat,[System.Globalization.CultureInfo]::InvariantCulture)
    }

    $formattedAngle = Format-AngleDmsInspectionResultValue $value $nominal
    if($formattedAngle){ return $formattedAngle }

    $prefixMatch = [regex]::Match($nominal.Trim(),'^(?<prefix>[CRØΦ]+)\s*','IgnoreCase')
    $prefix = if($prefixMatch.Success){ [string]$prefixMatch.Groups['prefix'].Value } else { "" }
    $suffix = if($nominal -match '[°º]\s*$'){ "°" } else { "" }
    $format = if([int]$decimals -gt 0){ "0." + ("0" * [int]$decimals) } else { "0" }
    $text = ([double]$value).ToString($format,[System.Globalization.CultureInfo]::InvariantCulture)
    return ($prefix + $text + $suffix)
}

function Get-DeterministicMeasurementUnitValue($seedText){
    $seed = [string]$seedText
    if([string]::IsNullOrWhiteSpace($seed)){ return 0.618 }

    $hash = 17
    foreach($ch in $seed.ToCharArray()){
        $hash = (($hash * 31) + [int][char]$ch) % 1000003
    }

    return (([double]($hash % 1000)) + 0.5) / 1000.0
}

function Test-AutoFillMeasurementSensitiveNominal($nominalText){
    $value = ([string]$nominalText).Trim().ToUpperInvariant()
    if([string]::IsNullOrWhiteSpace($value)){ return $false }
    if($value -match '[°º]'){ return $true }
    if($value -match '^[RCØΦ]'){ return $true }
    return $false
}

function Get-AutoFillMeasurementOffset($rowIndex,$nominalText,$tolMinus,$tolPlus){
    $lower = [double]$tolMinus
    $upper = [double]$tolPlus
    if($upper -lt $lower){
        $swap = $lower
        $lower = $upper
        $upper = $swap
    }

    $range = $upper - $lower
    if([Math]::Abs($range) -lt 0.0000001){
        return $lower
    }

    $stepText = Get-TableCellText $rowIndex 0
    $seedText = ([string]$stepText) + "|" + ([string]$nominalText) + "|" + (Format-InvariantSignedTolerance $lower) + "|" + (Format-InvariantSignedTolerance $upper)
    $unit = Get-DeterministicMeasurementUnitValue $seedText
    $isSensitive = Test-AutoFillMeasurementSensitiveNominal $nominalText

    if($isSensitive){
        $ratio = if($unit -lt 0.5){
            0.20 + ($unit * 0.34)
        }
        else{
            0.63 + (($unit - 0.5) * 0.34)
        }
    }
    else{
        $ratio = if($unit -lt 0.5){
            0.28 + ($unit * 0.28)
        }
        else{
            0.56 + (($unit - 0.5) * 0.28)
        }
    }

    $offset = $lower + ($range * $ratio)

    if([Math]::Abs($offset - (($lower + $upper) / 2.0)) -lt ($range * 0.03)){
        $offset += ($range * 0.08)
        if($offset -gt $upper){
            $offset = $upper - ($range * 0.06)
        }
    }

    return [Math]::Max($lower,[Math]::Min($upper,$offset))
}

function Get-AutoFillResultForRow($rowIndex){
    if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){ return $null }

    $nominalText = Get-TableCellText $rowIndex 1
    $tolMinus = Convert-MarkStepToleranceCellToDouble $table.Rows[$rowIndex].Cells[2].Value
    $tolPlus = Convert-MarkStepToleranceCellToDouble $table.Rows[$rowIndex].Cells[3].Value
    $measurementOffset = Get-AutoFillMeasurementOffset $rowIndex $nominalText $tolMinus $tolPlus
    $nominal = 0.0
    if(-not (Convert-AngleDmsTextToDouble $nominalText ([ref]$nominal))){
        if(-not (Convert-MechanicalNumberToDouble $nominalText ([ref]$nominal))){
            return $null
        }
    }
    $result = [double]$nominal + [double]$measurementOffset
    return (Format-InspectionResultValue $result $nominalText)
}

function AutoFill-InspectionResults{
    return $false
}

function Get-HoverResultTargetRow{
    return -1
}

function Set-ResultCellFromQuickInput($rowIndex,$text){
    return $false
}

function Handle-QuickResultKey($keyChar){
    return $false
}

function Refresh-DuplicateState{

    if($script:IsRefreshingDuplicateState){
        return
    }

    $script:IsRefreshingDuplicateState = $true

    try{
        if($table.Rows.Count -le 1){
            for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
                if($table.Columns.Count -gt 5){
                    $table.Rows[$rowIndex].Cells[5].Value = ""
                }
                $table.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::White
            }

            $script:DuplicateStepMap = @{}
            $script:SelectedDuplicateSteps = @{}
            $script:SelectedDuplicateAnchorStep = $null
            return
        }

        $duplicateGroups = @{}
        $duplicateStepMap = @{}

        for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
            if($table.Columns.Count -gt 5){
                $table.Rows[$rowIndex].Cells[5].Value = ""
            }
            $table.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::White

            $groupKey = Get-DuplicateGroupKey $rowIndex
            if([string]::IsNullOrWhiteSpace($groupKey)){
                continue
            }

            if(-not $duplicateGroups.ContainsKey($groupKey)){
                $duplicateGroups[$groupKey] = New-Object System.Collections.ArrayList
            }

            [void]$duplicateGroups[$groupKey].Add($rowIndex)
        }

        foreach($groupRows in $duplicateGroups.Values){
            if($groupRows.Count -lt 2){
                continue
            }

            $rowIndexes = @($groupRows)

            foreach($rowIndex in $rowIndexes){
                $currentStep = Get-TableCellText $rowIndex 0
                $matchedSteps = @()

                foreach($otherRowIndex in $rowIndexes){
                    if($otherRowIndex -eq $rowIndex){
                        continue
                    }

                    $otherStep = Get-TableCellText $otherRowIndex 0
                    if(-not [string]::IsNullOrWhiteSpace($otherStep)){
                        $matchedSteps += $otherStep
                    }
                }

                if($table.Columns.Count -gt 5){
                    $table.Rows[$rowIndex].Cells[5].Value = ($matchedSteps -join ",")
                }
                $table.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose

                if(-not [string]::IsNullOrWhiteSpace($currentStep) -and $matchedSteps.Count -gt 0){
                    $duplicateStepMap[$currentStep] = @($matchedSteps)
                }
            }
        }

        $selectedStep = $null
        if($table.SelectedRows.Count -gt 0){
            $selectedStep = Get-TableCellText $table.SelectedRows[0].Index 0
        }

        $script:DuplicateStepMap = $duplicateStepMap
        $script:SelectedDuplicateSteps = @{}
        $script:SelectedDuplicateAnchorStep = $null

        if(
            -not [string]::IsNullOrWhiteSpace($selectedStep) -and
            $script:DuplicateStepMap.ContainsKey($selectedStep)
        ){
            $script:SelectedDuplicateAnchorStep = $selectedStep

            foreach($matchedStep in @($script:DuplicateStepMap[$selectedStep])){
                if(-not [string]::IsNullOrWhiteSpace([string]$matchedStep)){
                    $script:SelectedDuplicateSteps[[string]$matchedStep] = $true
                }
            }
        }

        Request-CanvasRedraw
    }
    finally{
        $script:IsRefreshingDuplicateState = $false
    }
}

function Get-StepEntryAtIndex($rowIndex){

    if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){
        return $null
    }

    $cellValues = @()
    for($colIndex = 0; $colIndex -lt $table.Columns.Count; $colIndex++){
        $cellValues += $table.Rows[$rowIndex].Cells[$colIndex].Value
    }

    $savedRect = $null
    if($script:StepRects.ContainsKey($rowIndex)){
        $rect = $script:StepRects[$rowIndex]
        $savedRect = New-Object Drawing.Rectangle($rect.X,$rect.Y,$rect.Width,$rect.Height)
    }

    $savedMark = $null
    if($rowIndex -lt $script:marks.Count){
        $mark = $script:marks[$rowIndex]
        $savedMark = [PSCustomObject]@{
            Index = [int]$mark.Index
            X = [double]$mark.X
            Y = [double]$mark.Y
            Scale = (Get-MarkScale $mark)
        }
    }

    return [PSCustomObject]@{
        RowIndex = $rowIndex
        Cells = $cellValues
        Rect = $savedRect
        Mark = $savedMark
    }
}

function Get-AllStepEntries{

    $entries = @()

    for($i = 0; $i -lt $table.Rows.Count; $i++){
        $entries += (Get-StepEntryAtIndex $i)
    }

    return $entries
}

function Update-CurrentPageEntryCellFast($rowIndex,$colIndex,$value){

    $page = Get-CurrentDocumentPage
    if(!$page){ return }
    if($rowIndex -lt 0){ return }
    if($colIndex -lt 0){ return }
    if($rowIndex -ge @($page.Entries).Count){ return }

    $entry = $page.Entries[$rowIndex]
    if(!$entry){ return }
    if(!$entry.PSObject.Properties.Name -contains "Cells"){ return }
    if($null -eq $entry.Cells){ $entry.Cells = @() }

    while($entry.Cells.Count -le $colIndex){
        $entry.Cells += $null
    }

    if($colIndex -eq 7){
        $entry.Cells[$colIndex] = (Convert-ToStepToolState $value)
    }
    else{
        $entry.Cells[$colIndex] = $value
    }
}

function Convert-ToStepToolState($value){

    if($null -eq $value){ return "C" }

    if($value -is [bool]){
        if([bool]$value){ return "B" }
        return "C"
    }

    $text = ([string]$value).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return "C" }

    switch -Regex ($text.ToUpperInvariant()){
        '^(B|TRUE|1|YES|Y|CHECKED)$' { return "B" }
        '^(I|IGNORE|IND|INDETERMINATE)$' { return "I" }
        default { return "C" }
    }
}

function Convert-ToStepImportantFlag($value){
    if($value -is [bool]){ return [bool]$value }
    if($null -eq $value){ return $false }

    $text = ([string]$value).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return $false }

    switch -Regex ($text.ToLowerInvariant()){
        '^(true|1|yes|y|checked)$' { return $true }
        default { return $false }
    }
}

function Test-StepToolIgnored($value){
    return ((Convert-ToStepToolState $value) -eq "I")
}

function Get-SelectedStepRowIndex{
    if($table.SelectedRows.Count -gt 0){
        return [int]$table.SelectedRows[0].Index
    }
    if($table.CurrentCell){
        return [int]$table.CurrentCell.RowIndex
    }
    return -1
}

function Set-SelectedStepToolState([string]$state){
    $rowIndex = Get-SelectedStepRowIndex
    if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){ return $false }

    $requestedState = Convert-ToStepToolState $state
    $currentState = Convert-ToStepToolState $table.Rows[$rowIndex].Cells[7].Value
    $normalizedState = if($currentState -eq $requestedState){ "C" } else { $requestedState }
    $table.Rows[$rowIndex].Cells[7].Value = $normalizedState
    Update-CurrentPageEntryCellFast $rowIndex 7 $normalizedState
    Request-CanvasRedraw
    Queue-ImportantStepSave
    return $true
}

function Get-NormalizedRotationDegrees($rotationDegrees){

    $normalized = [int]$rotationDegrees
    while($normalized -lt 0){ $normalized += 360 }
    while($normalized -ge 360){ $normalized -= 360 }
    return $normalized
}

function Test-StepEntryImportant($entry){

    if(!$entry -or !$entry.Cells){ return $false }
    if($entry.Cells.Count -le 8){ return $false }

    return (Convert-ToStepImportantFlag $entry.Cells[8])
}

function Draw-ImportantStepHighlights($graphics,$entries,$zoomValue = 1.0){

    if(!$graphics){ return }
    if(!$entries){ return }

    $safeZoom = [Math]::Max([double]$zoomValue,0.0001)
    $fillBrush = $null
    try{
        $fillBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(62,255,232,60))

        foreach($entry in @($entries)){
            if(!(Test-StepEntryImportant $entry)){ continue }
            if(!$entry.Rect){ continue }

            $rect = $entry.Rect
            if($rect.Width -le 0 -or $rect.Height -le 0){ continue }
            $padX = [int][Math]::Max(2.0,(7.0 / $safeZoom))
            $padY = [int][Math]::Max(1.0,(3.0 / $safeZoom))
            if($rect.Height -gt ($rect.Width * 1.15)){
                $padX = [int][Math]::Max(2.0,(4.0 / $safeZoom))
                $padY = [int][Math]::Max(2.0,(7.0 / $safeZoom))
            }

            $left = [int][Math]::Max(0,($rect.X - $padX))
            $top = [int][Math]::Max(0,($rect.Y - $padY))
            $width = [int][Math]::Max(2,($rect.Width + ($padX * 2)))
            $height = [int][Math]::Max(2,($rect.Height + ($padY * 2)))
            $highlightRect = New-Object Drawing.Rectangle($left,$top,$width,$height)

            $graphics.FillRectangle($fillBrush,$highlightRect)
        }
    }
    finally{
        if($fillBrush){ $fillBrush.Dispose() }
    }
}

function Copy-StepEntry($entry){

    if(!$entry){ return $null }

    $cells = @()
    foreach($cell in @($entry.Cells)){
        $cells += $cell
    }

    $copiedRect = $null
    if($entry.Rect){
        $copiedRect = New-Object Drawing.Rectangle(
            $entry.Rect.X,
            $entry.Rect.Y,
            $entry.Rect.Width,
            $entry.Rect.Height
        )
    }

    $copiedMark = $null
    if($entry.Mark){
        $copiedMark = [PSCustomObject]@{
            Index = [int]$entry.Mark.Index
            X = [double]$entry.Mark.X
            Y = [double]$entry.Mark.Y
            Scale = (Get-MarkScale $entry.Mark)
        }
    }

    return [PSCustomObject]@{
        RowIndex = [int]$entry.RowIndex
        Cells = $cells
        Rect = $copiedRect
        Mark = $copiedMark
    }
}

function Copy-StepEntryCollection($entries){

    $copiedEntries = @()

    foreach($entry in @($entries)){
        $copiedEntries += (Copy-StepEntry $entry)
    }

    return $copiedEntries
}

function Set-StepEntryNumber($entry,$stepNumber){

    if(!$entry){ return }

    if(!$entry.Cells){
        $entry | Add-Member -NotePropertyName Cells -NotePropertyValue @() -Force
    }

    while($entry.Cells.Count -lt $table.Columns.Count){
        $entry.Cells += $null
    }

    $entry.Cells[0] = [string]$stepNumber
    while($entry.Cells.Count -lt $table.Columns.Count){
        $entry.Cells += $null
    }
    $entry.Cells[6] = "View"

    if($entry.Mark){
        $entry.Mark.Index = [int]$stepNumber
    }
}

function Get-ValidatedStepEntries($entries,$bitmap = $null){

    $validatedEntries = @()

    foreach($entry in @($entries)){
        $copiedEntry = Copy-StepEntry $entry
        if(!$copiedEntry){ continue }
        if(!$copiedEntry.Rect){ continue }
        if(!$copiedEntry.Mark){ continue }
        if($copiedEntry.Rect.Width -le 0 -or $copiedEntry.Rect.Height -le 0){ continue }
        if($copiedEntry.Mark.X -lt 0 -or $copiedEntry.Mark.Y -lt 0){ continue }

        if($bitmap){
            if(
                $copiedEntry.Rect.X -lt 0 -or
                $copiedEntry.Rect.Y -lt 0 -or
                $copiedEntry.Rect.Right -gt $bitmap.Width -or
                $copiedEntry.Rect.Bottom -gt $bitmap.Height
            ){
                continue
            }

            if(
                $copiedEntry.Mark.X -gt $bitmap.Width -or
                $copiedEntry.Mark.Y -gt $bitmap.Height
            ){
                continue
            }
        }

        $copiedEntry.RowIndex = if($copiedEntry.PSObject.Properties.Name -contains 'PreserveRowIndex' -and $copiedEntry.PreserveRowIndex){ [int]$copiedEntry.RowIndex } else { $validatedEntries.Count }
        $validatedEntries += $copiedEntry
    }

    return $validatedEntries
}

function Validate-StepState{

    if(
        $script:SelectedPageIndex -ge 0 -and
        $script:SelectedPageIndex -lt $script:DocumentPages.Count
    ){
        $currentPage = $script:DocumentPages[$script:SelectedPageIndex]
        $currentPage.Entries = @(Get-ValidatedStepEntries (Get-AllStepEntries) $currentPage.Bitmap)
        foreach($entry in @($script:DeletedSteps)){ $entry | Add-Member -NotePropertyName PreserveRowIndex -NotePropertyValue $true -Force }
        $currentPage.DeletedEntries = @(Get-ValidatedStepEntries $script:DeletedSteps $currentPage.Bitmap)
        Rebuild-StepEntries @($currentPage.Entries)
        $script:DeletedSteps = @(Copy-StepEntryCollection $currentPage.DeletedEntries)
    }
}

function Sync-VisibleStepNumbers{

    for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
        $stepValue = [string]$table.Rows[$rowIndex].Cells[0].Value
        $parsedStep = 0

        if([int]::TryParse($stepValue,[ref]$parsedStep)){
            $table.Rows[$rowIndex].Cells[0].Value = [string]$parsedStep
        }
        else{
            $table.Rows[$rowIndex].Cells[0].Value = $stepValue
        }

        $table.Rows[$rowIndex].Cells[6].Value = "View"
        $table.Rows[$rowIndex].Cells[7].Value = Convert-ToStepToolState $table.Rows[$rowIndex].Cells[7].Value
        $table.Rows[$rowIndex].Cells[8].Value = Convert-ToStepImportantFlag $table.Rows[$rowIndex].Cells[8].Value

        if($parsedStep -gt 0 -and $rowIndex -lt $script:marks.Count -and $script:marks[$rowIndex]){
            $script:marks[$rowIndex].Index = $parsedStep
        }
    }
}

function Select-LastStepRow{

    if($table.Rows.Count -le 0){
        $table.ClearSelection()
        return
    }

    $lastRowIndex = $table.Rows.Count - 1
    $table.ClearSelection()
    $table.Rows[$lastRowIndex].Selected = $true
    $table.CurrentCell = $table.Rows[$lastRowIndex].Cells[0]
    $table.FirstDisplayedScrollingRowIndex = $lastRowIndex
}

function Rebuild-StepEntries($entries,$selectedIndex = -1){

    $table.Rows.Clear()
    $script:StepRects = @{}
    $script:marks = @()

    foreach($entry in @($entries)){
        $rowIndex = $table.Rows.Add()

        for($colIndex = 0; $colIndex -lt $table.Columns.Count; $colIndex++){
            $value = $null
            if($colIndex -lt $entry.Cells.Count){
                $value = $entry.Cells[$colIndex]
            }
            if($table.Columns[$colIndex].Name -eq "Important"){
                $value = Convert-ToStepImportantFlag $value
            }
            elseif($table.Columns[$colIndex].Name -eq "Flag"){
                $value = Convert-ToStepToolState $value
            }

            $table.Rows[$rowIndex].Cells[$colIndex].Value = $value
        }

        if($entry.Rect){
            $script:StepRects[$rowIndex] = New-Object Drawing.Rectangle(
                $entry.Rect.X,
                $entry.Rect.Y,
                $entry.Rect.Width,
                $entry.Rect.Height
            )
        }

        if($entry.Mark){
            $script:marks += [PSCustomObject]@{
                Index = [int]$entry.Mark.Index
                X = [double]$entry.Mark.X
                Y = [double]$entry.Mark.Y
                Scale = (Get-MarkScale $entry.Mark)
            }
        }
        else{
            $script:marks += $null
        }
    }

    if($table.Rows.Count -gt 0 -and $selectedIndex -ge 0){
        $safeSelectedIndex = [Math]::Min($selectedIndex,($table.Rows.Count - 1))
        $table.ClearSelection()
        $table.Rows[$safeSelectedIndex].Selected = $true
        $table.CurrentCell = $table.Rows[$safeSelectedIndex].Cells[0]
        $table.FirstDisplayedScrollingRowIndex = $safeSelectedIndex
    }
    elseif($table.Rows.Count -gt 0){
        Select-LastStepRow
    }
    else{
        $table.ClearSelection()
    }

    Sync-VisibleStepNumbers
    Sync-MarkStepTextZonesFromTable
    Refresh-DuplicateState
    Apply-TableSearchFilter
}

function Remove-StepAtIndex($rowIndex){

    if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){
        return
    }

    if($rowIndex -eq ($table.Rows.Count - 1)){
        $removedEntry = Get-StepEntryAtIndex $rowIndex
        if($removedEntry){
            $removedEntry.RowIndex = $rowIndex
            $removedEntry | Add-Member -NotePropertyName PreserveRowIndex -NotePropertyValue $true -Force
            $script:DeletedSteps += $removedEntry
        }

        [void]$table.Rows.RemoveAt($rowIndex)
        if($script:StepRects.ContainsKey($rowIndex)){
            [void]$script:StepRects.Remove($rowIndex)
        }
        if($script:marks.Count -gt $rowIndex){
            if($script:marks.Count -eq 1){
                $script:marks = @()
            }
            else{
                $script:marks = @($script:marks[0..($script:marks.Count - 2)])
            }
        }

        if($table.Rows.Count -gt 0){
            $lastRowIndex = $table.Rows.Count - 1
            $table.ClearSelection()
            $table.Rows[$lastRowIndex].Selected = $true
            $table.CurrentCell = $table.Rows[$lastRowIndex].Cells[0]
            $table.FirstDisplayedScrollingRowIndex = $lastRowIndex
        }
        else{
            $table.ClearSelection()
        }

        Sync-MarkStepTextZonesFromTable
        Save-CurrentPageState
        Refresh-DuplicateState
        Apply-TableSearchFilter
        Request-CanvasRedraw
        Save-SessionState
        return
    }

    $entries = [System.Collections.ArrayList]::new()
    foreach($entry in (Get-AllStepEntries)){
        [void]$entries.Add($entry)
    }

    $removedEntry = $entries[$rowIndex]
    $removedEntry.RowIndex = $rowIndex
    $removedEntry | Add-Member -NotePropertyName PreserveRowIndex -NotePropertyValue $true -Force
    [void]$entries.RemoveAt($rowIndex)
    $script:DeletedSteps += $removedEntry

    $nextRowIndex = if($entries.Count -gt 0){ [Math]::Min($rowIndex,($entries.Count - 1)) } else { -1 }
    Rebuild-StepEntries @($entries) $nextRowIndex
    Save-CurrentPageState
    Refresh-DuplicateState
    Request-CanvasRedraw
    Save-SessionState
}

function Undo-DeletedStep{

    if($script:DeletedSteps.Count -eq 0){
        return
    }

    $deletedEntry = $script:DeletedSteps[-1]
    if($script:DeletedSteps.Count -eq 1){
        $script:DeletedSteps = @()
    }
    else{
        $script:DeletedSteps = @($script:DeletedSteps[0..($script:DeletedSteps.Count - 2)])
    }

    $entries = [System.Collections.ArrayList]::new()
    foreach($entry in (Get-AllStepEntries)){
        [void]$entries.Add($entry)
    }

    $insertIndex = [Math]::Min([Math]::Max(0,[int]$deletedEntry.RowIndex),$entries.Count)

    if($insertIndex -eq $entries.Count){
        $rowIndex = $table.Rows.Add()
        for($colIndex = 0; $colIndex -lt $table.Columns.Count; $colIndex++){
            $value = $null
            if($colIndex -lt $deletedEntry.Cells.Count){
                $value = $deletedEntry.Cells[$colIndex]
            }
            if($table.Columns[$colIndex].Name -eq "Important"){
                $value = Convert-ToStepImportantFlag $value
            }
            elseif($table.Columns[$colIndex].Name -eq "Flag"){
                $value = Convert-ToStepToolState $value
            }
            $table.Rows[$rowIndex].Cells[$colIndex].Value = $value
        }

        if($deletedEntry.Rect){
            $script:StepRects[$rowIndex] = New-Object Drawing.Rectangle(
                $deletedEntry.Rect.X,
                $deletedEntry.Rect.Y,
                $deletedEntry.Rect.Width,
                $deletedEntry.Rect.Height
            )
        }

        if($deletedEntry.Mark){
            $script:marks += [PSCustomObject]@{
                Index = [int]$deletedEntry.Mark.Index
                X = [double]$deletedEntry.Mark.X
                Y = [double]$deletedEntry.Mark.Y
                Scale = (Get-MarkScale $deletedEntry.Mark)
            }
        }
        else{
            $script:marks += $null
        }

        $table.ClearSelection()
        $table.Rows[$rowIndex].Selected = $true
        $table.CurrentCell = $table.Rows[$rowIndex].Cells[0]
        $table.FirstDisplayedScrollingRowIndex = $rowIndex

        Sync-MarkStepTextZonesFromTable
        Save-CurrentPageState
        Refresh-DuplicateState
        Apply-TableSearchFilter
        Request-CanvasRedraw
        Save-SessionState
        return
    }

    $entries.Insert($insertIndex,$deletedEntry)

    Rebuild-StepEntries @($entries) $insertIndex
    Save-CurrentPageState
    Refresh-DuplicateState
    Request-CanvasRedraw
    Save-SessionState
}

function Clear-PreviewPane{

    if($preview.Image){
        $preview.Image.Dispose()
        $preview.Image = $null
    }

    $script:HighlightRect = $null
}

function New-DocumentPageRecord($sourcePath,$displayName,$imagePath,$pageNumber,$rotationDegrees = 0){

    $loadedImage = $null

    try{
        $loadedImage = [Drawing.Bitmap]::FromFile($imagePath)
        $rotationDegrees = Get-NormalizedRotationDegrees $rotationDegrees
        $pageBitmap = New-Object Drawing.Bitmap $loadedImage
        if($rotationDegrees -ne 0){
            $rotatedBitmap = Rotate-Bitmap $pageBitmap $rotationDegrees
            $pageBitmap.Dispose()
            $pageBitmap = $rotatedBitmap
        }

        return [PSCustomObject]@{
            SourcePath = $sourcePath
            DisplayName = $displayName
            ImagePath = $imagePath
            PageNumber = $pageNumber
            RotationDegrees = $rotationDegrees
            Bitmap = $pageBitmap
            Entries = @()
            DeletedEntries = @()
            UiCopiedMarks = @()
            HighlightStrokes = @()
            DuplicateDeclinedRects = @()
            SuppressedTextZoneRects = @()
            PdfTextLayerZones = @()
            TextZoneCacheKey = $null
        }
    }
    finally{
        if($loadedImage){
            $loadedImage.Dispose()
        }
    }
}

function Dispose-DocumentPages{

    foreach($page in @($script:DocumentPages)){
        if($page -and $page.Bitmap){
            $page.Bitmap.Dispose()
        }
    }

    $script:DocumentPages = @()
    $script:SelectedPageIndex = -1
    $script:sourceBitmap = $null
    $script:CurrentSessionFilePath = $null

    $script:RenderedPdfTempDir = $null
}

function Save-CurrentPageState{

    if(
        $script:SelectedPageIndex -lt 0 -or
        $script:SelectedPageIndex -ge $script:DocumentPages.Count
    ){
        return
    }

    $page = $script:DocumentPages[$script:SelectedPageIndex]
    $page.Entries = @(Get-ValidatedStepEntries (Get-AllStepEntries) $page.Bitmap)
    foreach($entry in @($script:DeletedSteps)){ $entry | Add-Member -NotePropertyName PreserveRowIndex -NotePropertyValue $true -Force }
    $page.DeletedEntries = @(Get-ValidatedStepEntries $script:DeletedSteps $page.Bitmap)
    $page.UiCopiedMarks = @($script:UiCopiedMarks)
    $page.HighlightStrokes = @($script:HighlightStrokes)
    $page.DuplicateDeclinedRects = @($script:DuplicateDeclinedRects)
    Save-CurrentPageTextZoneCache
}

function Reset-PageMarkupState($page){

    if(!$page){ return }

    $page.Entries = @()
    $page.DeletedEntries = @()
    $page.UiCopiedMarks = @()
    $page.HighlightStrokes = @()
    $page.DuplicateDeclinedRects = @()
    $page.SuppressedTextZoneRects = @()
    $page.PdfTextLayerZones = @()
    $page.TextZoneCacheKey = $null
    $page | Add-Member -NotePropertyName HasPdfTextLayer -NotePropertyValue $false -Force
    $page | Add-Member -NotePropertyName PdfTextLayerBlockCount -NotePropertyValue 0 -Force
}

function Rotate-CurrentPageClockwise{

    $page = Get-CurrentDocumentPage
    if(!$page -or !$page.Bitmap){ return $false }

    $rotatedBitmap = $null
    try{
        $rotatedBitmap = Rotate-Bitmap $page.Bitmap 90
        if(!$rotatedBitmap){ return $false }

        $oldBitmap = $page.Bitmap
        $page.Bitmap = $rotatedBitmap
        $page.RotationDegrees = Get-NormalizedRotationDegrees ((Get-StatePropertyValue $page "RotationDegrees") + 90)
        Reset-PageMarkupState $page

        if($oldBitmap){ $oldBitmap.Dispose() }
        $rotatedBitmap = $null

        $script:sourceBitmap = $page.Bitmap
        $script:HighlightRect = $null
        $script:selectionRect = $null
        Clear-PreviewImage
        Clear-HiddenTextZoneHover
        Set-ViewMode "FitScreen"
        Apply-PageState $page
        Refresh-DuplicateState
        Update-CanvasCursor
        Request-CanvasRedraw
        Save-SessionState
        return $true
    }
    finally{
        if($rotatedBitmap){ $rotatedBitmap.Dispose() }
    }
}

function Get-CurrentDocumentPage{
    if(
        $script:SelectedPageIndex -lt 0 -or
        $script:SelectedPageIndex -ge $script:DocumentPages.Count
    ){
        return $null
    }

    return $script:DocumentPages[$script:SelectedPageIndex]
}

function Clear-CurrentPageTextZoneState{
    $script:PdfTextLayerZones = @()
    $script:SuppressedTextZoneRects = @()
    $script:TextZoneCacheKey = $null
    $script:TextZoneCacheResolved = $false
    $script:SelectedTextZoneIndex = -1
    $script:IsDraggingTextZone = $false
}

function Save-CurrentPageTextZoneCache{
    $page = Get-CurrentDocumentPage
    if(!$page){ return }

    if($page.PSObject.Properties.Name -notcontains 'PdfTextLayerZones'){
        $page | Add-Member -NotePropertyName PdfTextLayerZones -NotePropertyValue @()
    }
    if($page.PSObject.Properties.Name -notcontains 'SuppressedTextZoneRects'){
        $page | Add-Member -NotePropertyName SuppressedTextZoneRects -NotePropertyValue @()
    }
    if($page.PSObject.Properties.Name -notcontains 'TextZoneCacheKey'){
        $page | Add-Member -NotePropertyName TextZoneCacheKey -NotePropertyValue $null
    }
    if($page.PSObject.Properties.Name -notcontains 'TextZoneCacheResolved'){
        $page | Add-Member -NotePropertyName TextZoneCacheResolved -NotePropertyValue $false
    }
    $page.PdfTextLayerZones = @($script:PdfTextLayerZones)
    $page.SuppressedTextZoneRects = @($script:SuppressedTextZoneRects)
    $page.TextZoneCacheKey = $script:TextZoneCacheKey
    $page.TextZoneCacheResolved = [bool]$script:TextZoneCacheResolved
}

function Restore-PageTextZoneCache($page){
    if(!$page){
        Clear-CurrentPageTextZoneState
        return
    }

    $pageZones = @()
    if($page.PSObject.Properties.Name -contains 'PdfTextLayerZones'){
        $pageZones = @($page.PdfTextLayerZones)
    }

    $script:PdfTextLayerZones = @($pageZones)
    $script:SuppressedTextZoneRects = if($page.PSObject.Properties.Name -contains 'SuppressedTextZoneRects'){ @($page.SuppressedTextZoneRects) } else { @() }
    $script:TextZoneCacheKey = if($page.PSObject.Properties.Name -contains 'TextZoneCacheKey'){ $page.TextZoneCacheKey } else { $null }
    $script:TextZoneCacheResolved = if($page.PSObject.Properties.Name -contains 'TextZoneCacheResolved'){ [bool]$page.TextZoneCacheResolved } else { $false }
    $script:SelectedTextZoneIndex = -1
    $script:IsDraggingTextZone = $false
}

function Stop-DeferredTextZoneWarmup{
    if($script:DeferredTextZoneWarmupTimer){
        $script:DeferredTextZoneWarmupTimer.Stop()
    }
    $script:PendingTextZoneWarmupPageIndex = -1
    $script:PendingTextZoneWarmupStage = ""
    $script:PendingTextZoneWarmupMapRect = $null
    $script:PendingTextZoneWarmupImageCandidates = @()
    $script:IsDeferredTextZoneWarmupRunning = $false
}

function Test-CurrentPageTextZoneCacheReady{
    if(!$script:sourceBitmap){ return $false }
    $mapRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
    $key = Get-AutoOcrMapRectKey $mapRect
    if($script:TextZoneCacheKey -eq $key -and ($script:TextZoneCacheResolved -or @($script:PdfTextLayerZones).Count -gt 0)){
        return $true
    }

    $page = Get-CurrentDocumentPage
    if(
        $page -and
        $page.PSObject.Properties.Name -contains 'TextZoneCacheKey' -and
        $page.TextZoneCacheKey -eq $key -and
        (
            ($page.PSObject.Properties.Name -contains 'TextZoneCacheResolved' -and [bool]$page.TextZoneCacheResolved) -or
            ($page.PSObject.Properties.Name -contains 'PdfTextLayerZones' -and @($page.PdfTextLayerZones).Count -gt 0)
        )
    ){
        return $true
    }

    return $false
}

function Get-CurrentPageCachedTextZones{
    $page = Get-CurrentDocumentPage
    if(!$page){ return @() }
    if($page.PSObject.Properties.Name -notcontains 'PdfTextLayerZones'){ return @() }
    return @($page.PdfTextLayerZones)
}

function Test-TextZoneCollectionHasSource($zones,$source){
    if([string]::IsNullOrWhiteSpace([string]$source)){ return $false }
    foreach($zone in @($zones)){
        if(
            $zone -and
            $zone.PSObject.Properties.Name -contains 'Source' -and
            [string]$zone.Source -eq [string]$source
        ){
            return $true
        }
    }
    return $false
}

function Test-IsPdfTextLayerBackedZone($zone){
    if(!$zone){ return $false }

    $source = if($zone.PSObject.Properties.Name -contains 'Source'){ [string]$zone.Source } else { "" }
    $originalSource = if($zone.PSObject.Properties.Name -contains 'OriginalZoneSource'){ [string]$zone.OriginalZoneSource } else { "" }

    return (
        $source -eq 'PdfTextLayer' -or
        $originalSource -eq 'PdfTextLayer'
    )
}

function Set-CurrentPagePdfTextLayerAvailability($hasPdfTextLayer,$blockCount = 0){
    $page = Get-CurrentDocumentPage
    if(!$page){ return }
    $page | Add-Member -NotePropertyName HasPdfTextLayer -NotePropertyValue ([bool]$hasPdfTextLayer) -Force
    $page | Add-Member -NotePropertyName PdfTextLayerBlockCount -NotePropertyValue ([int]$blockCount) -Force
}

function Get-CurrentPagePdfTextLayerAvailability{
    $page = Get-CurrentDocumentPage
    if(!$page){
        return [PSCustomObject]@{ HasPdfTextLayer = $false; BlockCount = 0 }
    }

    if($page.PSObject.Properties.Name -contains 'HasPdfTextLayer'){
        $knownCount = 0
        if($page.PSObject.Properties.Name -contains 'PdfTextLayerBlockCount'){
            $knownCount = [int]$page.PdfTextLayerBlockCount
        }
        return [PSCustomObject]@{
            HasPdfTextLayer = [bool]$page.HasPdfTextLayer
            BlockCount = $knownCount
        }
    }

    $pageNumber = if($script:SelectedPageIndex -ge 0){ ($script:SelectedPageIndex + 1) } else { 1 }
    try{
        $blocks = @(Get-PdfTextLayerBlocks $script:CurrentSourcePath $pageNumber)
        $hasPdfTextLayer = (@($blocks).Count -gt 0)
        Set-CurrentPagePdfTextLayerAvailability $hasPdfTextLayer @($blocks).Count
        return [PSCustomObject]@{
            HasPdfTextLayer = $hasPdfTextLayer
            BlockCount = @($blocks).Count
        }
    }
    catch{
        Set-CurrentPagePdfTextLayerAvailability $false 0
        return [PSCustomObject]@{ HasPdfTextLayer = $false; BlockCount = 0 }
    }
}

function Show-PdfTextLayerAvailabilityHint{
    if(!$txtOcrDebug){ return }
    if(!$script:sourceBitmap){ return }
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){ return }

    $availability = Get-CurrentPagePdfTextLayerAvailability
    if($availability.HasPdfTextLayer){
        $txtOcrDebug.Text = (
            "PDF text layer detected" + [Environment]::NewLine +
            ("Text blocks: {0}" -f [int]$availability.BlockCount) + [Environment]::NewLine +
            "Use: Text Zones / Auto Map PDF"
        )
    }
    else{
        $txtOcrDebug.Text = "No PDF text layer detected. Text Zones / Auto Map PDF require embedded PDF text layer."
    }
}

function Schedule-DeferredTextZoneWarmup{
    if(!$script:sourceBitmap){ return $false }
    $page = Get-CurrentDocumentPage
    if(!$page){ return $false }
    if(Test-CurrentPageTextZoneCacheReady){ return $true }

    $script:PendingTextZoneWarmupPageIndex = [int]$script:SelectedPageIndex
    $script:PendingTextZoneWarmupStage = "PdfTextLayer"
    $script:PendingTextZoneWarmupMapRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
    $script:PendingTextZoneWarmupImageCandidates = @()
    $script:TextZoneCacheResolved = $false
    if($script:DeferredTextZoneWarmupTimer){
        $script:DeferredTextZoneWarmupTimer.Stop()
        $script:DeferredTextZoneWarmupTimer.Start()
    }
    return $true
}

function Apply-PageState($page){

    if(!$page){
        $table.Rows.Clear()
        $script:StepRects = @{}
        $script:marks = @()
        Clear-SelectedMark
        Clear-UiCopiedMarks
        $script:DeletedSteps = @()
        $script:HighlightStrokes = @()
        $script:DuplicateDeclinedRects = @()
        $script:SuppressedTextZoneRects = @()
        $script:selectionRect = $null
        Clear-PreviewPane
        Refresh-DuplicateState
        Apply-TableSearchFilter
        Request-CanvasRedraw
        return
    }

    $page.Entries = @(Get-ValidatedStepEntries $page.Entries $page.Bitmap)
    foreach($entry in @($page.DeletedEntries)){ $entry | Add-Member -NotePropertyName PreserveRowIndex -NotePropertyValue $true -Force }
    $page.DeletedEntries = @(Get-ValidatedStepEntries $page.DeletedEntries $page.Bitmap)
    Rebuild-StepEntries @($page.Entries)
    Clear-SelectedMark
    $script:UiCopiedMarks = @($page.UiCopiedMarks)
    if($script:UiCopiedMarks.Count -gt 0){
        $script:NextUiCopiedMarkId = ((@($script:UiCopiedMarks | ForEach-Object { [int]$_.Id }) | Measure-Object -Maximum).Maximum + 1)
    }
    else{
        $script:NextUiCopiedMarkId = 1
    }
    Update-CopiedUiNote
    $script:DeletedSteps = @(Copy-StepEntryCollection $page.DeletedEntries)
    $script:HighlightStrokes = if($page.PSObject.Properties.Name -contains "HighlightStrokes"){ @($page.HighlightStrokes) } else { @() }
    $script:DuplicateDeclinedRects = @($page.DuplicateDeclinedRects)
    $script:SuppressedTextZoneRects = if($page.PSObject.Properties.Name -contains "SuppressedTextZoneRects"){ @($page.SuppressedTextZoneRects) } else { @() }
    $script:selectionRect = $null
    Clear-PreviewPane
    Sync-VisibleStepNumbers
    Refresh-DuplicateState
    Apply-TableSearchFilter
    Request-CanvasRedraw
}

function Sync-StepNumbers{ Validate-StepState }

function Renumber-AllPages{ Validate-StepState }

function Get-StepSortValue($entry){

    if(!$entry -or !$entry.Cells -or $entry.Cells.Count -le 0){
        return [int]::MaxValue
    }

    $stepNumber = 0
    if([int]::TryParse([string]$entry.Cells[0],[ref]$stepNumber)){
        return $stepNumber
    }

    return [int]::MaxValue
}

function Sort-VisibleSteps{

    if($table.Rows.Count -le 1){ return }

    $currentPageBitmap = $null
    if(
        $script:SelectedPageIndex -ge 0 -and
        $script:SelectedPageIndex -lt $script:DocumentPages.Count
    ){
        $currentPageBitmap = $script:DocumentPages[$script:SelectedPageIndex].Bitmap
    }

    $selectedStepText = $null
    if($table.SelectedRows.Count -gt 0){
        $selectedStepText = [string]$table.SelectedRows[0].Cells[0].Value
    }

    $sortableEntries = @()
    $sourceEntries = @(Get-ValidatedStepEntries (Get-AllStepEntries) $currentPageBitmap)

    for($i = 0; $i -lt $sourceEntries.Count; $i++){
        $sortableEntries += [PSCustomObject]@{
            Entry = $sourceEntries[$i]
            Step = Get-StepSortValue $sourceEntries[$i]
            OriginalIndex = $i
        }
    }

    $sortedEntries = @(
        $sortableEntries |
        Sort-Object @{ Expression = "Step"; Descending = $false }, @{ Expression = "OriginalIndex"; Descending = $false } |
        ForEach-Object { $_.Entry }
    )

    Rebuild-StepEntries $sortedEntries

    if($selectedStepText -ne $null){
        for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
            if([string]$table.Rows[$rowIndex].Cells[0].Value -eq $selectedStepText){
                $table.ClearSelection()
                $table.Rows[$rowIndex].Selected = $true
                $table.CurrentCell = $table.Rows[$rowIndex].Cells[0]
                $table.FirstDisplayedScrollingRowIndex = $rowIndex
                break
            }
        }
    }

    Save-CurrentPageState
    Save-SessionState
    Refresh-DuplicateState
    Request-CanvasRedraw
}

function Get-NextStepNumber([switch]$SkipSaveCurrentPageState){

    if(-not $SkipSaveCurrentPageState){
        Save-CurrentPageState
    }

    $maxStep = 0

    if($SkipSaveCurrentPageState){
        for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
            $stepNumber = 0
            $stepText = Get-TableCellText $rowIndex 0
            if([int]::TryParse($stepText,[ref]$stepNumber) -and $stepNumber -gt $maxStep){
                $maxStep = $stepNumber
            }
        }
    }

    for($pageIndex = 0; $pageIndex -lt $script:DocumentPages.Count; $pageIndex++){
        if($SkipSaveCurrentPageState -and $pageIndex -eq $script:SelectedPageIndex){
            continue
        }

        $page = $script:DocumentPages[$pageIndex]
        foreach($entry in @($page.Entries)){
            $stepNumber = 0
            $stepText = if($entry.Cells.Count -gt 0){ [string]$entry.Cells[0] } else { "" }
            if([int]::TryParse($stepText,[ref]$stepNumber) -and $stepNumber -gt $maxStep){
                $maxStep = $stepNumber
            }
        }
    }

    return ($maxStep + 1)
}

function Update-PageNavigationUi{

    $pageCount = @($script:DocumentPages).Count
    $hasMultiplePages = ($pageCount -gt 1)

    $btnPrevPage.Visible = $hasMultiplePages
    $btnNextPage.Visible = $hasMultiplePages
    $lblPageInfo.Visible = $hasMultiplePages

    if($pageCount -le 0){
        $lblPageInfo.Text = ""
        $btnPrevPage.Enabled = $false
        $btnNextPage.Enabled = $false
        Update-UiLayout
        return
    }

    $safeIndex = [int]$script:SelectedPageIndex
    if($safeIndex -lt 0){ $safeIndex = 0 }
    $maxIndex = [int]($pageCount - 1)
    if($safeIndex -gt $maxIndex){ $safeIndex = $maxIndex }
    $lblPageInfo.Text = "Page {0} / {1}" -f ($safeIndex + 1),$pageCount
    $btnPrevPage.Enabled = $hasMultiplePages -and ($safeIndex -gt 0)
    $btnNextPage.Enabled = $hasMultiplePages -and ($safeIndex -lt $maxIndex)

    Update-UiLayout
}

function Show-PageByIndex($index){

    $pageCount = @($script:DocumentPages).Count
    if($pageCount -eq 0){
        Update-PageNavigationUi
        return
    }

    $safeIndex = [int]$index
    if($safeIndex -lt 0){ $safeIndex = 0 }
    $maxIndex = [int]($pageCount - 1)
    if($safeIndex -gt $maxIndex){ $safeIndex = $maxIndex }

    if($pageList.SelectedIndex -ne $safeIndex){
        $pageList.SelectedIndex = $safeIndex
    }
    else{
        Bind-SelectedPage
    }
}

function Bind-SelectedPage{

    if($script:IsBindingPage){ return }

    $script:IsBindingPage = $true

    try{
        $targetIndex = $pageList.SelectedIndex

        Save-CurrentPageState

        if($targetIndex -lt 0 -or $targetIndex -ge $script:DocumentPages.Count){
            $script:SelectedPageIndex = -1
            $script:sourceBitmap = $null
            Apply-PageState $null
            Update-PageNavigationUi
            return
        }

        $script:SelectedPageIndex = $targetIndex
        $page = $script:DocumentPages[$targetIndex]
        $script:sourceBitmap = $page.Bitmap
        $script:CurrentSourcePath = $page.SourcePath
        Stop-DeferredTextZoneWarmup
        Restore-PageTextZoneCache $page

        Set-ViewMode "FitScreen"
        Apply-PageState $page
        Clear-HiddenTextZoneHover
        $canPrepareZonesInBackground = (-not $script:IsLoadingSource -and -not $script:IsRestoringState)
        if($script:ShowPdfTextZones){
            if(Test-CurrentPageTextZoneCacheReady){
                Refresh-PdfTextLayerZones | Out-Null
            }
            elseif($canPrepareZonesInBackground){
                Schedule-DeferredTextZoneWarmup | Out-Null
            }
        }
        Validate-StepState
        Update-PageNavigationUi
        Save-SessionState
    }
    finally{
        $script:IsBindingPage = $false
    }
}

function Set-DocumentPages($pages,$sourcePath){

    Dispose-DocumentPages
    Reset-WorkspaceState

    $script:DocumentPages = @($pages)
    $script:CurrentSourcePath = $sourcePath
    $pageList.Items.Clear()

    foreach($page in @($script:DocumentPages)){
        [void]$pageList.Items.Add($page.DisplayName)
    }

    if($pageList.Items.Count -gt 0){
        Show-PageByIndex 0
    }
    else{
        $script:sourceBitmap = $null
        $script:SelectedPageIndex = -1
        Apply-PageState $null
    }

    Update-PageNavigationUi
}

function Find-RenderCacheDirectoryByFingerprint($fingerprint){

    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }
    if(!(Test-Path $script:RenderCacheRoot)){ return $null }

    $matchingDirs = @(
        Get-ChildItem -Path $script:RenderCacheRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (Get-CacheFingerprintFromPath $_.FullName) -eq $fingerprint.ToLowerInvariant()
        } |
        Sort-Object {
            if($_.Name -match '__backup$'){ 0 } else { 1 }
        }
    )

    foreach($cacheDir in $matchingDirs){
        if((Get-CacheFingerprintFromPath $cacheDir.FullName) -eq $fingerprint.ToLowerInvariant()){
            return $cacheDir.FullName
        }
    }

    return $null
}

function Get-SessionOrStateFingerprint($state,$sessionFilePath = $null){

    $sessionFingerprint = Get-SessionFingerprintFromPath $sessionFilePath
    if(-not [string]::IsNullOrWhiteSpace($sessionFingerprint)){
        return $sessionFingerprint.ToLowerInvariant()
    }

    $stateFingerprint = [string](Get-StatePropertyValue $state "SourceFingerprint")
    if(-not [string]::IsNullOrWhiteSpace($stateFingerprint)){
        return $stateFingerprint.ToLowerInvariant()
    }

    return $null
}

function Get-RenderCacheImagesForState($state,$sessionFilePath = $null){

    if(!$state){ return @() }

    $stateFingerprint = Get-SessionOrStateFingerprint $state $sessionFilePath
    if([string]::IsNullOrWhiteSpace($stateFingerprint)){ return @() }

    $cacheDir = Find-RenderCacheDirectoryByFingerprint $stateFingerprint
    if([string]::IsNullOrWhiteSpace($cacheDir) -or !(Test-Path $cacheDir)){ return @() }

    $script:RenderedPdfTempDir = $cacheDir
    return @(
        Get-ChildItem -Path $cacheDir -Filter "page-*.jpg" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -ExpandProperty FullName
    )
}

function New-DocumentPagesFromSessionState($state,$sessionFilePath = $null,$pagePathsOverride = $null){

    if(!$state){ return @() }

    $stateSourcePath = [string](Get-StatePropertyValue $state "SourcePath")
    $pagePaths = @()
    $pagePathSource = if($pagePathsOverride){ @($pagePathsOverride) } else { @(Get-RenderCacheImagesForState $state $sessionFilePath) }
    foreach($candidatePath in @($pagePathSource)){
        if([string]::IsNullOrWhiteSpace([string]$candidatePath)){ continue }
        $pagePaths += ,([string]$candidatePath)
    }
    if($pagePaths.Count -le 0){ return @() }

    $savedPages = @(Convert-SessionValueToList (Get-StatePropertyValue $state "DocumentPages"))
    $pageRecords = @()

    for($pageIndex = 0; $pageIndex -lt $pagePaths.Count; $pageIndex++){
        $pagePath = $pagePaths[$pageIndex]
        $savedPage = if($pageIndex -lt $savedPages.Count){ $savedPages[$pageIndex] } else { $null }
        $displayName = [string](Get-StatePropertyValue $savedPage "DisplayName")
        if([string]::IsNullOrWhiteSpace($displayName)){
            $displayName = "{0} - Page {1}" -f ([System.IO.Path]::GetFileName($stateSourcePath)),($pageIndex + 1)
        }

        $pageNumber = [int](Get-StatePropertyValue $savedPage "PageNumber")
        if($pageNumber -le 0){ $pageNumber = $pageIndex + 1 }
        $rotationDegrees = Get-NormalizedRotationDegrees (Get-StatePropertyValue $savedPage "RotationDegrees")

        $pageRecords += (New-DocumentPageRecord $stateSourcePath $displayName $pagePath $pageNumber $rotationDegrees)
    }

    return @($pageRecords)
}

function Restore-SessionFromCacheState($state,$sessionFilePath = $null){

    if(!$state){ return $false }

    $pageRecords = @(New-DocumentPagesFromSessionState $state $sessionFilePath)
    if($pageRecords.Count -le 0){ return $false }

    $stateSourcePath = [string](Get-StatePropertyValue $state "SourcePath")

    $script:IsLoadingSource = $true
    try{
        Clear-PreviewImage
        Set-DocumentPages @($pageRecords) $stateSourcePath
        if($sessionFilePath){
            $script:CurrentSessionFilePath = $sessionFilePath
        }
        Apply-SessionStateObject $state
        Stop-DeferredTextZoneWarmup
        Rebind-CurrentRestoredPage
    }
    finally{
        $script:IsLoadingSource = $false
    }

    return $true
}

function Restore-SessionFromSelectedCacheImages($state,$sessionFilePath,$selectedPagePaths){

    if(!$state){ return $false }

    $orderedPagePaths = @($selectedPagePaths)
    if($orderedPagePaths.Count -le 0){ return $false }

    $pageRecords = @(New-DocumentPagesFromSessionState $state $sessionFilePath $orderedPagePaths)
    if($pageRecords.Count -le 0){ return $false }

    $stateSourcePath = [string](Get-StatePropertyValue $state "SourcePath")

    $script:IsLoadingSource = $true
    try{
        Clear-PreviewImage
        Set-DocumentPages @($pageRecords) $stateSourcePath
        if($sessionFilePath){
            $script:CurrentSessionFilePath = $sessionFilePath
        }
        Apply-SessionStateObject $state
        Stop-DeferredTextZoneWarmup
        Rebind-CurrentRestoredPage
    }
    finally{
        $script:IsLoadingSource = $false
    }

    return $true
}

function Rebind-CurrentRestoredPage{

    if(
        $script:SelectedPageIndex -lt 0 -or
        $script:SelectedPageIndex -ge $script:DocumentPages.Count
    ){
        return
    }

    $page = $script:DocumentPages[$script:SelectedPageIndex]
    if(!$page){ return }

    Stop-DeferredTextZoneWarmup
    $script:sourceBitmap = $page.Bitmap
    Restore-PageTextZoneCache $page
    Apply-PageState $page
    Validate-StepState
    Refresh-DuplicateState
    Update-CanvasCursor
    Request-CanvasRedraw
}

function Get-RenderCachePagePathsByFingerprint($fingerprint){

    if([string]::IsNullOrWhiteSpace($fingerprint)){ return @() }

    $cacheDir = Find-RenderCacheDirectoryByFingerprint $fingerprint
    if([string]::IsNullOrWhiteSpace($cacheDir) -or !(Test-Path $cacheDir)){ return @() }

    return @(
        Get-ChildItem -Path $cacheDir -Filter "page-*.jpg" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -ExpandProperty FullName
    )
}

function Test-SessionRenderCacheGood($state,$sessionFilePath){

    if(!$state){ return $false }

    $fingerprint = Get-SessionOrStateFingerprint $state $sessionFilePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $false }

    $rowCount = Get-StateDocumentRowCount $state
    if($rowCount -le 0){
        $fallbackRowCount = Get-SessionEntryCount $state
        if($fallbackRowCount -le 0){ return $false }
    }

    $pagePaths = @(Get-RenderCachePagePathsByFingerprint $fingerprint)
    if($pagePaths.Count -le 0){ return $false }

    $savedPages = @(Convert-SessionValueToList (Get-StatePropertyValue $state "DocumentPages"))
    $expectedPageCount = $savedPages.Count
    if($expectedPageCount -le 0){ $expectedPageCount = 1 }

    return ($pagePaths.Count -eq $expectedPageCount)
}

function Find-BestSessionFileByFingerprint($fingerprint){

    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }
    if(!(Test-Path $script:SessionStoreDir)){ return $null }

    $bestSession = Get-ChildItem -Path $script:SessionStoreDir -Filter "*.clixml" -File -ErrorAction SilentlyContinue |
        Where-Object { (Get-SessionFingerprintFromPath $_.FullName) -eq $fingerprint.ToLowerInvariant() } |
        Sort-Object Length, LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if($bestSession){
        return $bestSession.FullName
    }

    return $null
}

function Find-SessionFileByCacheFolderName($cacheDir){

    if([string]::IsNullOrWhiteSpace($cacheDir)){ return $null }
    if(!(Test-Path $script:SessionStoreDir)){ return $null }

    $cacheName = [System.IO.Path]::GetFileName($cacheDir)
    if([string]::IsNullOrWhiteSpace($cacheName)){ return $null }

    $directSessionPath = Join-Path $script:SessionStoreDir ($cacheName + ".clixml")
    if(Test-Path $directSessionPath){
        return $directSessionPath
    }

    return $null
}

function Get-MatchingSessionFilesByFingerprint($fingerprint){

    if([string]::IsNullOrWhiteSpace($fingerprint)){ return @() }
    if(!(Test-Path $script:SessionStoreDir)){ return @() }

    $primarySessions = @()
    $backupSessions = @()

    foreach($sessionFile in @(
        Get-ChildItem -Path $script:SessionStoreDir -Filter "*.clixml" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    )){
        $sessionFingerprint = Get-SessionFingerprintFromPath $sessionFile.FullName
        if($sessionFingerprint -ne $fingerprint.ToLowerInvariant()){ continue }

        if($sessionFile.BaseName -match '__backup(?:_|$)'){
            $backupSessions += $sessionFile.FullName
        }
        else{
            $primarySessions += $sessionFile.FullName
        }
    }

    return @($primarySessions + $backupSessions)
}

function Get-BestSessionMatchForFingerprint($fingerprint,$preferredPath = $null){

    $sessionPath = Find-BestSessionFileByFingerprint $fingerprint
    if([string]::IsNullOrWhiteSpace($sessionPath) -or !(Test-Path $sessionPath)){ return $null }

    $state = Import-SessionStateFromClixmlXml $sessionPath
    if(!$state){
        $state = Import-ClixmlSafe $sessionPath
    }
    if(!$state){ return $null }

    return [PSCustomObject]@{
        SessionPath = $sessionPath
        State = $state
    }
}

function Delete-CurrentSessionAndRelatedData{

    $sourcePath = [string]$script:CurrentSourcePath
    $sessionFilePath = if($script:CurrentSessionFilePath){ [string]$script:CurrentSessionFilePath } else { $null }
    $fingerprint = $null

    if(-not [string]::IsNullOrWhiteSpace($sourcePath) -and (Test-Path $sourcePath)){
        $fingerprint = Get-SourceFingerprint $sourcePath
    }
    if([string]::IsNullOrWhiteSpace($fingerprint) -and -not [string]::IsNullOrWhiteSpace($sessionFilePath)){
        $fingerprint = Get-SessionFingerprintFromPath $sessionFilePath
    }

    if([string]::IsNullOrWhiteSpace($fingerprint) -and [string]::IsNullOrWhiteSpace($sessionFilePath)){
        [System.Windows.Forms.MessageBox]::Show("No current session was found to delete.")
        return $false
    }

    $confirm1 = [System.Windows.Forms.MessageBox]::Show(
        "Delete the current session and related cached data for this drawing? This cannot be undone.",
        "Delete Current Session",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if($confirm1 -ne [System.Windows.Forms.DialogResult]::Yes){ return $false }

    $confirm2 = [System.Windows.Forms.MessageBox]::Show(
        "Confirm again: all saved marks, balloons, text zones, highlights, and related render cache for the current drawing will be permanently removed.",
        "Delete Current Session",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Stop
    )
    if($confirm2 -ne [System.Windows.Forms.DialogResult]::Yes){ return $false }

    Stop-DeferredTextZoneWarmup

    $sessionPaths = @()
    if(-not [string]::IsNullOrWhiteSpace($fingerprint)){
        $sessionPaths += @(Get-MatchingSessionFilesByFingerprint $fingerprint)
    }
    if(-not [string]::IsNullOrWhiteSpace($sessionFilePath) -and (Test-Path $sessionFilePath)){
        $sessionPaths += $sessionFilePath
    }
    $sessionPaths = @($sessionPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    foreach($path in @($sessionPaths)){
        Remove-PathQuietly $path
    }

    if(-not [string]::IsNullOrWhiteSpace($fingerprint) -and (Test-Path $script:RenderCacheRoot)){
        foreach($cacheDir in @(Get-ChildItem -Path $script:RenderCacheRoot -Directory -ErrorAction SilentlyContinue)){
            if((Get-CacheFingerprintFromPath $cacheDir.FullName) -eq $fingerprint.ToLowerInvariant()){
                Remove-PathQuietly $cacheDir.FullName
            }
        }
    }

    Dispose-DocumentPages
    Reset-WorkspaceState
    $pageList.Items.Clear()
    $script:CurrentSourcePath = $null
    $script:CurrentSessionFilePath = $null
    $script:RenderedPdfTempDir = $null
    $script:JobFolder = $null
    $script:JobName = $null
    $script:PartNo = $null
    $script:MoldName = $null
$script:PartQuantity = ""
$script:PartMaterial = ""
$script:PartHrc = ""
$script:PartUser = "7139"
    Apply-PageState $null
    Update-PageNavigationUi
    Request-CanvasRedraw

    if(Test-Path $script:AppStateFilePath){
        $appState = [ordered]@{
            LastSourcePath = $null
            LastSessionFilePath = $null
            AdaptiveDetectorStats = $script:AdaptiveDetectorStats
        }
        [void](Export-ClixmlSafe $script:AppStateFilePath $appState)
    }

    [System.Windows.Forms.MessageBox]::Show("Current session and related cache were deleted.")
    return $true
}

function Get-AllInspectionRows{

    Save-CurrentPageState
    $rows = @()

    foreach($page in @($script:DocumentPages)){
        foreach($entry in @($page.Entries)){
            $stepText = [string]$entry.Cells[0]
            $measurementOverride = Get-MeasurementOverrideForStep $stepText
            $rows += [ordered]@{
                Step = $stepText
                Nominal = [string]$entry.Cells[1]
                TolMinus = [string]$entry.Cells[2]
                TolPlus = [string]$entry.Cells[3]
                Result = if($entry.Cells.Count -gt 4){ [string]$entry.Cells[4] } else { "" }
                MeasurementActual = if($measurementOverride){ [string]$measurementOverride.Actual } else { "" }
                MeasurementResult = if($measurementOverride){ [string]$measurementOverride.Result } else { "" }
                ToolState = if($entry.Cells.Count -gt 7){ (Convert-ToStepToolState $entry.Cells[7]) } else { "C" }
                ImportantStep = if($entry.Cells.Count -gt 8){ (Convert-ToStepImportantFlag $entry.Cells[8]) } else { $false }
                DisplayName = [string]$page.DisplayName
            }
        }
    }

    return $rows
}

function Get-QuantityFirstInteger($qtyText){

    $text = ([string]$qtyText).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return $null }

    $m = [regex]::Match($text,'(?<!\d)\d+(?!\d)')
    if(!$m.Success){ return $null }

    $parsed = 0
    if([int]::TryParse([string]$m.Value,[ref]$parsed)){
        return $parsed
    }

    return $null
}

function Test-JudgeOkFillAllSteps($qtyText){

    $qtyValue = Get-QuantityFirstInteger $qtyText
    if($qtyValue -eq $null){ return $true }
    return ([int]$qtyValue -le 1)
}

function Get-ExportResultValue($rowData,$qtyText){
    return ""
}

function Get-ExportMeasurementOffset($rowData,$absoluteSampleIndex,$variantSeed = ""){

    $nominalText = [string]$rowData.Nominal
    $displayDecimals = Get-InspectionDisplayDecimalPlaces $nominalText $rowData.TolMinus $rowData.TolPlus
    $tolMinus = Convert-MarkStepToleranceCellToDouble $rowData.TolMinus
    $tolPlus = Convert-MarkStepToleranceCellToDouble $rowData.TolPlus
    $lower = [double]$tolMinus
    $upper = [double]$tolPlus

    if($upper -lt $lower){
        $swap = $lower
        $lower = $upper
        $upper = $swap
    }

    $range = $upper - $lower
    if([Math]::Abs($range) -lt 0.0000001){
        return $lower
    }

    $seedText = ([string]$rowData.Step) + "|" + $nominalText + "|" + (Format-InvariantSignedTolerance $lower) + "|" + (Format-InvariantSignedTolerance $upper) + "|S" + [string]$absoluteSampleIndex + "|V" + [string]$variantSeed
    $unit = Get-DeterministicMeasurementUnitValue $seedText
    $unitJitter = Get-DeterministicMeasurementUnitValue ($seedText + "|J")
    $unitEdge = Get-DeterministicMeasurementUnitValue ($seedText + "|E")
    $isSensitive = Test-AutoFillMeasurementSensitiveNominal $nominalText

    if($isSensitive){
        $ratio = if($unit -lt 0.5){
            0.08 + ($unit * 0.40)
        }
        else{
            0.56 + (($unit - 0.5) * 0.40)
        }
    }
    else{
        $ratio = if($unit -lt 0.5){
            0.10 + ($unit * 0.36)
        }
        else{
            0.54 + (($unit - 0.5) * 0.36)
        }
    }

    $offset = $lower + ($range * $ratio)
    $mid = ($lower + $upper) / 2.0
    if([Math]::Abs($offset - $mid) -lt ($range * 0.035)){
        $push = if($unit -lt 0.5){ -1.0 } else { 1.0 }
        $offset += ($push * $range * (if($isSensitive){ 0.13 } else { 0.08 }))
    }

    $jitterAmplitude = if($isSensitive){ 0.16 } else { 0.12 }
    $offset += (($unitJitter - 0.5) * $range * $jitterAmplitude)

    $displayStep = if($displayDecimals -gt 0){ [Math]::Pow(10.0,-$displayDecimals) } else { 1.0 }
    if($range -gt ($displayStep * 0.55)){
        $displayNudgeDirection = if(($absoluteSampleIndex % 2) -eq 0){ -1.0 } else { 1.0 }
        if($unitEdge -gt 0.66){ $displayNudgeDirection = 1.0 }
        elseif($unitEdge -lt 0.33){ $displayNudgeDirection = -1.0 }

        $displayNudge = [Math]::Min(($range * 0.16),($displayStep * (0.58 + ($unitEdge * 0.34))))
        $offset += ($displayNudgeDirection * $displayNudge)
    }

    return [Math]::Max($lower,[Math]::Min($upper,$offset))
}

function Get-ExportMeasurementText($rowData,$absoluteSampleIndex,$variantSeed = ""){

    $nominalText = [string]$rowData.Nominal
    $displayDecimals = Get-InspectionDisplayDecimalPlaces $nominalText $rowData.TolMinus $rowData.TolPlus
    $nominal = 0.0
    if(-not (Convert-AngleDmsTextToDouble $nominalText ([ref]$nominal))){
        if(-not (Convert-MechanicalNumberToDouble $nominalText ([ref]$nominal))){
            return ""
        }
    }

    $measurementOffset = Get-ExportMeasurementOffset $rowData $absoluteSampleIndex $variantSeed
    $result = [double]$nominal + [double]$measurementOffset
    return (Format-InspectionResultValueWithDecimals $result $nominalText $displayDecimals)
}

function Get-ExportMeasurementTextUnique($rowData,$absoluteSampleIndex,$usedTexts){
    $attemptSeeds = @("base","alt1","alt2","alt3","edge1","edge2","swing1","swing2")
    $fallbackText = ""

    foreach($attemptSeed in $attemptSeeds){
        $text = Get-ExportMeasurementText $rowData $absoluteSampleIndex $attemptSeed
        if([string]::IsNullOrWhiteSpace([string]$text)){ continue }
        if([string]::IsNullOrWhiteSpace($fallbackText)){ $fallbackText = $text }

        if(!$usedTexts.ContainsKey($text)){
            $usedTexts[$text] = 1
            return $text
        }
    }

    if(-not [string]::IsNullOrWhiteSpace($fallbackText)){
        if($usedTexts.ContainsKey($fallbackText)){
            $usedTexts[$fallbackText] = [int]$usedTexts[$fallbackText] + 1
        }
        else{
            $usedTexts[$fallbackText] = 1
        }
    }
    return $fallbackText
}

function Write-InspectionSampleResults($sheet,$row,$rowData,$sampleStart,$sampleEnd){

    $sampleColumns = @(Get-InspectionSampleColumnNumbers)
    $sampleCount = [Math]::Min($sampleColumns.Count,[Math]::Max(0,([int]$sampleEnd - [int]$sampleStart + 1)))
    $usedTexts = @{}

    foreach($col in $sampleColumns){
        Set-ExcelCellTextValue $sheet $row $col ""
    }

    $manualActual = [string](Get-StatePropertyValue $rowData "MeasurementActual")
    if(-not [string]::IsNullOrWhiteSpace($manualActual)){
        if($sampleCount -gt 0){
            Set-ExcelCellTextValue $sheet $row $sampleColumns[0] $manualActual
        }
        return
    }

    for($sampleIndex = 1; $sampleIndex -le $sampleCount; $sampleIndex++){
        $absoluteSampleIndex = ([int]$sampleStart + $sampleIndex - 1)
        if(-not (Should-ExportMeasurementForSample $rowData $absoluteSampleIndex)){ continue }
        $targetColumn = $sampleColumns[$sampleIndex - 1]
        Set-ExcelCellTextValue $sheet $row $targetColumn (Get-ExportMeasurementTextUnique $rowData $absoluteSampleIndex $usedTexts)
    }
}

function Get-ExportToolCode($rowData){
    $toolState = Convert-ToStepToolState $rowData.ToolState
    if($toolState -eq "I"){ return "" }
    if($toolState -eq "B"){ return "B" }
    return "C"
}

function New-MarkedPageBitmap($page,$includeImportantHighlights = $false){

    if(!$page -or !$page.Bitmap){
        return $null
    }

    $bmp = New-Object Drawing.Bitmap $page.Bitmap
    $g = $null
    $originalMarks = $script:marks
    $originalUiCopiedMarks = $script:UiCopiedMarks
    $originalHighlightStrokes = $script:HighlightStrokes
    $originalSelectedMarkKind = $script:SelectedMarkKind
    $originalSelectedMarkRowIndex = $script:SelectedMarkRowIndex
    $originalSelectedUiCopyId = $script:SelectedUiCopyId

    try{
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = "HighQuality"
        $g.TextRenderingHint = "AntiAliasGridFit"

        $script:marks = @()
        foreach($entry in @($page.Entries)){
            if($entry.Mark){
                $script:marks += [PSCustomObject]@{
                    Index = [int]$entry.Mark.Index
                    X = [double]$entry.Mark.X
                    Y = [double]$entry.Mark.Y
                    Scale = (Get-MarkScale $entry.Mark)
                }
            }
            else{
                $script:marks += $null
            }
        }

        Clear-SelectedMark
        $script:UiCopiedMarks = @($page.UiCopiedMarks)
        $script:HighlightStrokes = if($page.PSObject.Properties.Name -contains "HighlightStrokes"){ @($page.HighlightStrokes) } else { @() }
        if($includeImportantHighlights){
            Draw-ImportantStepHighlights $g $page.Entries 1.0
        }
        Draw-HighlightStrokes $g
        Draw-MarkBalloons $g 1.0
        return $bmp
    }
    finally{
        $script:marks = $originalMarks
        $script:UiCopiedMarks = $originalUiCopiedMarks
        $script:HighlightStrokes = $originalHighlightStrokes
        $script:SelectedMarkKind = $originalSelectedMarkKind
        $script:SelectedMarkRowIndex = $originalSelectedMarkRowIndex
        $script:SelectedUiCopyId = $originalSelectedUiCopyId

        if($g){
            $g.Dispose()
        }
    }
}

function Test-AnyImportantInspectionSteps{
    foreach($page in @($script:DocumentPages)){
        foreach($entry in @($page.Entries)){
            if($entry -and $entry.Cells -and $entry.Cells.Count -gt 8){
                if(Convert-ToStepImportantFlag $entry.Cells[8]){
                    return $true
                }
            }
        }
    }
    return $false
}


function Get-StepEntryPdfText($entry){

    if(!$entry -or !$entry.Cells){ return "" }

    $nominal = if($entry.Cells.Count -gt 1){ ([string]$entry.Cells[1]).Trim() } else { "" }
    $tolMinus = if($entry.Cells.Count -gt 2){ ([string]$entry.Cells[2]).Trim() } else { "" }
    $tolPlus = if($entry.Cells.Count -gt 3){ ([string]$entry.Cells[3]).Trim() } else { "" }

    if([string]::IsNullOrWhiteSpace($nominal)){ return "" }

    $parts = @($nominal)
    if(-not [string]::IsNullOrWhiteSpace($tolMinus) -and $tolMinus -ne "0"){
        $parts += $tolMinus
    }
    if(-not [string]::IsNullOrWhiteSpace($tolPlus) -and $tolPlus -ne "0"){
        $parts += $tolPlus
    }

    return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join " ").Trim()
}

function Get-PagePdfTextLayerItems($page){

    $items = @()
    if(!$page){ return $items }

    $stepTextByStep = @{}

    foreach($entry in @($page.Entries)){
        if(!$entry -or !$entry.Rect){ continue }

        $text = Get-StepEntryPdfText $entry
        if([string]::IsNullOrWhiteSpace($text)){ continue }

        $stepKey = ""
        if($entry.Cells -and $entry.Cells.Count -gt 0){ $stepKey = ([string]$entry.Cells[0]).Trim() }
        if(-not [string]::IsNullOrWhiteSpace($stepKey)){ $stepTextByStep[$stepKey] = $text }

        $items += [PSCustomObject]@{
            Text = $text
            Rect = (New-Object Drawing.Rectangle($entry.Rect.X,$entry.Rect.Y,$entry.Rect.Width,$entry.Rect.Height))
        }
    }

    # Linked/copy dimensions are still real accepted text locations. If the copy mark
    # remembers the linked OCR rect, expose the same step text there too.
    foreach($mark in @($page.UiCopiedMarks)){
        if(!$mark){ continue }
        if(-not ($mark.PSObject.Properties.Name -contains "LinkedRect") -or !$mark.LinkedRect){ continue }

        $stepKey = ([string]$mark.SourceStep).Trim()
        if([string]::IsNullOrWhiteSpace($stepKey)){ $stepKey = ([string]$mark.Index).Trim() }
        if([string]::IsNullOrWhiteSpace($stepKey)){ continue }
        if(-not $stepTextByStep.ContainsKey($stepKey)){ continue }

        $rect = $mark.LinkedRect
        $items += [PSCustomObject]@{
            Text = [string]$stepTextByStep[$stepKey]
            Rect = (New-Object Drawing.Rectangle($rect.X,$rect.Y,$rect.Width,$rect.Height))
        }
    }

    return $items
}

function Get-AsciiBytes($text){
    return [System.Text.Encoding]::ASCII.GetBytes([string]$text)
}

function Convert-TextToPdfLiteral($text){
    $value = [string]$text
    if([string]::IsNullOrWhiteSpace($value)){ return "" }

    try{
        $encoding = [System.Text.Encoding]::GetEncoding(1252)
    }
    catch{
        $encoding = [System.Text.Encoding]::ASCII
    }

    $bytes = $encoding.GetBytes($value)
    $sb = New-Object System.Text.StringBuilder
    foreach($b in $bytes){
        if($b -eq 40 -or $b -eq 41 -or $b -eq 92){
            [void]$sb.Append('\')
            [void]$sb.Append([char]$b)
        }
        elseif($b -ge 32 -and $b -le 126){
            [void]$sb.Append([char]$b)
        }
        else{
            [void]$sb.Append('\')
            [void]$sb.Append(([Convert]::ToString($b,8)).PadLeft(3,'0'))
        }
    }

    return $sb.ToString()
}

function New-PdfStreamObjectBytes($dictionaryBody,$streamBytes){
    $streamLength = if($streamBytes){ [int]$streamBytes.Length } else { 0 }
    $prefixText = "<<" + [Environment]::NewLine
    if(-not [string]::IsNullOrWhiteSpace([string]$dictionaryBody)){
        $prefixText += ($dictionaryBody + [Environment]::NewLine)
    }
    $prefixText += ("/Length " + $streamLength + [Environment]::NewLine + ">>" + [Environment]::NewLine + "stream" + [Environment]::NewLine)
    $prefix = Get-AsciiBytes $prefixText
    $suffix = Get-AsciiBytes ([Environment]::NewLine + "endstream")
    $output = New-Object byte[] ($prefix.Length + $streamLength + $suffix.Length)
    [Array]::Copy($prefix,0,$output,0,$prefix.Length)
    if($streamLength -gt 0){
        [Array]::Copy($streamBytes,0,$output,$prefix.Length,$streamLength)
    }
    [Array]::Copy($suffix,0,$output,($prefix.Length + $streamLength),$suffix.Length)
    return $output
}

function Get-JpegCodecInfo{
    if($script:JpegCodecInfo){ return $script:JpegCodecInfo }
    $script:JpegCodecInfo = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    return $script:JpegCodecInfo
}

function Get-JpegBytesFromBitmap($bitmap,$quality = $null){
    if(!$bitmap){ return $null }

    $stream = $null
    $encoderParams = $null
    try{
        $stream = New-Object System.IO.MemoryStream
        $jpegCodec = Get-JpegCodecInfo
        $jpegQuality = if($null -eq $quality){ [long]$script:PdfExportJpegQualityDefault } else { [long]$quality }
        if($jpegQuality -lt 30L){ $jpegQuality = 30L }
        if($jpegQuality -gt 100L){ $jpegQuality = 100L }
        if($jpegCodec){
            $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality,$jpegQuality)
            $bitmap.Save($stream,$jpegCodec,$encoderParams)
        }
        else{
            $bitmap.Save($stream,[System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        return $stream.ToArray()
    }
    finally{
        if($encoderParams){ $encoderParams.Dispose() }
        if($stream){ $stream.Dispose() }
    }
}

function Get-PdfContentStreamTextCommands($page,$pageWidth,$pageHeight){
    $items = @(Get-PagePdfTextLayerItems $page)
    if($items.Count -le 0){ return "" }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach($item in $items){
        if(!$item -or !$item.Rect){ continue }

        $text = ([string]$item.Text).Trim()
        if([string]::IsNullOrWhiteSpace($text)){ continue }

        $rect = $item.Rect
        $fontSize = [double][Math]::Max(3.0,[Math]::Min(18.0,([double]$rect.Height * 0.72)))
        $x = [double][Math]::Max(0.0,[double]$rect.X)
        $y = [double][Math]::Max(0.0,([double]$pageHeight - [double]$rect.Y - $fontSize))
        $literal = Convert-TextToPdfLiteral $text
        if([string]::IsNullOrWhiteSpace($literal)){ continue }

        $lines.Add(("BT /F1 {0} Tf 3 Tr 1 0 0 1 {1} {2} Tm ({3}) Tj ET" -f
            (Format-InvariantDecimal $fontSize "0.###"),
            (Format-InvariantDecimal $x "0.###"),
            (Format-InvariantDecimal $y "0.###"),
            $literal
        )) | Out-Null
    }

    if($page){
        $lines.Add("BT /F1 1 Tf 3 Tr 1 0 0 1 2 2 Tm (Author: MrTho) Tj ET") | Out-Null
    }

    return ($lines -join [Environment]::NewLine)
}

function Write-PdfObjectToStream($stream,$objectId,$bodyBytes,$offsets){
    $offsets[$objectId] = [int64]$stream.Position
    $objHeader = Get-AsciiBytes ("$objectId 0 obj`n")
    $objFooter = Get-AsciiBytes "`nendobj`n"
    $stream.Write($objHeader,0,$objHeader.Length)
    $stream.Write($bodyBytes,0,$bodyBytes.Length)
    $stream.Write($objFooter,0,$objFooter.Length)
}

function Write-PdfStreamObjectToStream($stream,$objectId,$dictionaryBody,$streamBytes,$offsets){
    $streamLength = if($streamBytes){ [int]$streamBytes.Length } else { 0 }
    $prefixText = "<<" + [Environment]::NewLine
    if(-not [string]::IsNullOrWhiteSpace([string]$dictionaryBody)){
        $prefixText += ($dictionaryBody + [Environment]::NewLine)
    }
    $prefixText += ("/Length " + $streamLength + [Environment]::NewLine + ">>" + [Environment]::NewLine + "stream" + [Environment]::NewLine)
    $prefix = Get-AsciiBytes $prefixText
    $suffix = Get-AsciiBytes ([Environment]::NewLine + "endstream")

    $offsets[$objectId] = [int64]$stream.Position
    $objHeader = Get-AsciiBytes ("$objectId 0 obj`n")
    $objFooter = Get-AsciiBytes "`nendobj`n"
    $stream.Write($objHeader,0,$objHeader.Length)
    $stream.Write($prefix,0,$prefix.Length)
    if($streamLength -gt 0){
        $stream.Write($streamBytes,0,$streamLength)
    }
    $stream.Write($suffix,0,$suffix.Length)
    $stream.Write($objFooter,0,$objFooter.Length)
}

function Write-MarkStepPdfWithTextLayer($outputPdfPath,$pageExportPages,$includeImportantHighlights = $false,$jpegQuality = $null){
    if([string]::IsNullOrWhiteSpace([string]$outputPdfPath)){ throw "Output PDF path is empty." }
    if(!$pageExportPages -or $pageExportPages.Count -le 0){ throw "No pages are available for PDF export." }

    $outputDir = [System.IO.Path]::GetDirectoryName($outputPdfPath)
    if(-not [string]::IsNullOrWhiteSpace($outputDir) -and !(Test-Path $outputDir)){
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    $fontObjectId = 1
    $pageInfos = @()
    $nextObjectId = 2
    for($i = 0; $i -lt $pageExportPages.Count; $i++){
        $pageInfos += [PSCustomObject]@{
            Index = $i
            ImageObjectId = $nextObjectId
            ContentObjectId = ($nextObjectId + 1)
            PageObjectId = ($nextObjectId + 2)
        }
        $nextObjectId += 3
    }
    $pagesObjectId = $nextObjectId
    $catalogObjectId = ($nextObjectId + 1)
    $infoObjectId = ($nextObjectId + 2)

    $kids = (($pageInfos | ForEach-Object { "$($_.PageObjectId) 0 R" }) -join " ")
    $pagesObjectText = @(
        "<<"
        "/Type /Pages"
        "/Count $($pageInfos.Count)"
        "/Kids [ $kids ]"
        ">>"
    ) -join [Environment]::NewLine
    $catalogObjectText = @(
        "<<"
        "/Type /Catalog"
        "/Pages $pagesObjectId 0 R"
        ">>"
    ) -join [Environment]::NewLine
    $infoObjectText = @(
        "<<"
        "/Author (MrTho)"
        "/Creator (RapidOCR PDF Scan Tool)"
        "/Producer (RapidOCR PDF Scan Tool)"
        ">>"
    ) -join [Environment]::NewLine

    $actualOutputPdfPath = Get-WritablePdfOutputPath $outputPdfPath
    $stream = $null
    try{
        $stream = [System.IO.File]::Open($actualOutputPdfPath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        $pdfHeader = Get-AsciiBytes "%PDF-1.4`n"
        $binaryHeader = New-Object byte[] 5
        $binaryHeader[0] = 37
        $binaryHeader[1] = 226
        $binaryHeader[2] = 227
        $binaryHeader[3] = 207
        $binaryHeader[4] = 211
        $stream.Write($pdfHeader,0,$pdfHeader.Length)
        $stream.Write($binaryHeader,0,$binaryHeader.Length)
        $stream.Write((Get-AsciiBytes "`n"),0,1)

        $offsets = @{}
        Write-PdfObjectToStream $stream $fontObjectId (Get-AsciiBytes "<<`n/Type /Font`n/Subtype /Type1`n/BaseFont /Helvetica`n/Encoding /WinAnsiEncoding`n>>") $offsets

        foreach($pageInfo in @($pageInfos)){
            $page = $pageExportPages[$pageInfo.Index]
            $bitmap = $null
            try{
                $bitmap = New-MarkedPageBitmap $page $includeImportantHighlights
                if(!$bitmap){ throw "Failed to render marked page bitmap for PDF export." }

                $pageWidth = [double]$bitmap.Width
                $pageHeight = [double]$bitmap.Height
                $imageBytes = Get-JpegBytesFromBitmap $bitmap $jpegQuality
                if(!$imageBytes){ throw "Failed to encode page image for PDF export." }

                $imageDict = @(
                    "/Type /XObject"
                    "/Subtype /Image"
                    "/Width $([int]$bitmap.Width)"
                    "/Height $([int]$bitmap.Height)"
                    "/ColorSpace /DeviceRGB"
                    "/BitsPerComponent 8"
                    "/Filter /DCTDecode"
                ) -join [Environment]::NewLine
                Write-PdfStreamObjectToStream $stream $pageInfo.ImageObjectId $imageDict $imageBytes $offsets

                $contentLines = @(
                    "q"
                    ("{0} 0 0 {1} 0 0 cm" -f (Format-InvariantDecimal $pageWidth "0.###"),(Format-InvariantDecimal $pageHeight "0.###"))
                    "/Im0 Do"
                    "Q"
                )
                $textCommands = Get-PdfContentStreamTextCommands $page $pageWidth $pageHeight
                if(-not [string]::IsNullOrWhiteSpace($textCommands)){
                    $contentLines += $textCommands
                }
                $contentBytes = Get-AsciiBytes (($contentLines -join [Environment]::NewLine) + [Environment]::NewLine)
                Write-PdfStreamObjectToStream $stream $pageInfo.ContentObjectId "" $contentBytes $offsets

                $pageObjectText = @(
                    "<<"
                    "/Type /Page"
                    "/Parent $pagesObjectId 0 R"
                    ("/MediaBox [0 0 {0} {1}]" -f (Format-InvariantDecimal $pageWidth "0.###"),(Format-InvariantDecimal $pageHeight "0.###"))
                    "/Resources << /Font << /F1 $fontObjectId 0 R >> /XObject << /Im0 $($pageInfo.ImageObjectId) 0 R >> >>"
                    "/Contents $($pageInfo.ContentObjectId) 0 R"
                    ">>"
                ) -join [Environment]::NewLine
                Write-PdfObjectToStream $stream $pageInfo.PageObjectId (Get-AsciiBytes $pageObjectText) $offsets
            }
            finally{
                if($bitmap){ $bitmap.Dispose() }
            }
        }

        Write-PdfObjectToStream $stream $pagesObjectId (Get-AsciiBytes $pagesObjectText) $offsets
        Write-PdfObjectToStream $stream $catalogObjectId (Get-AsciiBytes $catalogObjectText) $offsets
        Write-PdfObjectToStream $stream $infoObjectId (Get-AsciiBytes $infoObjectText) $offsets

        $xrefStart = [int64]$stream.Position
        $maxObjectId = $infoObjectId
        $xrefHeader = Get-AsciiBytes ("xref`n0 {0}`n" -f ($maxObjectId + 1))
        $stream.Write($xrefHeader,0,$xrefHeader.Length)
        $freeEntry = Get-AsciiBytes "0000000000 65535 f `n"
        $stream.Write($freeEntry,0,$freeEntry.Length)
        for($id = 1; $id -le $maxObjectId; $id++){
            $offset = if($offsets.ContainsKey($id)){ [int64]$offsets[$id] } else { 0 }
            $entry = Get-AsciiBytes (("{0:0000000000} 00000 n `n" -f $offset))
            $stream.Write($entry,0,$entry.Length)
        }

        $trailer = Get-AsciiBytes (("trailer`n<<`n/Size {0}`n/Root {1} 0 R`n/Info {2} 0 R`n>>`nstartxref`n{3}`n%%EOF" -f ($maxObjectId + 1),$catalogObjectId,$infoObjectId,$xrefStart))
        $stream.Write($trailer,0,$trailer.Length)
    }
    finally{
        if($stream){ $stream.Dispose() }
    }

    return $actualOutputPdfPath
}

function Draw-PdfSelectableTextLayer($graphics,$page,$posX,$posY,$ratio){

    if(!$graphics -or !$page){ return }

    $items = @(Get-PagePdfTextLayerItems $page)
    if($items.Count -le 0){ return }

    $brush = $null
    $format = $null
    try{
        # Alpha=1 keeps the visual export effectively unchanged, but Microsoft Print to PDF
        # still receives real DrawString calls so PDF viewers can expose/select the text.
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(1,0,0,0))
        $format = New-Object Drawing.StringFormat
        $format.FormatFlags = [Drawing.StringFormatFlags]::NoClip
        $format.Trimming = [Drawing.StringTrimming]::None

        foreach($item in $items){
            if(!$item -or !$item.Rect){ continue }
            $text = ([string]$item.Text).Trim()
            if([string]::IsNullOrWhiteSpace($text)){ continue }

            $rect = $item.Rect
            $x = [float]($posX + ($rect.X * $ratio))
            $y = [float]($posY + ($rect.Y * $ratio))
            $w = [float][Math]::Max(($rect.Width * $ratio),4.0)
            $h = [float][Math]::Max(($rect.Height * $ratio),4.0)
            $fontSize = [float][Math]::Max(3.0,[Math]::Min(18.0,($h * 0.72)))
            $font = $null

            try{
                $font = New-Object Drawing.Font("Arial",$fontSize,[Drawing.FontStyle]::Regular)
                $textRect = New-Object Drawing.RectangleF -ArgumentList $x,$y,$w,$h
                $graphics.DrawString($text,$font,$brush,$textRect,$format)
            }
            finally{
                if($font){ $font.Dispose() }
            }
        }
    }
    finally{
        if($format){ $format.Dispose() }
        if($brush){ $brush.Dispose() }
    }
}

function Export-MarkedDocumentPdf($outputPdfPath,$includeImportantHighlights = $false,$jpegQuality = $null){

    Save-CurrentPageState
    Validate-StepState

    $pageExportPages = @()

    foreach($page in @($script:DocumentPages)){
        if($page -and $page.Bitmap){
            $pageExportPages += $page
        }
    }

    if($pageExportPages.Count -eq 0){
        throw "No pages are available for PDF export."
    }

    return (Write-MarkStepPdfWithTextLayer $outputPdfPath $pageExportPages $includeImportantHighlights $jpegQuality)
}

function Get-ImportantMarkedPdfPath($jobFolder,$jobName){

    return (Join-Path $jobFolder ("MarkStep Important " + $jobName + ".pdf"))
}

function Get-WritablePdfOutputPath($requestedPdfPath){
    if([string]::IsNullOrWhiteSpace([string]$requestedPdfPath)){ return $requestedPdfPath }

    $directory = [System.IO.Path]::GetDirectoryName($requestedPdfPath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($requestedPdfPath)
    $extension = [System.IO.Path]::GetExtension($requestedPdfPath)
    if([string]::IsNullOrWhiteSpace($extension)){ $extension = ".pdf" }

    $candidatePaths = New-Object System.Collections.Generic.List[string]
    $candidatePaths.Add($requestedPdfPath) | Out-Null
    for($i = 2; $i -le 20; $i++){
        $candidateName = ("{0} Copy {1}{2}" -f $baseName,$i,$extension)
        $candidatePaths.Add((Join-Path $directory $candidateName)) | Out-Null
    }

    foreach($candidatePath in $candidatePaths){
        try{
            if(Test-Path -LiteralPath $candidatePath){
                $probe = [System.IO.File]::Open($candidatePath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
                $probe.Dispose()
            }
            return $candidatePath
        }
        catch{
            continue
        }
    }

    throw ("Unable to create PDF output. Files are locked starting from: " + $requestedPdfPath)
}

function Apply-Tolerance($value){

    if(!$table.SelectedRows.Count){ return }

    # Detect mode
    if($rbPM.Checked){ $mode = "PM" }
    elseif($rbPlus.Checked){ $mode = "PLUS" }
    elseif($rbMinus.Checked){ $mode = "MINUS" }
    elseif($rbPP.Checked){ $mode = "PP" }
    elseif($rbMM.Checked){ $mode = "MM" }

    # ============================
    # BAND MODES ( ++ and -- )
    # ============================

    if($mode -eq "PP" -or $mode -eq "MM"){

        # first click
        if($script:bandFirst -eq $null){
            $script:bandFirst = $value
            return
        }

        # second click
        $first = $script:bandFirst
        $second = $value
        $script:bandFirst = $null
    }

    foreach($row in $table.SelectedRows){

        $r = $row.Index

        switch($mode){

            "PM" {
                $tolMinus = -$value
                $tolPlus  =  $value
            }

            "PLUS" {
                $tolMinus = 0
                $tolPlus  = $value
            }

            "MINUS" {
                $tolMinus = -$value
                $tolPlus  = 0
            }

            "PP" {
                $tolMinus = +$first
                $tolPlus  = +$second
            }

            "MM" {
                $tolMinus = -$first
                $tolPlus  = -$second
            }

        }

        $table.Rows[$r].Cells[2].Value = Format-InvariantSignedTolerance $tolMinus
        $table.Rows[$r].Cells[3].Value = Format-InvariantSignedTolerance $tolPlus

    }

    Sync-MarkStepTextZonesFromTable
    Refresh-DuplicateState
    Save-CurrentPageState
    Save-SessionState
    Register-TrainingSignal "tolerance_apply" @{
        Value = [double]$value
        Mode = $mode
        Count = @($table.SelectedRows).Count
    }
    Request-CanvasRedraw

}

function Get-NormalizedNominalText($value){

    $text = [string]$value
    $text = $text -replace "[`r`n]+",""
    return $text.Trim()
}

function Remove-MechanicalNominalPrefixes($text){

    $normalizedText = Get-NormalizedNominalText $text
    return ($normalizedText -replace '^(?:[RCØ])+','')
}

function Apply-NominalDecoration($mode){

    if(!$table.SelectedRows.Count){ return }

    foreach($row in $table.SelectedRows){
        $rowIndex = $row.Index
        if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){ continue }

        $currentNominal = Get-NormalizedNominalText $table.Rows[$rowIndex].Cells[1].Value
        if([string]::IsNullOrWhiteSpace($currentNominal)){ continue }

        switch($mode){
            "DEGREE" {
                if(-not $currentNominal.EndsWith("°",[System.StringComparison]::Ordinal)){
                    $currentNominal += "°"
                }
            }
            "D_PREFIX" {
                $currentNominal = "Ø" + (Remove-MechanicalNominalPrefixes $currentNominal)
            }
            "R_PREFIX" {
                $currentNominal = "R" + (Remove-MechanicalNominalPrefixes $currentNominal)
            }
            "C_PREFIX" {
                $currentNominal = "C" + (Remove-MechanicalNominalPrefixes $currentNominal)
            }
        }

        $table.Rows[$rowIndex].Cells[1].Value = $currentNominal
    }

    Sync-MarkStepTextZonesFromTable
    Save-CurrentPageState
    Save-SessionState
    Register-TrainingSignal "nominal_decoration" @{
        Mode = [string]$mode
        Count = @($table.SelectedRows).Count
    }
    Request-CanvasRedraw
}

function Set-LastTextInsertTarget($control){

    if(!$control){ return }
    if($control -isnot [System.Windows.Forms.TextBoxBase]){ return }
    if($control.ReadOnly){ return }

    $script:LastTextInsertTarget = $control
}

function Get-ActiveTextInputControl{

    $activeControl = $form.ActiveControl
    if($activeControl -is [System.Windows.Forms.TextBoxBase]){
        if(-not $activeControl.ReadOnly){
            Set-LastTextInsertTarget $activeControl
            return $activeControl
        }
    }

    if($activeControl -eq $table){
        $editingControl = $table.EditingControl
        if($editingControl -is [System.Windows.Forms.TextBoxBase]){
            Set-LastTextInsertTarget $editingControl
            return $editingControl
        }
    }

    if($activeControl -and $activeControl.ContainsFocus){
        foreach($candidate in @($txtTol0,$txtTol1,$txtTol2,$txtTol3,$txtTableSearch,$txtCopiedUi)){
            if($candidate -and $candidate.Focused -and -not $candidate.ReadOnly){
                Set-LastTextInsertTarget $candidate
                return $candidate
            }
        }
    }

    if(
        $script:LastTextInsertTarget -and
        $script:LastTextInsertTarget -is [System.Windows.Forms.TextBoxBase] -and
        -not $script:LastTextInsertTarget.ReadOnly
    ){
        return $script:LastTextInsertTarget
    }

    return $null
}

function Insert-TextIntoActiveInput($insertText){

    if([string]::IsNullOrEmpty($insertText)){ return $false }

    $target = Get-ActiveTextInputControl
    if(!$target){ return $false }

    $selectionStart = [int]$target.SelectionStart
    $selectionLength = [int]$target.SelectionLength
    $currentText = [string]$target.Text

    if($selectionStart -lt 0){ $selectionStart = 0 }
    if($selectionStart -gt $currentText.Length){ $selectionStart = $currentText.Length }
    if($selectionLength -lt 0){ $selectionLength = 0 }
    if(($selectionStart + $selectionLength) -gt $currentText.Length){
        $selectionLength = $currentText.Length - $selectionStart
    }

    $target.Text = $currentText.Remove($selectionStart,$selectionLength).Insert($selectionStart,$insertText)
    $target.SelectionStart = $selectionStart + $insertText.Length
    $target.SelectionLength = 0
    $target.Focus()

    return $true
}

function Prefix-TextIntoActiveInput($prefixText){

    if([string]::IsNullOrEmpty($prefixText)){ return $false }

    $target = Get-ActiveTextInputControl
    if(!$target){ return $false }

    $currentText = [string]$target.Text
    $normalizedText = $currentText.TrimStart()
    if($normalizedText.StartsWith($prefixText,[System.StringComparison]::Ordinal)){
        $target.Focus()
        return $true
    }

    $target.Text = $prefixText + $currentText
    $target.SelectionStart = $prefixText.Length
    $target.SelectionLength = 0
    $target.Focus()

    return $true
}

function Focus-OnRect($rect){

    if(!$rect -or !$script:sourceBitmap){ return }

    $viewport = Get-ViewportSize
    $centerX = $rect.X + ($rect.Width / 2.0)
    $centerY = $rect.Y + ($rect.Height / 2.0)

    $script:panX = ($viewport.Width / 2.0) - ($centerX * $script:zoom)
    $script:panY = ($viewport.Height / 2.0) - ($centerY * $script:zoom)
    Clamp-Pan

    # highlight rectangle
    $script:HighlightRect = $rect

    Request-CanvasRedraw
    Save-SessionState
}

# =========================
# ROTATE
# =========================

function Rotate-Bitmap($bmp,$angle){

    $normalizedAngle = [double]$angle
    while($normalizedAngle -lt 0){ $normalizedAngle += 360.0 }
    while($normalizedAngle -ge 360.0){ $normalizedAngle -= 360.0 }

    if([Math]::Abs($normalizedAngle) -lt 0.001){
        return $bmp.Clone()
    }

    if([Math]::Abs($normalizedAngle - 90.0) -lt 0.001 -or [Math]::Abs($normalizedAngle - 180.0) -lt 0.001 -or [Math]::Abs($normalizedAngle - 270.0) -lt 0.001){
        $rot = $bmp.Clone()

        switch([int][Math]::Round($normalizedAngle)){
            90  { $rot.RotateFlip([Drawing.RotateFlipType]::Rotate90FlipNone) }
            180 { $rot.RotateFlip([Drawing.RotateFlipType]::Rotate180FlipNone) }
            270 { $rot.RotateFlip([Drawing.RotateFlipType]::Rotate270FlipNone) }
        }

        return $rot
    }

    $theta = $normalizedAngle * ([Math]::PI / 180.0)
    $cos = [Math]::Abs([Math]::Cos($theta))
    $sin = [Math]::Abs([Math]::Sin($theta))
    $newWidth = [Math]::Max(1,[int][Math]::Ceiling(($bmp.Width * $cos) + ($bmp.Height * $sin)))
    $newHeight = [Math]::Max(1,[int][Math]::Ceiling(($bmp.Width * $sin) + ($bmp.Height * $cos)))
    $rotated = New-Object Drawing.Bitmap $newWidth,$newHeight

    $graphics = [Drawing.Graphics]::FromImage($rotated)
    try{
        $graphics.Clear([Drawing.Color]::White)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.TranslateTransform(($newWidth / 2.0),($newHeight / 2.0))
        $graphics.RotateTransform([float]$normalizedAngle)
        $graphics.TranslateTransform((-1.0 * $bmp.Width / 2.0),(-1.0 * $bmp.Height / 2.0))
        $graphics.DrawImage($bmp,0,0,$bmp.Width,$bmp.Height)
    }
    finally{
        $graphics.Dispose()
    }

    return $rotated
}

function Get-OcrPrimaryAngles{
    return @(0,90,180,270)
}

function Test-PdfSourceFile($pdfPath){
    if([string]::IsNullOrWhiteSpace($pdfPath)){
        return [PSCustomObject]@{ IsValid = $false; Reason = "Path is empty." }
    }
    if(!(Test-Path $pdfPath)){
        return [PSCustomObject]@{ IsValid = $false; Reason = "File not found: $pdfPath" }
    }

    $fileInfo = Get-Item -LiteralPath $pdfPath -ErrorAction SilentlyContinue
    if(!$fileInfo -or $fileInfo.Length -le 0){
        return [PSCustomObject]@{ IsValid = $false; Reason = "File is empty." }
    }

    $stream = $null
    try{
        $stream = [System.IO.File]::Open($pdfPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $bufferSize = [int][Math]::Min(1024,[int]$stream.Length)
        $buffer = New-Object byte[] $bufferSize
        $bytesRead = $stream.Read($buffer,0,$buffer.Length)
        if($bytesRead -le 0){
            return [PSCustomObject]@{ IsValid = $false; Reason = "Failed to read file header." }
        }

        $headerText = [System.Text.Encoding]::ASCII.GetString($buffer,0,$bytesRead)
        if($headerText.Contains("%PDF-")){
            return [PSCustomObject]@{ IsValid = $true; Reason = $null }
        }

        $previewLength = [Math]::Min($bytesRead,24)
        $previewBytes = $buffer[0..($previewLength - 1)]
        $previewHex = (($previewBytes | ForEach-Object { $_.ToString("X2") }) -join ' ')
        return [PSCustomObject]@{ IsValid = $false; Reason = "Header does not contain %PDF-. First bytes: $previewHex" }
    }
    catch{
        return [PSCustomObject]@{ IsValid = $false; Reason = $_.Exception.Message }
    }
    finally{
        if($stream){ $stream.Dispose() }
    }
}

function Convert-PDFToImages($pdfPath){
    $fingerprint = Get-SourceFingerprint $pdfPath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ throw "Cannot fingerprint PDF source." }
    if(!(Test-Path $script:RenderCacheRoot)){ New-Item -Path $script:RenderCacheRoot -ItemType Directory -Force | Out-Null }
    $cacheDir = Get-RenderCacheDirectoryPath $pdfPath
    if([string]::IsNullOrWhiteSpace($cacheDir)){ throw "Cannot determine render cache path." }
    if(!(Test-Path $cacheDir)){ New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }

    $pdfiumNativePath = Join-Path $script:AppRoot "x64"

    if(Test-Path $pdfiumNativePath){
        $env:PATH = $pdfiumNativePath + ";" + $env:PATH
    }

    $cachedImages = @(Get-ChildItem -Path $cacheDir -Filter "page-*.jpg" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if($cachedImages.Count -gt 0){
        $backupDir = Get-RenderCacheBackupDirectoryPath $cacheDir
        if(!(Test-Path $backupDir)){
            Backup-RenderCacheDirectory $cacheDir
        }
        $script:RenderedPdfTempDir = $cacheDir
        [void](Ensure-CanonicalSessionFileForSource $pdfPath @($cachedImages.FullName))
        return @($cachedImages.FullName)
    }

    $pdfSourceCheck = Test-PdfSourceFile $pdfPath
    if(-not $pdfSourceCheck.IsValid){
        throw "Source file is not a valid PDF. $($pdfSourceCheck.Reason)"
    }

    try{
        [void](Initialize-PdfiumRuntime)
        if(-not $script:PdfiumAvailable){
            throw "PdfiumViewer.dll is not available."
        }
        $doc = [PdfiumViewer.PdfDocument]::Load($pdfPath)
        $pagePaths = @()

        try{
            for($pageIndex = 0; $pageIndex -lt $doc.PageSizes.Count; $pageIndex++){
                $pageSize = $doc.PageSizes[$pageIndex]
                $dpi = 300.0
                $width = [Math]::Max(1,[int]([Math]::Round(($pageSize.Width / 72.0) * $dpi)))
                $height = [Math]::Max(1,[int]([Math]::Round(($pageSize.Height / 72.0) * $dpi)))
                $flags = [PdfiumViewer.PdfRenderFlags]::Annotations
                $image = $doc.Render($pageIndex,$width,$height,$dpi,$dpi,$flags)
                $out = Join-Path $cacheDir ("page-{0:d3}.jpg" -f ($pageIndex + 1))

                try{
                    $image.Save($out,[System.Drawing.Imaging.ImageFormat]::Jpeg)
                    $pagePaths += $out
                }
                finally{
                    $image.Dispose()
                }
            }
        }
        finally{
            $doc.Dispose()
        }

        Backup-RenderCacheDirectory $cacheDir
        $script:RenderedPdfTempDir = $cacheDir
        [void](Ensure-CanonicalSessionFileForSource $pdfPath @($pagePaths))
        return @($pagePaths)
    }
    catch{
        $pdftoppm = Get-Command pdftoppm -ErrorAction SilentlyContinue
        if(!$pdftoppm){
            throw "PDF rendering failed for '$pdfPath'. $($_.Exception.Message)"
        }

        $fallbackOut = Join-Path $cacheDir "page"
        & $pdftoppm.Source -jpeg -r 300 $pdfPath $fallbackOut 2>$null | Out-Null

        $images = Get-ChildItem -Path $cacheDir -Filter "page-*.jpg" -File -ErrorAction SilentlyContinue | Sort-Object Name
        if(!$images){
            throw "Failed to render PDF. $($_.Exception.Message)"
        }

        Backup-RenderCacheDirectory $cacheDir
        $script:RenderedPdfTempDir = $cacheDir
        [void](Ensure-CanonicalSessionFileForSource $pdfPath @($images.FullName))
        return @($images.FullName)
    }
}

function Reset-WorkspaceState{

    $table.Rows.Clear()
    $script:marks = @()
    Clear-SelectedMark
    Clear-UiCopiedMarks
    $script:StepRects = @{}
    $script:DeletedSteps = @()
    $script:DuplicateStepMap = @{}
    $script:SelectedDuplicateSteps = @{}
    $script:SelectedDuplicateAnchorStep = $null
    $script:HiddenDuplicateOriginalRect = $null
    $script:HiddenDuplicateGhostRect = $null
    $script:DuplicateDeclinedRects = @()
    $script:SuppressedTextZoneRects = @()
    $script:PdfTextLayerZones = @()
    Clear-ImageOcrAutoCache
    $script:selectionRect = $null
    $script:HighlightRect = $null
    $script:dragging = $false
    $script:isDraggingMark = $false
    $script:dragMarkIndex = -1
    $script:draggingMarkKind = $null
    $script:isPanning = $false
    $script:startPoint = $null
    $script:endPoint = $null

    if($preview.Image){
        $preview.Image.Dispose()
        $preview.Image = $null
    }

    Update-CanvasCursor
    Refresh-DuplicateState
}

function Load-SourceFile($filePath,[switch]$SkipMetadataPrompt,[switch]$SkipDuplicateWarning){
    Invoke-CacheCleanup
    Stop-DeferredTextZoneWarmup

    $previousZoom = $script:zoom
    $previousFitMode = $script:FitMode
    $previousSourcePath = [string]$script:CurrentSourcePath

    $script:IsLoadingSource = $true

    try{
        Clear-PreviewImage
        $script:sourceBitmap = $null
        $script:CurrentSourcePath = $filePath
        if(-not [string]::Equals($previousSourcePath,[string]$filePath,[System.StringComparison]::OrdinalIgnoreCase)){
            $script:JobFolder = $null
        }

        $existingState = $null
        $existingSessionFilePath = Find-MatchingSessionFile $filePath
        if($existingSessionFilePath -and (Test-Path $existingSessionFilePath)){
            $existingState = Import-SessionStateFromClixmlXml $existingSessionFilePath
            if(!$existingState){ $existingState = Import-ClixmlSafe $existingSessionFilePath }
        }

        $metadata = Get-DefaultDrawingMetadata $filePath $existingState
        $duplicateMatches = @()
        if(
            -not [string]::IsNullOrWhiteSpace([string]$metadata.PartNo) -and
            -not [string]::IsNullOrWhiteSpace([string]$metadata.MoldName)
        ){
            $duplicateMatches = @(Find-DuplicateMarkedSessionsByMetadata $metadata.PartNo $metadata.MoldName)
        }

        if($duplicateMatches.Count -gt 0){
            if(Open-DuplicateDrawingSession $duplicateMatches[0]){
                return
            }
            return
        }

        if($SkipMetadataPrompt){
            $metadata = Get-DefaultDrawingMetadata $filePath $existingState
        }
        else{
            $metadata = Show-DrawingMetadataDialog $filePath $existingState
            if(!$metadata){ return }
        }

        $script:PartNo = $metadata.PartNo
        $script:MoldName = $metadata.MoldName
        $script:PartQuantity = $metadata.Quantity
        $script:PartMaterial = $metadata.Material
        $script:PartHrc = $metadata.Hrc
        $script:PartUser = $metadata.User
        $script:JobName = $metadata.JobName

        $pageRecords = @()
        $extension = [System.IO.Path]::GetExtension($filePath).ToLower()

        if($extension -eq ".pdf"){
            $pagePaths = Convert-PDFToImages $filePath

            if(!$pagePaths -or @($pagePaths).Count -eq 0){
                throw "Cannot convert PDF to images."
            }

            $pageNumber = 1
            foreach($pagePath in @($pagePaths)){
                $displayName = "{0} - Page {1}" -f ([System.IO.Path]::GetFileName($filePath)),$pageNumber
                $pageRecords += (New-DocumentPageRecord $filePath $displayName $pagePath $pageNumber)
                $pageNumber++
            }
        }
        else{
            throw "Only PDF input is supported."
        }

        Set-DocumentPages @($pageRecords) $filePath

        if($script:PreserveZoomOnLoad -and $previousZoom -gt 0){
            switch($previousFitMode){
                "FitScreen" { Set-ViewMode "FitScreen" }
                "FitWidth" { Set-ViewMode "FitWidth" }
                "Actual" { Set-ViewMode "Actual" }
                default {
                    $script:zoom = Clamp-ZoomValue $previousZoom
                    $script:panX = 0
                    $script:panY = 0
                    $script:FitMode = "Custom"
                    Clamp-Pan
                    Update-ZoomStatus
                }
            }
        }
        else{
            $script:zoom = 1.0
            Set-ViewMode "FitScreen"
        }

        Restore-SourceSessionState $filePath
        $script:PartNo = $metadata.PartNo
        $script:MoldName = $metadata.MoldName
        $script:PartQuantity = $metadata.Quantity
        $script:PartMaterial = $metadata.Material
        $script:PartHrc = $metadata.Hrc
        $script:PartUser = $metadata.User
        $script:JobName = $metadata.JobName
        if($pageList.Items.Count -gt 0 -and $pageList.SelectedIndex -lt 0){
            $pageList.SelectedIndex = 0
            Bind-SelectedPage
        }

        Validate-StepState
        Refresh-DuplicateState
        Update-CanvasCursor
        Request-CanvasRedraw
    }
    finally{
        $script:IsLoadingSource = $false
    }

    Save-SessionState
}

function Invoke-FitScreenAction{
    Set-ViewMode "FitScreen"
    Save-SessionState
}

function Add-OcrLog($stepIndex,$ocrText){
    return
}

function Get-RenderCacheDirectoryPath($sourcePath){

    if([string]::IsNullOrWhiteSpace($sourcePath)){ return $null }

    $fingerprint = Get-SourceFingerprint $sourcePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }

    $sourceLabel = Get-SafeSessionLabel $sourcePath
    return Join-Path $script:RenderCacheRoot ($sourceLabel + "__" + $fingerprint + "__backup")
}

function Test-RenderCacheExistsForFingerprint($fingerprint){

    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $false }
    if(!(Test-Path $script:RenderCacheRoot)){ return $false }

    foreach($cacheDir in @(
        Get-ChildItem -Path $script:RenderCacheRoot -Directory -ErrorAction SilentlyContinue
    )){
        if((Get-CacheFingerprintFromPath $cacheDir.FullName) -ne $fingerprint.ToLowerInvariant()){ continue }
        $pageCount = @(
            Get-ChildItem -Path $cacheDir.FullName -Filter "page-*.jpg" -File -ErrorAction SilentlyContinue
        ).Count
        if($pageCount -gt 0){ return $true }
    }

    return $false
}

function Get-SafeSessionLabel($sourcePath){

    if([string]::IsNullOrWhiteSpace($sourcePath)){ return "session" }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath)
    if([string]::IsNullOrWhiteSpace($baseName)){ $baseName = "session" }

    $safeName = [System.Text.RegularExpressions.Regex]::Replace($baseName,'[\\/:*?"<>|]+','_')
    $safeName = [System.Text.RegularExpressions.Regex]::Replace($safeName,'\s+',' ').Trim()
    if([string]::IsNullOrWhiteSpace($safeName)){ $safeName = "session" }

    return $safeName
}

function Get-SessionFingerprintFromPath($sessionPath){

    if([string]::IsNullOrWhiteSpace($sessionPath)){ return $null }

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($sessionPath)
    if([string]::IsNullOrWhiteSpace($fileName)){ return $null }

    $normalizedName = [System.Text.RegularExpressions.Regex]::Replace($fileName,'(?i)__backup(?:_|$|[A-Za-z0-9-].*)$','')
    $separatorIndex = $normalizedName.LastIndexOf("__",[System.StringComparison]::Ordinal)
    if($separatorIndex -lt 0){ return $null }

    $fingerprint = $normalizedName.Substring($separatorIndex + 2).Trim()
    if($fingerprint -match '^[0-9a-fA-F]{40}$'){
        return $fingerprint.ToLowerInvariant()
    }

    return $null
}

function Get-FingerprintedItemLabel($path){

    if([string]::IsNullOrWhiteSpace($path)){ return $null }

    $itemName = [System.IO.Path]::GetFileNameWithoutExtension($path)
    if([string]::IsNullOrWhiteSpace($itemName)){
        $itemName = [System.IO.Path]::GetFileName($path)
    }
    if([string]::IsNullOrWhiteSpace($itemName)){ return $null }

    $normalizedName = [System.Text.RegularExpressions.Regex]::Replace($itemName,'(?i)__backup(?:_|$|[A-Za-z0-9-].*)$','')
    $separatorIndex = $normalizedName.LastIndexOf("__",[System.StringComparison]::Ordinal)
    if($separatorIndex -gt 0){
        $label = $normalizedName.Substring(0,$separatorIndex).Trim()
        if(-not [string]::IsNullOrWhiteSpace($label)){ return $label }
    }

    return $itemName
}

function Get-DrawingMetadataFromFingerprintedLabel($path){

    $label = Normalize-DrawingMetadataText (Get-FingerprintedItemLabel $path)
    $partNo = ""
    $moldName = ""

    if(-not [string]::IsNullOrWhiteSpace($label)){
        $parts = @($label -split '-')
        if($parts.Count -ge 2){
            $partNo = Normalize-DrawingMetadataText ($parts[0..($parts.Count - 2)] -join "-")
            $moldName = Normalize-DrawingMetadataText $parts[-1]
        }
        else{
            $partNo = $label
        }
    }

    return [PSCustomObject]@{
        PartNo = $partNo
        MoldName = $moldName
        JobName = $label
    }
}

function Get-SessionFilePath($sourcePath){

    if([string]::IsNullOrWhiteSpace($sourcePath)){ return $null }

    $fingerprint = Get-SourceFingerprint $sourcePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }

    $sessionLabel = Get-SafeSessionLabel $sourcePath
    return Join-Path $script:SessionStoreDir ($sessionLabel + "__" + $fingerprint + "__backup.clixml")
}

function Get-LegacyPrimarySessionFilePath($sourcePath){

    if([string]::IsNullOrWhiteSpace($sourcePath)){ return $null }

    $fingerprint = Get-SourceFingerprint $sourcePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }

    $sessionLabel = Get-SafeSessionLabel $sourcePath
    return Join-Path $script:SessionStoreDir ($sessionLabel + "__" + $fingerprint + ".clixml")
}

function Get-SourceFingerprint($sourcePath){

    if([string]::IsNullOrWhiteSpace($sourcePath)){ return $null }
    if(!(Test-Path $sourcePath)){ return $null }

    try{
        $fileInfo = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        $cacheKey = ([string]$fileInfo.FullName).ToUpperInvariant()
        $cacheStamp = ([string]$fileInfo.Length) + "|" + ([string]$fileInfo.LastWriteTimeUtc.Ticks)
        if($script:SourceFingerprintCache.ContainsKey($cacheKey)){
            $cached = $script:SourceFingerprintCache[$cacheKey]
            if(
                $cached -and
                $cached.PSObject.Properties.Name -contains "Stamp" -and
                [string]$cached.Stamp -eq $cacheStamp
            ){
                return [string]$cached.Fingerprint
            }
        }
    }
    catch{
        $fileInfo = $null
        $cacheKey = $null
        $cacheStamp = $null
    }

    $stream = $null
    $sha1 = [System.Security.Cryptography.SHA1]::Create()

    try{
        $stream = [System.IO.File]::OpenRead($sourcePath)
        $hashBytes = $sha1.ComputeHash($stream)
        $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-","").ToLowerInvariant()
        if(-not [string]::IsNullOrWhiteSpace($cacheKey)){
            $script:SourceFingerprintCache[$cacheKey] = [PSCustomObject]@{
                Stamp = [string]$cacheStamp
                Fingerprint = [string]$hash
            }
        }
        return $hash
    }
    finally{
        if($stream){
            $stream.Dispose()
        }
        $sha1.Dispose()
    }
}

function Get-StatePropertyValue($stateObject,$propertyName){

    if(!$stateObject){ return $null }

    if($stateObject -is [System.Collections.IDictionary]){
        if($stateObject.Contains($propertyName)){
            return $stateObject[$propertyName]
        }
        return $null
    }

    $property = $stateObject.PSObject.Properties[$propertyName]
    if($property){
        return $property.Value
    }

    return $null
}

function Set-StatePropertyValue($stateObject,$propertyName,$propertyValue){

    if(!$stateObject){ return }

    if($stateObject -is [System.Collections.IDictionary]){
        $stateObject[$propertyName] = $propertyValue
        return
    }

    $stateObject | Add-Member -NotePropertyName $propertyName -NotePropertyValue $propertyValue -Force
}

function Find-MatchingSessionFile($sourcePath){

    $sessionFilePath = Get-SessionFilePath $sourcePath
    if($sessionFilePath -and (Test-Path $sessionFilePath)){
        return $sessionFilePath
    }

    $legacySessionFilePath = Get-LegacyPrimarySessionFilePath $sourcePath
    if($legacySessionFilePath -and (Test-Path $legacySessionFilePath)){
        return $legacySessionFilePath
    }
    return $null
}

function Test-SessionAndRenderCacheAvailableForSource($sourcePath){
    if([string]::IsNullOrWhiteSpace($sourcePath)){ return $false }
    if(-not (Test-Path $sourcePath)){ return $false }

    $sessionFilePath = Find-MatchingSessionFile $sourcePath
    if([string]::IsNullOrWhiteSpace($sessionFilePath) -or -not (Test-Path $sessionFilePath)){ return $false }

    $fingerprint = Get-SourceFingerprint $sourcePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $false }

    return (Test-RenderCacheExistsForFingerprint $fingerprint)
}

function New-PlaceholderSessionStateForSource($sourcePath,$pagePaths = $null,$sourceFingerprintOverride = $null,$displayLabelOverride = $null){

    $resolvedPagePaths = @()
    foreach($candidatePath in @($pagePaths)){
        if([string]::IsNullOrWhiteSpace([string]$candidatePath)){ continue }
        $resolvedPagePaths += ,([string]$candidatePath)
    }

    $sourceFingerprint = $sourceFingerprintOverride
    if([string]::IsNullOrWhiteSpace($sourceFingerprint) -and $sourcePath -and (Test-Path $sourcePath)){
        $sourceFingerprint = Get-SourceFingerprint $sourcePath
    }

    $displayBaseLabel = $displayLabelOverride
    if([string]::IsNullOrWhiteSpace($displayBaseLabel)){
        if($sourcePath){
            $displayBaseLabel = [System.IO.Path]::GetFileName($sourcePath)
        }
        if([string]::IsNullOrWhiteSpace($displayBaseLabel)){
            $displayBaseLabel = 'Rendered Document'
        }
    }

    return [ordered]@{
        SourcePath = $sourcePath
        SourceFingerprint = $sourceFingerprint
        ExcelTemplate = $script:ExcelTemplate
        JobName = $script:JobName
        JobFolder = $script:JobFolder
        SelectedPageIndex = 0
        ViewState = [ordered]@{
            Zoom = 1.0
            PanX = 0
            PanY = 0
            FitMode = 'FitScreen'
        }
        DefaultTolerance = [ordered]@{
            Tol0 = $txtTol0.Text
            Tol1 = $txtTol1.Text
            Tol2 = $txtTol2.Text
            Tol3 = $txtTol3.Text
        }
        ToleranceMode = if($rbPM.Checked){ 'PM' } elseif($rbPlus.Checked){ 'PLUS' } elseif($rbMinus.Checked){ 'MINUS' } elseif($rbPP.Checked){ 'PP' } elseif($rbMM.Checked){ 'MM' } else { 'PM' }
        DocumentPages = @(
            for($pageIndex = 0; $pageIndex -lt $resolvedPagePaths.Count; $pageIndex++){
                [ordered]@{
                    DisplayName = "{0} - Page {1}" -f $displayBaseLabel,($pageIndex + 1)
                    PageNumber = ($pageIndex + 1)
                    Rows = @()
                    DeletedRows = @()
                    UiCopiedMarks = @()
                }
            }
        )
        Marks = @()
        Rows = @()
    }
}

function Ensure-CanonicalSessionFileForSource($sourcePath,$pagePaths = $null,[switch]$PreferCurrentState){

    if([string]::IsNullOrWhiteSpace($sourcePath) -or !(Test-Path $sourcePath)){ return $null }
    if(!(Test-Path $script:SessionStoreDir)){ New-Item -Path $script:SessionStoreDir -ItemType Directory -Force | Out-Null }

    $sessionFilePath = Get-SessionFilePath $sourcePath
    if([string]::IsNullOrWhiteSpace($sessionFilePath)){ return $null }

    $fingerprint = Get-SourceFingerprint $sourcePath
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }

    $isCurrentSource = $false
    if($script:CurrentSourcePath -and (Test-Path $script:CurrentSourcePath)){
        $isCurrentSource = ([string]::Equals((Get-SourceFingerprint $script:CurrentSourcePath),$fingerprint,[System.StringComparison]::OrdinalIgnoreCase))
    }

    if($PreferCurrentState -or $isCurrentSource){
        $script:CurrentSessionFilePath = $sessionFilePath
        Save-SessionState
    }

    if(Test-Path $sessionFilePath){
        return $sessionFilePath
    }

    $bestExistingSession = Find-BestSessionFileByFingerprint $fingerprint
    if($bestExistingSession -and (Test-Path $bestExistingSession)){
        try{
            Copy-Item -Path $bestExistingSession -Destination $sessionFilePath -Force
            if(Test-Path $sessionFilePath){ return $sessionFilePath }
        }
        catch{}
    }

    $resolvedPagePaths = @()
    foreach($candidatePath in @($pagePaths)){
        if([string]::IsNullOrWhiteSpace([string]$candidatePath)){ continue }
        $resolvedPagePaths += ,([string]$candidatePath)
    }
    if($resolvedPagePaths.Count -le 0){
        $cacheDir = Get-RenderCacheDirectoryPath $sourcePath
        if($cacheDir -and (Test-Path $cacheDir)){
            $resolvedPagePaths = @(
                Get-ChildItem -Path $cacheDir -Filter 'page-*.jpg' -File -ErrorAction SilentlyContinue |
                Sort-Object Name |
                Select-Object -ExpandProperty FullName
            )
        }
    }

    $placeholderState = New-PlaceholderSessionStateForSource $sourcePath $resolvedPagePaths $fingerprint (Get-SafeSessionLabel $sourcePath)
    [void](Export-ClixmlSafe $sessionFilePath $placeholderState)
    if(Test-Path $sessionFilePath){
        return $sessionFilePath
    }

    return $null
}

function Ensure-CanonicalSessionFileForCacheFolder($cacheDir){

    if([string]::IsNullOrWhiteSpace($cacheDir) -or !(Test-Path $cacheDir -PathType Container)){ return $null }
    if(!(Test-Path $script:SessionStoreDir)){ New-Item -Path $script:SessionStoreDir -ItemType Directory -Force | Out-Null }

    $cacheName = [System.IO.Path]::GetFileName($cacheDir)
    if([string]::IsNullOrWhiteSpace($cacheName)){ return $null }

    $sessionFilePath = Join-Path $script:SessionStoreDir ($cacheName + '.clixml')
    if(Test-Path $sessionFilePath){ return $sessionFilePath }

    $fingerprint = Get-CacheFingerprintFromPath $cacheDir
    if([string]::IsNullOrWhiteSpace($fingerprint)){ return $null }

    if($script:CurrentSourcePath -and (Test-Path $script:CurrentSourcePath)){
        $currentFingerprint = Get-SourceFingerprint $script:CurrentSourcePath
        if($currentFingerprint -and $currentFingerprint -eq $fingerprint){
            $ensuredCurrentSession = Ensure-CanonicalSessionFileForSource $script:CurrentSourcePath $null -PreferCurrentState
            if($ensuredCurrentSession -and (Test-Path $ensuredCurrentSession)){ return $ensuredCurrentSession }
        }
    }

    $bestExistingSession = Find-BestSessionFileByFingerprint $fingerprint
    if($bestExistingSession -and (Test-Path $bestExistingSession)){
        try{
            Copy-Item -Path $bestExistingSession -Destination $sessionFilePath -Force
            if(Test-Path $sessionFilePath){ return $sessionFilePath }
        }
        catch{}
    }

    $pagePaths = @(
        Get-ChildItem -Path $cacheDir -Filter 'page-*.jpg' -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -ExpandProperty FullName
    )
    $placeholderState = New-PlaceholderSessionStateForSource $null $pagePaths $fingerprint (Get-FingerprintedItemLabel $cacheDir)
    [void](Export-ClixmlSafe $sessionFilePath $placeholderState)
    if(Test-Path $sessionFilePath){
        return $sessionFilePath
    }

    return $null
}

function Get-MostRecentSessionFile{

    if(!(Test-Path $script:SessionStoreDir)){ return $null }

    $sessionFile = Get-ChildItem -Path $script:SessionStoreDir -Filter "*.clixml" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if($sessionFile){
        return $sessionFile.FullName
    }

    return $null
}

function Convert-StepEntriesToSessionRows($entries){

    return @(
        foreach($entry in @($entries)){
            $rect = $entry.Rect

            [ordered]@{
                RowIndex = $entry.RowIndex
                Step = if($entry.Cells.Count -gt 0){ $entry.Cells[0] } else { $null }
                Nominal = if($entry.Cells.Count -gt 1){ $entry.Cells[1] } else { $null }
                TolMinus = if($entry.Cells.Count -gt 2){ $entry.Cells[2] } else { $null }
                TolPlus = if($entry.Cells.Count -gt 3){ $entry.Cells[3] } else { $null }
                Result = if($entry.Cells.Count -gt 4){ $entry.Cells[4] } else { $null }
                ToolState = if($entry.Cells.Count -gt 7){ (Convert-ToStepToolState $entry.Cells[7]) } else { "C" }
                ImportantStep = if($entry.Cells.Count -gt 8){ (Convert-ToStepImportantFlag $entry.Cells[8]) } else { $false }
                Position = if($entry.Cells.Count -gt 6){ $entry.Cells[6] } elseif($entry.Cells.Count -gt 5){ $entry.Cells[5] } else { "View" }
                Rect = if($rect){
                    [ordered]@{
                        X = $rect.X
                        Y = $rect.Y
                        Width = $rect.Width
                        Height = $rect.Height
                    }
                }
                else{
                    $null
                }
                Mark = if($entry.Mark){
                [ordered]@{
                    Index = $entry.Mark.Index
                    X = $entry.Mark.X
                    Y = $entry.Mark.Y
                    Scale = (Get-MarkScale $entry.Mark)
                }
                }
                else{
                    $null
                }
            }
        }
    )
}

function Convert-SessionRowsToStepEntries($rows){

    $entries = @()

    foreach($savedRow in @(Convert-SessionValueToList $rows)){
        $savedRect = Get-StatePropertyValue $savedRow "Rect"
        $savedMark = Get-StatePropertyValue $savedRow "Mark"
        $savedPosition = Get-StatePropertyValue $savedRow "Position"
        $savedResult = Get-StatePropertyValue $savedRow "Result"
        $savedRowIndex = Get-StatePropertyValue $savedRow "RowIndex"

        $cells = @(
            [string](Get-StatePropertyValue $savedRow "Step"),
            [string](Get-StatePropertyValue $savedRow "Nominal"),
            [string](Get-StatePropertyValue $savedRow "TolMinus"),
            [string](Get-StatePropertyValue $savedRow "TolPlus"),
            [string]$savedResult,
            "",
            $(if($savedPosition){ [string]$savedPosition } else { "View" }),
            $(Convert-ToStepToolState (Get-StatePropertyValue $savedRow "ToolState")),
            $(Convert-ToStepImportantFlag (Get-StatePropertyValue $savedRow "ImportantStep"))
        )

        $entries += [PSCustomObject]@{
            RowIndex = if($savedRowIndex -ne $null){ [int]$savedRowIndex } else { $entries.Count }
            Cells = $cells
            Rect = if($savedRect){
                New-Object Drawing.Rectangle(
                    [int](Get-StatePropertyValue $savedRect "X"),
                    [int](Get-StatePropertyValue $savedRect "Y"),
                    [int](Get-StatePropertyValue $savedRect "Width"),
                    [int](Get-StatePropertyValue $savedRect "Height")
                )
            }
            else{
                $null
            }
            Mark = if($savedMark){
                [PSCustomObject]@{
                    Index = [int](Get-StatePropertyValue $savedMark "Index")
                    X = [double](Get-StatePropertyValue $savedMark "X")
                    Y = [double](Get-StatePropertyValue $savedMark "Y")
                    Scale = (Normalize-MarkScale (Get-StatePropertyValue $savedMark "Scale"))
                }
            }
            else{
                $null
            }
        }
    }

    return $entries
}

function Convert-UiCopiedMarksToSessionRows($marks){

    return @(
        foreach($mark in @($marks)){
            if(!$mark){ continue }

            [ordered]@{
                Id = $mark.Id
                Index = $mark.Index
                X = $mark.X
                Y = $mark.Y
                Scale = (Get-MarkScale $mark)
                SourceStep = $mark.SourceStep
                SourceRect = if($mark.SourceRect){
                    [ordered]@{
                        X = $mark.SourceRect.X
                        Y = $mark.SourceRect.Y
                        Width = $mark.SourceRect.Width
                        Height = $mark.SourceRect.Height
                    }
                }
                else{
                    $null
                }
            }
        }
    )
}

function Convert-SessionRowsToUiCopiedMarks($rows){

    $marks = @()

    foreach($savedRow in @(Convert-SessionValueToList $rows)){
        $savedRect = Get-StatePropertyValue $savedRow "SourceRect"
        $indexText = [string](Get-StatePropertyValue $savedRow "Index")
        $sourceStep = [string](Get-StatePropertyValue $savedRow "SourceStep")
        $xText = [string](Get-StatePropertyValue $savedRow "X")
        $yText = [string](Get-StatePropertyValue $savedRow "Y")
        $x = 0.0
        $y = 0.0

        if([string]::IsNullOrWhiteSpace($indexText)){ continue }
        if(-not [double]::TryParse($xText,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$x)){ continue }
        if(-not [double]::TryParse($yText,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$y)){ continue }

        $sourceRect = if($savedRect){
            New-Object Drawing.Rectangle(
                [int](Get-StatePropertyValue $savedRect "X"),
                [int](Get-StatePropertyValue $savedRect "Y"),
                [int](Get-StatePropertyValue $savedRect "Width"),
                [int](Get-StatePropertyValue $savedRect "Height")
            )
        }
        else{
            $null
        }

        if(
            [Math]::Abs($x) -lt 0.0001 -and
            [Math]::Abs($y) -lt 0.0001 -and
            [string]::IsNullOrWhiteSpace($sourceStep) -and
            !$sourceRect
        ){
            continue
        }

        $marks += [PSCustomObject]@{
            Id = [int](Get-StatePropertyValue $savedRow "Id")
            Index = $indexText
            X = $x
            Y = $y
            Scale = (Normalize-MarkScale (Get-StatePropertyValue $savedRow "Scale"))
            SourceStep = $sourceStep
            SourceRect = $sourceRect
        }
    }

    return $marks
}

function Convert-RectsToSessionRows($rects){
    return @(
        foreach($rect in @($rects)){
            if(!$rect){ continue }
            [ordered]@{
                X = [int]$rect.X
                Y = [int]$rect.Y
                Width = [int]$rect.Width
                Height = [int]$rect.Height
            }
        }
    )
}

function Convert-SessionRowsToRects($rows){
    $rects = @()
    foreach($savedRect in @(Convert-SessionValueToList $rows)){
        if(!$savedRect){ continue }
        $rects += New-Object Drawing.Rectangle(
            [int](Get-StatePropertyValue $savedRect "X"),
            [int](Get-StatePropertyValue $savedRect "Y"),
            [int](Get-StatePropertyValue $savedRect "Width"),
            [int](Get-StatePropertyValue $savedRect "Height")
        )
    }
    return $rects
}

function Convert-RectangleToSessionObject($rect){
    if(!$rect){ return $null }
    return [ordered]@{
        X = [int]$rect.X
        Y = [int]$rect.Y
        Width = [int]$rect.Width
        Height = [int]$rect.Height
    }
}

function Convert-SessionObjectToRectangle($savedRect){
    if(!$savedRect){ return $null }
    return (New-Object Drawing.Rectangle(
        [int](Get-StatePropertyValue $savedRect "X"),
        [int](Get-StatePropertyValue $savedRect "Y"),
        [int](Get-StatePropertyValue $savedRect "Width"),
        [int](Get-StatePropertyValue $savedRect "Height")
    ))
}

function Convert-HighlightStrokesToSessionRows($strokes){
    return @(
        foreach($stroke in @($strokes)){
            if(!$stroke){ continue }
            [ordered]@{
                Width = if($stroke.PSObject.Properties.Name -contains "Width"){ [double]$stroke.Width } else { [double]$script:HighlightStrokeBaseWidth }
                Points = @(
                    foreach($point in @($stroke.Points)){
                        if(!$point){ continue }
                        [ordered]@{
                            X = [double]$point.X
                            Y = [double]$point.Y
                        }
                    }
                )
            }
        }
    )
}

function Convert-SessionRowsToHighlightStrokes($rows){
    $strokes = @()
    foreach($savedStroke in @(Convert-SessionValueToList $rows)){
        if(!$savedStroke){ continue }
        $points = @()
        foreach($savedPoint in @(Convert-SessionValueToList (Get-StatePropertyValue $savedStroke "Points"))){
            if(!$savedPoint){ continue }
            $points += (New-Object Drawing.PointF(
                [float](Get-StatePropertyValue $savedPoint "X"),
                [float](Get-StatePropertyValue $savedPoint "Y")
            ))
        }
        if(@($points).Count -le 0){ continue }
        $strokes += [PSCustomObject]@{
            Width = [double](Get-StatePropertyValue $savedStroke "Width")
            Points = @($points)
        }
    }
    return $strokes
}

function Convert-TextZoneToleranceToSessionObject($tolerance){
    if(!$tolerance){ return $null }
    return [ordered]@{
        Detected = [bool](Get-StatePropertyValue $tolerance "Detected")
        TolMinus = [double](Get-StatePropertyValue $tolerance "TolMinus")
        TolPlus = [double](Get-StatePropertyValue $tolerance "TolPlus")
        NormalizedText = [string](Get-StatePropertyValue $tolerance "NormalizedText")
        ParseMode = [string](Get-StatePropertyValue $tolerance "ParseMode")
    }
}

function Convert-SessionObjectToTextZoneTolerance($savedTolerance){
    if(!$savedTolerance){ return $null }
    return [PSCustomObject]@{
        Detected = [bool](Get-StatePropertyValue $savedTolerance "Detected")
        TolMinus = [double](Get-StatePropertyValue $savedTolerance "TolMinus")
        TolPlus = [double](Get-StatePropertyValue $savedTolerance "TolPlus")
        NormalizedText = [string](Get-StatePropertyValue $savedTolerance "NormalizedText")
        ParseMode = [string](Get-StatePropertyValue $savedTolerance "ParseMode")
    }
}

function Convert-TextZonesToSessionRows($zones){
    return @(
        foreach($zone in @($zones)){
            if(!$zone){ continue }
            [ordered]@{
                Text = [string]$zone.Text
                RawText = if($zone.PSObject.Properties.Name -contains "RawText"){ [string]$zone.RawText } else { "" }
                Nominal = if($zone.PSObject.Properties.Name -contains "Nominal"){ [string]$zone.Nominal } else { "" }
                Rect = Convert-RectangleToSessionObject $zone.Rect
                OriginalRect = if($zone.PSObject.Properties.Name -contains "OriginalRect"){ Convert-RectangleToSessionObject $zone.OriginalRect } else { $null }
                ReadRect = if($zone.PSObject.Properties.Name -contains "ReadRect"){ Convert-RectangleToSessionObject $zone.ReadRect } else { $null }
                IsDimension = [bool]$zone.IsDimension
                ResolvedAngle = if($zone.PSObject.Properties.Name -contains "ResolvedAngle"){ [int]$zone.ResolvedAngle } else { 0 }
                Orientation = if($zone.PSObject.Properties.Name -contains "Orientation"){ [string]$zone.Orientation } else { "" }
                StableScore = if($zone.PSObject.Properties.Name -contains "StableScore"){ [double]$zone.StableScore } else { 0.0 }
                Source = if($zone.PSObject.Properties.Name -contains "Source"){ [string]$zone.Source } else { "" }
                OriginalZoneSource = if($zone.PSObject.Properties.Name -contains "OriginalZoneSource"){ [string]$zone.OriginalZoneSource } else { "" }
                MarkStepIndex = if($zone.PSObject.Properties.Name -contains "MarkStepIndex"){ [int]$zone.MarkStepIndex } else { -1 }
                RowIndex = if($zone.PSObject.Properties.Name -contains "RowIndex"){ [int]$zone.RowIndex } else { -1 }
                HiddenSuggestAccepted = if($zone.PSObject.Properties.Name -contains "HiddenSuggestAccepted"){ [bool]$zone.HiddenSuggestAccepted } else { $false }
                DuplicateLinkDeclined = if($zone.PSObject.Properties.Name -contains "DuplicateLinkDeclined"){ [bool]$zone.DuplicateLinkDeclined } else { $false }
                ClusterCount = if($zone.PSObject.Properties.Name -contains "ClusterCount"){ [int]$zone.ClusterCount } else { 0 }
                Tolerance = if($zone.PSObject.Properties.Name -contains "Tolerance"){ Convert-TextZoneToleranceToSessionObject $zone.Tolerance } else { $null }
            }
        }
    )
}

function Convert-SessionRowsToTextZones($rows){
    $zones = @()
    foreach($savedZone in @(Convert-SessionValueToList $rows)){
        if(!$savedZone){ continue }
        $zoneRect = Convert-SessionObjectToRectangle (Get-StatePropertyValue $savedZone "Rect")
        if(!$zoneRect){ continue }
        $zone = [PSCustomObject]@{
            Text = [string](Get-StatePropertyValue $savedZone "Text")
            RawText = [string](Get-StatePropertyValue $savedZone "RawText")
            Nominal = [string](Get-StatePropertyValue $savedZone "Nominal")
            Rect = $zoneRect
            OriginalRect = Convert-SessionObjectToRectangle (Get-StatePropertyValue $savedZone "OriginalRect")
            ReadRect = Convert-SessionObjectToRectangle (Get-StatePropertyValue $savedZone "ReadRect")
            IsDimension = [bool](Get-StatePropertyValue $savedZone "IsDimension")
            ResolvedAngle = [int](Get-StatePropertyValue $savedZone "ResolvedAngle")
            Orientation = [string](Get-StatePropertyValue $savedZone "Orientation")
            StableScore = [double](Get-StatePropertyValue $savedZone "StableScore")
            Source = [string](Get-StatePropertyValue $savedZone "Source")
            OriginalZoneSource = [string](Get-StatePropertyValue $savedZone "OriginalZoneSource")
            MarkStepIndex = [int](Get-StatePropertyValue $savedZone "MarkStepIndex")
            RowIndex = [int](Get-StatePropertyValue $savedZone "RowIndex")
            HiddenSuggestAccepted = [bool](Get-StatePropertyValue $savedZone "HiddenSuggestAccepted")
            DuplicateLinkDeclined = [bool](Get-StatePropertyValue $savedZone "DuplicateLinkDeclined")
            ClusterCount = [int](Get-StatePropertyValue $savedZone "ClusterCount")
            Tolerance = Convert-SessionObjectToTextZoneTolerance (Get-StatePropertyValue $savedZone "Tolerance")
        }
        $zones += $zone
    }
    return $zones
}

function Get-CurrentSessionState{

    Save-CurrentPageState

    $sourceFingerprint = $null
    if($script:CurrentSessionFilePath){
        $sourceFingerprint = Get-SessionFingerprintFromPath $script:CurrentSessionFilePath
    }
    if([string]::IsNullOrWhiteSpace($sourceFingerprint)){
        $sourceFingerprint = Get-SourceFingerprint $script:CurrentSourcePath
    }

    return [ordered]@{
        SourcePath = $script:CurrentSourcePath
        SourceFingerprint = $sourceFingerprint
        ExcelTemplate = $script:ExcelTemplate
        JobName = $script:JobName
        JobFolder = $script:JobFolder
        PartNo = $script:PartNo
        MoldName = $script:MoldName
        PartQuantity = $script:PartQuantity
        PartMaterial = $script:PartMaterial
        PartHrc = $script:PartHrc
        PartUser = $script:PartUser
        BalloonColorPreset = $script:BalloonColorPreset
        MeasurementResults = @(
            foreach($stepKey in @($script:MeasurementResults.Keys)){
                $measurement = $script:MeasurementResults[$stepKey]
                if(!$measurement){ continue }
                [ordered]@{
                    Step = [string]$stepKey
                    Actual = [string]$measurement.Actual
                    Result = [string]$measurement.Result
                    UpdatedAt = $measurement.UpdatedAt
                }
            }
        )
        JudgeOkAutoFillEnabled = [bool]$script:JudgeOkAutoFillEnabled
        InspectionSampleAutoFillEnabled = [bool]$script:InspectionSampleAutoFillEnabled
        SelectedPageIndex = $script:SelectedPageIndex
        ViewState = [ordered]@{
            Zoom = $script:zoom
            PanX = $script:panX
            PanY = $script:panY
            FitMode = $script:FitMode
        }
        DefaultTolerance = [ordered]@{
            Tol0 = $txtTol0.Text
            Tol1 = $txtTol1.Text
            Tol2 = $txtTol2.Text
            Tol3 = $txtTol3.Text
        }
        ToleranceMode = if($rbPM.Checked){ "PM" } elseif($rbPlus.Checked){ "PLUS" } elseif($rbMinus.Checked){ "MINUS" } elseif($rbPP.Checked){ "PP" } elseif($rbMM.Checked){ "MM" } else { "PM" }
        DocumentPages = @(
            foreach($page in @($script:DocumentPages)){
                [ordered]@{
                    DisplayName = $page.DisplayName
                    PageNumber = $page.PageNumber
                    RotationDegrees = Get-NormalizedRotationDegrees (Get-StatePropertyValue $page "RotationDegrees")
                    Rows = Convert-StepEntriesToSessionRows $page.Entries
                    DeletedRows = Convert-StepEntriesToSessionRows $page.DeletedEntries
                    UiCopiedMarks = Convert-UiCopiedMarksToSessionRows $page.UiCopiedMarks
                    HighlightStrokes = Convert-HighlightStrokesToSessionRows $page.HighlightStrokes
                    DuplicateDeclinedRects = Convert-RectsToSessionRows $page.DuplicateDeclinedRects
                    SuppressedTextZoneRects = Convert-RectsToSessionRows $page.SuppressedTextZoneRects
                    TextZoneCacheKey = if($page.PSObject.Properties.Name -contains "TextZoneCacheKey"){ $page.TextZoneCacheKey } else { $null }
                    PdfTextLayerZones = if($page.PSObject.Properties.Name -contains "PdfTextLayerZones"){ Convert-TextZonesToSessionRows $page.PdfTextLayerZones } else { @() }
                }
            }
        )
        Marks = @(
            foreach($m in $script:marks){
                if(!$m){ continue }
                [ordered]@{
                    Index = $m.Index
                    X = $m.X
                    Y = $m.Y
                    Scale = (Get-MarkScale $m)
                }
            }
        )
        Rows = @(
            for($i=0; $i -lt $table.Rows.Count; $i++){
                $rect = $null
                if($script:StepRects.ContainsKey($i)){
                    $rect = $script:StepRects[$i]
                }

                [ordered]@{
                    Step = $table.Rows[$i].Cells[0].Value
                    Nominal = $table.Rows[$i].Cells[1].Value
                    TolMinus = $table.Rows[$i].Cells[2].Value
                    TolPlus = $table.Rows[$i].Cells[3].Value
                    Result = $table.Rows[$i].Cells[4].Value
                    ToolState = Convert-ToStepToolState $table.Rows[$i].Cells[7].Value
                    ImportantStep = Convert-ToStepImportantFlag $table.Rows[$i].Cells[8].Value
                    Position = $table.Rows[$i].Cells[6].Value
                    Rect = if($rect){
                        [ordered]@{
                            X = $rect.X
                            Y = $rect.Y
                            Width = $rect.Width
                            Height = $rect.Height
                        }
                    }
                    else{
                        $null
                    }
                }
            }
        )
    }
}

function Apply-SessionStateObject($state){

    if(!$state){ return }

    $script:IsRestoringState = $true

    try{
        $stateExcelTemplate = Get-StatePropertyValue $state "ExcelTemplate"
        if($stateExcelTemplate -and (Test-Path $stateExcelTemplate)){
            $script:ExcelTemplate = [string]$stateExcelTemplate
        }

        $stateJobName = [string](Get-StatePropertyValue $state "JobName")
        if(-not [string]::IsNullOrWhiteSpace($stateJobName)){ $script:JobName = $stateJobName }
        $stateJobFolder = [string](Get-StatePropertyValue $state "JobFolder")
        if(-not [string]::IsNullOrWhiteSpace($stateJobFolder)){ $script:JobFolder = $stateJobFolder }
        $statePartNo = [string](Get-StatePropertyValue $state "PartNo")
        if(-not [string]::IsNullOrWhiteSpace($statePartNo)){ $script:PartNo = $statePartNo }
        $stateMoldName = [string](Get-StatePropertyValue $state "MoldName")
        if(-not [string]::IsNullOrWhiteSpace($stateMoldName)){ $script:MoldName = $stateMoldName }
        $statePartQuantity = [string](Get-StatePropertyValue $state "PartQuantity")
        if(-not [string]::IsNullOrWhiteSpace($statePartQuantity)){ $script:PartQuantity = $statePartQuantity }
        $statePartMaterial = [string](Get-StatePropertyValue $state "PartMaterial")
        if($statePartMaterial -ne $null){ $script:PartMaterial = $statePartMaterial }
        $statePartHrc = [string](Get-StatePropertyValue $state "PartHrc")
        if($statePartHrc -ne $null){ $script:PartHrc = $statePartHrc }
        $statePartUser = [string](Get-StatePropertyValue $state "PartUser")
        if(-not [string]::IsNullOrWhiteSpace($statePartUser)){ $script:PartUser = $statePartUser }
        $stateBalloonColorPreset = [string](Get-StatePropertyValue $state "BalloonColorPreset")
        if(-not [string]::IsNullOrWhiteSpace($stateBalloonColorPreset)){
            $script:BalloonColorPreset = $stateBalloonColorPreset
        }
        Update-BalloonColorMenuState
        $script:MeasurementResults = @{}
        $stateMeasurementResults = Get-StatePropertyValue $state "MeasurementResults"
        foreach($measurement in @(Convert-SessionValueToList $stateMeasurementResults)){
            $step = [string](Get-StatePropertyValue $measurement "Step")
            if([string]::IsNullOrWhiteSpace($step)){ continue }
            $script:MeasurementResults[$step] = [PSCustomObject]@{
                Actual = [string](Get-StatePropertyValue $measurement "Actual")
                Result = [string](Get-StatePropertyValue $measurement "Result")
                UpdatedAt = Get-StatePropertyValue $measurement "UpdatedAt"
            }
        }
        $script:JudgeOkAutoFillEnabled = Convert-ToStepImportantFlag (Get-StatePropertyValue $state "JudgeOkAutoFillEnabled")
        $sampleAutoFillState = Get-StatePropertyValue $state "InspectionSampleAutoFillEnabled"
        if($null -eq $sampleAutoFillState -or [string]::IsNullOrWhiteSpace([string]$sampleAutoFillState)){
            $script:InspectionSampleAutoFillEnabled = $true
        }
        else{
            $script:InspectionSampleAutoFillEnabled = Convert-ToStepImportantFlag $sampleAutoFillState
        }
        Update-JudgeOkMenuItem

        $stateDefaultTolerance = Get-StatePropertyValue $state "DefaultTolerance"
        if($stateDefaultTolerance){
            if((Get-StatePropertyValue $stateDefaultTolerance "Tol0") -ne $null){ $txtTol0.Text = [string](Get-StatePropertyValue $stateDefaultTolerance "Tol0") }
            if((Get-StatePropertyValue $stateDefaultTolerance "Tol1") -ne $null){ $txtTol1.Text = [string](Get-StatePropertyValue $stateDefaultTolerance "Tol1") }
            if((Get-StatePropertyValue $stateDefaultTolerance "Tol2") -ne $null){ $txtTol2.Text = [string](Get-StatePropertyValue $stateDefaultTolerance "Tol2") }
            if((Get-StatePropertyValue $stateDefaultTolerance "Tol3") -ne $null){ $txtTol3.Text = [string](Get-StatePropertyValue $stateDefaultTolerance "Tol3") }
        }

        switch([string](Get-StatePropertyValue $state "ToleranceMode")){
            "PLUS" { $rbPlus.Checked = $true }
            "MINUS" { $rbMinus.Checked = $true }
            "PP" { $rbPP.Checked = $true }
            "MM" { $rbMM.Checked = $true }
            default { $rbPM.Checked = $true }
        }

        $table.Rows.Clear()
        $script:StepRects = @{}
        $script:marks = @()
        $script:DeletedSteps = @()
        $script:DuplicateStepMap = @{}
        $script:SelectedDuplicateSteps = @{}
        $script:SelectedDuplicateAnchorStep = $null

        $stateDocumentPages = Get-StatePropertyValue $state "DocumentPages"
        if($stateDocumentPages -and $script:DocumentPages.Count -gt 0){
            $normalizedDocumentPages = @(Convert-SessionValueToList $stateDocumentPages)
            $maxCount = [Math]::Min($normalizedDocumentPages.Count,$script:DocumentPages.Count)

            for($pageIndex = 0; $pageIndex -lt $maxCount; $pageIndex++){
                $savedPage = $normalizedDocumentPages[$pageIndex]
                $script:DocumentPages[$pageIndex].Entries = @(Convert-SessionRowsToStepEntries (Get-StatePropertyValue $savedPage "Rows"))
                $script:DocumentPages[$pageIndex].DeletedEntries = @(Convert-SessionRowsToStepEntries (Get-StatePropertyValue $savedPage "DeletedRows"))
                $script:DocumentPages[$pageIndex].UiCopiedMarks = @(Convert-SessionRowsToUiCopiedMarks (Get-StatePropertyValue $savedPage "UiCopiedMarks"))
                $script:DocumentPages[$pageIndex].HighlightStrokes = @(Convert-SessionRowsToHighlightStrokes (Get-StatePropertyValue $savedPage "HighlightStrokes"))
                $script:DocumentPages[$pageIndex].DuplicateDeclinedRects = @(Convert-SessionRowsToRects (Get-StatePropertyValue $savedPage "DuplicateDeclinedRects"))
                $script:DocumentPages[$pageIndex].SuppressedTextZoneRects = @(Convert-SessionRowsToRects (Get-StatePropertyValue $savedPage "SuppressedTextZoneRects"))
                $script:DocumentPages[$pageIndex].TextZoneCacheKey = Get-StatePropertyValue $savedPage "TextZoneCacheKey"
                $script:DocumentPages[$pageIndex].PdfTextLayerZones = @(Convert-SessionRowsToTextZones (Get-StatePropertyValue $savedPage "PdfTextLayerZones"))
            }
        }
        elseif($script:DocumentPages.Count -gt 0){
            $stateRows = Get-StatePropertyValue $state "Rows"
            if($stateRows){
                $script:DocumentPages[0].Entries = @(Convert-SessionRowsToStepEntries $stateRows)
            }
            $script:DocumentPages[0].UiCopiedMarks = @()
            $script:DocumentPages[0].HighlightStrokes = @()

            $stateMarks = Get-StatePropertyValue $state "Marks"
            if($stateMarks){
                $usedIndexes = @{}
                $fallbackIndex = 0

                foreach($savedMark in @(Convert-SessionValueToList $stateMarks)){
                    $targetIndex = -1
                    $savedStep = [int](Get-StatePropertyValue $savedMark "Index")

                    if($savedStep -gt 0){
                        for($entryIndex = 0; $entryIndex -lt $script:DocumentPages[0].Entries.Count; $entryIndex++){
                            if($usedIndexes.ContainsKey($entryIndex)){ continue }

                            $entryStep = 0
                            $entryStepText = [string]$script:DocumentPages[0].Entries[$entryIndex].Cells[0]
                            if([int]::TryParse($entryStepText,[ref]$entryStep) -and $entryStep -eq $savedStep){
                                $targetIndex = $entryIndex
                                break
                            }
                        }
                    }

                    if($targetIndex -lt 0){
                        while($fallbackIndex -lt $script:DocumentPages[0].Entries.Count -and $usedIndexes.ContainsKey($fallbackIndex)){
                            $fallbackIndex++
                        }

                        if($fallbackIndex -ge $script:DocumentPages[0].Entries.Count){
                            break
                        }

                        $targetIndex = $fallbackIndex
                    }

                    $script:DocumentPages[0].Entries[$targetIndex].Mark = [PSCustomObject]@{
                        Index = [int](Get-StatePropertyValue $savedMark "Index")
                        X = [double](Get-StatePropertyValue $savedMark "X")
                        Y = [double](Get-StatePropertyValue $savedMark "Y")
                        Scale = (Normalize-MarkScale (Get-StatePropertyValue $savedMark "Scale"))
                    }

                    $usedIndexes[$targetIndex] = $true
                }
            }
        }

        $selectedPageIndex = [int](Get-StatePropertyValue $state "SelectedPageIndex")
        if($script:DocumentPages.Count -gt 0){
            $safePageIndex = [Math]::Max(0,[Math]::Min($selectedPageIndex,($script:DocumentPages.Count - 1)))
            $script:SelectedPageIndex = $safePageIndex
            if($pageList.Items.Count -gt $safePageIndex){
                $pageList.SelectedIndex = $safePageIndex
            }

            $page = $script:DocumentPages[$safePageIndex]
            $script:sourceBitmap = $page.Bitmap
            $script:CurrentSourcePath = $page.SourcePath
            Restore-PageTextZoneCache $page
            Apply-PageState $page
            Update-PageNavigationUi
            Validate-StepState
        }
        else{
            Apply-PageState $null
            Update-PageNavigationUi
        }

        $viewState = Get-StatePropertyValue $state "ViewState"
        if($viewState -and $script:sourceBitmap){
            $stateFitMode = [string](Get-StatePropertyValue $viewState "FitMode")

            switch($stateFitMode){
                "FitScreen" { Set-ViewMode "FitScreen" }
                "FitWidth" { Set-ViewMode "FitWidth" }
                "Actual" { Set-ViewMode "Actual" }
                default {
                    $script:zoom = Clamp-ZoomValue ([double](Get-StatePropertyValue $viewState "Zoom"))
                    $script:panX = [double](Get-StatePropertyValue $viewState "PanX")
                    $script:panY = [double](Get-StatePropertyValue $viewState "PanY")
                    $script:FitMode = if([string]::IsNullOrWhiteSpace($stateFitMode)){ "Custom" } else { $stateFitMode }
                    Clamp-Pan
                    Update-ZoomStatus
                    Request-CanvasRedraw
                }
            }
        }
        else{
            Sync-ViewToViewport
        }
    }
    finally{
        $script:IsRestoringState = $false
    }
}

function Restore-SourceSessionState($sourcePath){

    $sessionFilePath = Find-MatchingSessionFile $sourcePath
    if(!$sessionFilePath -or !(Test-Path $sessionFilePath)){ return }
    $script:CurrentSessionFilePath = $sessionFilePath

    $state = Import-SessionStateFromClixmlXml $sessionFilePath
    if(!$state){
        $state = Import-ClixmlSafe $sessionFilePath
    }
    if(!$state){ return }

    Apply-SessionStateObject $state
}

function Load-CurrentSessionToUi{

    $sessionFilePath = $null
    if(-not [string]::IsNullOrWhiteSpace($script:CurrentSourcePath) -and (Test-Path $script:CurrentSourcePath)){
        $sessionFilePath = Find-MatchingSessionFile $script:CurrentSourcePath
    }
    elseif($script:CurrentSessionFilePath -and (Test-Path $script:CurrentSessionFilePath)){
        $sessionFilePath = $script:CurrentSessionFilePath
    }

    if(!$sessionFilePath -or !(Test-Path $sessionFilePath)){
        [System.Windows.Forms.MessageBox]::Show("No saved session was found.")
        return
    }

    $state = Import-SessionStateFromClixmlXml $sessionFilePath
    if(!$state){
        $state = Import-ClixmlSafe $sessionFilePath
    }
    if(!$state){
        [System.Windows.Forms.MessageBox]::Show("The saved session file could not be loaded.")
        return
    }

    $script:CurrentSessionFilePath = $sessionFilePath
    if(
        ([string]::IsNullOrWhiteSpace($script:CurrentSourcePath) -or !(Test-Path $script:CurrentSourcePath)) -and
        (Restore-SessionFromCacheState $state $sessionFilePath)
    ){
        return
    }

    Apply-SessionStateObject $state
    Validate-StepState
    Refresh-DuplicateState
    Update-CanvasCursor
    Request-CanvasRedraw
}

function Show-RenderCacheFolderOpenDialog($initialDirectory){

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Open Render Cache Folder"
    $dialog.Filter = "Render Cache Folder|*.folder"
    $dialog.CheckFileExists = $false
    $dialog.CheckPathExists = $true
    $dialog.ValidateNames = $false
    $dialog.FileName = "Select this folder"
    $dialog.RestoreDirectory = $true

    if(-not [string]::IsNullOrWhiteSpace($initialDirectory) -and (Test-Path $initialDirectory)){
        $dialog.InitialDirectory = $initialDirectory
    }

    if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){
        return $null
    }

    $selectedPath = $dialog.FileName
    if([string]::IsNullOrWhiteSpace($selectedPath)){
        return $null
    }

    if(Test-Path $selectedPath -PathType Container){
        return $selectedPath
    }

    $parentPath = [System.IO.Path]::GetDirectoryName($selectedPath)
    if(-not [string]::IsNullOrWhiteSpace($parentPath) -and (Test-Path $parentPath -PathType Container)){
        return $parentPath
    }

    return $null
}

function Open-SessionEditor{

    if(!(Test-Path $script:RenderCacheRoot)){
        [System.Windows.Forms.MessageBox]::Show("No render cache folders with saved step data were found.")
        return
    }

    $hasAnyCache = @(
        Get-ChildItem -Path $script:RenderCacheRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '__backup$' }
    ).Count -gt 0
    if(-not $hasAnyCache){
        [System.Windows.Forms.MessageBox]::Show("No render cache folders with saved step data were found.")
        return
    }

    $selectedFolder = Show-RenderCacheFolderOpenDialog $script:RenderCacheRoot
    if([string]::IsNullOrWhiteSpace($selectedFolder)){
        return
    }

    if(-not (Test-Path $selectedFolder -PathType Container) -or $selectedFolder -notmatch '__backup$'){
        [System.Windows.Forms.MessageBox]::Show("The selected folder is not a valid render cache with saved step data.")
        return
    }

    $cacheDir = $selectedFolder
    $pagePaths = @(
        Get-ChildItem -Path $cacheDir -Filter "page-*.jpg" -File -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -ExpandProperty FullName
    )
    if($pagePaths.Count -le 0){
        [System.Windows.Forms.MessageBox]::Show("The selected folder is not a valid render cache with saved step data.")
        return
    }

    $fingerprint = Get-CacheFingerprintFromPath $cacheDir
    if([string]::IsNullOrWhiteSpace($fingerprint)){
        [System.Windows.Forms.MessageBox]::Show("The selected folder does not contain a valid fingerprint.")
        return
    }

    $sessionFilePath = Ensure-CanonicalSessionFileForCacheFolder $cacheDir
    if([string]::IsNullOrWhiteSpace($sessionFilePath)){
        $sessionFilePath = Find-SessionFileByCacheFolderName $cacheDir
    }
    if([string]::IsNullOrWhiteSpace($sessionFilePath)){
        $sessionFilePath = Find-BestSessionFileByFingerprint $fingerprint
    }
    if([string]::IsNullOrWhiteSpace($sessionFilePath) -or !(Test-Path $sessionFilePath)){
        [System.Windows.Forms.MessageBox]::Show("No saved step data was found for this render cache.")
        return
    }
    $state = Import-SessionStateFromClixmlXml $sessionFilePath
    if(!$state){
        $state = Import-ClixmlSafe $sessionFilePath
    }
    if(!$state){
        [System.Windows.Forms.MessageBox]::Show("The saved session file could not be loaded.")
        return
    }
    $sessionFingerprint = Get-SessionFingerprintFromPath $sessionFilePath
    if(-not [string]::IsNullOrWhiteSpace($sessionFingerprint)){
        Set-StatePropertyValue $state "SourceFingerprint" $sessionFingerprint
    }
    $stateMetadata = Get-DrawingMetadataFromState $state
    $qtyDefault = if(-not [string]::IsNullOrWhiteSpace([string]$stateMetadata.Quantity)){ [string]$stateMetadata.Quantity } else { [string]$script:PartQuantity }
    $updatedQty = Request-QuantityUpdate $qtyDefault "Edit Steps QTY Update" "QTY update bằng bao nhiêu?"
    if([string]::IsNullOrWhiteSpace([string]$updatedQty)){
        return
    }
    Set-StatePropertyValue $state "PartQuantity" ([string]$updatedQty)
    $selectedImagePaths = @($pagePaths)

    if(-not (Restore-SessionFromSelectedCacheImages $state $sessionFilePath $selectedImagePaths)){
        [System.Windows.Forms.MessageBox]::Show("Render cache was not found for this session.")
        return
    }

    $selectedImagePath = $selectedImagePaths[0]
    $selectedImageName = [System.IO.Path]::GetFileNameWithoutExtension($selectedImagePath)
    $targetPageIndex = -1
    if($selectedImageName -match 'page-(\d+)$'){
        $targetPageIndex = [int]$matches[1] - 1
    }
    if($targetPageIndex -ge 0 -and $targetPageIndex -lt $script:DocumentPages.Count){
        Show-PageByIndex $targetPageIndex
    }

    $script:PartQuantity = [string]$updatedQty
    Save-SessionState
}

function Save-SessionState{

    if($script:IsRestoringState -or $script:IsLoadingSource){ return }

    if(!(Test-Path $script:SessionStoreDir)){
        New-Item -Path $script:SessionStoreDir -ItemType Directory -Force | Out-Null
    }

    $appState = [ordered]@{
        LastSourcePath = $script:CurrentSourcePath
        LastSessionFilePath = $script:CurrentSessionFilePath
        AdaptiveDetectorStats = $script:AdaptiveDetectorStats
        TrainingSaveExportEnabled = [bool]$script:TrainingSaveExportEnabled
    }

    [void](Export-ClixmlSafe $script:AppStateFilePath $appState)

    $sessionFilePath = $null
    if($script:CurrentSessionFilePath -and (Test-Path (Split-Path -Parent $script:CurrentSessionFilePath))){
        $sessionFilePath = $script:CurrentSessionFilePath
    }
    elseif(-not [string]::IsNullOrWhiteSpace($script:CurrentSourcePath)){
        $sessionFilePath = Get-SessionFilePath $script:CurrentSourcePath
    }
    if(!$sessionFilePath){ return }
    $script:CurrentSessionFilePath = $sessionFilePath
    $legacyPrimarySessionFilePath = if(-not [string]::IsNullOrWhiteSpace($script:CurrentSourcePath)){ Get-LegacyPrimarySessionFilePath $script:CurrentSourcePath } else { $null }

    $state = Get-CurrentSessionState
    $currentEntryCount = Get-SessionEntryCount $state
    $existingState = Import-ClixmlSafe $sessionFilePath
    $existingEntryCount = Get-SessionEntryCount $existingState

    if($currentEntryCount -le 0 -and $existingEntryCount -gt 0){
        return
    }

    [void](Export-ClixmlSafe $sessionFilePath $state)
    if($legacyPrimarySessionFilePath -and (Test-Path $legacyPrimarySessionFilePath)){
        Remove-Item -Path $legacyPrimarySessionFilePath -Force -ErrorAction SilentlyContinue
    }
    Invoke-CacheCleanup
}

function Restore-SessionState{
    Invoke-CacheCleanup

    $appState = $null
    if(Test-Path $script:AppStateFilePath){
        $appState = Import-ClixmlSafe $script:AppStateFilePath
    }

    $stateTrainingSaveExportEnabled = Get-StatePropertyValue $appState "TrainingSaveExportEnabled"
    if($null -ne $stateTrainingSaveExportEnabled -and -not [string]::IsNullOrWhiteSpace([string]$stateTrainingSaveExportEnabled)){
        $script:TrainingSaveExportEnabled = Convert-ToStepImportantFlag $stateTrainingSaveExportEnabled
    }
    Update-TrainingSaveExportMenuState

    $script:AdaptiveDetectorStats = @{}
    $stateAdaptiveDetectorStats = Get-StatePropertyValue $appState "AdaptiveDetectorStats"
    if($stateAdaptiveDetectorStats){
        foreach($key in @($stateAdaptiveDetectorStats.Keys)){
            $value = $stateAdaptiveDetectorStats[$key]
            if(!$value){ continue }
            $script:AdaptiveDetectorStats[[string]$key] = [PSCustomObject]@{
                Accept = [int](Get-StatePropertyValue $value "Accept")
                Link = [int](Get-StatePropertyValue $value "Link")
                KeepNew = [int](Get-StatePropertyValue $value "KeepNew")
                Decline = [int](Get-StatePropertyValue $value "Decline")
            }
        }
    }

    return
}

function Clear-InspectionSheet($sheet,$rowStart,$maxPerPage){

    $lastRow = $rowStart + $maxPerPage - 1
    $sheet.Range([string]("A{0}:O{1}" -f [int]$rowStart,[int]$lastRow)).ClearContents()
}

function Set-InspectionHeader($sheet,$model,$mold,$qty = "",$material = "",$hrc = "",$user = ""){

    $sheet.Range("C5").Value2 = [string]$model
    $sheet.Range("G5").Value2 = [string]$mold
    $sheet.Range("C6").Value2 = [string]$material
    $sheet.Range("G6").Value2 = [string]$hrc
    if(-not [string]::IsNullOrWhiteSpace([string]$qty)){
        try{
            $sheet.Range("N6").Value2 = [string]$qty
        }
        catch{}
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$user)){
        try{
            $sheet.Range("C58").Value2 = [string]$user
        }
        catch{}
    }
    $dateCell = $sheet.Range("N4")
    $dateCell.NumberFormat = "@"
    $dateCell.Value2 = (Get-Date).ToString("dd-MMM-yyyy",[System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-InspectionBatchLabel($sampleStart,$sampleEnd){
    return "Sample $sampleStart-$sampleEnd"
}

function Get-InspectionSheetName($startIndex,$endIndex){
    return "Inspection $startIndex-$endIndex"
}

function Set-ExcelCellTextValue($sheet,$row,$column,$value){
    $sheet.Cells.Item([int]$row,[int]$column).Value2 = [string]$value
}

function Set-ExcelCellBold($sheet,$row,$column,$isBold){
    try{
        $sheet.Cells.Item([int]$row,[int]$column).Font.Bold = [bool]$isBold
    }
    catch{}
}

function Try-QueueBackgroundTrainingFlush{
    if(-not $script:TrainingSaveExportEnabled){
        if($txtOcrDebug){
            $txtOcrDebug.Text = "Training save/export is off. Background training save skipped."
        }
        return $false
    }

    try{
        Queue-DeferredTrainingDatasetFlush
        return $true
    }
    catch{
        if($txtOcrDebug){
            $txtOcrDebug.Text = "Background training queue skipped: $($_.Exception.Message)"
        }
        return $false
    }
}

function Set-InspectionSampleHeaders($sheet,$sampleStart,$sampleEnd){
    $sampleColumns = @(Get-InspectionSampleColumnNumbers)
    $sampleCount = [Math]::Min($sampleColumns.Count,[Math]::Max(0,([int]$sampleEnd - [int]$sampleStart + 1)))

    for($i = 0; $i -lt $sampleColumns.Count; $i++){
        $targetColumn = [int]$sampleColumns[$i]
        if($i -lt $sampleCount){
            Set-ExcelCellTextValue $sheet 12 $targetColumn ([string]([int]$sampleStart + $i))
        }
        else{
            Set-ExcelCellTextValue $sheet 12 $targetColumn ""
        }
    }
}

function Get-InspectionSampleColumnNumbers{
    return @(6..15)
}

function Get-InspectionTotalSampleCount($qtyText){

    $qtyValue = Get-QuantityFirstInteger $qtyText
    if($qtyValue -eq $null){ return 1 }
    return [Math]::Max(1,[int]$qtyValue)
}

function Get-InspectionSampleBatches($qtyText){

    $totalSamples = Get-InspectionTotalSampleCount $qtyText
    $batches = @()
    $start = 1
    while($start -le $totalSamples){
        $end = [Math]::Min(($start + 9),$totalSamples)
        $batches += [PSCustomObject]@{
            Start = [int]$start
            End = [int]$end
        }
        $start = $end + 1
    }

    return @($batches)
}

function Should-ExportMeasurementForSample($rowData,$absoluteSampleIndex){
    if(-not $script:InspectionSampleAutoFillEnabled){ return $false }
    if(Test-StepToolIgnored $rowData.ToolState){ return $false }
    if([int]$absoluteSampleIndex -le 1){ return $true }
    return (Convert-ToStepImportantFlag $rowData.ImportantStep)
}

function Get-ExportJobInfo{
    $metadataState = $null
    if(-not [string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){
        $metadataState = Get-CurrentSessionState
    }
    if(-not $metadataState){
        $metadataState = [ordered]@{
            PartNo = $script:PartNo
            MoldName = $script:MoldName
            PartQuantity = $script:PartQuantity
            PartMaterial = $script:PartMaterial
            PartHrc = $script:PartHrc
            PartUser = $script:PartUser
            JobName = $script:JobName
        }
    }

    $metadata = Show-DrawingMetadataDialog $script:CurrentSourcePath $metadataState
    if(!$metadata){ return $null }
    $script:PartNo = $metadata.PartNo
    $script:MoldName = $metadata.MoldName
    $script:PartQuantity = $metadata.Quantity
    $script:PartMaterial = $metadata.Material
    $script:PartHrc = $metadata.Hrc
    $script:PartUser = $metadata.User
    $script:JobName = $metadata.JobName

    $folderDialog = New-Object Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Choose output folder"
    $folderDialog.ShowNewFolderButton = $true

    if($script:JobFolder -and (Test-Path $script:JobFolder)){
        $folderDialog.SelectedPath = $script:JobFolder
    }
    elseif($script:CurrentSourcePath){
        $sourceDir = [System.IO.Path]::GetDirectoryName($script:CurrentSourcePath)
        if($sourceDir -and (Test-Path $sourceDir)){ $folderDialog.SelectedPath = $sourceDir }
    }

    if($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK){ return $null }

    $jobName = Get-SafeWindowsPathComponent (Get-PreferredExportJobName) "InspectionJob"
    if([string]::IsNullOrWhiteSpace($jobName)){ return $null }

    $jobFolder = Join-Path $folderDialog.SelectedPath $jobName
    if(!(Test-Path $jobFolder)){ New-Item -ItemType Directory -Path $jobFolder -Force | Out-Null }

    $script:JobName = $jobName
    $script:JobFolder = $jobFolder
    return @{ JobName = $jobName; JobFolder = $jobFolder }
}

function Get-ExcelSaveInfo($requestedPath,$templatePath){

    $templateExt = [System.IO.Path]::GetExtension($templatePath).ToLower()
    $requestedExt = [System.IO.Path]::GetExtension($requestedPath).ToLower()

    if($templateExt -eq ".xlsb" -or $requestedExt -eq ".xlsb"){
        return @{
            Path = [System.IO.Path]::ChangeExtension($requestedPath,"xlsb")
            Format = 50
        }
    }

    if($templateExt -in @(".xlsm",".xltm")){
        return @{
            Path = [System.IO.Path]::ChangeExtension($requestedPath,"xlsm")
            Format = 52
        }
    }

    if($requestedExt -eq ".xls"){
        return @{
            Path = [System.IO.Path]::ChangeExtension($requestedPath,"xls")
            Format = 56
        }
    }

    if($requestedExt -eq ".xlsm"){
        return @{
            Path = [System.IO.Path]::ChangeExtension($requestedPath,"xlsm")
            Format = 52
        }
    }

    return @{
        Path = [System.IO.Path]::ChangeExtension($requestedPath,"xlsx")
        Format = 51
    }
}


# =========================
# IMAGE RECT CONVERSION
# =========================

function Get-ViewportSize{

    $canvas = $script:CanvasControl

    if($canvas -and $canvas.ClientSize.Width -gt 0 -and $canvas.ClientSize.Height -gt 0){
        return $canvas.ClientSize
    }

    return New-Object Drawing.Size(1,1)
}

function Get-FitToScreenZoom{

    if(!$script:sourceBitmap){ return 1.0 }

    $viewport = Get-ViewportSize
    if($viewport.Width -le 0 -or $viewport.Height -le 0){ return 1.0 }

    return [Math]::Min(
        $viewport.Width / [double]$script:sourceBitmap.Width,
        $viewport.Height / [double]$script:sourceBitmap.Height
    )
}

function Get-FitToWidthZoom{

    if(!$script:sourceBitmap){ return 1.0 }

    $viewport = Get-ViewportSize
    if($viewport.Width -le 0){ return 1.0 }

    return $viewport.Width / [double]$script:sourceBitmap.Width
}

function Get-MinZoom{

    if(!$script:sourceBitmap){ return 0.1 }

    # Keep fit-to-screen as the practical floor, while still allowing 100% for small images.
    return [Math]::Min((Get-FitToScreenZoom),1.0)
}

function Clamp-ZoomValue($zoomValue){

    $minZoom = Get-MinZoom
    $maxZoom = [Math]::Max($script:maxZoom,$minZoom)

    if($zoomValue -lt $minZoom){ return $minZoom }
    if($zoomValue -gt $maxZoom){ return $maxZoom }

    return $zoomValue
}

function Clamp-Pan{

    if(!$script:sourceBitmap){ return }

    $viewport = Get-ViewportSize
    $scaledWidth = $script:sourceBitmap.Width * $script:zoom
    $scaledHeight = $script:sourceBitmap.Height * $script:zoom

    if($scaledWidth -le $viewport.Width){
        $script:panX = ($viewport.Width - $scaledWidth) / 2.0
    }
    else{
        $minPanX = $viewport.Width - $scaledWidth
        if($script:panX -lt $minPanX){ $script:panX = $minPanX }
        if($script:panX -gt 0){ $script:panX = 0 }
    }

    if($scaledHeight -le $viewport.Height){
        $script:panY = ($viewport.Height - $scaledHeight) / 2.0
    }
    else{
        $minPanY = $viewport.Height - $scaledHeight
        if($script:panY -lt $minPanY){ $script:panY = $minPanY }
        if($script:panY -gt 0){ $script:panY = 0 }
    }
}

function Update-ZoomStatus{
    return
}

function Request-CanvasRedraw{

    $canvas = $script:CanvasControl
    if($canvas){
        $canvas.Invalidate()
    }
}

function Set-InteractiveCanvasMode([bool]$isInteractive){

    $script:IsInteractiveCanvasUpdate = $isInteractive
}

function Queue-ViewStateSave{
    if($script:ViewStateSaveTimer){
        $script:ViewStateSaveTimer.Stop()
        $script:ViewStateSaveTimer.Start()
    }
}

function Queue-SessionStateSave{
    if($script:SessionStateSaveTimer){
        $script:SessionStateSaveTimer.Stop()
        $script:SessionStateSaveTimer.Start()
        return
    }

    Save-SessionState
}

function Queue-ImportantStepSave{
    if($script:ImportantStepSaveTimer){
        $script:ImportantStepSaveTimer.Stop()
        $script:ImportantStepSaveTimer.Start()
        return
    }

    Queue-SessionStateSave
}

function Queue-AcceptSuggestionPostUpdate{
    if($script:AcceptSuggestionPostUpdateTimer){
        $script:AcceptSuggestionPostUpdateTimer.Stop()
        $script:AcceptSuggestionPostUpdateTimer.Start()
        return
    }

    Save-CurrentPageState
    Queue-SessionStateSave
    Refresh-DuplicateState
    if($txtTableSearch -and -not [string]::IsNullOrWhiteSpace(([string]$txtTableSearch.Text).Trim())){
        Apply-TableSearchFilter
    }
}

function Begin-TransientInteractiveRender{
    Set-InteractiveCanvasMode $true
    if($script:InteractiveRenderResetTimer){
        $script:InteractiveRenderResetTimer.Stop()
        $script:InteractiveRenderResetTimer.Start()
    }
}

function Clear-PreviewImage{

    $script:PendingPreviewRect = $null
    $script:LastPreviewRect = $null

    if($script:PreviewUpdateTimer){
        $script:PreviewUpdateTimer.Stop()
    }

    if($preview -and $preview.Image){
        $preview.Image.Dispose()
        $preview.Image = $null
    }
}

function Set-ControlCursor($control,$cursor){

    if(!$control){ return }

    try{
        $control.set_Cursor($cursor)
    }
    catch{
        try{
            $control.Cursor = $cursor
        }
        catch{}
    }
}

function Update-CanvasCursor{

    $canvas = $script:CanvasControl

    if($script:isPanning -or $script:isSpacePressed){
        Set-ControlCursor $canvas ([System.Windows.Forms.Cursors]::Hand)
    }
    elseif($script:AnnotationToolMode -eq "Eraser" -and $script:sourceBitmap){
        Set-ControlCursor $canvas ([System.Windows.Forms.Cursors]::No)
    }
    elseif($script:sourceBitmap){
        Set-ControlCursor $canvas ([System.Windows.Forms.Cursors]::Cross)
    }
    else{
        Set-ControlCursor $canvas ([System.Windows.Forms.Cursors]::Default)
    }
}

function Convert-ScreenPointToImagePoint($point){

    if(!$script:sourceBitmap){
        return New-Object Drawing.PointF(0,0)
    }

    return New-Object Drawing.PointF(
        [float](($point.X - $script:panX) / [Math]::Max($script:zoom,0.0001)),
        [float](($point.Y - $script:panY) / [Math]::Max($script:zoom,0.0001))
    )
}

function Convert-ImagePointToScreenPoint($x,$y){
    return New-Object Drawing.PointF(
        [float](($x * $script:zoom) + $script:panX),
        [float](($y * $script:zoom) + $script:panY)
    )
}

function Get-HighlightStrokeDistanceSquared($stroke,$point){
    if(!$stroke -or !$point){ return [double]::PositiveInfinity }
    $best = [double]::PositiveInfinity
    foreach($strokePoint in @($stroke.Points)){
        if(!$strokePoint){ continue }
        $dx = ([double]$strokePoint.X - [double]$point.X)
        $dy = ([double]$strokePoint.Y - [double]$point.Y)
        $dist = ($dx * $dx) + ($dy * $dy)
        if($dist -lt $best){ $best = $dist }
    }
    return $best
}

function Remove-HighlightStrokeAtPoint($imagePoint){
    if(!$imagePoint){ return $false }
    if(@($script:HighlightStrokes).Count -le 0){ return $false }
    $threshold = [double]([Math]::Max(6.0,$script:EraserRadius) * [Math]::Max(6.0,$script:EraserRadius))
    $remaining = @()
    $removed = $false
    foreach($stroke in @($script:HighlightStrokes)){
        if(!$removed -and (Get-HighlightStrokeDistanceSquared $stroke $imagePoint) -le $threshold){
            $removed = $true
            continue
        }
        $remaining += $stroke
    }
    if($removed){
        $script:HighlightStrokes = @($remaining)
    }
    return $removed
}

function Add-HighlightStrokePoint($imagePoint){
    if(!$script:CurrentHighlightStroke -or !$imagePoint){ return }
    $points = @($script:CurrentHighlightStroke.Points)
    if($points.Count -gt 0){
        $lastPoint = $points[-1]
        if($lastPoint){
            $dx = [Math]::Abs([double]$lastPoint.X - [double]$imagePoint.X)
            $dy = [Math]::Abs([double]$lastPoint.Y - [double]$imagePoint.Y)
            if($dx -lt 1.0 -and $dy -lt 1.0){ return }
        }
    }
    $script:CurrentHighlightStroke.Points += (New-Object Drawing.PointF([float]$imagePoint.X,[float]$imagePoint.Y))
}

function Draw-HighlightStrokes($graphics){
    if(!$graphics){ return }
    foreach($stroke in @($script:HighlightStrokes)){
        if(!$stroke){ continue }
        $points = @($stroke.Points)
        if($points.Count -le 0){ continue }
        $strokeWidth = [float][Math]::Max(4.0,[double]$stroke.Width)
        $pen = $null
        $brush = $null
        try{
            $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(118,255,235,59),$strokeWidth)
            $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
            $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
            if($points.Count -eq 1){
                $radius = [float]($strokeWidth / 2.0)
                $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(118,255,235,59))
                $graphics.FillEllipse($brush,[float]($points[0].X - $radius),[float]($points[0].Y - $radius),[float]$strokeWidth,[float]$strokeWidth)
            }
            else{
                $graphics.DrawLines($pen,[Drawing.PointF[]]$points)
            }
        }
        finally{
            if($pen){ $pen.Dispose() }
            if($brush){ $brush.Dispose() }
        }
    }
}

function Clamp-ImagePointToBitmap($point){

    if(!$script:sourceBitmap -or !$point){
        return $point
    }

    return New-Object Drawing.PointF(
        [float][Math]::Max(0,[Math]::Min($script:sourceBitmap.Width,[double]$point.X)),
        [float][Math]::Max(0,[Math]::Min($script:sourceBitmap.Height,[double]$point.Y))
    )
}

function Set-LastImageMousePointFromCanvasPoint($canvasPoint){

    if(!$script:sourceBitmap -or !$canvasPoint){ return $null }

    $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $canvasPoint)
    $script:LastImageMousePoint = $imagePoint
    return $imagePoint
}

function Get-CurrentCrosshairImagePoint{

    if(!$script:sourceBitmap){ return $null }

    $canvas = $script:CanvasControl
    if($canvas){
        try{
            $clientPoint = $canvas.PointToClient([System.Windows.Forms.Cursor]::Position)
            if($clientPoint.X -ge 0 -and $clientPoint.Y -ge 0 -and $clientPoint.X -lt $canvas.ClientSize.Width -and $clientPoint.Y -lt $canvas.ClientSize.Height){
                return (Set-LastImageMousePointFromCanvasPoint $clientPoint)
            }
        }
        catch{}
    }

    if($script:LastImageMousePoint){
        return (Clamp-ImagePointToBitmap $script:LastImageMousePoint)
    }

    return $null
}

function Get-NormalizedSelectionRect($startPoint,$endPoint){

    $safeStartPoint = Clamp-ImagePointToBitmap $startPoint
    $safeEndPoint = Clamp-ImagePointToBitmap $endPoint

    $x = [Math]::Min($safeStartPoint.X,$safeEndPoint.X)
    $y = [Math]::Min($safeStartPoint.Y,$safeEndPoint.Y)
    $width = [Math]::Abs($safeStartPoint.X - $safeEndPoint.X)
    $height = [Math]::Abs($safeStartPoint.Y - $safeEndPoint.Y)

    return New-Object Drawing.RectangleF(
        [float]$x,
        [float]$y,
        [float]$width,
        [float]$height
    )
}

function Convert-ToImageRect($rect){

    if(!$rect){ return $null }

    $x = [Math]::Floor([Math]::Min($rect.X,($rect.X + $rect.Width)))
    $y = [Math]::Floor([Math]::Min($rect.Y,($rect.Y + $rect.Height)))
    $right = [Math]::Ceiling([Math]::Max($rect.X,($rect.X + $rect.Width)))
    $bottom = [Math]::Ceiling([Math]::Max($rect.Y,($rect.Y + $rect.Height)))

    if($script:sourceBitmap){
        $x = [Math]::Max(0,$x)
        $y = [Math]::Max(0,$y)
        $right = [Math]::Min($script:sourceBitmap.Width,$right)
        $bottom = [Math]::Min($script:sourceBitmap.Height,$bottom)
    }

    return New-Object Drawing.Rectangle(
        [int]$x,
        [int]$y,
        [int][Math]::Max(0,($right - $x)),
        [int][Math]::Max(0,($bottom - $y))
    )
}

function Test-SelectionLargeEnough($selectionRect){

    if(!$selectionRect){ return $false }

    return (
        (($selectionRect.Width * $script:zoom) -gt 8) -and
        (($selectionRect.Height * $script:zoom) -gt 8)
    )
}

function Set-PendingPreviewRect($selectionRect){

    if(!$selectionRect){
        $script:PendingPreviewRect = $null
        return
    }

    $script:PendingPreviewRect = New-Object Drawing.RectangleF(
        [float]$selectionRect.X,
        [float]$selectionRect.Y,
        [float]$selectionRect.Width,
        [float]$selectionRect.Height
    )
}

function Set-ZoomAtPoint($targetZoom,$screenPoint,[string]$fitMode = "Custom"){

    if(!$script:sourceBitmap){ return }

    $clampedZoom = Clamp-ZoomValue $targetZoom
    if([Math]::Abs($clampedZoom - $script:zoom) -lt 0.0001){
        Update-ZoomStatus
        return
    }

    $imagePoint = Convert-ScreenPointToImagePoint $screenPoint

    # Keep the image-space point under the cursor fixed while zoom changes.
    $script:zoom = $clampedZoom
    $script:panX = $screenPoint.X - ($imagePoint.X * $script:zoom)
    $script:panY = $screenPoint.Y - ($imagePoint.Y * $script:zoom)
    $script:FitMode = $fitMode

    Clamp-Pan
    Update-ZoomStatus
    Request-CanvasRedraw
}

function Set-ViewMode($mode){

    if(!$script:sourceBitmap){ return }

    $viewport = Get-ViewportSize

    switch($mode){
        "FitScreen" {
            $script:zoom = Clamp-ZoomValue (Get-FitToScreenZoom)
            $script:panX = ($viewport.Width - ($script:sourceBitmap.Width * $script:zoom)) / 2.0
            $script:panY = ($viewport.Height - ($script:sourceBitmap.Height * $script:zoom)) / 2.0
        }
        "FitWidth" {
            $script:zoom = Clamp-ZoomValue (Get-FitToWidthZoom)
            $script:panX = ($viewport.Width - ($script:sourceBitmap.Width * $script:zoom)) / 2.0
            $scaledHeight = $script:sourceBitmap.Height * $script:zoom
            if($scaledHeight -le $viewport.Height){
                $script:panY = ($viewport.Height - $scaledHeight) / 2.0
            }
            else{
                $script:panY = 0
            }
        }
        "Actual" {
            $centerPoint = New-Object Drawing.PointF(($viewport.Width / 2.0),($viewport.Height / 2.0))
            Set-ZoomAtPoint 1.0 $centerPoint "Actual"
            return
        }
        default {
            return
        }
    }

    $script:FitMode = $mode
    Clamp-Pan
    Update-ZoomStatus
    Request-CanvasRedraw
}

function Sync-ViewToViewport{

    if(!$script:sourceBitmap){
        Update-ZoomStatus
        return
    }

    switch($script:FitMode){
        "FitScreen" { Set-ViewMode "FitScreen" }
        "FitWidth" { Set-ViewMode "FitWidth" }
        "Actual" {
            $script:zoom = Clamp-ZoomValue 1.0
            Clamp-Pan
            Update-ZoomStatus
            Request-CanvasRedraw
        }
        default {
            $script:zoom = Clamp-ZoomValue $script:zoom
            Clamp-Pan
            Update-ZoomStatus
            Request-CanvasRedraw
        }
    }
}

function Scroll-Viewer($deltaX,$deltaY){

    if(!$script:sourceBitmap){ return }

    $script:panX += $deltaX
    $script:panY += $deltaY

    Clamp-Pan
    Request-CanvasRedraw
}

function Update-PreviewFromSelectionRect($selectionRect){

    if(!$script:sourceBitmap -or !$selectionRect){ return }

    $realRect = Convert-ToImageRect $selectionRect
    if(!$realRect -or $realRect.Width -le 2 -or $realRect.Height -le 2){ return }

    if(
        $script:LastPreviewRect -and
        $script:LastPreviewRect.X -eq $realRect.X -and
        $script:LastPreviewRect.Y -eq $realRect.Y -and
        $script:LastPreviewRect.Width -eq $realRect.Width -and
        $script:LastPreviewRect.Height -eq $realRect.Height
    ){
        return
    }

    $crop = $null
    $big = $null
    $g = $null

    try{
        $crop = $script:sourceBitmap.Clone($realRect,$script:sourceBitmap.PixelFormat)
        $zoomFactor = 6
        $big = New-Object Drawing.Bitmap ([Math]::Max(1,$crop.Width * $zoomFactor)),([Math]::Max(1,$crop.Height * $zoomFactor))
        $g = [Drawing.Graphics]::FromImage($big)
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = "HighQualityBicubic"
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.DrawImage($crop,0,0,$big.Width,$big.Height)

        if($preview.Image){
            $preview.Image.Dispose()
        }

        $preview.Image = $big
        $big = $null
        $script:LastPreviewRect = $realRect
    }
    finally{
        if($g){ $g.Dispose() }
        if($crop){ $crop.Dispose() }
        if($big){ $big.Dispose() }
    }
}

function Update-PreviewFromSelection{
    Update-PreviewFromSelectionRect $script:selectionRect
}

function Request-SelectionPreviewRefresh{

    if(!$script:sourceBitmap -or !(Test-SelectionLargeEnough $script:selectionRect)){
        return
    }

    Set-PendingPreviewRect $script:selectionRect
    $script:PreviewUpdateTimer.Stop()
    $script:PreviewUpdateTimer.Start()
}

function Try-ParseAngleDmsText($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return $null }
    $degree = [string][char]176
    $value = ([string]$text).Trim()
    $value = $value -replace ',', '.'
    $value = $value -replace '(?i)DEG',$degree
    $value = $value -replace ([string][char]186),$degree
    $value = $value -replace "[′’`´]","'"
    $value = $value -replace '[″“”]','"'
    $compact = ($value -replace '\s+','')
    # Parentheses around reference angle, e.g. (0.352°), are wrappers only.
    # OCR may also miss one side of the wrapper, so strip them before angle parse.
    $compact = $compact -replace '[\(\)\[\]]',''

    if($compact -match ("^(?<deg>[-+]?\d+(?:\.\d+)?)" + [regex]::Escape($degree) + "$")){
        return [PSCustomObject]@{ Text = ([string]$Matches['deg'] + $degree); Degrees = [string]$Matches['deg']; Minutes = ''; Seconds = '' }
    }

    if($compact -match ("^(?<deg>[-+]?\d+(?:\.\d+)?)" + [regex]::Escape($degree) + "(?<min>\d{1,2})'(?<sec>\d{1,2}(?:\.\d+)?)\""$")){
        $degText = [string]$Matches['deg']
        $minText = [string]$Matches['min']
        $secText = [string]$Matches['sec']
        $txt = ('{0}{1}{2}{3}{4}"' -f $degText,$degree,$minText,([string][char]39),$secText)
        return [PSCustomObject]@{ Text = $txt; Degrees = $degText; Minutes = $minText; Seconds = $secText }
    }

    if($compact -match ("^(?<deg>[-+]?\d+(?:\.\d+)?)" + [regex]::Escape($degree) + "(?<min>\d{1,2})'$")){
        $degText = [string]$Matches['deg']
        $minText = [string]$Matches['min']
        $txt = ('{0}{1}{2}{3}' -f $degText,$degree,$minText,([string][char]39))
        return [PSCustomObject]@{ Text = $txt; Degrees = $degText; Minutes = $minText; Seconds = '' }
    }

    if($compact -match ("^(?<deg>[-+]?\d+)" + [regex]::Escape($degree) + "(?<rest>\d{2,4}).*$")){
        $rest = [string]$Matches['rest']
        if($rest.Length -ge 4){
            $txt = ('{0}{1}{2}{3}{4}{5}' -f $Matches['deg'],$degree,$rest.Substring(0,2),([string][char]39),$rest.Substring(2,2),([string][char]34))
            return [PSCustomObject]@{ Text = $txt; Degrees = [string]$Matches['deg']; Minutes = $rest.Substring(0,2); Seconds = $rest.Substring(2,2) }
        }
        if($rest.Length -ge 2){
            $txt = ('{0}{1}{2}{3}' -f $Matches['deg'],$degree,$rest.Substring(0,2),([string][char]39))
            return [PSCustomObject]@{ Text = $txt; Degrees = [string]$Matches['deg']; Minutes = $rest.Substring(0,2); Seconds = '' }
        }
    }

    return $null
}

function Normalize-MechanicalOcrText($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return "" }
    $value = ([string]$text).ToUpperInvariant()
    $value = $value -replace ',', '.'
    $value = $value -replace '：', ':'
    $value = $value -replace ':', '.'
    # Mechanical OCR often returns chamfer/radius prefixes like CO.100 / RO.5
    # where O is actually zero. Repair this before filtering non-mechanical text.
    $value = [regex]::Replace($value,'(?<![A-Z0-9])([CR])\s*O(?=\s*(?:\.\s*\d|\d))', '${1}0')
    # OCR pattern in stacked tolerance: +0.005 may come back as +8:885/+8.885
    # or +8.8885 / +8.8882 where leading 8 means zero and the extra 8s mean
    # missing zeros before the final tolerance digit.
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8\.88(?<d>[1-9])(?!\d)', '${sign}0.00${d}')
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8\.8{3,}(?<d>[1-9])(?!\d)', '${sign}0.00${d}')
    $value = $value -replace 'º','°'
    $value = $value -replace 'Ø','Ø'
    $value = $value -replace '[^0-9\.\+\-±RCØ°º\(\)\s]', ' '
    $value = [regex]::Replace($value,'(?<=\d)\s*\.\s*(?=\d)', '.')
    $value = [regex]::Replace($value,'(?<![A-Z0-9])[+\-]\s*([CR])(?=\s*(?:0|\.\d|\d))', '$1')
    $value = [regex]::Replace($value,'(?<![A-Z0-9])([CR])\s*\.\s*(\d)', '${1}0.$2')

    # Leading zero repair for tiny stacked tolerances misread as 8.xxx.
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8(?<frac>\.0{1,3}\d{1,3})', '${sign}0${frac}')
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8\.88(?<d>[1-9])(?!\d)', '${sign}0.00${d}')
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8\.8{3,}(?<d>[1-9])(?!\d)', '${sign}0.00${d}')

    # Do NOT keep garbage like +8.885. Mechanical tolerance text should only
    # contain signs followed by plausible small tolerance values.
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8(?:\.\d+|\d{2,})(?!\d)', ' ')

    # Remove any signed tolerance whose magnitude is outside our practical preset domain.
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*(?<num>\d+\.\d+|\.\d+|\d+)', {
        param($m)
        $numText = [string]$m.Groups['num'].Value
        $num = 0.0
        if([double]::TryParse($numText,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$num)){
            if([Math]::Abs($num) -gt 0.5){ return ' ' }
        }
        return $m.Value
    })

    $value = $value -replace '\s+',' '
    return $value.Trim()
}

function Test-UsefulMechanicalRawText($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return $false }

    $source = ([string]$text).ToUpperInvariant()
    $normalized = Normalize-MechanicalOcrText $source
    if([string]::IsNullOrWhiteSpace($normalized)){ return $false }

    $digitCount = ([regex]::Matches($normalized,'\d')).Count
    if($digitCount -le 0){ return $false }

    if($normalized -match '(?:[RCØ]\s*\d|[±+\-]\s*(?:0?\.\d+|0\d{3}|\d+\.\d+)|\d+\.\d+)'){
        return $true
    }

    return $false
}

function Collapse-SpacedMechanicalDimensionText($text){

    $value = [string]$text
    if([string]::IsNullOrWhiteSpace($value)){ return "" }

    $trimmed = $value.Trim()

    # Vertical OCR can emit one glyph per token, e.g. "2 1 . 5 2" or
    # "R 0 . 5". Compact only these simple single-glyph mechanical runs.
    $collapsed = [regex]::Replace(
        $trimmed,
        '(?<!\S)(?:[RCØ]\s+)?(?:[\d\.\+\-°º''"]\s+){2,}[\d\.\+\-°º''"](?=\s|$)',
        {
            param($m)
            return (($m.Value -replace '\s+','').Trim())
        }
    )

    $collapsed = [regex]::Replace($collapsed,'(?<!\S)([RCØ])\s+(?=[\d\.])','$1')
    return ($collapsed -replace '\s+',' ').Trim()
}

function Repair-ManualMechanicalNominalFromRaw($resolved,$rawText,$cleanedText,$rect){

    $value = ([string]$resolved).Trim()
    $normalized = Normalize-MechanicalOcrText $cleanedText
    if([string]::IsNullOrWhiteSpace($normalized) -and (Test-UsefulMechanicalRawText $rawText)){
        $normalized = Normalize-MechanicalOcrText $rawText
    }
    if([string]::IsNullOrWhiteSpace($normalized)){ return $value }

    # If parser accidentally chose tolerance garbage like 885, choose the first
    # decimal before explicit tolerance signs: e.g. 0.5 +0.005 +0.003.
    if($value -match '^\d{3,}$' -or $value -match '^8\d{2,}$'){
        $firstSign = $normalized.Length
        $mSign = [regex]::Match($normalized,'[+\-±]')
        if($mSign.Success){ $firstSign = $mSign.Index }
        $nominalRegion = $normalized.Substring(0,$firstSign)
        $mNom = [regex]::Match($nominalRegion,'(?<!\d)([RCØ]?\d+\.\d+|[RCØ]?\.\d+|[RCØ]?\d+)(?!\d)')
        if($mNom.Success){
            $nom = [string]$mNom.Groups[1].Value
            if($nom -match '^([RCØ]?)\.'){ $nom = $Matches[1] + '0' + $nom.Substring($Matches[1].Length) }
            return $nom
        }
    }

    return $value
}

function Parse-Dimension($text){

    if(!$text){ return "" }

    $text = [string]$text
    $text = $text.Trim()
    $text = $text -replace ',', '.'
    $text = $text -replace '•','.'
    $text = $text -replace '·','.'
    $text = $text -replace 'ą','±'
    $text = $text -replace 'Ą','±'
    $text = $text.ToUpperInvariant()
    $text = Collapse-SpacedMechanicalDimensionText $text
    $text = [regex]::Replace($text,'(?<=\d)\s*\.\s*(?=\d)','.')

    $angleDms = Try-ParseAngleDmsText $text
    if($angleDms){ return [string]$angleDms.Text }

    # ===== COMMON OCR ERRORS =====
    $text = $text -replace 'O','0'
    $text = $text -replace 'L','1'
    $text = $text -replace 'I','1'
    $text = $text -replace 'M','00'
    $text = [regex]::Replace($text,'(?<=\d)\s*\.\s*(?=\d)','.')
    $text = $text -replace 'S','5'
    $text = $text -replace 'B','8'

    # If the crop starts with a plausible nominal and then contains signed
    # tolerance text/noise (including broken OCR like "-0 00 ... -0002"),
    # prefer the leading nominal immediately.
    $leadingNominalWithTolerance = [regex]::Match(
        $text,
        '^\s*(?<nom>[RC]?(?:\d+\.\d+|\.\d+|\d+))(?=\s*[+\-±])'
    )
    if($leadingNominalWithTolerance.Success){
        $leadingNominal = [string]$leadingNominalWithTolerance.Groups['nom'].Value
        if(-not [string]::IsNullOrWhiteSpace($leadingNominal) -and $leadingNominal -notmatch '^(?:0+|0*\.0+)$'){
            if($leadingNominal -match '^\.(\d+)$'){ $leadingNominal = '0.' + $Matches[1] }
            return $leadingNominal
        }
    }

    # Chamfer/radius notes can include Japanese marker text before C/R.
    # Prefer C0.2/R0.2 over unrelated nearby text.
    if($text -match '(?i)(?:^|[^A-Z0-9])([CR])\s*([0-9]+(?:\.[0-9]+)?|\.[0-9]+)'){
        $prefix = ([string]$Matches[1]).ToUpperInvariant()
        $num = [string]$Matches[2]
        if($num -match '^\.'){ $num = '0' + $num }
        return ($prefix + $num)
    }

    if($text -match '(?i)(?:^|[^0-9.])\d+\s*[X×]\s*((?:[RC])?\d*\.\d+)\s*(?:D\s*P)?\b'){
        return (($matches[1] -replace '\s+','').ToUpperInvariant())
    }

    $toleranceStart = $text.Length
    $toleranceMatch = [regex]::Match($text,'[±]|(?<!^)[+\-]\s*(?:0?\.\d+|0\d{3}|\d+\.\d+)')
    if($toleranceMatch.Success){
        $toleranceStart = $toleranceMatch.Index
    }
    $nominalRegion = $text.Substring(0,$toleranceStart)
    $nominalRegion = [regex]::Replace($nominalRegion,'(?i)(?:^|[^0-9.])\d+\s*[X×]\s*',' ')
    $nominalRegion = [regex]::Replace($nominalRegion,'(?<=\d)\s*\.\s*(?=\d)','.')
    $nominalRegion = $nominalRegion -replace '[^0-9\.\+\-\±RC\s]',' '
    $nominalRegion = $nominalRegion -replace '\s+',' '
    $nominalRegion = $nominalRegion.Trim()
    if(-not [string]::IsNullOrWhiteSpace($nominalRegion)){
        $nominalMatches = @([regex]::Matches($nominalRegion,'(?<![0-9\.])([RC]?(?:\d+\.\d+|\d+|\.\d+))(?![0-9\.])'))
        if($nominalMatches.Count -gt 0){
            $bestNominal = $null
            $bestScore = [double]::NegativeInfinity
            foreach($match in $nominalMatches){
                $token = [string]$match.Groups[1].Value
                if([string]::IsNullOrWhiteSpace($token)){ continue }
                if($token -match '^(?:0+|0*\.0+)$'){ continue }

                $score = [double]$match.Index
                if($token -match '^[RC]'){ $score += 18 }
                if($token -match '\d+\.\d+'){ $score += 14 }
                if($token -match '^0?\.\d+$'){ $score -= 12 }

                if($score -gt $bestScore){
                    $bestScore = $score
                    $bestNominal = $token
                }
            }

            if(-not [string]::IsNullOrWhiteSpace($bestNominal)){
                if($bestNominal -match '^\.(\d+)$'){ $bestNominal = '0.' + $matches[1] }
                return $bestNominal
            }
        }
    }

    # Keep whitespace long enough to avoid merging nominal with stacked tolerance.
    $spacedText = $text -replace '[^0-9\.\+\-\±RC\s]',' '
    $spacedText = $spacedText -replace '\s+',' '
    $spacedText = $spacedText.Trim()
    $spacedText = [regex]::Replace($spacedText,'(^|\s)\.(\d+)','${1}0.$2')

    # Stacked OCR often returns tolerance first, then nominal on the next line,
    # e.g. "±0.005 0.83". In that case, skip the leading signed tolerance token
    # and recover the later nominal instead of incorrectly taking 0.005.
    $leadingTolerance = [regex]::Match($spacedText,'^\s*[±+\-]\s*(?:0?\.\d+|0\d{3}|\d+\.\d+)(?:\s+|$)')
    if($leadingTolerance.Success){
        $remainingNominalRegion = $spacedText.Substring($leadingTolerance.Length).Trim()
        if(-not [string]::IsNullOrWhiteSpace($remainingNominalRegion)){
            $remainingNominalMatches = @([regex]::Matches($remainingNominalRegion,'(?<![0-9\.])([RC]?(?:\d+\.\d+|\d+|\.\d+))(?![0-9\.])'))
            if($remainingNominalMatches.Count -gt 0){
                $bestRemainingNominal = $null
                $bestRemainingScore = [double]::NegativeInfinity
                foreach($match in $remainingNominalMatches){
                    $token = [string]$match.Groups[1].Value
                    if([string]::IsNullOrWhiteSpace($token)){ continue }
                    if($token -match '^(?:0+|0*\.0+)$'){ continue }

                    $score = [double]$match.Index
                    if($token -match '^[RC]'){ $score += 18 }
                    if($token -match '\d+\.\d+'){ $score += 14 }
                    if($token -match '^0?\.\d+$'){ $score -= 12 }

                    if($score -gt $bestRemainingScore){
                        $bestRemainingScore = $score
                        $bestRemainingNominal = $token
                    }
                }

                if(-not [string]::IsNullOrWhiteSpace($bestRemainingNominal)){
                    if($bestRemainingNominal -match '^\.(\d+)$'){ $bestRemainingNominal = '0.' + $matches[1] }
                    return $bestRemainingNominal
                }
            }
        }
    }

    if($spacedText -match '(?<![0-9\.])([RC]?(?:\d+\.\d+|\d+|\.\d+))(?![0-9\.])'){
        return [string]$matches[1]
    }

    if($spacedText -match '(?<![0-9\.])((?:\d+\.\d+|\d+|\.\d+))(?![0-9\.])'){
        return [string]$matches[1]
    }

    $compactText = $spacedText -replace '\s+',''
    $compactText = $compactText -replace '\.{2,}','.'
    $compactText = $compactText -replace '^\.(\d+)', '0.$1'
    $compactText = $compactText -replace '\.$',''

    if($compactText -match '^([RC]?)[-+]?0\.(\d{3})0{3,}$'){
        return ([string]$matches[1] + '0.' + [string]$matches[2])
    }

    if($compactText -match '[RC][-+]?\d*\.?\d+'){
        return (($matches[0] -replace '^([RC])[-+]','$1'))
    }

    if($compactText -match '[-+]?\d*\.?\d+'){
        return (($matches[0] -replace '^[-+]',''))
    }

    return ""
}

function Normalize-DetectedNominalSign($nominal){
    if([string]::IsNullOrWhiteSpace([string]$nominal)){ return "" }
    $value = ([string]$nominal).Trim()
    if($value -match '^([RC])[-+](.+)$'){
        return ([string]$Matches[1] + [string]$Matches[2])
    }
    return ($value -replace '^[-+]','')
}

function Remove-GrayTextZones{
    if(!$script:PdfTextLayerZones -or @($script:PdfTextLayerZones).Count -le 0){ return 0 }
    $before = @($script:PdfTextLayerZones).Count
    $script:PdfTextLayerZones = @($script:PdfTextLayerZones | Where-Object { $_ -and $_.IsDimension })
    $script:SelectedTextZoneIndex = -1
    Save-CurrentPageTextZoneCache
    Request-CanvasRedraw
    return ($before - @($script:PdfTextLayerZones).Count)
}

function Try-ExtractParenthesizedDimension($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){
        return ""
    }

    $sourceText = [string]$text
    $sourceText = $sourceText.ToUpperInvariant()
    $sourceText = $sourceText -replace ',', '.'
    $sourceText = $sourceText -replace '\s+', ''
    $sourceText = $sourceText -replace 'O', '0'
    $sourceText = $sourceText -replace 'I', '1'
    $sourceText = $sourceText -replace 'L', '1'
    $sourceText = $sourceText -replace 'S', '5'
    $sourceText = $sourceText -replace 'B', '8'

    if($sourceText -match '[\(\[]([-+]?\d*\.?\d+)[°º]?[)\]]'){
        return [string]$matches[1]
    }

    return ""
}

function Repair-VerticalSmallDecimalNominal($nominal,$rawText,$cleanedText){

    $value = ([string]$nominal).Trim()
    if($value -notmatch '^[1-9]$'){ return $value }

    $context = ((([string]$rawText) + " " + ([string]$cleanedText)).ToUpperInvariant() -replace '\s+','')
    if([string]::IsNullOrWhiteSpace($context)){ return $value }

    # Do not infer 4 -> 0.4 merely because a small tolerance exists.
    # Example: "4 -0.005/+0" is a valid integer nominal with one-sided tolerance.
    # Only repair when the OCR context still contains explicit evidence of 0.x.
    $escapedDigit = [regex]::Escape($value)
    if($context -match ("(?<!\d)0\." + $escapedDigit + "(?!\d)")){
        return ('0.' + $value)
    }

    return $value
}


function Resolve-OcrTextAsMechanicalNominal($rawText,$rect = $null,$labelText = ""){

    $raw = [string]$rawText
    if([string]::IsNullOrWhiteSpace($raw) -and -not [string]::IsNullOrWhiteSpace([string]$labelText)){
        $raw = [string]$labelText
    }

    $clean = Clean-OCRText $raw
    $mechanical = Normalize-MechanicalOcrText $raw

    $parsed = Parse-Dimension $mechanical
    if([string]::IsNullOrWhiteSpace($parsed)){ $parsed = Parse-Dimension $clean }
    if([string]::IsNullOrWhiteSpace($parsed) -and -not [string]::IsNullOrWhiteSpace([string]$labelText)){
        $parsed = Parse-Dimension ([string]$labelText)
    }

    $nominal = Resolve-MechanicalDimensionText $mechanical $clean $parsed
    $nominal = Repair-ManualMechanicalNominalFromRaw $nominal $raw $clean $rect
    $nominal = Repair-ManualVerticalMissingDecimalNominal $nominal $raw $clean $rect

    return [PSCustomObject]@{
        Nominal = [string]$nominal
        RawText = $raw
        CleanText = $clean
        MechanicalText = $mechanical
        ParsedText = [string]$parsed
    }
}

function Resolve-MechanicalDimensionText($rawText,$cleanedText,$parsedText){

    foreach($sourceText in @($rawText,$cleanedText,$parsedText)){
        $s = ([string]$sourceText).ToUpperInvariant() -replace ',', '.'
        if($s -match '(?:^|[^A-Z0-9])([CR])\s*([0-9]+(?:\.[0-9]+)?|\.[0-9]+)'){
            $prefix = [string]$Matches[1]
            $num = [string]$Matches[2]
            if($num -match '^\.'){ $num = '0' + $num }
            return ($prefix + $num)
        }
    }

    foreach($sourceText in @($rawText,$cleanedText,$parsedText)){
        $angleDms = Try-ParseAngleDmsText $sourceText
        if($angleDms){ return [string]$angleDms.Text }
    }

    $normalizedRawCompact = (([string]$rawText).ToUpperInvariant() -replace ',', '.' -replace '\s+','')
    $normalizedCleanCompact = (([string]$cleanedText).ToUpperInvariant() -replace ',', '.' -replace '\s+','')
    $normalizedParsed = Normalize-DetectedNominalSign ([string]$parsedText)

    # If OCR split digits with spaces but the cleaned text already reconstructed
    # a stronger decimal (e.g. "5 3.6 4" -> "53.64"), prefer that over a weaker
    # partial parse like "3.6".
    foreach($sourceText in @($normalizedCleanCompact,$normalizedRawCompact)){
        if([string]::IsNullOrWhiteSpace($sourceText)){ continue }
        $allDecimals = @(
            [regex]::Matches($sourceText,'(?<![\d.])\d+\.\d+(?![\d.])') |
            ForEach-Object { [string]$_.Value }
        )
        if($allDecimals.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($normalizedParsed)){
            $singleDecimal = [string]$allDecimals[0]
            if(
                $singleDecimal.Length -gt $normalizedParsed.Length -and
                $singleDecimal -like ("*" + $normalizedParsed + "*") -and
                $normalizedRawCompact -match '\d\s+\d+\.\d+\s+\d'
            ){
                return $singleDecimal
            }
        }
    }

    $candidate = $normalizedParsed
    if([string]::IsNullOrWhiteSpace($candidate)){
        return ""
    }

    $candidate = Repair-VerticalSmallDecimalNominal $candidate $rawText $cleanedText

    foreach($sourceText in @($rawText,$cleanedText)){
        $parenthesizedDimension = Try-ExtractParenthesizedDimension $sourceText
        if(-not [string]::IsNullOrWhiteSpace($parenthesizedDimension)){
            return $parenthesizedDimension
        }
    }

    if($candidate -match '^[RC][-+]?\d*\.?\d+$'){
        return $candidate
    }

    if($candidate -match '^(?<nom>\d+\.\d{4})(?<tol>0\d{2})$'){
        return [string]$Matches['nom']
    }

    $normalizedRaw = [string]$rawText
    $normalizedClean = [string]$cleanedText

    foreach($sourceText in @($normalizedRaw,$normalizedClean)){
        if([string]::IsNullOrWhiteSpace($sourceText)){ continue }

        $sourceText = $sourceText.ToUpperInvariant()
        $sourceText = $sourceText -replace ',', '.'
        $sourceText = $sourceText -replace '\s+', ''
        $sourceText = $sourceText -replace 'O','0'
        $sourceText = $sourceText -replace 'I','1'
        $sourceText = $sourceText -replace 'L','1'
        $sourceText = $sourceText -replace 'S','5'
        $sourceText = $sourceText -replace 'B','8'

        if($sourceText -match '(?<nom>\d+\.\d{4})(?<tol>0\d{2})(?!\d)'){
            return [string]$Matches['nom']
        }

        if($sourceText -match '([RC])[^0-9\+\-]*([-+]?\d*\.?\d+)'){
            $prefix = [string]$matches[1]
            $numberPart = [string]$matches[2]
            if($numberPart -match '^\.(\d+)$'){
                $numberPart = '0.' + $matches[1]
            }
            return (Normalize-DetectedNominalSign ($prefix + $numberPart))
        }
    }

    if($candidate -notmatch '^[-+]?\d*\.?\d+$'){
        return $candidate
    }

    $plainNumber = Normalize-DetectedNominalSign $candidate
    $contextText = (([string]$rawText) + " " + ([string]$cleanedText)).ToUpperInvariant()
    $contextText = $contextText -replace ',', '.'

    if($plainNumber -match '^[0-9]{3}$'){
        $smallToleranceMatches = [regex]::Matches($contextText,'[+\-±]\s*(?:0?\.\d{3,})')
        if($smallToleranceMatches.Count -gt 0){
            $plainNumber = '0.' + $plainNumber
        }
    }

    if($plainNumber -match '^[1-9][0-9]$' -and $contextText -match '[±+\-]\s*0?\.0+\d+'){
        $decimalCandidate = $plainNumber.Substring(0,1) + "." + $plainNumber.Substring(1)
        if($contextText -match ([regex]::Escape($decimalCandidate))){
            $plainNumber = $decimalCandidate
        }
        elseif($contextText -match ($plainNumber.Substring(0,1) + '\s*[.\|:/]?\s*' + $plainNumber.Substring(1))){
            $plainNumber = $decimalCandidate
        }
    }

    $hasChamferPattern =
        ($contextText -match '45\s*[°O]') -or
        ($contextText -match '[X×]\s*45') -or
        ($contextText -match '45\s*[X×]') -or
        ($contextText -match '\bCHAMFER\b')
    if($hasChamferPattern){
        return ("C" + $plainNumber)
    }

    $hasRadiusPattern =
        ($contextText -match '\bRAD\b') -or
        ($contextText -match '\bRADIUS\b') -or
        ($contextText -match '\bFILLET\b')
    if($hasRadiusPattern){
        return ("R" + $plainNumber)
    }

    return (Normalize-DetectedNominalSign $plainNumber)
}
# =========================
# LOAD IMAGE
# =========================
$btnLoad.Add_Click({

    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = "PDF Files (*.pdf)|*.pdf"

    if($dialog.ShowDialog() -eq "OK"){
        try{
            if($txtOcrDebug){
                $txtOcrDebug.Text = (
                    "Loading PDF..." + [Environment]::NewLine +
                    [System.IO.Path]::GetFileName($dialog.FileName)
                )
            }
            Begin-TransientInteractiveRender
            Request-CanvasRedraw
            [System.Windows.Forms.Application]::DoEvents()

            Load-SourceFile $dialog.FileName

            if($txtOcrDebug){
                $txtOcrDebug.Text = "PDF loaded."
            }
        }
        catch{
            [System.Windows.Forms.MessageBox]::Show("Cannot load file: $($_.Exception.Message)")
        }
    }
})

$btnEditStep.Add_Click({
    Open-SessionEditor
})

$btnSortStepAsc.Add_Click({
    Sort-VisibleSteps
})

$btnAdvance.Add_Click({
    Update-AdvancePanelButton
    if($advanceMenu){
        Update-CopyViewButton
        Update-PdfTextZonesButton
        Update-InspectionSampleAutoFillButton
        Update-BalloonColorMenuState
        Update-TrainingSaveExportMenuState
        Update-SidePanelToggleUi
        $advanceMenu.Show($btnAdvance,0,$btnAdvance.Height)
    }
})

if($btnToggleSidePanel){
    $btnToggleSidePanel.Add_Click({ Toggle-DrawSidePanel })
}

$miAdvanceRotatePage = $null
$miAdvanceSampleAutoFill = $null
if($advanceMenu){
    $miAdvanceSampleAutoFill = New-Object System.Windows.Forms.ToolStripMenuItem("Sample Auto Fill On")
    if($miAdvanceOcrMenu){ [void]$miAdvanceOcrMenu.DropDownItems.Add($miAdvanceSampleAutoFill) }
    else{ [void]$advanceMenu.Items.Add($miAdvanceSampleAutoFill) }
    $miAdvanceRotatePage = New-Object System.Windows.Forms.ToolStripMenuItem("Rotate Drawing 90°")
    $miAdvanceRotatePage.ShortcutKeyDisplayString = "Ctrl+Shift+R"
    if($miAdvanceViewMenu){ [void]$miAdvanceViewMenu.DropDownItems.Add($miAdvanceRotatePage) }
    else{ [void]$advanceMenu.Items.Add($miAdvanceRotatePage) }
    $miAdvanceDeleteCurrentSession = New-Object System.Windows.Forms.ToolStripMenuItem("Delete Current Session")
    $miAdvanceDeleteCurrentSession.ForeColor = [System.Drawing.Color]::FromArgb(192,32,32)
    if($miAdvanceDangerMenu){ [void]$miAdvanceDangerMenu.DropDownItems.Add($miAdvanceDeleteCurrentSession) }
    else{
        [void]$advanceMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        [void]$advanceMenu.Items.Add($miAdvanceDeleteCurrentSession)
    }
}

$btnAiUseEnv.Add_Click({
    Invoke-AiVisionRescanSelectedStep
})

$chkAiTestOnly.Add_CheckedChanged({
    $script:AiTestOnlyEnabled = [bool]$chkAiTestOnly.Checked
    if($script:AiTestOnlyEnabled){
        Append-AiVisionLog ("AI test only enabled: " + [string]$cmbAiModel.Text)
    }
    else{
        Append-AiVisionLog "AI test only disabled."
    }
})

$btnAiTest.Add_Click({
    $selectedModel = if($cmbAiModel){ [string]$cmbAiModel.Text } else { "" }
    if($selectedModel.StartsWith("ollama:",[System.StringComparison]::OrdinalIgnoreCase) -and -not $script:AiVisionBusy){
        [void](Warm-OllamaVisionModel $selectedModel)
    }
    Invoke-AiVisionForSelection
})

$btnAiAccept.Add_Click({
    Accept-AiVisionResult
})

$btnAiClear.Add_Click({
    if($txtAiResult){ $txtAiResult.Text = "" }
    Clear-AiVisionResult
})

if($miAdvanceAiModelQwen){
    $miAdvanceAiModelQwen.Add_Click({
        Set-AiVisionModelSelection "ollama:qwen2.5vl:3b"
    })
}

if($miAdvanceAiModelMiniCpm){
    $miAdvanceAiModelMiniCpm.Add_Click({
        Set-AiVisionModelSelection "ollama:minicpm-v"
    })
}

$btnCopyView.Add_Click({
    $script:CopyViewOnly = -not $script:CopyViewOnly
    Update-CopyViewButton
    $picture.Invalidate()
})

$btnAutoMapPdf.Add_Click({
    Invoke-AutoMapPdfTextLayer
})

$btnTranslateLens.Add_Click({
    if($script:TranslateLensEnabled){
        Set-TranslateLensEnabled $false
    }
    else{
        Clear-TranslateLensResult
    }

    [void](Start-WindowTranslator)
})

$btnPdfTextZones.Add_Click({
    $script:ShowPdfTextZones = -not $script:ShowPdfTextZones
    if($script:ShowPdfTextZones){
        if(Test-CurrentPageTextZoneCacheReady){
            Refresh-PdfTextLayerZones
        }
        else{
            if($txtOcrDebug){
                $txtOcrDebug.Text = "Preparing text zones in background..."
            }
            Schedule-DeferredTextZoneWarmup | Out-Null
        }
    }
    else{
        $script:SelectedTextZoneIndex = -1
        $script:IsDraggingTextZone = $false
    }
    Update-PdfTextZonesButton
    Request-CanvasRedraw
})

$btnClearGrayZones.Add_Click({
    $removedCount = Remove-GrayTextZones
    if($txtOcrDebug){
        $txtOcrDebug.Text = "Removed gray boxes: $removedCount"
    }
})

if($miAdvanceTemplate){
    $miAdvanceTemplate.Add_Click({ $btnTemplate.PerformClick() })
}
if($miAdvanceTranslate){
    $miAdvanceTranslate.Add_Click({
        if($script:TranslateLensEnabled){
            Set-TranslateLensEnabled $false
        }
        else{
            Set-TranslateLensEnabled $true
        }
    })
}
if($miAdvanceEditSteps){
    $miAdvanceEditSteps.Add_Click({ $btnEditStep.PerformClick() })
}
if($miAdvanceSortSteps){
    $miAdvanceSortSteps.Add_Click({ $btnSortStepAsc.PerformClick() })
}
if($miAdvanceCopyView){
    $miAdvanceCopyView.Add_Click({ $btnCopyView.PerformClick() })
}
if($miAdvancePdfTextZones){
    $miAdvancePdfTextZones.Add_Click({ $btnPdfTextZones.PerformClick() })
}
if($miAdvanceToggleSidePanel){
    $miAdvanceToggleSidePanel.Add_Click({ Toggle-DrawSidePanel })
}
if($miAdvanceAutoMapPdf){
    $miAdvanceAutoMapPdf.Add_Click({ $btnAutoMapPdf.PerformClick() })
}
if($miAdvanceClearGray){
    $miAdvanceClearGray.Add_Click({ $btnClearGrayZones.PerformClick() })
}
if($miAdvanceSampleAutoFill){
    $miAdvanceSampleAutoFill.Add_Click({
        $script:InspectionSampleAutoFillEnabled = -not $script:InspectionSampleAutoFillEnabled
        Update-InspectionSampleAutoFillButton
        Save-SessionState
    })
}
if($miAdvanceRotatePage){
    $miAdvanceRotatePage.Add_Click({
        if(Rotate-CurrentPageClockwise){
            if($txtOcrDebug){
                $txtOcrDebug.Text = "Drawing rotated 90 degrees."
            }
        }
    })
}
if($miAdvanceDeleteCurrentSession){
    $miAdvanceDeleteCurrentSession.Add_Click({
        [void](Delete-CurrentSessionAndRelatedData)
    })
}
$btnDegreeSymbol.Add_Click({
    Apply-NominalDecoration "DEGREE"
})

$btnDiameterSymbol.Add_Click({
    Apply-NominalDecoration "D_PREFIX"
})

$btnRadiusSymbol.Add_Click({
    Apply-NominalDecoration "R_PREFIX"
})

$btnChamferSymbol.Add_Click({
    Apply-NominalDecoration "C_PREFIX"
})

$form.Add_KeyDown({

    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Space){
        if(-not $script:isSpacePressed){
            $script:isSpacePressed = $true
            Update-CanvasCursor
        }

        $_.SuppressKeyPress = $true
        return
    }

    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){
        if(Cancel-PendingManualDuplicateCandidate){
            $_.SuppressKeyPress = $true
            return
        }

        if($script:TranslateLensEnabled){
            Set-TranslateLensEnabled $false
            $_.SuppressKeyPress = $true
            return
        }

        if($script:selectionRect){
            $script:selectionRect = $null
            Clear-PreviewImage
            Request-CanvasRedraw
            Save-SessionState
            $_.SuppressKeyPress = $true
            return
        }
    }

    if((-not (Test-TextInputActive)) -and $_.KeyCode -eq [System.Windows.Forms.Keys]::E){
        if(Keep-HiddenDuplicateCandidateAsNew){
            $_.SuppressKeyPress = $true
            return
        }
    }

    if((-not (Test-TextInputActive)) -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Enter){
        if(Accept-HiddenTextZoneHover){
            $_.SuppressKeyPress = $true
            return
        }
    }

    if($_.Control -and $_.Shift -and $_.KeyCode -eq [System.Windows.Forms.Keys]::R){
        if(Rotate-CurrentPageClockwise){
            if($txtOcrDebug){
                $txtOcrDebug.Text = "Drawing rotated 90 degrees."
            }
            $_.SuppressKeyPress = $true
            return
        }
    }

    if((-not (Test-TextInputActive)) -and $_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::R){
        if($table.SelectedRows.Count -gt 0){
            Invoke-AiVisionRescanSelectedStep
            $_.SuppressKeyPress = $true
            return
        }
    }

    if((-not (Test-TextInputActive)) -and $_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::B){
        Toggle-DrawSidePanel
        $_.SuppressKeyPress = $true
        return
    }

    if((-not (Test-TextInputActive)) -and $_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::S){
        if((Get-SelectedStepRowIndex) -ge 0){
            Invoke-AiRecoveryModeForSelectedStep
            $_.SuppressKeyPress = $true
            return
        }
    }

    if($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Z){
        Undo-DeletedStep
        $_.SuppressKeyPress = $true
        return
    }

    if(
        -not (Test-TextInputActive) -and
        (
            $_.KeyCode -eq [System.Windows.Forms.Keys]::Oemplus -or
            $_.KeyCode -eq [System.Windows.Forms.Keys]::Add
        )
    ){
        $null = Adjust-AllCurrentMarkScales 1.1
        $_.SuppressKeyPress = $true
        return
    }

    if(
        -not (Test-TextInputActive) -and
        (
            $_.KeyCode -eq [System.Windows.Forms.Keys]::OemMinus -or
            $_.KeyCode -eq [System.Windows.Forms.Keys]::Subtract
        )
    ){
        $null = Adjust-AllCurrentMarkScales (1.0 / 1.1)
        $_.SuppressKeyPress = $true
        return
    }

    if(-not (Test-TextInputActive) -and $_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::C){
        if(Copy-SelectedMarkToClipboard){
            $_.SuppressKeyPress = $true
            return
        }
    }

    if(-not (Test-TextInputActive) -and $_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::V){
        if(Paste-ClipboardMark){
            $_.SuppressKeyPress = $true
            return
        }
    }

    if(-not (Test-TextInputActive) -and $_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::D){
        if(Duplicate-SelectedTextZone){
            $_.SuppressKeyPress = $true
            return
        }
    }

    if(-not (Test-TextInputActive) -and -not $_.Control -and -not $_.Alt){
        if($_.KeyCode -eq [System.Windows.Forms.Keys]::B){
            if(Set-SelectedStepToolState "B"){
                $_.SuppressKeyPress = $true
                return
            }
        }
        if($_.KeyCode -eq [System.Windows.Forms.Keys]::C){
            if(Set-SelectedStepToolState "C"){
                $_.SuppressKeyPress = $true
                return
            }
        }
        if($_.KeyCode -eq [System.Windows.Forms.Keys]::I){
            if(Set-SelectedStepToolState "I"){
                $_.SuppressKeyPress = $true
                return
            }
        }
    }

    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Delete){
        if(Remove-SelectedTextZone){
            $_.SuppressKeyPress = $true
            return
        }
        if(Remove-SelectedUiCopiedMark){
            $_.SuppressKeyPress = $true
            return
        }
        if($table.SelectedRows.Count){
            Remove-StepAtIndex $table.SelectedRows[0].Index
            $_.SuppressKeyPress = $true
            return
        }
    }

    if($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::D0){
        Invoke-FitScreenAction
        $_.SuppressKeyPress = $true
        return
    }

    if($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::D1){
        Set-ViewMode "Actual"
        Save-SessionState
        $_.SuppressKeyPress = $true
    }
})

$form.Add_KeyPress({
    if(Handle-QuickResultKey $_.KeyChar){
        $_.Handled = $true
    }
})

$form.Add_KeyUp({

    if($_.KeyCode -eq [System.Windows.Forms.Keys]::Space){
        $script:isSpacePressed = $false
        Update-CanvasCursor
        $_.SuppressKeyPress = $true
    }
})

$picture.Add_MouseEnter({
    $picture.Focus()
    Update-CanvasCursor
})

$picture.Add_MouseLeave({
    if($script:TranslateLensEnabled){
        Clear-TranslateLensResult
        Request-CanvasRedraw
    }
    if(-not $script:isPanning){
        Update-CanvasCursor
    }
})

$picture.Add_MouseWheel({

    if(!$script:sourceBitmap){ return }

    $picture.Focus()
    Begin-TransientInteractiveRender

    $wheelSteps = $_.Delta / 120.0
    $modifiers = [System.Windows.Forms.Control]::ModifierKeys
    $hasShift = (($modifiers -band [System.Windows.Forms.Keys]::Shift) -eq [System.Windows.Forms.Keys]::Shift)
    $zoomFactor = [Math]::Pow($script:zoomStep,$wheelSteps)
    Set-ZoomAtPoint ($script:zoom * $zoomFactor) $_.Location "Custom"
    if($hasShift){ Scroll-Viewer (24 * $wheelSteps) 0 }

    Queue-ViewStateSave
})

# =========================
# MOUSE DOWN
# =========================
$picture.Add_MouseDown({

    if(!$script:sourceBitmap){ return }
    $picture.Focus()

    if($_.Button -eq [System.Windows.Forms.MouseButtons]::Middle -or ($script:isSpacePressed -and $_.Button -eq [System.Windows.Forms.MouseButtons]::Left)){
        Set-InteractiveCanvasMode $true
        $script:isPanning = $true
        $script:panStartPoint = $_.Location
        $script:panStartX = $script:panX
        $script:panStartY = $script:panY
        $picture.Capture = $true
        Update-CanvasCursor
        return
    }

    # =========================
    # GET REAL IMAGE POSITION
    # =========================
    $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
    $script:LastImageMousePoint = $imagePoint
    $mx = $imagePoint.X
    $my = $imagePoint.Y

    if($script:TranslateLensEnabled){
        Request-TranslateLensRefresh $imagePoint
        return
    }

    if($_.Button -eq [System.Windows.Forms.MouseButtons]::Left){
        if($script:AnnotationToolMode -eq "Highlight"){
            Set-InteractiveCanvasMode $true
            $script:IsDrawingHighlightStroke = $true
            $script:CurrentHighlightStroke = [PSCustomObject]@{
                Width = [double]$script:HighlightStrokeBaseWidth
                Points = @()
            }
            Add-HighlightStrokePoint $imagePoint
            $picture.Capture = $true
            Request-CanvasRedraw
            return
        }
        elseif($script:AnnotationToolMode -eq "Eraser"){
            if(Remove-HighlightStrokeAtPoint $imagePoint){
                Save-CurrentPageState
                Queue-SessionStateSave
                Request-CanvasRedraw
            }
            $picture.Capture = $true
            return
        }
    }

    # =========================
    # 1. RIGHT CLICK -> REMOVE LAST PLACED BALLOON
    # =========================
    if($_.Button -eq [System.Windows.Forms.MouseButtons]::Right){
        if(Cancel-PendingManualDuplicateCandidate){
            return
        }

        Update-HiddenTextZoneHoverFromPoint $imagePoint
        if(Keep-HiddenDuplicateCandidateAsNew){
            return
        }

        $uiCopiedMark = Get-UiCopiedMarkAtPoint $mx $my
        if($uiCopiedMark){
            Select-UiCopiedMark $uiCopiedMark.Id
            Remove-SelectedUiCopiedMark | Out-Null
            Save-CurrentPageState
            Save-SessionState
            return
        }

        $originalMark = Get-MarkAtPoint $mx $my
        if($originalMark){
            $markRowIndex = $script:marks.IndexOf($originalMark)
            if($markRowIndex -ge 0){
                Remove-StepAtIndex $markRowIndex
            }
            return
        }

        if($table.Rows.Count -gt 0){
            Remove-StepAtIndex ($table.Rows.Count - 1)
        }

        return
    }

    # =========================
    # 2. DRAG EXISTING BALLOON (TOP PRIORITY)
    # =========================
    if($_.Button -eq [System.Windows.Forms.MouseButtons]::Left){
        if($script:ShowPdfTextZones){
            $zoneHit = Get-TextZoneHit $imagePoint
            if($zoneHit){
                $script:SelectedTextZoneIndex = [int]$zoneHit.Index
                $script:IsDraggingTextZone = $true
                $script:TextZoneDragMode = [string]$zoneHit.Mode
                $script:TextZoneDragStartPoint = $imagePoint
                $zoneRect = $script:PdfTextLayerZones[$script:SelectedTextZoneIndex].Rect
                $script:TextZoneDragStartRect = New-Object Drawing.Rectangle($zoneRect.X,$zoneRect.Y,$zoneRect.Width,$zoneRect.Height)
                Set-InteractiveCanvasMode $true
                $picture.Capture = $true
                Request-CanvasRedraw
                return
            }
            $script:SelectedTextZoneIndex = -1
            # Text-zone editing mode owns the canvas completely. Do not let a
            # click on empty space fall through into the normal red OCR crop
            # workflow while the overlay is on.
            Request-CanvasRedraw
            return
        }

        $uiCopiedMark = Get-UiCopiedMarkAtPoint $mx $my
        if($uiCopiedMark){
            Select-UiCopiedMark $uiCopiedMark.Id
            Set-InteractiveCanvasMode $true
            $script:isDraggingMark = $true
            $script:draggingMarkKind = "Copy"
            $script:dragMarkIndex = -1
            $picture.Capture = $true
            $script:dragOffset = @{
                X = $mx - $uiCopiedMark.X
                Y = $my - $uiCopiedMark.Y
            }
            Request-CanvasRedraw
            return
        }

        $originalMark = Get-MarkAtPoint $mx $my
        if($originalMark){
            $markRowIndex = $script:marks.IndexOf($originalMark)
            if($markRowIndex -ge 0){
                Select-OriginalMark $markRowIndex $true
            }

            Set-InteractiveCanvasMode $true
            $script:isDraggingMark = $true
            $script:draggingMarkKind = "Original"
            $script:dragMarkIndex = $markRowIndex
            $picture.Capture = $true

            $script:dragOffset = @{
                X = $mx - $originalMark.X
                Y = $my - $originalMark.Y
            }

            Request-CanvasRedraw
            return
        }

    }

    # =========================
    # 3. OCR DRAG MODE (DEFAULT)
    # =========================
    if($_.Button -ne [System.Windows.Forms.MouseButtons]::Left){ return }

    Set-InteractiveCanvasMode $true
    Clear-SelectedMark
    Clear-HiddenTextZoneHover
    $script:dragging = $true
    $script:startPoint = $imagePoint
    $script:endPoint = $imagePoint
    $picture.Capture = $true
    Clear-PreviewImage
    Clear-AiVisionResult
    $script:selectionRect = New-Object Drawing.RectangleF(
        [float]$imagePoint.X,
        [float]$imagePoint.Y,
        0.0,
        0.0
    )

})

# =========================
# DRAG SELECT
# =========================
$picture.Add_MouseMove({

    if($script:sourceBitmap){
        $null = Set-LastImageMousePointFromCanvasPoint $_.Location
    }

    if($script:isPanning){

        $script:panX = $script:panStartX + ($_.Location.X - $script:panStartPoint.X)
        $script:panY = $script:panStartY + ($_.Location.Y - $script:panStartPoint.Y)

        Clamp-Pan
        Request-CanvasRedraw
        return
    }

    if($script:IsDrawingHighlightStroke){
        $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
        Add-HighlightStrokePoint $imagePoint
        Request-CanvasRedraw
        return
    }

    if($script:AnnotationToolMode -eq "Eraser" -and $picture.Capture){
        $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
        if(Remove-HighlightStrokeAtPoint $imagePoint){
            Request-CanvasRedraw
        }
        return
    }

    # =========================
    # 1. DRAG BALLOON (TOP PRIORITY)
    # =========================
    if($script:IsDraggingTextZone){
        $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
        $newRect = Get-DraggedTextZoneRect $imagePoint
        if($newRect -and $script:SelectedTextZoneIndex -ge 0 -and $script:SelectedTextZoneIndex -lt @($script:PdfTextLayerZones).Count){
            $script:PdfTextLayerZones[$script:SelectedTextZoneIndex].Rect = $newRect
            Request-CanvasRedraw
        }
        return
    }

    if($script:isDraggingMark){

        $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
        $mx = $imagePoint.X
        $my = $imagePoint.Y

        $newX = $mx - $script:dragOffset.X
        $newY = $my - $script:dragOffset.Y

        if($script:draggingMarkKind -eq "Copy"){
            $uiCopiedMark = Get-UiCopiedMarkById $script:SelectedUiCopyId
            if($uiCopiedMark){
                $uiCopiedMark.X = $newX
                $uiCopiedMark.Y = $newY
            }
        }
        elseif($script:dragMarkIndex -ge 0 -and $script:dragMarkIndex -lt $script:marks.Count){
            $script:marks[$script:dragMarkIndex].X = $newX
            $script:marks[$script:dragMarkIndex].Y = $newY
        }

        Request-CanvasRedraw
        return
    }

    # =========================
    # 2. OCR DRAG SELECTION
    # =========================
    if($script:dragging){

        $script:endPoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
        $script:selectionRect = Get-NormalizedSelectionRect $script:startPoint $script:endPoint
        Clear-HiddenTextZoneHover
        Request-CanvasRedraw

        # =========================
        # LIVE PREVIEW (ZOOM OCR AREA)
        # =========================
        if(Test-SelectionLargeEnough $script:selectionRect){
            Request-SelectionPreviewRefresh
        }
    }
    else{
        $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
        if($script:TranslateLensEnabled){
            Request-TranslateLensRefresh $imagePoint
            return
        }
        Update-HiddenTextZoneHoverFromPoint $imagePoint
    }

})


$picture.Add_MouseDoubleClick({
    if(!$script:sourceBitmap){ return }
    if($script:TranslateLensEnabled){ return }
    if($_.Button -ne [System.Windows.Forms.MouseButtons]::Left){ return }
    $imagePoint = Clamp-ImagePointToBitmap (Convert-ScreenPointToImagePoint $_.Location)
    Update-HiddenTextZoneHoverFromPoint $imagePoint
    if(Accept-HiddenTextZoneHover){
        return
    }
})

$picture.Add_MouseUp({

    if($script:isPanning){
        $script:isPanning = $false
        $script:panStartPoint = $null
        $picture.Capture = $false
        Update-CanvasCursor
        Request-CanvasRedraw
        Begin-TransientInteractiveRender
        Queue-ViewStateSave
        return
    }

    if($script:IsDrawingHighlightStroke){
        $script:IsDrawingHighlightStroke = $false
        Set-InteractiveCanvasMode $false
        $picture.Capture = $false
        if($script:CurrentHighlightStroke -and @($script:CurrentHighlightStroke.Points).Count -gt 0){
            $script:HighlightStrokes += $script:CurrentHighlightStroke
            Save-CurrentPageState
            Queue-SessionStateSave
        }
        $script:CurrentHighlightStroke = $null
        Request-CanvasRedraw
        return
    }

    if($script:AnnotationToolMode -eq "Eraser" -and $picture.Capture){
        $picture.Capture = $false
        Save-CurrentPageState
        Queue-SessionStateSave
        Request-CanvasRedraw
        return
    }

    $runSelectionAction =
        $script:dragging -and
        (-not $script:isDraggingMark) -and
        $script:selectionRect -and
        (Test-SelectionLargeEnough $script:selectionRect)

    # =========================
    # STOP OCR DRAG
    # =========================
    $script:dragging = $false
    Set-InteractiveCanvasMode $false
    $picture.Capture = $false

    # =========================
    # STOP BALLOON DRAG
    # =========================
    if($script:isDraggingMark){
        $script:isDraggingMark = $false
        $draggedOriginalMark = ($script:draggingMarkKind -eq "Original")
        $script:draggingMarkKind = $null
        $script:dragMarkIndex = -1
        Request-CanvasRedraw
        if($draggedOriginalMark){
            Save-SessionState
        }
    }

    if($script:IsDraggingTextZone){
        $script:IsDraggingTextZone = $false
        $script:TextZoneDragMode = $null
        $script:TextZoneDragStartPoint = $null
        $script:TextZoneDragStartRect = $null
        Set-InteractiveCanvasMode $false
        $picture.Capture = $false
        if($script:SelectedTextZoneIndex -ge 0 -and $script:SelectedTextZoneIndex -lt @($script:PdfTextLayerZones).Count){
            Update-TextZoneReviewAtIndex $script:SelectedTextZoneIndex -ForceFresh
        }
        Request-CanvasRedraw
        return
    }

    if($runSelectionAction){
        Update-PreviewFromSelection
        Invoke-SelectedOcr
    }
    else{
        Clear-PreviewImage
    }

    Update-CanvasCursor

})

# =========================
# DRAW OVERLAY
# =========================

$picture.Add_Paint({

    $g = $_.Graphics
    $g.Clear([Drawing.Color]::White)
    if($script:IsInteractiveCanvasUpdate){
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighSpeed
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::Low
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighSpeed
        $g.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighSpeed
    }
    else{
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
    }

    if(!$script:sourceBitmap){ return }

    $matrix = New-Object Drawing.Drawing2D.Matrix
    $matrix.Translate([float]$script:panX,[float]$script:panY)
    $matrix.Scale([float]$script:zoom,[float]$script:zoom)
    $g.Transform = $matrix

    $g.DrawImage(
        $script:sourceBitmap,
        0,
        0,
        $script:sourceBitmap.Width,
        $script:sourceBitmap.Height
    )

    Draw-PdfTextLayerZones $g
    Draw-HiddenTextZoneSuggestion $g
    if($script:CurrentHighlightStroke){
        $previewStroke = @($script:HighlightStrokes)
        $previewStroke += $script:CurrentHighlightStroke
        $originalStrokes = $script:HighlightStrokes
        try{
            $script:HighlightStrokes = $previewStroke
            Draw-HighlightStrokes $g
        }
        finally{
            $script:HighlightStrokes = $originalStrokes
        }
    }
    else{
        Draw-HighlightStrokes $g
    }

    $overlayWidth = [float][Math]::Max(1.0,(2.25 / [Math]::Max($script:zoom,0.0001)))

    # ===== DRAW OCR SELECTION RECTANGLE =====
    if($script:selectionRect){

        $selectionColor = [Drawing.Color]::Red
        $fillBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(38,$selectionColor))
        $pen = New-Object Drawing.Pen($selectionColor,$overlayWidth)
        $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $g.FillRectangle(
            $fillBrush,
            $script:selectionRect.X,
            $script:selectionRect.Y,
            $script:selectionRect.Width,
            $script:selectionRect.Height
        )
        $g.DrawRectangle(
            $pen,
            $script:selectionRect.X,
            $script:selectionRect.Y,
            $script:selectionRect.Width,
            $script:selectionRect.Height
        )
        if($script:selectionRect.Width -gt 0 -and $script:selectionRect.Height -gt 0){
            $selectionSizeText = ("{0} x {1}" -f [int][Math]::Round($script:selectionRect.Width),[int][Math]::Round($script:selectionRect.Height))
            $labelFont = New-Object Drawing.Font("Segoe UI", [float][Math]::Max(9,(11 / [Math]::Max($script:zoom,0.0001))), [Drawing.FontStyle]::Bold)
            $labelPoint = New-Object Drawing.PointF(
                [float]($script:selectionRect.X + (8 / [Math]::Max($script:zoom,0.0001))),
                [float]($script:selectionRect.Y + (8 / [Math]::Max($script:zoom,0.0001)))
            )
            $labelShadowBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(150,[Drawing.Color]::Black))
            $labelBrush = New-Object Drawing.SolidBrush([Drawing.Color]::White)
            $shadowX = [float]($labelPoint.X + (1 / [Math]::Max($script:zoom,0.0001)))
            $shadowY = [float]($labelPoint.Y + (1 / [Math]::Max($script:zoom,0.0001)))
            $g.DrawString($selectionSizeText,$labelFont,$labelShadowBrush,$shadowX,$shadowY)
            $g.DrawString($selectionSizeText,$labelFont,$labelBrush,$labelPoint)
            $labelBrush.Dispose()
            $labelShadowBrush.Dispose()
            $labelFont.Dispose()
        }
        $pen.Dispose()
        $fillBrush.Dispose()
    }


    # ===== DRAW POSITION HIGHLIGHT =====
    if($script:HighlightRect){

        $pen = New-Object Drawing.Pen([Drawing.Color]::Lime,[float][Math]::Max(1.5,(3.0 / [Math]::Max($script:zoom,0.0001))))

        $g.DrawRectangle(
            $pen,
            $script:HighlightRect.X,
            $script:HighlightRect.Y,
            $script:HighlightRect.Width,
            $script:HighlightRect.Height
        )

        $pen.Dispose()
    }

    Draw-ImportantStepHighlights $g (Get-AllStepEntries) $script:zoom

    # Draw balloons in image space; the active transform turns them into a WYSIWYG zoomed preview.
    Draw-MarkBalloons $g 1.0 $true $script:CopyViewOnly
    $g.ResetTransform()
    Draw-TranslateLensOverlay $g
    $matrix.Dispose()
})
# =========================
# Clear rubish ocr
# =========================
function Clean-OCRText($text){

    if(!$text){ return "" }

    $text = $text.Trim()

    $text = $text.ToUpperInvariant()
    # normalize common OCR characters before stripping
    $text = $text -replace 'O','0'
    $text = $text -replace 'I','1'
    $text = $text -replace 'L','1'
    $text = $text -replace 'M','00'

    $text = $text -replace '•','.'
    $text = $text -replace '·','.'
    $text = $text -replace '\s',''

    # remove wrappers/noise but keep mechanical numeric symbols, including degree.
    $text = $text -replace 'º','°'
    $text = $text -replace '[\(\)\[\]]',''
    $text = $text -replace '[^0-9\.\+\-\±°]',''

    # fix double dots
    $text = $text -replace '\.{2,}','.'

    # fix multiple signs
    $text = $text -replace '\+{2,}','+'
    $text = $text -replace '\-{2,}','-'

    # remove leading dot
    $text = $text -replace '^\.(\d+)','0.$1'

    # remove trailing dot
    $text = $text -replace '\.$',''

    return $text
}

function Normalize-ToleranceOcrText($text){

    if(!$text){ return "" }

    $text = [string]$text
    $text = $text.ToUpperInvariant()
    $text = $text -replace "\r\n?"," "
    $text = $text -replace "`n"," "
    $text = $text -replace '=','+'
    $text = $text -replace 'T','+'
    $text = $text -replace ',','.'
    $text = $text -replace '：', ':'
    $text = $text -replace ':','.'
    $text = $text -replace '•','.'
    $text = $text -replace '·','.'
    $text = $text -replace 'O','0'
    $text = $text -replace 'I','1'
    $text = $text -replace 'L','1'
    $text = $text -replace 'M','00'
    $text = [regex]::Replace($text,'(\d)\s*\.\s*(\d)','$1.$2')
    # OCR pattern in stacked tolerance: +0.005 may come back as +8:885/+8.885.
    $text = [regex]::Replace($text,'(?<sign>[+\-±])\s*8\.88(?<d>[1-9])(?!\d)', '${sign}0.00${d}')
    # Signed zero-prefixed tolerance tokens should be interpreted as decimals:
    # +01 => +0.1, +021 => +0.21, +0001 => +0.001. Without an explicit sign,
    # do not rewrite because it may be the nominal itself.
    $text = [regex]::Replace($text,'([+\-])\s*0(\d{1,4})(?![\d\.])','${1}0.$2')
    $text = [regex]::Replace($text,'±\s*[08](\d{1,4})(?![\d\.])','±0.$1')

    return $text.Trim()
}

function Get-DetachedToleranceFromStuckNominal($text,$nominal){

    if([string]::IsNullOrWhiteSpace([string]$text) -or [string]::IsNullOrWhiteSpace([string]$nominal)){
        return $null
    }

    $nominalText = ([string]$nominal).Trim()
    if($nominalText -notmatch '^\d+\.(\d{4})$'){ return $null }

    $source = ([string]$text).ToUpperInvariant()
    $source = $source -replace ',', '.'
    $source = $source -replace 'O','0'
    $source = $source -replace 'I','1'
    $source = $source -replace 'L','1'
    $source = $source -replace 'S','5'
    $source = $source -replace 'B','8'
    $compact = $source -replace '\s+',''
    $escapedNominal = [regex]::Escape($nominalText)

    $tolDigits = $null
    $mode = $null
    if($compact -match ($escapedNominal + '(?<tol>\d{3})(?!\d)')){
        $tolDigits = [string]$Matches['tol']
        $mode = "StuckNominalTolerance"
    }
    elseif($compact -match ('(?<whole>\d+\.\d{7})(?!\d)')){
        $whole = [string]$Matches['whole']
        if($whole.StartsWith($nominalText)){
            $tolDigits = $whole.Substring($nominalText.Length)
            $mode = "StuckNominalTolerance7"
        }
    }

    if([string]::IsNullOrWhiteSpace($tolDigits) -or $tolDigits.Length -ne 3){ return $null }

    $tolValue = 0.0
    if(-not [double]::TryParse(('0.' + $tolDigits),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$tolValue)){
        return $null
    }
    if($tolValue -le 0 -or $tolValue -ge 0.1){ return $null }

    return [PSCustomObject]@{
        Detected = $true
        TolMinus = -[Math]::Abs($tolValue)
        TolPlus = [Math]::Abs($tolValue)
        NormalizedText = $source
        ParseMode = $mode
    }
}

function Get-GeneralToleranceForNominal($nominalText){

    if([string]::IsNullOrWhiteSpace([string]$nominalText)){
        return [PSCustomObject]@{
            TolMinus = ""
            TolPlus = ""
            Detected = $false
            Source = "None"
        }
    }

    try{
        $nominalValue = [string]$nominalText
        if($nominalValue -match '[°º]'){
            $angleDms = Try-ParseAngleDmsText $nominalValue
            if($angleDms -and (
                -not [string]::IsNullOrWhiteSpace([string]$angleDms.Minutes) -or
                -not [string]::IsNullOrWhiteSpace([string]$angleDms.Seconds)
            )){
                $decimals = 3
            }
            else{
                $decimals = Get-InspectionResultDecimalPlaces (($nominalValue -replace '[°º]',''))
            }

            switch($decimals){
                1 { $tol = 0.2 }
                2 { $tol = 0.05 }
                3 { $tol = 0.01 }
                default { $tol = 0.5 }
            }
        }
        elseif($nominalValue -match '\.(\d+)'){
            $decimals = $Matches[1].Length

            switch($decimals){
                1 { $tol = [double]$txtTol1.Text }
                2 { $tol = [double]$txtTol2.Text }
                3 { $tol = [double]$txtTol3.Text }
                default { $tol = [double]$txtTol0.Text }
            }
        }
        else{
            $tol = [double]$txtTol0.Text
        }

        $tolMagnitude = [Math]::Abs([double]$tol)

        return [PSCustomObject]@{
            TolMinus = -$tolMagnitude
            TolPlus = $tolMagnitude
            Detected = $false
            Source = "General"
        }
    }
    catch{
        return [PSCustomObject]@{
            TolMinus = ""
            TolPlus = ""
            Detected = $false
            Source = "None"
        }
    }
}

function Get-ToleranceOcrScore($text){

    $normalized = Normalize-ToleranceOcrText $text
    if([string]::IsNullOrWhiteSpace($normalized)){ return 0 }

    $score = 0
    $score += ([regex]::Matches($normalized,'\d')).Count
    $score += (([regex]::Matches($normalized,'(?:\d+\.\d+|\.\d+)')).Count * 10)
    $score += (([regex]::Matches($normalized,'[+\-±]')).Count * 6)

    if($normalized -match '±'){
        $score += 8
    }

    return $score
}

function Repair-StackedToleranceZeroOcrText($text,$nominal){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return [string]$text }
    $value = [string]$text

    # OCR frequently reads a leading tolerance zero as 8 in vertical stacked
    # tolerance crops: -0.002 => -8.002, +0.002 => +8.002, +0.002 => +8.8882.
    # Repair only tiny tolerance-looking decimals after an explicit sign so
    # nominal 8.x is safe.
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8(?<frac>\.0{1,3}\d{1,3})', '${sign}0${frac}')
    $value = [regex]::Replace($value,'(?<sign>[+\-±])\s*8\.8{3,}(?<d>[1-9])(?!\d)', '${sign}0.00${d}')

    # Same issue can appear with full-width/minus variants after normalization.
    $value = [regex]::Replace($value,'(?<sign>[－−])\s*8(?<frac>\.0{1,3}\d{1,3})', '-0${frac}')
    $value = [regex]::Replace($value,'(?<sign>[－−])\s*8\.8{3,}(?<d>[1-9])(?!\d)', '-0.00${d}')

    return $value
}

function Test-MechanicalTolerancePlausible($tol,$nominal){

    if(!$tol -or -not $tol.Detected){ return $false }

    $minus = [Math]::Abs([double]$tol.TolMinus)
    $plus = [Math]::Abs([double]$tol.TolPlus)
    $maxTol = [Math]::Max($minus,$plus)

    # Our UI/preset domain is normal machining tolerance. If OCR says +0.883,
    # it is almost certainly garbage from stacked vertical text, not tolerance.
    if($maxTol -gt 0.5){ return $false }

    $nominalText = ([string]$nominal).Trim()
    if($nominalText -match '^[RCØΦO/]+\s*(.+)$'){
        $nominalText = [string]$Matches[1]
    }
    $nominalText = $nominalText -replace '[°º]',''

    $nominalValue = 0.0
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if([double]::TryParse($nominalText,[System.Globalization.NumberStyles]::Float,$culture,[ref]$nominalValue)){
        $nominalValue = [Math]::Abs($nominalValue)
        if($nominalValue -gt 0 -and $maxTol -ge $nominalValue){ return $false }
        if($nominalValue -lt 1.0 -and $maxTol -gt 0.05){ return $false }
        if($nominalValue -lt 0.1 -and $maxTol -gt 0.01){ return $false }
    }

    return $true
}

function Parse-ToleranceFull($text, $nominal){

    $text = Repair-StackedToleranceZeroOcrText $text $nominal
    $normalized = Normalize-ToleranceOcrText $text
    $stuckTolerance = Get-DetachedToleranceFromStuckNominal $normalized $nominal
    if($stuckTolerance){
        return $stuckTolerance
    }

    if([string]::IsNullOrWhiteSpace($normalized)){
        return [PSCustomObject]@{
            Detected = $false
            TolMinus = 0
            TolPlus = 0
            NormalizedText = $normalized
            ParseMode = "None"
        }
    }

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if($normalized -match '(?i)\bR\s*(\d*\.?\d+)\s*MAX\b'){
        $radiusMaxValue = 0.0
        if([double]::TryParse($Matches[1],[System.Globalization.NumberStyles]::Float,$culture,[ref]$radiusMaxValue)){
            return [PSCustomObject]@{
                Detected = $true
                TolMinus = -[Math]::Abs($radiusMaxValue)
                TolPlus = 0
                NormalizedText = $normalized
                ParseMode = "RadiusMax"
            }
        }
    }

    $nominalValue = 0.0
    [void][double]::TryParse(([string]$nominal),[System.Globalization.NumberStyles]::Float,$culture,[ref]$nominalValue)

    $nums = @(
        [regex]::Matches($normalized,'(?:\d+\.\d+|\.\d+|\d+)') |
        ForEach-Object { [double]::Parse($_.Value,$culture) }
    )

    $tolCandidates = @(
        $nums |
        Where-Object { $_ -lt 1.0 } |
        Where-Object { [Math]::Abs($_ - $nominalValue) -gt 0.0001 }
    )
    $nominalFractionValue = $null
    if([string]$nominal -match '^\s*\d+\.(\d+)\s*$'){
        $fractionDigits = [string]$Matches[1]
        if(-not [string]::IsNullOrWhiteSpace($fractionDigits)){
            $fractionText = '0.' + $fractionDigits
            $fractionValue = 0.0
            if([double]::TryParse($fractionText,[System.Globalization.NumberStyles]::Float,$culture,[ref]$fractionValue)){
                $nominalFractionValue = [Math]::Abs($fractionValue)
            }
        }
    }
    if($null -ne $nominalFractionValue -and $nominalValue -ge 1.0){
        $tolCandidates = @(
            $tolCandidates |
            Where-Object { [Math]::Abs($_ - $nominalFractionValue) -gt 0.0001 }
        )
    }


    $plusMatches = @(
        [regex]::Matches($normalized,'\+\s*((?:[0-9]+\.[0-9]+|\.[0-9]+|[0-9]+))') |
        ForEach-Object { [double]::Parse($_.Groups[1].Value,$culture) } |
        Where-Object { $_ -lt 1.0 } |
        Where-Object { [Math]::Abs($_ - $nominalValue) -gt 0.0001 }
    )
    $minusMatches = @(
        [regex]::Matches($normalized,'-\s*((?:[0-9]+\.[0-9]+|\.[0-9]+|[0-9]+))') |
        ForEach-Object { [double]::Parse($_.Groups[1].Value,$culture) } |
        Where-Object { $_ -lt 1.0 } |
        Where-Object { [Math]::Abs($_ - $nominalValue) -gt 0.0001 }
    )
    $plusCompactMatches = @(
        [regex]::Matches($normalized,'\+\s*(\d{4})(?![\d\.])') |
        ForEach-Object { [double]::Parse(('0.' + $_.Groups[1].Value.Substring(1)),$culture) } |
        Where-Object { $_ -lt 1.0 } |
        Where-Object { [Math]::Abs($_ - $nominalValue) -gt 0.0001 }
    )
    if($plusCompactMatches.Count -gt 0){
        $plusMatches = @($plusMatches + $plusCompactMatches)
    }

    $minusCompactMatches = @(
        [regex]::Matches($normalized,'-\s*(\d{4})(?![\d\.])') |
        ForEach-Object { [double]::Parse(('0.' + $_.Groups[1].Value.Substring(1)),$culture) } |
        Where-Object { $_ -lt 1.0 } |
        Where-Object { [Math]::Abs($_ - $nominalValue) -gt 0.0001 }
    )
    if($minusCompactMatches.Count -gt 0){
        $minusMatches = @($minusMatches + $minusCompactMatches)
    }


    if($normalized -match '±' -and $tolCandidates.Count -gt 0){
        $tolMagnitude = [Math]::Abs([double]$tolCandidates[0])
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = -$tolMagnitude
            TolPlus = $tolMagnitude
            NormalizedText = $normalized
            ParseMode = "PlusMinus"
        }
    }

    if($plusMatches.Count -gt 0 -and $minusMatches.Count -gt 0){
        $tolPlus = [Math]::Abs([double]$plusMatches[0])
        $tolMinus = [Math]::Abs([double]$minusMatches[0])
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = -$tolMinus
            TolPlus = $tolPlus
            NormalizedText = $normalized
            ParseMode = "SignedPair"
        }
    }

    if($minusMatches.Count -eq 1 -and $plusMatches.Count -eq 0 -and $tolCandidates.Count -ge 2){
        $tolMinusValue = [Math]::Abs([double]$minusMatches[0])
        $tolPlusCandidate = @(
            $tolCandidates |
            Where-Object { [Math]::Abs([double]$_ - $tolMinusValue) -gt 0.0001 } |
            Select-Object -First 1
        )
        if($tolPlusCandidate.Count -gt 0){
            $tolPlusValue = [Math]::Abs([double]$tolPlusCandidate[0])
            return [PSCustomObject]@{
                Detected = $true
                TolMinus = -$tolMinusValue
                TolPlus = $tolPlusValue
                NormalizedText = $normalized
                ParseMode = "StackedMinusPlusRecovered"
            }
        }
    }

    if($plusMatches.Count -eq 1 -and $minusMatches.Count -eq 0 -and $tolCandidates.Count -ge 2){
        $tolPlusValue = [Math]::Abs([double]$plusMatches[0])
        $tolMinusCandidate = @(
            $tolCandidates |
            Where-Object { [Math]::Abs([double]$_ - $tolPlusValue) -gt 0.0001 } |
            Select-Object -First 1
        )
        if($tolMinusCandidate.Count -gt 0){
            $tolMinusValue = [Math]::Abs([double]$tolMinusCandidate[0])
            return [PSCustomObject]@{
                Detected = $true
                TolMinus = -$tolMinusValue
                TolPlus = $tolPlusValue
                NormalizedText = $normalized
                ParseMode = "StackedPlusMinusRecovered"
            }
        }
    }

    if($plusMatches.Count -ge 2){
        $orderedPlus = @($plusMatches | ForEach-Object { [Math]::Abs([double]$_) } | Sort-Object)
        $tolLower = [double]$orderedPlus[0]
        $tolUpper = [double]$orderedPlus[$orderedPlus.Count - 1]
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = $tolLower
            TolPlus = $tolUpper
            NormalizedText = $normalized
            ParseMode = "StackedPlus"
        }
    }

    if($minusMatches.Count -ge 2){
        $orderedMinus = @($minusMatches | ForEach-Object { [Math]::Abs([double]$_) } | Sort-Object -Descending)
        $tolLower = [double]$orderedMinus[0]
        $tolUpper = [double]$orderedMinus[$orderedMinus.Count - 1]
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = -$tolLower
            TolPlus = -$tolUpper
            NormalizedText = $normalized
            ParseMode = "StackedMinus"
        }
    }

    if($plusMatches.Count -eq 1 -and $minusMatches.Count -eq 0 -and $tolCandidates.Count -ge 2){
        $orderedPlusFallback = @($tolCandidates | ForEach-Object { [Math]::Abs([double]$_) } | Sort-Object)
        $tolLower = [double]$orderedPlusFallback[0]
        $tolUpper = [double]$orderedPlusFallback[$orderedPlusFallback.Count - 1]
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = $tolLower
            TolPlus = $tolUpper
            NormalizedText = $normalized
            ParseMode = "StackedPlusRecovered"
        }
    }

    if($minusMatches.Count -eq 1 -and $plusMatches.Count -eq 0 -and $tolCandidates.Count -ge 2){
        $orderedMinusFallback = @($tolCandidates | ForEach-Object { [Math]::Abs([double]$_) } | Sort-Object -Descending)
        $tolLower = [double]$orderedMinusFallback[0]
        $tolUpper = [double]$orderedMinusFallback[$orderedMinusFallback.Count - 1]
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = -$tolLower
            TolPlus = -$tolUpper
            NormalizedText = $normalized
            ParseMode = "StackedMinusRecovered"
        }
    }

    if($plusMatches.Count -eq 1 -and $minusMatches.Count -eq 0){
        $tolPlus = [Math]::Abs([double]$plusMatches[0])
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = 0
            TolPlus = $tolPlus
            NormalizedText = $normalized
            ParseMode = "PlusOnly"
        }
    }

    if($minusMatches.Count -eq 1 -and $plusMatches.Count -eq 0){
        $tolMinus = [Math]::Abs([double]$minusMatches[0])
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = -$tolMinus
            TolPlus = 0
            NormalizedText = $normalized
            ParseMode = "MinusOnly"
        }
    }

    if($tolCandidates.Count -ge 2){
        $tolUpper = [Math]::Abs([double]$tolCandidates[0])
        $tolLower = [Math]::Abs([double]$tolCandidates[1])
        if($normalized -match '\+' -and $normalized -notmatch '-'){
            return [PSCustomObject]@{
                Detected = $true
                TolMinus = $tolLower
                TolPlus = $tolUpper
                NormalizedText = $normalized
                ParseMode = "StackedPlusFallback"
            }
        }
        if($normalized -match '-' -and $normalized -notmatch '\+'){
            return [PSCustomObject]@{
                Detected = $true
                TolMinus = -$tolLower
                TolPlus = -$tolUpper
                NormalizedText = $normalized
                ParseMode = "StackedMinusFallback"
            }
        }
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = -$tolLower
            TolPlus = $tolUpper
            NormalizedText = $normalized
            ParseMode = "Stacked"
        }
    }

    if($tolCandidates.Count -eq 1 -and -not ($normalized -match '[\+\-±]') -and $nums.Count -ge 2){
        $tolMagnitude = [Math]::Abs([double]$tolCandidates[0])
        return [PSCustomObject]@{
            Detected = $true
            TolMinus = -$tolMagnitude
            TolPlus = $tolMagnitude
            NormalizedText = $normalized
            ParseMode = "TwoNumberFallback"
        }
    }

    if($normalized -match '(?<sign>[+\-±])\s*0(?<frac>\.0{1,3}\d{1,3})'){
        $tolMagnitude = [Math]::Abs([double]::Parse(('0' + [string]$Matches['frac']),$culture))
        if([string]$Matches['sign'] -eq '+'){
            return [PSCustomObject]@{ Detected = $true; TolMinus = 0; TolPlus = $tolMagnitude; NormalizedText = $normalized; ParseMode = "RepairedZeroPlus" }
        }
        elseif([string]$Matches['sign'] -eq '±'){
            return [PSCustomObject]@{ Detected = $true; TolMinus = -$tolMagnitude; TolPlus = $tolMagnitude; NormalizedText = $normalized; ParseMode = "RepairedZeroPlusMinus" }
        }
        else{
            return [PSCustomObject]@{ Detected = $true; TolMinus = -$tolMagnitude; TolPlus = 0; NormalizedText = $normalized; ParseMode = "RepairedZeroMinus" }
        }
    }

    return [PSCustomObject]@{
        Detected = $false
        TolMinus = 0
        TolPlus = 0
        NormalizedText = $normalized
        ParseMode = "None"
    }
}

function Extract-ToleranceFromRegion($image, $x, $y, $w, $h, $nominalText = ""){

    if(!$image){
        return [PSCustomObject]@{
            Detected = $false
            TolMinus = ""
            TolPlus = ""
            OcrText = ""
            NormalizedText = ""
            ParseMode = "None"
        }
    }

    $left = [Math]::Max(0,[int]$x)
    $top = [Math]::Max(0,[int]$y)
    $right = [Math]::Min($image.Width,([int]$x + [int]$w))
    $bottom = [Math]::Min($image.Height,([int]$y + [int]$h))
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)

    if($width -le 2 -or $height -le 2){
        return [PSCustomObject]@{
            Detected = $false
            TolMinus = ""
            TolPlus = ""
            OcrText = ""
            NormalizedText = ""
            ParseMode = "None"
        }
    }

    $strictRect = New-Object Drawing.Rectangle($left,$top,$width,$height)
    $crop = $null
    $scaled = $null

    try{
        $crop = $image.Clone($strictRect,$image.PixelFormat)
        $scale = 6
        $scaled = New-Object Drawing.Bitmap ([Math]::Max(1,($crop.Width * $scale))),([Math]::Max(1,($crop.Height * $scale)))

        $graphics = [Drawing.Graphics]::FromImage($scaled)
        try{
            $graphics.InterpolationMode = "HighQualityBicubic"
            $graphics.DrawImage($crop,0,0,$scaled.Width,$scaled.Height)
        }
        finally{
            $graphics.Dispose()
        }

        $bestText = ""
        $bestScore = -1
        foreach($angle in @(Get-OcrPrimaryAngles)){
            if($angle -eq 0){
                $ocrBitmap = $scaled
            }
            else{
                $ocrBitmap = Rotate-Bitmap $scaled $angle
            }

            try{
                $ocrText = Run-FastOcr $ocrBitmap
                $score = Get-ToleranceOcrScore $ocrText
                if($score -gt $bestScore){
                    $bestScore = $score
                    $bestText = $ocrText
                }
            }
            finally{
                if($angle -ne 0 -and $ocrBitmap){
                    $ocrBitmap.Dispose()
                }
            }
        }

        $parsedTolerance = Parse-ToleranceFull $bestText $nominalText
        $parsedTolerance | Add-Member -NotePropertyName OcrText -NotePropertyValue ([string]$bestText) -Force
        return $parsedTolerance
    }
    finally{
        if($scaled){
            $scaled.Dispose()
        }
        if($crop){
            $crop.Dispose()
        }
    }
}
# =========================
# OCR FUNCTION
# =========================

function Run-RapidOcrTextFromImagePath($imagePath){

    if([string]::IsNullOrWhiteSpace([string]$imagePath) -or !(Test-Path $imagePath)){ return "" }
    if(-not (Initialize-RapidOcrNetForAutoOcr)){ return "" }

    try{
        $options = [RapidOcrNet.RapidOcrOptions]::Default
        $result = $script:RapidOcrNetEngine.Detect($imagePath,$options)
        if(!$result -or !$result.StrRes){ return "" }
        return ([string]$result.StrRes).Trim()
    }
    catch{
        return ""
    }
}

function Run-RapidOcrDetailedFromImagePath($imagePath){

    $emptyResult = [PSCustomObject]@{
        Text = ""
        Lines = @()
    }

    if([string]::IsNullOrWhiteSpace([string]$imagePath) -or !(Test-Path $imagePath)){ return $emptyResult }
    if(-not (Initialize-RapidOcrNetForAutoOcr)){ return $emptyResult }

    try{
        $options = [RapidOcrNet.RapidOcrOptions]::Default
        $result = $script:RapidOcrNetEngine.Detect($imagePath,$options)
        if(!$result){ return $emptyResult }

        $lines = @()
        foreach($block in @($result.TextBlocks)){
            if(!$block -or [string]::IsNullOrWhiteSpace([string]$block.Text) -or !$block.BoxPoints){ continue }

            $points = @($block.BoxPoints)
            if($points.Count -le 0){ continue }

            $minX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Minimum).Minimum
            $minY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Minimum).Minimum
            $maxX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Maximum).Maximum
            $maxY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Maximum).Maximum

            $lines += [PSCustomObject]@{
                Text = [string]$block.Text
                Rect = (New-Object Drawing.RectangleF(
                    [float]$minX,
                    [float]$minY,
                    [float][Math]::Max(1.0,($maxX - $minX)),
                    [float][Math]::Max(1.0,($maxY - $minY))
                ))
            }
        }

        return [PSCustomObject]@{
            Text = [string]$result.StrRes
            Lines = @($lines)
        }
    }
    catch{
        return $emptyResult
    }
}

function Run-OCR($bmp){

    if(!$bmp){ return "" }

    $temp = Join-Path $env:TEMP ("ocr_text_{0}.png" -f ([guid]::NewGuid().ToString("N")))
    try{
        $bmp.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)

        $windowsText = Run-WindowsOcrTextFromImagePath $temp
        if(-not [string]::IsNullOrWhiteSpace([string]$windowsText)){
            return $windowsText
        }

        return (Run-RapidOcrTextFromImagePath $temp)
    }
    finally{
        try{
            if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }
}

function Run-FastOcr($bmp){

    if(!$bmp){ return "" }

    $temp = Join-Path $env:TEMP ("ocr_fast_{0}.png" -f ([guid]::NewGuid().ToString("N")))
    try{
        $bmp.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)
        return (Run-RapidOcrTextFromImagePath $temp)
    }
    finally{
        try{
            if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }
}

function Prepare-FastOcrCropBitmap($bmp){

    if(!$bmp){ return $null }
    if(-not (Initialize-OpenCvSharpForAutoOcr)){ return $null }

    $tempIn = Join-Path $env:TEMP ("ocr_fast_pre_in_{0}.png" -f ([guid]::NewGuid().ToString("N")))
    $tempOut = Join-Path $env:TEMP ("ocr_fast_pre_out_{0}.png" -f ([guid]::NewGuid().ToString("N")))

    $src = $null
    $bin = $null
    $horizontal = $null
    $vertical = $null
    $lineMask = $null
    $glyphMask = $null
    $out = $null
    $kernelH = $null
    $kernelV = $null

    try{
        $bmp.Save($tempIn,[System.Drawing.Imaging.ImageFormat]::Png)
        $src = [OpenCvSharp.Cv2]::ImRead($tempIn,[OpenCvSharp.ImreadModes]::Grayscale)
        if(!$src -or $src.Empty()){ return $null }

        $bin = New-Object OpenCvSharp.Mat
        [void][OpenCvSharp.Cv2]::Threshold($src,$bin,0,255,([OpenCvSharp.ThresholdTypes]::BinaryInv -bor [OpenCvSharp.ThresholdTypes]::Otsu))

        $horizontal = New-Object OpenCvSharp.Mat
        $vertical = New-Object OpenCvSharp.Mat
        $lineMask = New-Object OpenCvSharp.Mat
        $glyphMask = New-Object OpenCvSharp.Mat
        $out = New-Object OpenCvSharp.Mat

        # Manual red-crop cleanup: remove only very long drawing strokes.
        # Keep kernels conservative so decimal dots and digit stems survive.
        $hLen = [Math]::Max(28,[int]($src.Width * 0.45))
        $vLen = [Math]::Max(40,[int]($src.Height * 0.70))
        $kernelH = [OpenCvSharp.Cv2]::GetStructuringElement([OpenCvSharp.MorphShapes]::Rect,(New-Object OpenCvSharp.Size($hLen,1)))
        $kernelV = [OpenCvSharp.Cv2]::GetStructuringElement([OpenCvSharp.MorphShapes]::Rect,(New-Object OpenCvSharp.Size(1,$vLen)))

        [void][OpenCvSharp.Cv2]::MorphologyEx($bin,$horizontal,[OpenCvSharp.MorphTypes]::Open,$kernelH)
        [void][OpenCvSharp.Cv2]::MorphologyEx($bin,$vertical,[OpenCvSharp.MorphTypes]::Open,$kernelV)
        [void][OpenCvSharp.Cv2]::BitwiseOr($horizontal,$vertical,$lineMask)
        [void][OpenCvSharp.Cv2]::Subtract($bin,$lineMask,$glyphMask)

        # Return OCR-friendly black text on white background.
        [void][OpenCvSharp.Cv2]::BitwiseNot($glyphMask,$out)
        [OpenCvSharp.Cv2]::ImWrite($tempOut,$out) | Out-Null

        $result = [Drawing.Bitmap]::FromFile($tempOut)
        return (New-Object Drawing.Bitmap $result)
    }
    catch{
        return $null
    }
    finally{
        foreach($m in @($src,$bin,$horizontal,$vertical,$lineMask,$glyphMask,$out,$kernelH,$kernelV)){
            try{ if($m){ $m.Dispose() } } catch{}
        }
        try{ if($result){ $result.Dispose() } } catch{}
        try{ if(Test-Path $tempIn){ Remove-Item -LiteralPath $tempIn -Force -ErrorAction SilentlyContinue } } catch{}
        try{ if(Test-Path $tempOut){ Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue } } catch{}
    }
}

function Run-OCRDetailed($bmp){

    $emptyResult = [PSCustomObject]@{
        Text = ""
        Lines = @()
    }

    if(!$bmp){ return $emptyResult }

    $temp = Join-Path $env:TEMP ("ocr_detail_{0}.png" -f ([guid]::NewGuid().ToString("N")))

    try{
        $bmp.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)

        $windowsResult = Run-WindowsOcrDetailedFromImagePath $temp
        if($windowsResult -and -not [string]::IsNullOrWhiteSpace([string]$windowsResult.Text)){
            return $windowsResult
        }

        return (Run-RapidOcrDetailedFromImagePath $temp)
    }
    finally{
        try{
            if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }
}

function Convert-RotatedOcrRectToSourceRect($ocrRect,$angle,$sourceWidth,$sourceHeight,$scale,$offsetX,$offsetY){

    if(!$ocrRect -or $scale -le 0){ return $null }

    $x = [double]$ocrRect.X
    $y = [double]$ocrRect.Y
    $w = [double]$ocrRect.Width
    $h = [double]$ocrRect.Height
    $scaledW = [double]$sourceWidth * [double]$scale
    $scaledH = [double]$sourceHeight * [double]$scale

    switch([int]$angle){
        90 {
            $sx = $y
            $sy = $scaledH - ($x + $w)
            $sw = $h
            $sh = $w
        }
        180 {
            $sx = $scaledW - ($x + $w)
            $sy = $scaledH - ($y + $h)
            $sw = $w
            $sh = $h
        }
        270 {
            $sx = $scaledW - ($y + $h)
            $sy = $x
            $sw = $h
            $sh = $w
        }
        default {
            $sx = $x
            $sy = $y
            $sw = $w
            $sh = $h
        }
    }

    $pad = [Math]::Max(5.0,(8.0 / [double]$scale))
    $left = [int][Math]::Floor($offsetX + ($sx / [double]$scale) - $pad)
    $top = [int][Math]::Floor($offsetY + ($sy / [double]$scale) - $pad)
    $right = [int][Math]::Ceiling($offsetX + (($sx + $sw) / [double]$scale) + $pad)
    $bottom = [int][Math]::Ceiling($offsetY + (($sy + $sh) / [double]$scale) + $pad)

    if($script:sourceBitmap){
        $left = [Math]::Max(0,$left)
        $top = [Math]::Max(0,$top)
        $right = [Math]::Min($script:sourceBitmap.Width,$right)
        $bottom = [Math]::Min($script:sourceBitmap.Height,$bottom)
    }

    return New-Object Drawing.Rectangle(
        $left,
        $top,
        [Math]::Max(1,($right - $left)),
        [Math]::Max(1,($bottom - $top))
    )
}

function Test-AutoOcrDimensionCandidate($rawText,$nominalText,[switch]$AllowBareInteger){

    if([string]::IsNullOrWhiteSpace([string]$rawText)){ return $false }
    if([string]::IsNullOrWhiteSpace([string]$nominalText)){ return $false }

    $raw = ([string]$rawText).ToUpperInvariant()
    $compact = $raw -replace '\s+',''

    if($raw -match 'DETAIL|SCALE|MATERIAL|PART|UNIT|DRAW|DRW|CHECK|DATE|IRISO|TOLERANCE|RECORD|PROJ|OPPOSITE|GATE|HRC|REV\.?REC|PRODUCT|PRODUC|Q''TY|NEW RELEASE|START ANGLE POINT|PART\s*NAME|PART\s*NO|DIE\s*NO|MR\.?|APP|MARK|3DR|3D\s*R|ANG|1\s*MM|PD\d+|CORE|LAM|DEO|KAMIJO|TOAN|JULY'){
        return $false
    }

    if((-not $AllowBareInteger) -and ($compact -match '^[0-9]+$')){ return $false }
    if($compact -match '^\d{1,2}[/-]\d{1,2}[/-]\d{2,4}$'){ return $false }
    if($compact -match '^\d{1,2}[A-Z]{3}\d{2,4}$'){ return $false }
    if($compact.Length -gt 28 -and $compact -notmatch '[\+\-±]'){ return $false }

    $nominal = ([string]$nominalText).ToUpperInvariant().Trim()
    if($nominal -match '^[\+\-]?0(?:\.0+)?$'){ return $false }
    if($nominal -match '^[RC][\+\-]?0+(?:\.0+)?$'){ return $false }
    if($nominal -match '^[RC]?\d{4}$'){ return $false }
    if($nominal -match '^[RC]?20\d{2}$'){ return $false }
    if($nominal -match '^[RC]1(?:\.0+)?$' -and $raw -notmatch '(?:\bR\s*1(?:\.0+)?\b|\bC\s*1(?:\.0+)?\b)'){ return $false }
    if($raw -match '^\s*[±+\-]' -and $nominal -match '^[\+\-]?(?:0?\.\d+)$'){
        $nominalValue = 0.0
        if([double]::TryParse(($nominal -replace '^[+]',''),[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$nominalValue)){
            if([Math]::Abs($nominalValue) -le 0.02){
                return $false
            }
        }
    }
    if($nominal -match '^[RC][-+]?\d*\.?\d+$'){ return $true }
    if($nominal -match '^\d+°\d+''\d+"$'){ return $true }
    if($nominal -match '[-+]?\d+(?:\.\d+)?°$'){ return $true }
    if($nominal -match '^\d+$' -and $raw -match '[\(\[]\s*' + [regex]::Escape($nominal) + '\s*[\)\]]'){ return $true }
    if($nominal -match '^\d+$' -and $raw -match '(?:[±]|[+\-]\s*0?\.\d+)'){ return $true }
    if($raw -match '[±]'){ return $true }
    if($raw -match '[\+\-]\s*0?\.\d+'){ return $true }
    if($raw -match '\d+\s*[°º]'){ return $true }
    if($nominal -match '[-+]?\d+\.\d+'){ return $true }

    return $false
}

function Test-AutoOcrInteriorBareIntegerRect($rect){

    if(!$rect -or !$script:sourceBitmap){ return $false }

    $centerX = [double]$rect.X + ([double]$rect.Width / 2.0)
    $centerY = [double]$rect.Y + ([double]$rect.Height / 2.0)
    $imgW = [double]$script:sourceBitmap.Width
    $imgH = [double]$script:sourceBitmap.Height
    if($imgW -le 0 -or $imgH -le 0){ return $false }

    # Bare integers are useful in mechanical drawings, but the outer border
    # also contains grid labels such as 1..6 / A..D. Keep the rescue path
    # limited to the drawing interior so we do not re-open those false positives.
    $insideOuterFrame = (
        $centerX -gt ($imgW * 0.06) -and
        $centerX -lt ($imgW * 0.94) -and
        $centerY -gt ($imgH * 0.06) -and
        $centerY -lt ($imgH * 0.94)
    )
    if(-not $insideOuterFrame){ return $false }
    if(Test-AutoOcrTitleBlockRect $rect){ return $false }

    return $true
}

function Test-AutoOcrTitleBlockRect($rect){

    if(!$rect -or !$script:sourceBitmap){ return $false }

    $centerX = [double]$rect.X + ([double]$rect.Width / 2.0)
    $centerY = [double]$rect.Y + ([double]$rect.Height / 2.0)
    $imgW = [double]$script:sourceBitmap.Width
    $imgH = [double]$script:sourceBitmap.Height

    if($imgW -le 0 -or $imgH -le 0){ return $false }

    return (
        ($centerY -ge ($imgH * 0.72) -and $centerX -ge ($imgW * 0.45)) -or
        ($centerY -ge ($imgH * 0.80)) -or
        ($centerX -ge ($imgW * 0.74) -and $centerY -ge ($imgH * 0.50))
    )
}

function Get-TightImageInkRect($image,$rect){

    if(!$image -or !$rect){ return $rect }

    $left = [Math]::Max(0,[int]$rect.X)
    $top = [Math]::Max(0,[int]$rect.Y)
    $right = [Math]::Min($image.Width,[int]$rect.Right)
    $bottom = [Math]::Min($image.Height,[int]$rect.Bottom)
    if(($right - $left) -le 4 -or ($bottom - $top) -le 4){ return $rect }

    $minX = $right
    $minY = $bottom
    $maxX = $left
    $maxY = $top
    $darkCount = 0
    $step = 1
    if((($right - $left) * ($bottom - $top)) -gt 90000){ $step = 2 }

    for($y = $top; $y -lt $bottom; $y += $step){
        for($x = $left; $x -lt $right; $x += $step){
            $pixel = $image.GetPixel($x,$y)
            $brightness = (([int]$pixel.R * 0.299) + ([int]$pixel.G * 0.587) + ([int]$pixel.B * 0.114))
            if($brightness -lt 150){
                $darkCount++
                if($x -lt $minX){ $minX = $x }
                if($y -lt $minY){ $minY = $y }
                if($x -gt $maxX){ $maxX = $x }
                if($y -gt $maxY){ $maxY = $y }
            }
        }
    }

    if($darkCount -le 2){ return $rect }

    $inkWidth = [Math]::Max(1,($maxX - $minX + 1))
    $inkHeight = [Math]::Max(1,($maxY - $minY + 1))
    $originalArea = [Math]::Max(1,(([int]$rect.Width) * ([int]$rect.Height)))
    $inkArea = [Math]::Max(1,($inkWidth * $inkHeight))
    $aspect = [double]([Math]::Max($inkWidth,$inkHeight)) / [double]([Math]::Max(1,[Math]::Min($inkWidth,$inkHeight)))

    if($inkArea -gt ($originalArea * 1.05)){ return $rect }
    if($aspect -gt 18.0 -and [Math]::Max($inkWidth,$inkHeight) -gt 180){ return $rect }

    $pad = [int][Math]::Max(4,[Math]::Min(14,([Math]::Max($inkWidth,$inkHeight) * 0.08)))
    $tightLeft = [Math]::Max(0,($minX - $pad))
    $tightTop = [Math]::Max(0,($minY - $pad))
    $tightRight = [Math]::Min($image.Width,($maxX + $pad + 1))
    $tightBottom = [Math]::Min($image.Height,($maxY + $pad + 1))

    if(($tightRight - $tightLeft) -lt 4 -or ($tightBottom - $tightTop) -lt 4){ return $rect }

    return New-Object Drawing.Rectangle(
        [int]$tightLeft,
        [int]$tightTop,
        [int]($tightRight - $tightLeft),
        [int]($tightBottom - $tightTop)
    )
}

function Get-AutoOcrCandidateScore($candidate){

    if(!$candidate){ return 0 }

    $score = 0
    $nominal = ([string]$candidate.Nominal).ToUpperInvariant().Trim()
    $raw = ([string]$candidate.RawText).ToUpperInvariant()
    $source = ""
    if($candidate.PSObject.Properties.Name -contains 'Source'){
        $source = ([string]$candidate.Source).Trim()
    }
    $tolerance = $null
    if($candidate.PSObject.Properties.Name -contains 'Tolerance'){
        $tolerance = $candidate.Tolerance
    }

    if($nominal -match '\d+\.\d+'){ $score += 12 }
    if($nominal -match '^\d+$' -and $raw -match '[\(\[]\s*' + [regex]::Escape($nominal) + '\s*[\)\]]'){ $score += 10 }
    if($nominal -match '^\d+$' -and $raw -match '(?:[±]|[+\-]\s*0?\.\d+)'){ $score += 9 }
    if($nominal -match '^[RC]\d+\.\d+$'){ $score += 8 }
    if($raw -match '[±]'){ $score += 8 }
    if($raw -match '[+\-]\s*0?\.\d+'){ $score += 6 }
    if($raw -match '\d+\s*[°º]'){ $score += 5 }
    if($raw -match '\b(?:\d+\s*[-X×]\s*)?[RC]?\d+\.\d+'){ $score += 4 }
    if($source -eq 'PdfTextLayer'){ $score += 10 }
    if($source -eq 'PdfTextLayer' -and (Test-ExplicitToleranceText $raw)){ $score += 18 }
    if(
        $tolerance -and
        $tolerance.Detected -and
        (
            [Math]::Abs([double]$tolerance.TolMinus) -gt 0 -or
            [Math]::Abs([double]$tolerance.TolPlus) -gt 0
        )
    ){
        $score += 12
    }
    if($raw -match '\+\-'){ $score -= 10 }
    if($nominal -match '^[RC]?\d+$'){ $score -= 8 }
    if($nominal -match '^[RC]?0+(?:\.0+)?$'){ $score -= 40 }
    if($candidate.Rect){
        $area = [double]$candidate.Rect.Width * [double]$candidate.Rect.Height
        if($area -gt 0){ $score += [Math]::Min(8,[Math]::Log10($area)) }
    }
    $score += (Get-AdaptiveDetectorBias $candidate)

    return [double]$score
}

function Test-AutoOcrContainedDuplicate($candidate,$existingCandidates){

    if(!$candidate -or !$candidate.Rect){ return $false }

    foreach($existing in @($existingCandidates)){
        if(!$existing -or !$existing.Rect){ continue }

        $left = [Math]::Max($existing.Rect.Left,$candidate.Rect.Left)
        $top = [Math]::Max($existing.Rect.Top,$candidate.Rect.Top)
        $right = [Math]::Min($existing.Rect.Right,$candidate.Rect.Right)
        $bottom = [Math]::Min($existing.Rect.Bottom,$candidate.Rect.Bottom)
        $interArea = [Math]::Max(0,($right - $left)) * [Math]::Max(0,($bottom - $top))
        if($interArea -le 0){ continue }

        $candidateArea = [Math]::Max(1,([double]$candidate.Rect.Width * [double]$candidate.Rect.Height))
        $existingArea = [Math]::Max(1,([double]$existing.Rect.Width * [double]$existing.Rect.Height))
        $candidateCovered = $interArea / $candidateArea
        $existingCovered = $interArea / $existingArea

        $candidateScore = Get-AutoOcrCandidateScore $candidate
        $existingScore = Get-AutoOcrCandidateScore $existing
        $candidateNominal = ([string]$candidate.Nominal).ToUpperInvariant().Trim()
        $existingNominal = ([string]$existing.Nominal).ToUpperInvariant().Trim()
        $candidateLooksPartialZero = ($candidateNominal -match '^[RC]?0+(?:\.0+)?$')

        if($candidateLooksPartialZero -and $candidateCovered -gt 0.35){ return $true }
        if($candidateCovered -gt 0.72 -and $existingArea -ge ($candidateArea * 1.45)){ return $true }
        if($candidateArea -lt 18000 -and $candidateCovered -gt 0.52 -and $existingArea -ge ($candidateArea * 2.2)){ return $true }
        if($candidateCovered -gt 0.82 -and $existingArea -ge ($candidateArea * 1.15) -and $existingScore -ge ($candidateScore - 2)){ return $true }
        if($candidateCovered -gt 0.55 -and $existingCovered -gt 0.55 -and $existingScore -gt ($candidateScore + 4)){ return $true }
    }

    return $false
}

function Compress-AutoOcrCandidates($candidates){

    $kept = @()
    foreach($candidate in @($candidates | Sort-Object @{ Expression = { Get-AutoOcrCandidateScore $_ }; Descending = $true }, @{ Expression = { if($_.Rect){ [double]$_.Rect.Width * [double]$_.Rect.Height } else { 0 } }; Descending = $true })){
        if(!$candidate){ continue }
        if(Test-AutoOcrDuplicateCandidate $candidate $kept){ continue }
        if(Test-AutoOcrContainedDuplicate $candidate $kept){ continue }
        $kept += $candidate
    }

    return @(
        $kept |
        Sort-Object @{ Expression = { $_.Rect.Y }; Descending = $false }, @{ Expression = { $_.Rect.X }; Descending = $false }
    )
}

function Test-AutoOcrDuplicateCandidate($candidate,$existingCandidates){

    foreach($existing in @($existingCandidates)){
        if(!$existing -or !$existing.Rect -or !$candidate -or !$candidate.Rect){ continue }

        $sameNominal = ([string]$existing.Nominal -eq [string]$candidate.Nominal)
        $candidateNominal = ([string]$candidate.Nominal).Trim()
        $existingNominal = ([string]$existing.Nominal).Trim()
        $dx = (($existing.Rect.X + ($existing.Rect.Width / 2.0)) - ($candidate.Rect.X + ($candidate.Rect.Width / 2.0)))
        $dy = (($existing.Rect.Y + ($existing.Rect.Height / 2.0)) - ($candidate.Rect.Y + ($candidate.Rect.Height / 2.0)))
        $distance = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))

        $left = [Math]::Max($existing.Rect.Left,$candidate.Rect.Left)
        $top = [Math]::Max($existing.Rect.Top,$candidate.Rect.Top)
        $right = [Math]::Min($existing.Rect.Right,$candidate.Rect.Right)
        $bottom = [Math]::Min($existing.Rect.Bottom,$candidate.Rect.Bottom)
        $intersection = [Math]::Max(0,($right - $left)) * [Math]::Max(0,($bottom - $top))
        $smallerArea = [Math]::Max(1,[Math]::Min(($existing.Rect.Width * $existing.Rect.Height),($candidate.Rect.Width * $candidate.Rect.Height)))
        $candidateArea = [Math]::Max(1,([double]$candidate.Rect.Width * [double]$candidate.Rect.Height))
        $existingArea = [Math]::Max(1,([double]$existing.Rect.Width * [double]$existing.Rect.Height))
        $overlapRatio = $intersection / $smallerArea

        if($sameNominal -and ($distance -lt 45 -or $overlapRatio -gt 0.35)){
            return $true
        }
        if($sameNominal -and $intersection -gt 0 -and $candidateArea -lt ($existingArea * 0.55) -and ($intersection / $candidateArea) -gt 0.45){
            return $true
        }
        if(
            $candidateNominal -match '^\d+\.\d+$' -and
            $existingNominal -match '^\d+\.\d+$' -and
            $candidateNominal -ne $existingNominal -and
            $overlapRatio -gt 0.40
        ){
            $candidateValue = 0.0
            $existingValue = 0.0
            if(
                [double]::TryParse($candidateNominal,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$candidateValue) -and
                [double]::TryParse($existingNominal,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$existingValue) -and
                [Math]::Abs($candidateValue - $existingValue) -lt 0.35
            ){
                return $true
            }
        }
    }

    return $false
}

function Get-AutoOcrScale($width,$height){

    $maxDimension = 2500
    $largest = [Math]::Max([int]$width,[int]$height)
    if($largest -le 0){ return 1 }

    $scale = [Math]::Floor($maxDimension / [double]$largest)
    if($scale -lt 1){ $scale = 1 }
    if($scale -gt 4){ $scale = 4 }
    return [int]$scale
}

function Get-AutoOcrToleranceSearchRect($candidate){

    if(!$candidate -or !$candidate.Rect -or !$script:sourceBitmap){ return $null }

    $rect = $candidate.Rect
    $angle = [int]$candidate.Angle
    $padX = [int][Math]::Max(90,[Math]::Min(180,($rect.Width * 2.0)))
    $padY = [int][Math]::Max(70,[Math]::Min(170,($rect.Height * 2.0)))

    if($angle -eq 90 -or $angle -eq 270){
        $padX = [int][Math]::Max(85,[Math]::Min(160,($rect.Width * 4.0)))
        $padY = [int][Math]::Max(45,[Math]::Min(130,($rect.Height * 0.8)))
    }

    $left = [Math]::Max(0,($rect.X - $padX))
    $top = [Math]::Max(0,($rect.Y - $padY))
    $right = [Math]::Min($script:sourceBitmap.Width,($rect.Right + $padX))
    $bottom = [Math]::Min($script:sourceBitmap.Height,($rect.Bottom + $padY))

    return New-Object Drawing.Rectangle(
        [int]$left,
        [int]$top,
        [int][Math]::Max(1,($right - $left)),
        [int][Math]::Max(1,($bottom - $top))
    )
}

function Test-ExplicitToleranceText($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return $false }

    $normalized = Normalize-ToleranceOcrText $text
    return ($normalized -match '(?:[±]|[+\-]\s*(?:0?\.\d+|0\d{3}|\d+\.\d+)|\bR\s*\d*\.?\d+\s*MAX\b)')
}

function Normalize-PdfTextLayerText($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return "" }

    $value = [System.Net.WebUtility]::HtmlDecode([string]$text)
    $value = $value -replace 'ą','±'
    $value = $value -replace 'Ą','±'
    $value = $value -replace 'º','°'
    $value = $value -replace ',', '.'
    $value = $value -replace '\s+',' '
    return $value.Trim()
}

function Convert-PdfRectToImageRect($pdfRect,$pageWidth,$pageHeight){

    if(!$pdfRect -or !$script:sourceBitmap){ return $null }
    if($pageWidth -le 0 -or $pageHeight -le 0){ return $null }

    $scaleX = [double]$script:sourceBitmap.Width / [double]$pageWidth
    $scaleY = [double]$script:sourceBitmap.Height / [double]$pageHeight
    $pad = [Math]::Max(6.0,[Math]::Min(18.0,([Math]::Max(($pdfRect.XMax - $pdfRect.XMin),($pdfRect.YMax - $pdfRect.YMin)) * $scaleX * 0.18)))

    $left = [int][Math]::Floor(($pdfRect.XMin * $scaleX) - $pad)
    $top = [int][Math]::Floor(($pdfRect.YMin * $scaleY) - $pad)
    $right = [int][Math]::Ceiling(($pdfRect.XMax * $scaleX) + $pad)
    $bottom = [int][Math]::Ceiling(($pdfRect.YMax * $scaleY) + $pad)

    $left = [Math]::Max(0,$left)
    $top = [Math]::Max(0,$top)
    $right = [Math]::Min($script:sourceBitmap.Width,$right)
    $bottom = [Math]::Min($script:sourceBitmap.Height,$bottom)

    return New-Object Drawing.Rectangle(
        $left,
        $top,
        [Math]::Max(1,($right - $left)),
        [Math]::Max(1,($bottom - $top))
    )
}

function Convert-PdfWordMatchToRecord($wordMatch,$culture){

    if(!$wordMatch){ return $null }

    $attrs = $wordMatch.Groups["attrs"].Value
    $attrMatch = [regex]::Match($attrs,'xMin="(?<x1>[-0-9.]+)"\s+yMin="(?<y1>[-0-9.]+)"\s+xMax="(?<x2>[-0-9.]+)"\s+yMax="(?<y2>[-0-9.]+)"')
    if(!$attrMatch.Success){ return $null }

    $text = Normalize-PdfTextLayerText $wordMatch.Groups["text"].Value
    if([string]::IsNullOrWhiteSpace($text)){ return $null }

    return [PSCustomObject]@{
        Text = $text
        XMin = [double]::Parse($attrMatch.Groups["x1"].Value,$culture)
        YMin = [double]::Parse($attrMatch.Groups["y1"].Value,$culture)
        XMax = [double]::Parse($attrMatch.Groups["x2"].Value,$culture)
        YMax = [double]::Parse($attrMatch.Groups["y2"].Value,$culture)
    }
}

function Get-PdfWordGroupRect($words){

    $wordList = @($words)
    if($wordList.Count -le 0){ return $null }

    return [PSCustomObject]@{
        XMin = (@($wordList | ForEach-Object { [double]$_.XMin }) | Measure-Object -Minimum).Minimum
        YMin = (@($wordList | ForEach-Object { [double]$_.YMin }) | Measure-Object -Minimum).Minimum
        XMax = (@($wordList | ForEach-Object { [double]$_.XMax }) | Measure-Object -Maximum).Maximum
        YMax = (@($wordList | ForEach-Object { [double]$_.YMax }) | Measure-Object -Maximum).Maximum
    }
}

function Get-PdfRectUnion($rects){

    $rectList = @($rects | Where-Object { $_ })
    if($rectList.Count -le 0){ return $null }

    return [PSCustomObject]@{
        XMin = (@($rectList | ForEach-Object { [double]$_.XMin }) | Measure-Object -Minimum).Minimum
        YMin = (@($rectList | ForEach-Object { [double]$_.YMin }) | Measure-Object -Minimum).Minimum
        XMax = (@($rectList | ForEach-Object { [double]$_.XMax }) | Measure-Object -Maximum).Maximum
        YMax = (@($rectList | ForEach-Object { [double]$_.YMax }) | Measure-Object -Maximum).Maximum
    }
}

function Get-PdfTextLayerAngleDmsAt($blocks,$startIndex){

    if(!$blocks -or $startIndex -lt 0 -or $startIndex -ge $blocks.Count){ return $null }

    $startBlock = $blocks[$startIndex]
    if(!$startBlock -or !$startBlock.Rect){ return $null }

    $startText = Normalize-PdfTextLayerText $startBlock.Text
    $startCompact = $startText -replace '\s+',''
    $deg = $null
    $min = $null
    $minuteBlock = $null
    $minuteSecondBlock = $null
    $minuteSecondIndex = $null
    $secondPrefix = $null

    if($startCompact -match '^(?:\d+\-)?(?<deg>\d+)°(?<min>\d+)$'){
        $deg = $Matches['deg']
        $min = $Matches['min']
    }
    elseif($startCompact -match '^(?:\d+\-)?(?<deg>\d+)°$'){
        $deg = $Matches['deg']

        $minuteSecondCandidates = @()
        for($i = 0; $i -lt $blocks.Count; $i++){
            if($i -eq $startIndex){ continue }
            $candidateBlock = $blocks[$i]
            if(!$candidateBlock -or !$candidateBlock.Rect){ continue }
            $candidateText = (Normalize-PdfTextLayerText $candidateBlock.Text) -replace '\s+',''
            if($candidateText -notmatch '^(?<min>\d+)(?:''|′)(?<secPrefix>\d+)$'){ continue }

            $dx = [Math]::Abs((([double]$candidateBlock.Rect.XMin + [double]$candidateBlock.Rect.XMax) / 2.0) - (([double]$startBlock.Rect.XMin + [double]$startBlock.Rect.XMax) / 2.0))
            $dy = [Math]::Abs((([double]$candidateBlock.Rect.YMin + [double]$candidateBlock.Rect.YMax) / 2.0) - (([double]$startBlock.Rect.YMin + [double]$startBlock.Rect.YMax) / 2.0))
            if($dx -le 45.0 -and $dy -le 45.0){
                $minuteSecondCandidates += [PSCustomObject]@{
                    Index = $i
                    Block = $candidateBlock
                    Minute = $Matches['min']
                    SecondPrefix = $Matches['secPrefix']
                    Distance = ($dx + $dy)
                }
            }
        }

        if($minuteSecondCandidates.Count -le 0){ return $null }
        $bestMinuteSecond = @($minuteSecondCandidates | Sort-Object Distance | Select-Object -First 1)[0]
        $min = $bestMinuteSecond.Minute
        $secondPrefix = $bestMinuteSecond.SecondPrefix
        $minuteSecondBlock = $bestMinuteSecond.Block
        $minuteSecondIndex = [int]$bestMinuteSecond.Index
    }
    elseif($startCompact -match '^(?:\d+\-)(?<deg>\d+)$'){
        $deg = $Matches['deg']

        $minuteCandidates = @()
        for($i = 0; $i -lt $blocks.Count; $i++){
            if($i -eq $startIndex){ continue }
            $candidateBlock = $blocks[$i]
            if(!$candidateBlock -or !$candidateBlock.Rect){ continue }
            $candidateText = (Normalize-PdfTextLayerText $candidateBlock.Text) -replace '\s+',''
            if($candidateText -notmatch '^°(?<min>\d+)$'){ continue }

            $dx = [Math]::Abs((([double]$candidateBlock.Rect.XMin + [double]$candidateBlock.Rect.XMax) / 2.0) - (([double]$startBlock.Rect.XMin + [double]$startBlock.Rect.XMax) / 2.0))
            $dy = [Math]::Abs((([double]$candidateBlock.Rect.YMin + [double]$candidateBlock.Rect.YMax) / 2.0) - (([double]$startBlock.Rect.YMin + [double]$startBlock.Rect.YMax) / 2.0))
            if($dx -le 35.0 -and $dy -le 45.0){
                $minuteCandidates += [PSCustomObject]@{
                    Index = $i
                    Block = $candidateBlock
                    Minute = $Matches['min']
                    Distance = ($dx + $dy)
                }
            }
        }

        if($minuteCandidates.Count -le 0){ return $null }
        $bestMinute = @($minuteCandidates | Sort-Object Distance | Select-Object -First 1)[0]
        $min = $bestMinute.Minute
        $minuteBlock = $bestMinute.Block
    }
    else{
        return $null
    }

    $anchorBlock = $startBlock
    if($minuteBlock){ $anchorBlock = $minuteBlock }
    if($minuteSecondBlock){ $anchorBlock = $minuteSecondBlock }
    $secondCandidates = @()
    for($i = 0; $i -lt $blocks.Count; $i++){
        if($i -eq $startIndex){ continue }
        $candidateBlock = $blocks[$i]
        if(!$candidateBlock -or !$candidateBlock.Rect){ continue }
        $candidateText = (Normalize-PdfTextLayerText $candidateBlock.Text) -replace '\s+',''
        $secondValue = $null
        if($null -ne $secondPrefix){
            if($candidateText -notmatch '^(?<secSuffix>\d+)(?:"|″)$'){ continue }
            $secondValue = [string]$secondPrefix + [string]$Matches['secSuffix']
        }
        else{
            if($candidateText -notmatch '^(?:"|″)?(?:''|′)(?<sec>\d+)(?:"|″)?$'){ continue }
            $secondValue = $Matches['sec']
        }

        $dx = [Math]::Abs((([double]$candidateBlock.Rect.XMin + [double]$candidateBlock.Rect.XMax) / 2.0) - (([double]$anchorBlock.Rect.XMin + [double]$anchorBlock.Rect.XMax) / 2.0))
        $dy = [Math]::Abs((([double]$candidateBlock.Rect.YMin + [double]$candidateBlock.Rect.YMax) / 2.0) - (([double]$anchorBlock.Rect.YMin + [double]$anchorBlock.Rect.YMax) / 2.0))
        if($dx -le 35.0 -and $dy -le 45.0){
            $secondCandidates += [PSCustomObject]@{
                Index = $i
                Block = $candidateBlock
                Second = $secondValue
                Distance = ($dx + $dy)
            }
        }
    }

    if($secondCandidates.Count -le 0){ return $null }
    $bestSecond = @($secondCandidates | Sort-Object Distance | Select-Object -First 1)[0]

    $partBlocks = @($startBlock)
    $usedIndexes = @($startIndex)
    if($minuteBlock){
        $partBlocks += $minuteBlock
        $usedIndexes += [int]$bestMinute.Index
    }
    if($minuteSecondBlock){
        $partBlocks += $minuteSecondBlock
        $usedIndexes += [int]$minuteSecondIndex
    }
    $partBlocks += $bestSecond.Block
    $usedIndexes += [int]$bestSecond.Index

    $nominal = ('{0}°{1}''{2}"' -f $deg,$min,$bestSecond.Second)
    $text = Normalize-PdfTextLayerText (($partBlocks | Sort-Object { [double]$_.Rect.YMin }, { [double]$_.Rect.XMin } | ForEach-Object { $_.Text }) -join "")
    $rect = Get-PdfRectUnion (@($partBlocks | ForEach-Object { $_.Rect }))
    if(!$rect){ return $null }

    return [PSCustomObject]@{
        Text = $text
        Nominal = $nominal
        Rect = $rect
        UsedIndexes = @($usedIndexes | Sort-Object -Unique)
        Tolerance = $null
    }

}

function Get-PdfTextLayerBlocks($pdfPath,$pageNumber){

    if([string]::IsNullOrWhiteSpace([string]$pdfPath) -or !(Test-Path $pdfPath)){ return @() }

    $pdftotext = Get-Command pdftotext -ErrorAction SilentlyContinue
    if(!$pdftotext){ throw "pdftotext not found. Install Poppler to use Auto Map PDF." }

    $tempPath = Join-Path $env:TEMP ("ocrtool_bbox_{0}.html" -f ([guid]::NewGuid().ToString("N")))
    try{
        & $pdftotext.Source -f $pageNumber -l $pageNumber -bbox-layout $pdfPath $tempPath 2>$null
        if(!(Test-Path $tempPath)){ return @() }

        $content = [System.IO.File]::ReadAllText($tempPath,[System.Text.Encoding]::UTF8)
        $pageMatch = [regex]::Match($content,'<page\s+width="(?<w>[-0-9.]+)"\s+height="(?<h>[-0-9.]+)"','IgnoreCase')
        if(!$pageMatch.Success){ return @() }

        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $pageWidth = [double]::Parse($pageMatch.Groups["w"].Value,$culture)
        $pageHeight = [double]::Parse($pageMatch.Groups["h"].Value,$culture)
        $blocks = @()

        foreach($blockMatch in [regex]::Matches($content,'<block\s+(?<attrs>[^>]*)>(?<body>.*?)</block>','Singleline')){
            $attrs = $blockMatch.Groups["attrs"].Value
            $body = $blockMatch.Groups["body"].Value
            $attrMatch = [regex]::Match($attrs,'xMin="(?<x1>[-0-9.]+)"\s+yMin="(?<y1>[-0-9.]+)"\s+xMax="(?<x2>[-0-9.]+)"\s+yMax="(?<y2>[-0-9.]+)"')
            if(!$attrMatch.Success){ continue }

            $words = @()
            $wordRecords = @()
            foreach($wordMatch in [regex]::Matches($body,'<word\s+(?<attrs>[^>]*)>(?<text>.*?)</word>','Singleline')){
                $wordRecord = Convert-PdfWordMatchToRecord $wordMatch $culture
                if($wordRecord){
                    $wordRecords += $wordRecord
                    $words += $wordRecord.Text
                }
            }
            if($words.Count -le 0){ continue }

            $blocks += [PSCustomObject]@{
                Text = Normalize-PdfTextLayerText ($words -join " ")
                Rect = [PSCustomObject]@{
                    XMin = [double]::Parse($attrMatch.Groups["x1"].Value,$culture)
                    YMin = [double]::Parse($attrMatch.Groups["y1"].Value,$culture)
                    XMax = [double]::Parse($attrMatch.Groups["x2"].Value,$culture)
                    YMax = [double]::Parse($attrMatch.Groups["y2"].Value,$culture)
                }
                PageWidth = $pageWidth
                PageHeight = $pageHeight
                Words = @($wordRecords)
            }
        }

        return @($blocks)
    }
    finally{
        try{
            if(Test-Path $tempPath){ Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }
}

function Test-PdfTextLayerDimensionBlock($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return $false }

    $value = Normalize-PdfTextLayerText $text
    if(Test-PdfTextLayerIgnoredBlock $value){ return $false }
    if($value -match 'DETAIL|SCALE|MATERIAL|PART|UNIT|DRAW|DRW|CHECK|DATE|IRISO|TOLERANCE|RECORD|PROJ|OPPOSITE|GATE|HRC|REV\.?REC|PRODUCT|Q''TY|NEW RELEASE|START ANGLE POINT|REQUEST|PCS|PD613|YW-|11002'){
        return $false
    }

    if($value -match '^\s*[A-D1-6]\s*$'){ return $false }
    if($value -match '^\s*\(?\s*\d+\s*\)?\s*$'){ return $false }
    if($value -match '(?:\d+\s*-\s*)?\d+\s*°\s*\d+\s*(?:''|′)\s*\d+'){ return $true }

    return ($value -match '(?:[RC]\s*\d*\.?\d+|\d+\.\d+°?|\d+°|C\s*\d*\.?\d+)')
}

function Test-PdfTextLayerIgnoredBlock($text){

    if([string]::IsNullOrWhiteSpace([string]$text)){ return $true }

    $value = Normalize-PdfTextLayerText $text

    # Tolerance table cells and title-block metadata are not inspectable dimensions.
    if($value -match '='){ return $true }
    if($value -match 'TOLERANCE|MATERIAL|PART\s*NO|PART\s*NAME|Q''TY|RECORD|REV\.?REC|DATE|DRAW|DRW|CHECK|APP|PROJ|UNIT|SCALE\s*:|DIE\s*NO|PRODUC\s*NO|PRODUCT\s*NO|NEW RELEASE|IRISO|HRC|PD613|YW-|11002'){
        return $true
    }

    return $false
}

function Normalize-DegreeNominalSign($nominal){
    $value = ([string]$nominal).Trim()
    if([string]::IsNullOrWhiteSpace($value)){ return "" }
    if($value -notmatch '°'){ return $value }

    $value = $value -replace '^\+\s*',''
    $value = $value -replace '^\-\s*',''
    $value = $value -replace '^\.([0-9]+)\s*°$','0.$1°'
    return $value.Trim()
}

function Get-PdfTextLayerNominal($text){

    $value = Normalize-PdfTextLayerText $text
    $value = $value -replace 'MAX\b',''
    $value = $value -replace '(?i)DP\b',''
    $compact = $value -replace '\s+',''

    $stackedTokens = @(
        [regex]::Matches($value,'(?<![\d.])[-+]?\d*\.\d+(?![\d.])') |
        ForEach-Object { ([string]$_.Value).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if($stackedTokens.Count -ge 3){
        $firstValue = 0.0
        $middleValue = 0.0
        $lastValue = 0.0
        if(
            [double]::TryParse($stackedTokens[0],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$firstValue) -and
            [double]::TryParse($stackedTokens[1],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$middleValue) -and
            [double]::TryParse($stackedTokens[2],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$lastValue)
        ){
            if(
                $stackedTokens[2] -match '^[-±]' -and
                $stackedTokens[0] -notmatch '^[-±]' -and
                [Math]::Abs($middleValue) -ge 0.1 -and
                [Math]::Abs($firstValue) -lt [Math]::Abs($middleValue)
            ){
                return [string]$stackedTokens[1]
            }
        }
    }

    if($compact -match '(?i)^\d+[X×](?<nom>(?:[RC])?\d*\.\d+)$'){
        return (($Matches['nom'] -replace '\s+','').ToUpperInvariant())
    }

    if($compact -match '^(?:\d+\-)?(?<deg>\d+)°(?<min>\d+)(?:''|′)(?<sec>\d+)(?:"|″)?$'){
        return (Normalize-DegreeNominalSign ('{0}°{1}''{2}"' -f $Matches['deg'],$Matches['min'],$Matches['sec']))
    }

    if($value -match '(?i)(?:^|\s)(?:\d+\s*-\s*)?(C\s*\d*\.?\d+)'){
        return (($Matches[1] -replace '\s+','').ToUpperInvariant())
    }
    if($value -match '(?i)(?:^|\s)(R\s*\d*\.?\d+)'){
        return (($Matches[1] -replace '\s+','').ToUpperInvariant())
    }
    if($value -match '(?:^|\s)(?:\d+\s*-\s*)?([-+]?\d+(?:\.\d+)?\s*°)'){
        return (Normalize-DegreeNominalSign ($Matches[1] -replace '\s+',''))
    }
    if($value -match '(?:^|\s)(?:\d+\s*-\s*)?([-+]?\d+\.\d+)(?:°)?'){
        return [string]$Matches[1]
    }

    return ""
}

function Get-PdfTextLayerTolerance($text,$nominal){

    $value = Normalize-PdfTextLayerText $text
    if($value -match '(?i)\bR\s*(\d*\.?\d+)\s*MAX\b'){
        $radiusMaxValue = 0.0
        if([double]::TryParse($Matches[1],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$radiusMaxValue)){
            return [PSCustomObject]@{
                Detected = $true
                TolMinus = -[Math]::Abs($radiusMaxValue)
                TolPlus = 0
                NormalizedText = $value
                ParseMode = "RadiusMax"
            }
        }
    }

    $nominalValue = [regex]::Escape([string]$nominal)
    if(-not [string]::IsNullOrWhiteSpace($nominalValue)){
        $value = [regex]::Replace($value,'(?<![\d.])' + $nominalValue + '(?![\d.])',' ',1)
    }

    $nominalDecimals = 0
    $nominalMatch = [regex]::Match(([string]$nominal).Trim(),'\.(\d+)')
    if($nominalMatch.Success){
        $nominalDecimals = [int]$nominalMatch.Groups[1].Value.Length
    }

    $stackedTokens = @(
        [regex]::Matches($value,'(?<![\d.])[-+]?\d*\.?\d+(?![\d.])') |
        ForEach-Object { ([string]$_.Value).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if($stackedTokens.Count -ge 2){
        $normalizedTokens = @()
        foreach($token in $stackedTokens){
            $tokenText = [string]$token
            if(
                $nominalDecimals -gt 0 -and
                $tokenText -match '^[+]?\d+$' -and
                $tokenText.Length -eq ($nominalDecimals + 1)
            ){
                $tokenText = $tokenText.Insert(1,'.')
            }
            elseif(
                $nominalDecimals -gt 0 -and
                $tokenText -match '^-\d+$' -and
                $tokenText.Length -eq ($nominalDecimals + 2)
            ){
                $tokenText = $tokenText.Insert(2,'.')
            }
            $normalizedTokens += $tokenText
        }

        $firstTokenValue = 0.0
        $secondTokenValue = 0.0
        if(
            [double]::TryParse($normalizedTokens[0],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$firstTokenValue) -and
            [double]::TryParse($normalizedTokens[1],[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$secondTokenValue)
        ){
            if($normalizedTokens[0] -notmatch '^[-±]' -and $normalizedTokens[1] -match '^[-±]'){
                return [PSCustomObject]@{
                    Detected = $true
                    TolMinus = [double]$secondTokenValue
                    TolPlus = [double]$firstTokenValue
                    NormalizedText = (($normalizedTokens -join ' ').Trim())
                    ParseMode = "PdfStackedUnsignedSigned"
                }
            }
            if($normalizedTokens[0] -match '^[-±]' -and $normalizedTokens[1] -notmatch '^[-±]'){
                return [PSCustomObject]@{
                    Detected = $true
                    TolMinus = [double]$firstTokenValue
                    TolPlus = [double]$secondTokenValue
                    NormalizedText = (($normalizedTokens -join ' ').Trim())
                    ParseMode = "PdfStackedSignedUnsigned"
                }
            }
        }
    }

    $value = $value -replace '\+\+','+ +'
    $value = $value -replace '--','- -'
    $value = $value -replace '±\s*([0-9]+(?:\.[0-9]+)?)','±$1'
    $parsed = Parse-ToleranceFull $value $nominal

    if($parsed -and $parsed.Detected -and (Test-ExplicitToleranceText $value)){
        return $parsed
    }

    return $null
}

function Test-ToleranceHasSignal($tolerance){
    if(!$tolerance -or -not $tolerance.Detected){ return $false }
    return (([double]$tolerance.TolMinus) -ne 0 -or ([double]$tolerance.TolPlus) -ne 0)
}

function Get-PreferredTolerance($existingTolerance,$rawText,$nominal){
    $parsedTolerance = $null
    if(-not [string]::IsNullOrWhiteSpace([string]$rawText)){
        $parsedTolerance = Parse-ToleranceFull $rawText $nominal
        if(-not ($parsedTolerance -and $parsedTolerance.Detected -and (Test-ExplicitToleranceText $rawText))){
            $parsedTolerance = $null
        }
    }

    if(Test-ToleranceHasSignal $parsedTolerance){ return $parsedTolerance }
    if(Test-ToleranceHasSignal $existingTolerance){ return $existingTolerance }
    if($parsedTolerance){ return $parsedTolerance }
    return $existingTolerance
}

function Split-PdfTextLayerBlockIntoDimensionGroups($block){

    if(!$block){ return @() }

    $words = @($block.Words)
    if($words.Count -le 0){ return @($block) }

    $blockRect = Get-PdfWordGroupRect $words
    if(!$blockRect){ return @($block) }

    $leftColumnLimit = [Math]::Max(8.0,(([double]$blockRect.XMax - [double]$blockRect.XMin) * 0.42))
    $blockHasToleranceSign = (@($words | Where-Object { (Normalize-PdfTextLayerText $_.Text) -match '^[+\-±ąĄ]' }).Count -gt 0)
    $nominalIndexes = @()
    for($i = 0; $i -lt $words.Count; $i++){
        $wordText = Normalize-PdfTextLayerText $words[$i].Text
        $isLeftColumnWord = ([double]$words[$i].XMin - [double]$blockRect.XMin) -le $leftColumnLimit
        if($isLeftColumnWord -and ($wordText -match '^(?:\d+\-)?(?:[RC])?\d+\.\d+°?$' -or $wordText -match '^(?:\d+\-)?C\d+\.\d+$')){
            $nominalText = Get-PdfTextLayerNominal $wordText
            if(-not [string]::IsNullOrWhiteSpace($nominalText)){
                $nominalValue = 0.0
                $isSmallToleranceValue = $false
                $plainNominal = ([string]$nominalText) -replace '^[RC]',''
                if([double]::TryParse($plainNominal,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$nominalValue)){
                    $isSmallToleranceValue = ($blockHasToleranceSign -and [Math]::Abs($nominalValue) -lt 0.1)
                }

                if(-not $isSmallToleranceValue){
                    $nominalIndexes += $i
                }
            }
        }
    }

    if($nominalIndexes.Count -le 1){ return @($block) }

    $groups = @()

    $nominalCenters = @()
    foreach($nominalIndex in $nominalIndexes){
        $nominalWord = $words[$nominalIndex]
        $nominalCenters += [PSCustomObject]@{
            Index = $nominalIndex
            CenterY = (([double]$nominalWord.YMin + [double]$nominalWord.YMax) / 2.0)
            Word = $nominalWord
        }
    }

    foreach($nominalCenter in $nominalCenters){
        $groupWords = @()

        foreach($word in $words){
            $wordCenterY = ([double]$word.YMin + [double]$word.YMax) / 2.0
            $nearest = $null
            $nearestDistance = [double]::PositiveInfinity

            foreach($candidateCenter in $nominalCenters){
                $distance = [Math]::Abs($wordCenterY - [double]$candidateCenter.CenterY)
                if($distance -lt $nearestDistance){
                    $nearestDistance = $distance
                    $nearest = $candidateCenter
                }
            }

            if($nearest -and [int]$nearest.Index -eq [int]$nominalCenter.Index){
                $groupWords += $word
            }
        }

        $groupWords = @($groupWords | Sort-Object XMin, YMin)

        if($groupWords.Count -le 0){ continue }

        $groupText = Normalize-PdfTextLayerText (($groupWords | ForEach-Object { $_.Text }) -join " ")
        $groupRect = Get-PdfWordGroupRect $groupWords
        if(!$groupRect){ continue }

        $groups += [PSCustomObject]@{
            Text = $groupText
            Rect = $groupRect
            PageWidth = $block.PageWidth
            PageHeight = $block.PageHeight
            Words = @($groupWords)
        }
    }

    if($groups.Count -le 0){ return @($block) }
    return @($groups)
}

function Get-PdfTextLayerDimensionLabels($block){

    if(!$block){ return @() }

    $splitBlocks = @(Split-PdfTextLayerBlockIntoDimensionGroups $block)
    $labels = @()

    foreach($splitBlock in $splitBlocks){
        $text = Normalize-PdfTextLayerText $splitBlock.Text
        if([string]::IsNullOrWhiteSpace($text)){ continue }
        if(-not (Test-PdfTextLayerDimensionBlock $text)){ continue }

        $nominal = Get-PdfTextLayerNominal $text
        if([string]::IsNullOrWhiteSpace($nominal)){ continue }
        if(-not (Test-AutoOcrDimensionCandidate $text $nominal)){ continue }

        $labels += [PSCustomObject]@{
            Text = $text
            Nominal = $nominal
            Tolerance = (Get-PdfTextLayerTolerance $text $nominal)
        }
    }

    return @($labels)
}

function Find-PdfTextLayerDimensionCandidates($blocks,$mapRect){

    $candidates = @()
    $skipBlockIndexes = @{}

    for($blockIndex = 0; $blockIndex -lt @($blocks).Count; $blockIndex++){
        if($skipBlockIndexes.ContainsKey($blockIndex)){ continue }

        $angleDms = Get-PdfTextLayerAngleDmsAt $blocks $blockIndex
        if($angleDms){
            $imageRect = Convert-PdfRectToImageRect $angleDms.Rect $blocks[$blockIndex].PageWidth $blocks[$blockIndex].PageHeight
            if($imageRect -and ((-not $mapRect) -or $imageRect.IntersectsWith($mapRect))){
                $candidate = [PSCustomObject]@{
                    Nominal = $angleDms.Nominal
                    RawText = $angleDms.Text
                    LabelText = $angleDms.Text
                    LabelNominal = $angleDms.Nominal
                    BboxText = $angleDms.Text
                    BboxItemIndex = 0
                    BboxItemCount = 1
                    Rect = $imageRect
                    Angle = 0
                    Tolerance = $angleDms.Tolerance
                    Source = "PdfTextLayer"
                }

                if(-not (Test-AutoOcrDuplicateCandidate $candidate $candidates)){
                    $candidates += $candidate
                }
            }

            foreach($usedIndex in @($angleDms.UsedIndexes)){
                $skipBlockIndexes[[int]$usedIndex] = $true
            }
            continue
        }

        $block = $blocks[$blockIndex]
        if(!$block){ continue }
        $text = Normalize-PdfTextLayerText $block.Text
        if(-not (Test-PdfTextLayerDimensionBlock $text)){ continue }

        $imageRect = Convert-PdfRectToImageRect $block.Rect $block.PageWidth $block.PageHeight
        if(!$imageRect){ continue }
        if($mapRect -and -not $imageRect.IntersectsWith($mapRect)){ continue }

        $labels = @(Get-PdfTextLayerDimensionLabels $block)
        for($labelIndex = 0; $labelIndex -lt $labels.Count; $labelIndex++){
            $label = $labels[$labelIndex]
            $candidate = [PSCustomObject]@{
                Nominal = $label.Nominal
                RawText = $label.Text
                LabelText = $label.Text
                LabelNominal = $label.Nominal
                BboxText = $text
                BboxItemIndex = $labelIndex
                BboxItemCount = $labels.Count
                Rect = $imageRect
                Angle = 0
                Tolerance = $label.Tolerance
                Source = "PdfTextLayer"
            }

            if(-not (Test-AutoOcrDuplicateCandidate $candidate $candidates)){
                $candidates += $candidate
            }
        }
    }

    return @(Compress-AutoOcrCandidates $candidates)
}

function Find-ImageOcrDimensionCandidates($mapRect){

    $candidates = @()
    if(!$script:sourceBitmap){ return @($candidates) }

    $scanRect = $mapRect
    if(!$scanRect){
        $scanRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
    }

    $left = [Math]::Max(0,[int]$scanRect.X)
    $top = [Math]::Max(0,[int]$scanRect.Y)
    $right = [Math]::Min($script:sourceBitmap.Width,[int]$scanRect.Right)
    $bottom = [Math]::Min($script:sourceBitmap.Height,[int]$scanRect.Bottom)
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if($width -le 20 -or $height -le 20){ return @($candidates) }

    $cropRect = New-Object Drawing.Rectangle($left,$top,$width,$height)
    $crop = $null
    $scaled = $null

    try{
        $crop = $script:sourceBitmap.Clone($cropRect,$script:sourceBitmap.PixelFormat)
        $scale = Get-AutoOcrScale $crop.Width $crop.Height
        $scaled = New-Object Drawing.Bitmap ([Math]::Max(1,($crop.Width * $scale))),([Math]::Max(1,($crop.Height * $scale)))
        $g = [Drawing.Graphics]::FromImage($scaled)
        try{
            $g.Clear([Drawing.Color]::White)
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($crop,0,0,$scaled.Width,$scaled.Height)
        }
        finally{
            $g.Dispose()
        }

        foreach($angle in @(Get-OcrPrimaryAngles)){
            $ocrBitmap = $null
            try{
                if($angle -eq 0){
                    $ocrBitmap = $scaled
                }
                else{
                    $ocrBitmap = Rotate-Bitmap $scaled $angle
                }

                $detail = Run-OCRDetailed $ocrBitmap
                foreach($line in @($detail.Lines)){
                    if(!$line -or [string]::IsNullOrWhiteSpace([string]$line.Text)){ continue }

                    $rawText = [string]$line.Text
                    $sourceRect = Convert-RotatedOcrRectToSourceRect $line.Rect $angle $crop.Width $crop.Height $scale $left $top
                    if(!$sourceRect){ continue }
                    $sourceRect = Get-TightImageInkRect $script:sourceBitmap $sourceRect
                    if($sourceRect.Width -lt 8 -or $sourceRect.Height -lt 8){ continue }
                    if($sourceRect.Width -gt ($script:sourceBitmap.Width * 0.35) -or $sourceRect.Height -gt ($script:sourceBitmap.Height * 0.35)){ continue }
                    if($mapRect -and -not $sourceRect.IntersectsWith($mapRect)){ continue }
                    if(Test-AutoOcrTitleBlockRect $sourceRect){ continue }

                    $resolved = Resolve-OcrTextAsMechanicalNominal $rawText $sourceRect
                    $nominal = [string]$resolved.Nominal
                    if([string]::IsNullOrWhiteSpace($nominal)){
                        Register-HardNegativeSample $sourceRect $rawText "resolve_empty" "ImageOcrAuto" @{
                            Angle = [int]$angle
                            ScanKind = "detailed-line"
                        }
                        continue
                    }
                    $allowInteriorBareInteger = (
                        ([string]$nominal -match '^[2-9]$') -and
                        (([string]$rawText -replace '\s+','') -match '^[2-9]$') -and
                        (Test-AutoOcrInteriorBareIntegerRect $sourceRect)
                    )
                    if(-not (Test-AutoOcrDimensionCandidate $rawText $nominal -AllowBareInteger:$allowInteriorBareInteger)){
                        Register-HardNegativeSample $sourceRect $rawText "candidate_rejected" "ImageOcrAuto" @{
                            Angle = [int]$angle
                            NominalGuess = [string]$nominal
                            ScanKind = "detailed-line"
                        }
                        continue
                    }

                    $candidate = [PSCustomObject]@{
                        Nominal = $nominal
                        RawText = $rawText
                        Rect = $sourceRect
                        Angle = [int]$angle
                        Tolerance = (Parse-ToleranceFull $rawText $nominal)
                        Source = "ImageOcrAuto"
                    }

                    if(
                        -not (Test-AutoOcrDuplicateCandidate $candidate $candidates) -and
                        -not (Test-AutoOcrContainedDuplicate $candidate $candidates)
                    ){
                        $candidates += $candidate
                    }
                }
            }
            finally{
                if($angle -ne 0 -and $ocrBitmap){
                    $ocrBitmap.Dispose()
                }
            }
        }
    }
    finally{
        if($scaled){ $scaled.Dispose() }
        if($crop){ $crop.Dispose() }
    }

    return @(
        $candidates |
        Sort-Object @{ Expression = { $_.Rect.Y }; Descending = $false }, @{ Expression = { $_.Rect.X }; Descending = $false }
    )
}

function New-AutoOcrClampedRect($x,$y,$w,$h,$baseLeft,$baseTop,$baseRight,$baseBottom){

    $left = [Math]::Max([int]$baseLeft,[int][Math]::Floor([double]$x))
    $top = [Math]::Max([int]$baseTop,[int][Math]::Floor([double]$y))
    $right = [Math]::Min([int]$baseRight,[int][Math]::Ceiling(([double]$x + [double]$w)))
    $bottom = [Math]::Min([int]$baseBottom,[int][Math]::Ceiling(([double]$y + [double]$h)))

    if(($right - $left) -le 20 -or ($bottom - $top) -le 20){ return $null }

    return New-Object Drawing.Rectangle(
        [int]$left,
        [int]$top,
        [int]($right - $left),
        [int]($bottom - $top)
    )
}

function Add-AutoOcrScanRect($scanRects,$rect,$label,$priority){

    if(!$scanRects -or !$rect){ return }

    $candidateArea = [double]$rect.Width * [double]$rect.Height
    if($candidateArea -le 0){ return }

    foreach($existing in @($scanRects)){
        if(!$existing -or !$existing.Rect){ continue }

        $existingRect = $existing.Rect
        $left = [Math]::Max($existingRect.Left,$rect.Left)
        $top = [Math]::Max($existingRect.Top,$rect.Top)
        $right = [Math]::Min($existingRect.Right,$rect.Right)
        $bottom = [Math]::Min($existingRect.Bottom,$rect.Bottom)
        $intersection = [Math]::Max(0,($right - $left)) * [Math]::Max(0,($bottom - $top))
        if($intersection -le 0){ continue }

        $existingArea = [double]$existingRect.Width * [double]$existingRect.Height
        $smallerArea = [Math]::Max(1.0,[Math]::Min($candidateArea,$existingArea))
        $sameSize = ([Math]::Abs($existingRect.Width - $rect.Width) -le 12 -and [Math]::Abs($existingRect.Height - $rect.Height) -le 12)
        if(($intersection / $smallerArea) -gt 0.86 -and $sameSize){
            return
        }
    }

    [void]$scanRects.Add([PSCustomObject]@{
        Rect = $rect
        Label = [string]$label
        Priority = [int]$priority
        Area = $candidateArea
    })
}

function Initialize-RapidOcrNetForAutoOcr{

    if($script:RapidOcrNetAutoOcrLoaded -and $script:RapidOcrNetEngine){ return $true }
    if($script:RapidOcrNetAutoOcrUnavailable){ return $false }
    if($PSVersionTable.PSEdition -ne "Core"){
        $script:RapidOcrNetAutoOcrUnavailable = $true
        return $false
    }

    try{
        $ocrRoot = Join-Path $script:AppRoot "lib\OcrAi"
        $nativeRoot = Join-Path $ocrRoot "Microsoft.ML.OnnxRuntime.1.24.3\runtimes\win-x64\native"
        $skiaNativeRoot = Join-Path $ocrRoot "SkiaSharp.NativeAssets.Win32\runtimes\win-x64\native"
        $modelRoot = Join-Path $ocrRoot "RapidOcrNet\models\v5"

        $requiredFiles = @(
            (Join-Path $nativeRoot "onnxruntime.dll"),
            (Join-Path $nativeRoot "onnxruntime_providers_shared.dll"),
            (Join-Path $skiaNativeRoot "libSkiaSharp.dll"),
            (Join-Path $ocrRoot "System.Numerics.Tensors\lib\net9.0\System.Numerics.Tensors.dll"),
            (Join-Path $ocrRoot "Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll"),
            (Join-Path $ocrRoot "SkiaSharp\lib\net8.0\SkiaSharp.dll"),
            (Join-Path $ocrRoot "Clipper2\lib\netstandard2.0\Clipper2Lib.dll"),
            (Join-Path $ocrRoot "RapidOcrNet\lib\net8.0\RapidOcrNet.dll"),
            (Join-Path $modelRoot "ch_PP-OCRv5_mobile_det.onnx"),
            (Join-Path $modelRoot "ch_ppocr_mobile_v2.0_cls_infer.onnx"),
            (Join-Path $modelRoot "latin_PP-OCRv5_rec_mobile_infer.onnx"),
            (Join-Path $modelRoot "ppocrv5_latin_dict.txt")
        )

        foreach($file in $requiredFiles){
            if(!(Test-Path $file)){
                $script:RapidOcrNetAutoOcrUnavailable = $true
                return $false
            }
        }

        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot "onnxruntime_providers_shared.dll")) | Out-Null
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot "onnxruntime.dll")) | Out-Null
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $skiaNativeRoot "libSkiaSharp.dll")) | Out-Null

        foreach($assemblyPath in @(
            (Join-Path $ocrRoot "System.Numerics.Tensors\lib\net9.0\System.Numerics.Tensors.dll"),
            (Join-Path $ocrRoot "Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll"),
            (Join-Path $ocrRoot "SkiaSharp\lib\net8.0\SkiaSharp.dll"),
            (Join-Path $ocrRoot "Clipper2\lib\netstandard2.0\Clipper2Lib.dll"),
            (Join-Path $ocrRoot "RapidOcrNet\lib\net8.0\RapidOcrNet.dll")
        )){
            Add-Type -Path $assemblyPath -ErrorAction Stop
        }

        $engine = [RapidOcrNet.RapidOcr]::new()
        $engine.InitModels(
            (Join-Path $modelRoot "ch_PP-OCRv5_mobile_det.onnx"),
            (Join-Path $modelRoot "ch_ppocr_mobile_v2.0_cls_infer.onnx"),
            (Join-Path $modelRoot "latin_PP-OCRv5_rec_mobile_infer.onnx"),
            (Join-Path $modelRoot "ppocrv5_latin_dict.txt"),
            0
        )

        $script:RapidOcrNetEngine = $engine
        $script:RapidOcrNetAutoOcrLoaded = $true
        return $true
    }
    catch{
        if($script:RapidOcrNetEngine){
            try{ $script:RapidOcrNetEngine.Dispose() } catch{}
        }
        $script:RapidOcrNetEngine = $null
        $script:RapidOcrNetAutoOcrUnavailable = $true
        return $false
    }
}

function Initialize-PaddleOcrOnnxForTextZones{

    if($script:PaddleOcrOnnxTextZoneLoaded -and $script:PaddleOcrOnnxEngine){ return $true }
    if($script:PaddleOcrOnnxTextZoneUnavailable){ return $false }

    try{
        $ocrRoot = Join-Path $script:AppRoot "lib\OcrAi"
        $nativeRoot = Join-Path $ocrRoot "Microsoft.ML.OnnxRuntime.1.24.3\runtimes\win-x64\native"
        $modelRoot = Join-Path $ocrRoot "PaddleOCR.Onnx\build\Models\inference"
        $emguNativeRoot = Join-Path $ocrRoot "Emgu.CV.runtime.windows\build\x64"

        $requiredFiles = @(
            (Join-Path $nativeRoot "onnxruntime.dll"),
            (Join-Path $nativeRoot "onnxruntime_providers_shared.dll"),
            (Join-Path $ocrRoot "Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll"),
            (Join-Path $ocrRoot "Emgu.CV\lib\netstandard2.0\Emgu.CV.Platform.NetStandard.dll"),
            (Join-Path $emguNativeRoot "cvextern.dll"),
            (Join-Path $ocrRoot "clipper_standard\lib\netstandard2.0\clipper.dll"),
            (Join-Path $ocrRoot "PaddleOCR.Onnx\lib\net6.0\PaddleOCR.Onnx.dll"),
            (Join-Path $modelRoot "ch_PP-OCRv3_det_infer.onnx"),
            (Join-Path $modelRoot "ch_ppocr_mobile_v2.0_cls_infer.onnx"),
            (Join-Path $modelRoot "ch_PP-OCRv3_rec_infer.onnx"),
            (Join-Path $modelRoot "ppocr_keys.txt")
        )

        foreach($file in $requiredFiles){
            if(!(Test-Path $file)){
                $script:PaddleOcrOnnxTextZoneUnavailable = $true
                return $false
            }
        }

        if($env:PATH -notlike ("*" + $emguNativeRoot + "*")){
            $env:PATH = $emguNativeRoot + ";" + $env:PATH
        }
        if($env:PATH -notlike ("*" + $nativeRoot + "*")){
            $env:PATH = $nativeRoot + ";" + $env:PATH
        }

        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot "onnxruntime_providers_shared.dll")) | Out-Null
        [System.Runtime.InteropServices.NativeLibrary]::Load((Join-Path $nativeRoot "onnxruntime.dll")) | Out-Null

        foreach($assemblyPath in @(
            (Join-Path $ocrRoot "Microsoft.ML.OnnxRuntime.Managed\lib\net8.0\Microsoft.ML.OnnxRuntime.dll"),
            (Join-Path $ocrRoot "Emgu.CV\lib\netstandard2.0\Emgu.CV.Platform.NetStandard.dll"),
            (Join-Path $ocrRoot "clipper_standard\lib\netstandard2.0\clipper.dll"),
            (Join-Path $ocrRoot "PaddleOCR.Onnx\lib\net6.0\PaddleOCR.Onnx.dll")
        )){
            Add-Type -Path $assemblyPath -ErrorAction Stop
        }

        $config = [PaddleOCR.Onnx.OCRModelConfig]::new()
        $config.det_infer = Join-Path $modelRoot "ch_PP-OCRv3_det_infer.onnx"
        $config.cls_infer = Join-Path $modelRoot "ch_ppocr_mobile_v2.0_cls_infer.onnx"
        $config.rec_infer = Join-Path $modelRoot "ch_PP-OCRv3_rec_infer.onnx"
        $config.keys = Join-Path $modelRoot "ppocr_keys.txt"

        $parameter = [PaddleOCR.Onnx.OCRParameter]::new()
        $parameter.use_custom_model = $true
        $parameter.DoAngle = $true
        $parameter.MostAngle = $true
        $parameter.BoxThresh = 0.18
        $parameter.BoxScoreThresh = 0.25
        $parameter.UnClipRatio = 1.8

        $script:PaddleOcrOnnxEngine = [PaddleOCR.Onnx.PaddleOCREngine]::new($config,$parameter)
        $script:PaddleOcrOnnxTextZoneLoaded = $true
        return $true
    }
    catch{
        if($script:PaddleOcrOnnxEngine){
            try{ $script:PaddleOcrOnnxEngine.Dispose() } catch{}
        }
        $script:PaddleOcrOnnxEngine = $null
        $script:PaddleOcrOnnxTextZoneUnavailable = $true
        return $false
    }
}

function Get-RapidOcrNetAutoOcrTextScanRects($baseRect){

    $results = @()
    if(!$script:sourceBitmap -or !$baseRect){ return @($results) }
    if(-not (Initialize-RapidOcrNetForAutoOcr)){ return @($results) }

    $left = [Math]::Max(0,[int]$baseRect.X)
    $top = [Math]::Max(0,[int]$baseRect.Y)
    $right = [Math]::Min($script:sourceBitmap.Width,[int]$baseRect.Right)
    $bottom = [Math]::Min($script:sourceBitmap.Height,[int]$baseRect.Bottom)
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if($width -le 30 -or $height -le 30){ return @($results) }

    $cropRect = New-Object Drawing.Rectangle($left,$top,$width,$height)
    $crop = $null
    $temp = Join-Path $env:TEMP ("ocrtool_rapidocr_zone_{0}.png" -f ([guid]::NewGuid().ToString("N")))

    try{
        $crop = $script:sourceBitmap.Clone($cropRect,$script:sourceBitmap.PixelFormat)
        $crop.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)

        $options = [RapidOcrNet.RapidOcrOptions]::Default
        $result = $script:RapidOcrNetEngine.Detect($temp,$options)
        if(!$result -or !$result.TextBlocks){ return @($results) }

        foreach($block in @($result.TextBlocks)){
            if(!$block -or !$block.BoxPoints){ continue }
            $points = @($block.BoxPoints)
            if($points.Count -le 0){ continue }

            $minX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Minimum).Minimum
            $minY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Minimum).Minimum
            $maxX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Maximum).Maximum
            $maxY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Maximum).Maximum

            $boxW = [Math]::Max(1,[int]($maxX - $minX))
            $boxH = [Math]::Max(1,[int]($maxY - $minY))
            if($boxW -lt 6 -or $boxH -lt 6){ continue }

            $blockText = [string]$block.Text
            $isDimensionLike = (
                $blockText -match '(?:[RC]?\d+\.\d+|\d+\s*[°º]|[+\-±]\s*0?\.\d+|\([^)]+\))' -or
                (($boxH -gt ($boxW * 1.8)) -and $boxH -gt 35)
            )
            if(-not $isDimensionLike){ continue }

            $padX = [int][Math]::Max(34,[Math]::Min(180,($boxW * 2.7)))
            $padY = [int][Math]::Max(38,[Math]::Min(210,($boxH * 1.15)))
            if($boxH -gt ($boxW * 1.6)){
                $padX = [int][Math]::Max(58,[Math]::Min(220,($boxW * 4.2)))
                $padY = [int][Math]::Max(90,[Math]::Min(280,($boxH * 0.80)))
            }

            $zone = New-AutoOcrClampedRect ($left + $minX - $padX) ($top + $minY - $padY) ($boxW + ($padX * 2)) ($boxH + ($padY * 2)) $left $top $right $bottom
            if(!$zone){ continue }
            if(Test-AutoOcrTitleBlockRect $zone){ continue }

            $results += [PSCustomObject]@{
                Rect = $zone
                Label = "rapidocr-dbnet"
                Priority = 2
                Area = ([double]$zone.Width * [double]$zone.Height)
                Text = $blockText
            }
        }
    }
    catch{
        return @($results)
    }
    finally{
        if($crop){ $crop.Dispose() }
        try{
            if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }

    return @($results)
}

function Get-OpenCvTextLineZones($baseRect){

    $zones = @()
    if(!$script:sourceBitmap -or !$baseRect){ return @($zones) }
    if(-not (Initialize-OpenCvSharpForAutoOcr)){ return @($zones) }

    $left = [Math]::Max(0,[int]$baseRect.X)
    $top = [Math]::Max(0,[int]$baseRect.Y)
    $right = [Math]::Min($script:sourceBitmap.Width,[int]$baseRect.Right)
    $bottom = [Math]::Min($script:sourceBitmap.Height,[int]$baseRect.Bottom)
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if($width -le 40 -or $height -le 40){ return @($zones) }

    $cropRect = New-Object Drawing.Rectangle($left,$top,$width,$height)
    $crop = $null
    $temp = Join-Path $env:TEMP ("ocrtool_opencv_textline_{0}.png" -f ([guid]::NewGuid().ToString("N")))

    $src = $null
    $bin = $null
    $horizontal = $null
    $vertical = $null
    $lineMask = $null
    $textMask = $null
    $work = $null
    $kernelH = $null
    $kernelV = $null
    $kernelClose = $null

    try{
        $crop = $script:sourceBitmap.Clone($cropRect,$script:sourceBitmap.PixelFormat)
        $crop.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)

        $src = [OpenCvSharp.Cv2]::ImRead($temp,[OpenCvSharp.ImreadModes]::Grayscale)
        if(!$src -or $src.Empty()){ return @($zones) }

        $bin = New-Object OpenCvSharp.Mat
        [OpenCvSharp.Cv2]::Threshold($src,$bin,0,255,([OpenCvSharp.ThresholdTypes]::BinaryInv -bor [OpenCvSharp.ThresholdTypes]::Otsu))

        # Remove long drawing strokes before grouping glyphs into text-line candidates.
        $horizontal = New-Object OpenCvSharp.Mat
        $vertical = New-Object OpenCvSharp.Mat
        $lineMask = New-Object OpenCvSharp.Mat
        $textMask = New-Object OpenCvSharp.Mat

        $kernelH = [OpenCvSharp.Cv2]::GetStructuringElement([OpenCvSharp.MorphShapes]::Rect,(New-Object OpenCvSharp.Size([Math]::Max(35,[int]($width * 0.035)),1)))
        $kernelV = [OpenCvSharp.Cv2]::GetStructuringElement([OpenCvSharp.MorphShapes]::Rect,(New-Object OpenCvSharp.Size(1,[Math]::Max(35,[int]($height * 0.035)))))
        [OpenCvSharp.Cv2]::MorphologyEx($bin,$horizontal,[OpenCvSharp.MorphTypes]::Open,$kernelH)
        [OpenCvSharp.Cv2]::MorphologyEx($bin,$vertical,[OpenCvSharp.MorphTypes]::Open,$kernelV)
        [OpenCvSharp.Cv2]::BitwiseOr($horizontal,$vertical,$lineMask)
        [OpenCvSharp.Cv2]::Subtract($bin,$lineMask,$textMask)

        $plans = @(
            @{ Label = "OpenCvTextLine"; W = 22; H = 5; MinW = 12; MinH = 6; Vertical = $false },
            @{ Label = "OpenCvTextSmall"; W = 13; H = 4; MinW = 8; MinH = 5; Vertical = $false },
            @{ Label = "OpenCvTextVertical"; W = 5; H = 22; MinW = 5; MinH = 12; Vertical = $true }
        )

        foreach($plan in $plans){
            if($work){ $work.Dispose(); $work = $null }
            if($kernelClose){ $kernelClose.Dispose(); $kernelClose = $null }

            $kernelClose = [OpenCvSharp.Cv2]::GetStructuringElement(
                [OpenCvSharp.MorphShapes]::Rect,
                (New-Object OpenCvSharp.Size([int]$plan.W,[int]$plan.H))
            )
            $work = New-Object OpenCvSharp.Mat
            [OpenCvSharp.Cv2]::MorphologyEx($textMask,$work,[OpenCvSharp.MorphTypes]::Close,$kernelClose)

            $contours = $null
            $hierarchy = $null
            [OpenCvSharp.Cv2]::FindContours($work,[ref]$contours,[ref]$hierarchy,[OpenCvSharp.RetrievalModes]::External,[OpenCvSharp.ContourApproximationModes]::ApproxSimple)

            foreach($contour in @($contours)){
                if(!$contour){ continue }
                $r = [OpenCvSharp.Cv2]::BoundingRect($contour)
                if($r.Width -lt [int]$plan.MinW -or $r.Height -lt [int]$plan.MinH){ continue }
                if($r.Width -gt ($width * 0.36) -or $r.Height -gt ($height * 0.28)){ continue }

                $area = [double]$r.Width * [double]$r.Height
                if($area -lt 45){ continue }

                $aspectWH = [double]$r.Width / [double][Math]::Max(1,$r.Height)
                if([bool]$plan.Vertical){
                    if($aspectWH -gt 1.3){ continue }
                }
                else{
                    if($aspectWH -lt 0.45){ continue }
                    if($aspectWH -gt 18.0){ continue }
                }

                $candidateRoi = New-Object OpenCvSharp.Rect($r.X,$r.Y,$r.Width,$r.Height)
                $roi = $null
                $ink = 0
                try{
                    $roi = New-Object OpenCvSharp.Mat($textMask,$candidateRoi)
                    $ink = [OpenCvSharp.Cv2]::CountNonZero($roi)
                }
                finally{ if($roi){ $roi.Dispose() } }
                $inkRatio = [double]$ink / [Math]::Max(1.0,$area)
                if($inkRatio -lt 0.015 -or $inkRatio -gt 0.72){ continue }

                $padX = if([bool]$plan.Vertical){ [Math]::Max(5,[int]($r.Width * 0.35)) } else { [Math]::Max(5,[int]($r.Height * 0.45)) }
                $padY = if([bool]$plan.Vertical){ [Math]::Max(5,[int]($r.Width * 0.55)) } else { [Math]::Max(4,[int]($r.Height * 0.32)) }

                $zoneRect = New-AutoOcrClampedRect ($left + $r.X - $padX) ($top + $r.Y - $padY) ($r.Width + ($padX * 2)) ($r.Height + ($padY * 2)) $left $top $right $bottom
                if(!$zoneRect){ continue }
                if(Test-AutoOcrTitleBlockRect $zoneRect){ continue }

                $zones += [PSCustomObject]@{
                    Text = "Text"
                    RawText = ""
                    Rect = $zoneRect
                    IsDimension = $false
                    Source = [string]$plan.Label
                    InkRatio = [double]$inkRatio
                }
            }
        }
    }
    catch{
        return @($zones)
    }
    finally{
        if($kernelClose){ $kernelClose.Dispose() }
        if($kernelV){ $kernelV.Dispose() }
        if($kernelH){ $kernelH.Dispose() }
        if($work){ $work.Dispose() }
        if($textMask){ $textMask.Dispose() }
        if($lineMask){ $lineMask.Dispose() }
        if($vertical){ $vertical.Dispose() }
        if($horizontal){ $horizontal.Dispose() }
        if($bin){ $bin.Dispose() }
        if($src){ $src.Dispose() }
        if($crop){ $crop.Dispose() }
        try{ if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } } catch{}
    }

    return @(
        $zones |
        Sort-Object @{ Expression = { $_.Rect.Y }; Descending = $false }, @{ Expression = { $_.Rect.X }; Descending = $false }
    )
}

function Get-DetectedTextZonesFromRapidOcr($baseRect){

    $zones = @()
    if(!$script:sourceBitmap -or !$baseRect){ return @($zones) }
    if(-not (Initialize-RapidOcrNetForAutoOcr)){ return @($zones) }

    $left = [Math]::Max(0,[int]$baseRect.X)
    $top = [Math]::Max(0,[int]$baseRect.Y)
    $right = [Math]::Min($script:sourceBitmap.Width,[int]$baseRect.Right)
    $bottom = [Math]::Min($script:sourceBitmap.Height,[int]$baseRect.Bottom)
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if($width -le 20 -or $height -le 20){ return @($zones) }

    $cropRect = New-Object Drawing.Rectangle($left,$top,$width,$height)
    $crop = $null
    $temp = Join-Path $env:TEMP ("ocrtool_rapidocr_preview_{0}.png" -f ([guid]::NewGuid().ToString("N")))

    try{
        $crop = $script:sourceBitmap.Clone($cropRect,$script:sourceBitmap.PixelFormat)
        $crop.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)
        $options = [RapidOcrNet.RapidOcrOptions]::Default
        $result = $script:RapidOcrNetEngine.Detect($temp,$options)
        if(!$result -or !$result.TextBlocks){ return @($zones) }

        foreach($block in @($result.TextBlocks)){
            if(!$block -or !$block.BoxPoints){ continue }
            $points = @($block.BoxPoints)
            if($points.Count -le 0){ continue }

            $minX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Minimum).Minimum
            $minY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Minimum).Minimum
            $maxX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Maximum).Maximum
            $maxY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Maximum).Maximum
            $boxW = [Math]::Max(1,[int]($maxX - $minX))
            $boxH = [Math]::Max(1,[int]($maxY - $minY))
            if($boxW -lt 4 -or $boxH -lt 4){ continue }

            $zoneRect = New-AutoOcrClampedRect ($left + $minX - 5) ($top + $minY - 5) ($boxW + 10) ($boxH + 10) $left $top $right $bottom
            if(!$zoneRect){ continue }
            $zones += [PSCustomObject]@{
                Text = if([string]::IsNullOrWhiteSpace([string]$block.Text)){ "Text" } else { [string]$block.Text }
                RawText = [string]$block.Text
                Rect = $zoneRect
                IsDimension = $false
                Source = "RapidOcrDetectedText"
            }
        }
    }
    catch{
        return @($zones)
    }
    finally{
        if($crop){ $crop.Dispose() }
        try{
            if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }

    return @($zones)
}

function Get-DetectedTextZonesFromPaddleOcr($baseRect){

    $zones = @()
    if(!$script:sourceBitmap -or !$baseRect){ return @($zones) }
    if(-not (Initialize-PaddleOcrOnnxForTextZones)){ return @($zones) }

    $left = [Math]::Max(0,[int]$baseRect.X)
    $top = [Math]::Max(0,[int]$baseRect.Y)
    $right = [Math]::Min($script:sourceBitmap.Width,[int]$baseRect.Right)
    $bottom = [Math]::Min($script:sourceBitmap.Height,[int]$baseRect.Bottom)
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if($width -le 20 -or $height -le 20){ return @($zones) }

    $cropRect = New-Object Drawing.Rectangle($left,$top,$width,$height)
    $crop = $null
    try{
        $crop = $script:sourceBitmap.Clone($cropRect,$script:sourceBitmap.PixelFormat)
        $result = $script:PaddleOcrOnnxEngine.DetectText($crop)
        if(!$result -or !$result.TextBlocks){ return @($zones) }

        foreach($block in @($result.TextBlocks)){
            if(!$block -or !$block.BoxPoints){ continue }
            $points = @($block.BoxPoints)
            if($points.Count -le 0){ continue }

            $minX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Minimum).Minimum
            $minY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Minimum).Minimum
            $maxX = (@($points | ForEach-Object { [int]$_.X }) | Measure-Object -Maximum).Maximum
            $maxY = (@($points | ForEach-Object { [int]$_.Y }) | Measure-Object -Maximum).Maximum
            $boxW = [Math]::Max(1,[int]($maxX - $minX))
            $boxH = [Math]::Max(1,[int]($maxY - $minY))
            if($boxW -lt 4 -or $boxH -lt 4){ continue }

            $zoneRect = New-AutoOcrClampedRect ($left + $minX - 5) ($top + $minY - 5) ($boxW + 10) ($boxH + 10) $left $top $right $bottom
            if(!$zoneRect){ continue }
            $zones += [PSCustomObject]@{
                Text = if([string]::IsNullOrWhiteSpace([string]$block.Text)){ "Text" } else { [string]$block.Text }
                RawText = [string]$block.Text
                Rect = $zoneRect
                IsDimension = $false
                Source = "PaddleOcrDetectedText"
            }
        }
    }
    catch{
        return @($zones)
    }
    finally{
        if($crop){ $crop.Dispose() }
    }

    return @($zones)
}

function Initialize-OpenCvSharpForAutoOcr{

    if($script:OpenCvSharpAutoOcrLoaded){ return $true }
    if($script:OpenCvSharpAutoOcrUnavailable){ return $false }

    try{
        $opencvRoot = Join-Path $script:AppRoot "lib\OpenCvSharp"
        $managedCandidates = @()
        if($PSVersionTable.PSEdition -eq "Core"){
            $managedCandidates += Join-Path $opencvRoot "opencvsharp4\lib\net8.0\OpenCvSharp.dll"
            $managedCandidates += Join-Path $opencvRoot "opencvsharp4\lib\netstandard2.1\OpenCvSharp.dll"
        }
        $managedCandidates += Join-Path $opencvRoot "opencvsharp4\lib\netstandard2.0\OpenCvSharp.dll"
        $nativeDir = Join-Path $opencvRoot "opencvsharp4.runtime.win\runtimes\win-x64\native"
        $managedDll = @($managedCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)[0]

        if([string]::IsNullOrWhiteSpace([string]$managedDll) -or !(Test-Path (Join-Path $nativeDir "OpenCvSharpExtern.dll"))){
            $script:OpenCvSharpAutoOcrUnavailable = $true
            return $false
        }

        if($env:PATH -notlike ("*" + $nativeDir + "*")){
            $env:PATH = $nativeDir + ";" + $env:PATH
        }

        Add-Type -Path $managedDll -ErrorAction Stop
        $testMat = [OpenCvSharp.Mat]::Zeros(2,2,[OpenCvSharp.MatType]::CV_8UC1)
        try{ [void][OpenCvSharp.Cv2]::CountNonZero($testMat) }
        finally{ if($testMat){ $testMat.Dispose() } }

        $script:OpenCvSharpAutoOcrLoaded = $true
        return $true
    }
    catch{
        $script:OpenCvSharpAutoOcrUnavailable = $true
        return $false
    }
}

function Get-OpenCvAutoOcrTextScanRects($baseRect){

    $results = @()
    if(!$script:sourceBitmap -or !$baseRect){ return @($results) }
    if(-not (Initialize-OpenCvSharpForAutoOcr)){ return @($results) }

    $left = [Math]::Max(0,[int]$baseRect.X)
    $top = [Math]::Max(0,[int]$baseRect.Y)
    $right = [Math]::Min($script:sourceBitmap.Width,[int]$baseRect.Right)
    $bottom = [Math]::Min($script:sourceBitmap.Height,[int]$baseRect.Bottom)
    $width = [int]($right - $left)
    $height = [int]($bottom - $top)
    if($width -le 30 -or $height -le 30){ return @($results) }

    $cropRect = New-Object Drawing.Rectangle($left,$top,$width,$height)
    $crop = $null
    $temp = Join-Path $env:TEMP ("ocrtool_opencv_zone_{0}.png" -f ([guid]::NewGuid().ToString("N")))

    $src = $null
    $bin = $null
    $work = $null
    $kernel = $null

    try{
        $crop = $script:sourceBitmap.Clone($cropRect,$script:sourceBitmap.PixelFormat)
        $crop.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)

        $src = [OpenCvSharp.Cv2]::ImRead($temp,[OpenCvSharp.ImreadModes]::Grayscale)
        if(!$src -or $src.Empty()){ return @($results) }

        $bin = New-Object OpenCvSharp.Mat
        [OpenCvSharp.Cv2]::Threshold($src,$bin,0,255,([OpenCvSharp.ThresholdTypes]::BinaryInv -bor [OpenCvSharp.ThresholdTypes]::Otsu))

        $plans = @(
            @{ W = 24; H = 5;  Label = "opencv-wide" },
            @{ W = 12; H = 7;  Label = "opencv-word" },
            @{ W = 5;  H = 24; Label = "opencv-tall" },
            @{ W = 9;  H = 72; Label = "opencv-vdim" },
            @{ W = 17; H = 96; Label = "opencv-vdim-wide" }
        )

        foreach($plan in $plans){
            if($work){ $work.Dispose(); $work = $null }
            if($kernel){ $kernel.Dispose(); $kernel = $null }

            $kernel = [OpenCvSharp.Cv2]::GetStructuringElement(
                [OpenCvSharp.MorphShapes]::Rect,
                (New-Object OpenCvSharp.Size([int]$plan.W,[int]$plan.H))
            )
            $work = New-Object OpenCvSharp.Mat
            [OpenCvSharp.Cv2]::MorphologyEx($bin,$work,[OpenCvSharp.MorphTypes]::Close,$kernel)

            $contours = $null
            $hierarchy = $null
            [OpenCvSharp.Cv2]::FindContours($work,[ref]$contours,[ref]$hierarchy,[OpenCvSharp.RetrievalModes]::External,[OpenCvSharp.ContourApproximationModes]::ApproxSimple)
            foreach($contour in @($contours)){
                if(!$contour){ continue }

                $r = [OpenCvSharp.Cv2]::BoundingRect($contour)
                if($r.Width -lt 10 -or $r.Height -lt 7){ continue }
                if($r.Width -gt ($width * 0.45) -or $r.Height -gt ($height * 0.45)){ continue }

                $area = [double]$r.Width * [double]$r.Height
                if($area -lt 80){ continue }

                $aspect = [double][Math]::Max($r.Width,$r.Height) / [double][Math]::Max(1,[Math]::Min($r.Width,$r.Height))
                if($aspect -gt 32.0){ continue }

                $label = [string]$plan.Label
                $padX = [int][Math]::Max(24,[Math]::Min(115,([double]$r.Width * 1.35)))
                $padY = [int][Math]::Max(20,[Math]::Min(85,([double]$r.Height * 1.85)))
                if($label -eq "opencv-tall"){
                    $padX = [int][Math]::Max(20,[Math]::Min(80,([double]$r.Width * 1.75)))
                    $padY = [int][Math]::Max(30,[Math]::Min(125,([double]$r.Height * 1.15)))
                }
                elseif($label -eq "opencv-vdim" -or $label -eq "opencv-vdim-wide"){
                    $padX = [int][Math]::Max(46,[Math]::Min(190,([double]$r.Width * 3.2)))
                    $padY = [int][Math]::Max(105,[Math]::Min(260,([double]$r.Height * 0.55)))
                }

                $zone = New-AutoOcrClampedRect ($left + $r.X - $padX) ($top + $r.Y - $padY) ($r.Width + ($padX * 2)) ($r.Height + ($padY * 2)) $left $top $right $bottom
                if(!$zone){ continue }
                if(Test-AutoOcrTitleBlockRect $zone){ continue }

                $results += [PSCustomObject]@{
                    Rect = $zone
                    Label = $label
                    Priority = if($label -match 'vdim'){ 4 } else { 8 }
                    Area = ([double]$zone.Width * [double]$zone.Height)
                }

                if($label -match 'vdim' -and $zone.Width -gt 90 -and $zone.Height -gt 110){
                    $leftSlice = New-AutoOcrClampedRect $zone.Left $zone.Top ([Math]::Ceiling($zone.Width * 0.68)) $zone.Height $left $top $right $bottom
                    $rightSlice = New-AutoOcrClampedRect ($zone.Left + [Math]::Floor($zone.Width * 0.32)) $zone.Top ([Math]::Ceiling($zone.Width * 0.68)) $zone.Height $left $top $right $bottom

                    foreach($slice in @($leftSlice,$rightSlice)){
                        if(!$slice){ continue }
                        $results += [PSCustomObject]@{
                            Rect = $slice
                            Label = "opencv-vdim-slice"
                            Priority = 5
                            Area = ([double]$slice.Width * [double]$slice.Height)
                        }
                    }
                }
            }
        }
    }
    catch{
        return @($results)
    }
    finally{
        if($kernel){ $kernel.Dispose() }
        if($work){ $work.Dispose() }
        if($bin){ $bin.Dispose() }
        if($src){ $src.Dispose() }
        if($crop){ $crop.Dispose() }
        try{
            if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }

    return @($results)
}

function Add-AutoOcrCoverageSweepRects($scanRects,$baseLeft,$baseTop,$baseRight,$baseBottom){

    if(!$scanRects){ return }

    $baseWidth = [int]($baseRight - $baseLeft)
    $baseHeight = [int]($baseBottom - $baseTop)
    if($baseWidth -le 40 -or $baseHeight -le 40){ return }

    $sweeps = @(
        @{ W = 260; H = 980; StepX = 105; StepY = 430; Label = "sweep-vlong"; Priority = 6 },
        @{ W = 210; H = 620; StepX = 90;  StepY = 260; Label = "sweep-vmid";  Priority = 7 },
        @{ W = 180; H = 360; StepX = 72;  StepY = 150; Label = "sweep-vtight";Priority = 9 },
        @{ W = 720; H = 250; StepX = 300; StepY = 105; Label = "sweep-hwide"; Priority = 12 },
        @{ W = 460; H = 210; StepX = 190; StepY = 82;  Label = "sweep-hmid";  Priority = 14 }
    )

    foreach($sweep in $sweeps){
        $zoneWidth = [Math]::Min([int]$sweep.W,$baseWidth)
        $zoneHeight = [Math]::Min([int]$sweep.H,$baseHeight)
        if($zoneWidth -le 40 -or $zoneHeight -le 40){ continue }

        $stepX = [Math]::Max(36,[Math]::Min([int]$sweep.StepX,[int]($zoneWidth * 0.62)))
        $stepY = [Math]::Max(36,[Math]::Min([int]$sweep.StepY,[int]($zoneHeight * 0.62)))

        for($y = $baseTop; $y -lt $baseBottom; $y += $stepY){
            $zoneBottom = [Math]::Min($baseBottom,($y + $zoneHeight))
            if(($baseBottom - $zoneBottom) -lt [Math]::Min(75,[int]($zoneHeight * 0.22))){ $zoneBottom = $baseBottom }

            for($x = $baseLeft; $x -lt $baseRight; $x += $stepX){
                $zoneRight = [Math]::Min($baseRight,($x + $zoneWidth))
                if(($baseRight - $zoneRight) -lt [Math]::Min(75,[int]($zoneWidth * 0.22))){ $zoneRight = $baseRight }

                $rect = New-AutoOcrClampedRect $x $y ($zoneRight - $x) ($zoneBottom - $y) $baseLeft $baseTop $baseRight $baseBottom
                Add-AutoOcrScanRect $scanRects $rect $sweep.Label $sweep.Priority

                if($zoneRight -ge $baseRight){ break }
            }

            if($zoneBottom -ge $baseBottom){ break }
        }
    }
}

function Get-AutoOcrStrongScanRects($baseRect){

    $scanRects = New-Object System.Collections.ArrayList
    if(!$script:sourceBitmap){ return @() }

    if(!$baseRect){
        $baseRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
    }

    $baseLeft = [Math]::Max(0,[int]$baseRect.X)
    $baseTop = [Math]::Max(0,[int]$baseRect.Y)
    $baseRight = [Math]::Min($script:sourceBitmap.Width,[int]$baseRect.Right)
    $baseBottom = [Math]::Min($script:sourceBitmap.Height,[int]$baseRect.Bottom)
    $baseWidth = [int]($baseRight - $baseLeft)
    $baseHeight = [int]($baseBottom - $baseTop)
    if($baseWidth -le 20 -or $baseHeight -le 20){ return @() }

    $fullRect = New-Object Drawing.Rectangle($baseLeft,$baseTop,$baseWidth,$baseHeight)
    Add-AutoOcrScanRect $scanRects $fullRect "full" 0

    foreach($rapidOcrZone in @(Get-RapidOcrNetAutoOcrTextScanRects $fullRect)){
        if(!$rapidOcrZone -or !$rapidOcrZone.Rect){ continue }
        Add-AutoOcrScanRect $scanRects $rapidOcrZone.Rect $rapidOcrZone.Label $rapidOcrZone.Priority
    }

    foreach($opencvZone in @(Get-OpenCvAutoOcrTextScanRects $fullRect)){
        if(!$opencvZone -or !$opencvZone.Rect){ continue }
        Add-AutoOcrScanRect $scanRects $opencvZone.Rect $opencvZone.Label $opencvZone.Priority
    }

    Add-AutoOcrCoverageSweepRects $scanRects $baseLeft $baseTop $baseRight $baseBottom

    $plans = @(
        @{ W = 1100; H = 850;  O = 240; Label = "large";  Priority = 10 },
        @{ W = 760;  H = 540;  O = 190; Label = "medium"; Priority = 20 },
        @{ W = 1350; H = 360;  O = 180; Label = "wide";   Priority = 30 },
        @{ W = 420;  H = 1180; O = 170; Label = "tall";   Priority = 35 },
        @{ W = 520;  H = 360;  O = 140; Label = "tight";  Priority = 45 },
        @{ W = 300;  H = 520;  O = 180; Label = "micro-v";Priority = 11 },
        @{ W = 640;  H = 190;  O = 140; Label = "micro-h";Priority = 16 }
    )

    foreach($plan in $plans){
        $tileWidth = [Math]::Min([int]$plan.W,$baseWidth)
        $tileHeight = [Math]::Min([int]$plan.H,$baseHeight)
        if($tileWidth -le 40 -or $tileHeight -le 40){ continue }

        $overlap = [Math]::Min([int]$plan.O,([Math]::Min($tileWidth,$tileHeight) - 30))
        $stepX = [Math]::Max(120,($tileWidth - $overlap))
        $stepY = [Math]::Max(120,($tileHeight - $overlap))

        for($y = $baseTop; $y -lt $baseBottom; $y += $stepY){
            $tileBottom = [Math]::Min($baseBottom,($y + $tileHeight))
            if(($baseBottom - $tileBottom) -lt [Math]::Min(90,[int]($tileHeight * 0.20))){ $tileBottom = $baseBottom }

            for($x = $baseLeft; $x -lt $baseRight; $x += $stepX){
                $tileRight = [Math]::Min($baseRight,($x + $tileWidth))
                if(($baseRight - $tileRight) -lt [Math]::Min(90,[int]($tileWidth * 0.20))){ $tileRight = $baseRight }

                $rect = New-AutoOcrClampedRect $x $y ($tileRight - $x) ($tileBottom - $y) $baseLeft $baseTop $baseRight $baseBottom
                Add-AutoOcrScanRect $scanRects $rect $plan.Label $plan.Priority

                if($tileRight -ge $baseRight){ break }
            }

            if($tileBottom -ge $baseBottom){ break }
        }
    }

    $centerW = [int][Math]::Max(220,[Math]::Min($baseWidth,($baseWidth * 0.72)))
    $centerH = [int][Math]::Max(220,[Math]::Min($baseHeight,($baseHeight * 0.72)))
    $centerRect = New-AutoOcrClampedRect ($baseLeft + (($baseWidth - $centerW) / 2.0)) ($baseTop + (($baseHeight - $centerH) / 2.0)) $centerW $centerH $baseLeft $baseTop $baseRight $baseBottom
    Add-AutoOcrScanRect $scanRects $centerRect "center" 5

    $maxZones = 240
    return @(
        $scanRects |
        Sort-Object @{ Expression = { $_.Priority }; Descending = $false }, @{ Expression = { $_.Area }; Descending = $true } |
        Select-Object -First $maxZones
    )
}

function Find-ImageOcrDimensionCandidatesTiled($mapRect){

    $allCandidates = @()
    if(!$script:sourceBitmap){ return @($allCandidates) }

    $baseRect = $mapRect
    if(!$baseRect){
        $baseRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
    }

    $baseLeft = [Math]::Max(0,[int]$baseRect.X)
    $baseTop = [Math]::Max(0,[int]$baseRect.Y)
    $baseRight = [Math]::Min($script:sourceBitmap.Width,[int]$baseRect.Right)
    $baseBottom = [Math]::Min($script:sourceBitmap.Height,[int]$baseRect.Bottom)
    $baseWidth = [int]($baseRight - $baseLeft)
    $baseHeight = [int]($baseBottom - $baseTop)
    if($baseWidth -le 20 -or $baseHeight -le 20){ return @($allCandidates) }

    $scanRects = @(Get-AutoOcrStrongScanRects (New-Object Drawing.Rectangle($baseLeft,$baseTop,$baseWidth,$baseHeight)))
    if($scanRects.Count -le 0){
        return @(Find-ImageOcrDimensionCandidates (New-Object Drawing.Rectangle($baseLeft,$baseTop,$baseWidth,$baseHeight)))
    }

    $tileIndex = 0
    $tileCount = $scanRects.Count

    foreach($scan in $scanRects){
        if(!$scan -or !$scan.Rect){ continue }

        $tileIndex++
        if($txtOcrDebug){
            $txtOcrDebug.Text = "Strong OCR zone $tileIndex/$tileCount ($($scan.Label))..."
            [System.Windows.Forms.Application]::DoEvents()
        }

        foreach($candidate in @(Find-ImageOcrDimensionCandidates $scan.Rect)){
            if(
                -not (Test-AutoOcrDuplicateCandidate $candidate $allCandidates) -and
                -not (Test-AutoOcrContainedDuplicate $candidate $allCandidates)
            ){
                $allCandidates += $candidate
            }
        }
    }

    return @(Compress-AutoOcrCandidates $allCandidates)
}

function Get-AutoOcrMapRectKey($mapRect){

    $pagePart = if($script:SelectedPageIndex -ge 0){ [string]$script:SelectedPageIndex } else { "0" }
    if(!$mapRect){
        if($script:sourceBitmap){
            $mapRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
        }
        else{
            return ($pagePart + ":none")
        }
    }

    return ("{0}:{1},{2},{3},{4}" -f $pagePart,[int]$mapRect.X,[int]$mapRect.Y,[int]$mapRect.Width,[int]$mapRect.Height)
}

function Clear-ImageOcrAutoCache{
    $script:ImageOcrAutoCacheKey = $null
    $script:ImageOcrAutoCandidates = @()
    $script:ImageOcrAutoZones = @()
    $script:TextZoneCacheKey = $null
}

function Get-CachedImageOcrAutoCandidates($mapRect){
    $key = Get-AutoOcrMapRectKey $mapRect
    if($script:ImageOcrAutoCacheKey -eq $key -and $script:ImageOcrAutoCandidates -and @($script:ImageOcrAutoCandidates).Count -gt 0){
        return @($script:ImageOcrAutoCandidates)
    }
    return @()
}

function Set-ImageOcrAutoCache($mapRect,$candidates){
    $script:ImageOcrAutoCacheKey = Get-AutoOcrMapRectKey $mapRect
    $script:ImageOcrAutoCandidates = @($candidates)
    $script:ImageOcrAutoZones = @(Convert-ImageOcrCandidatesToZones $script:ImageOcrAutoCandidates)
}

function Get-OcrFallbackTextZones($mapRect,[switch]$ForceFresh){
    $dimensionCandidates = @()
    if(-not $ForceFresh){
        $dimensionCandidates = @(Get-CachedImageOcrAutoCandidates $mapRect)
    }
    if($dimensionCandidates.Count -le 0){
        $dimensionCandidates = @(Find-ImageOcrDimensionCandidatesTiled $mapRect)
        Set-ImageOcrAutoCache $mapRect $dimensionCandidates
    }

    $dimensionZones = @($script:ImageOcrAutoZones)
    if($dimensionZones.Count -le 0 -and $dimensionCandidates.Count -gt 0){
        $dimensionZones = @(Convert-ImageOcrCandidatesToZones $dimensionCandidates)
    }

    $rawZones = @()
    foreach($textZone in @(Get-OpenCvTextLineZones $mapRect)){
        if($textZone -and $textZone.Rect){
            $rawZones += $textZone
        }
    }
    $rawZones = @(Add-RawTextRailMergeZones $rawZones)
    $rawZones = @(Merge-RawTextZoneFragments $rawZones)

    return @(Merge-TextZonePreviewSources $dimensionZones $rawZones)
}

function Convert-PdfTextLayerBlocksToZones($blocks){

    $zones = @()

    $expandedBlocks = @()
    foreach($sourceBlock in @($blocks)){
        $expandedBlocks += @(Split-PdfTextLayerBlockIntoDimensionGroups $sourceBlock)
    }

    foreach($block in @($expandedBlocks)){
        if(!$block){ continue }

        $imageRect = Convert-PdfRectToImageRect $block.Rect $block.PageWidth $block.PageHeight
        if(!$imageRect){ continue }

        $text = Normalize-PdfTextLayerText $block.Text
        if([string]::IsNullOrWhiteSpace($text)){ continue }
        if(Test-PdfTextLayerIgnoredBlock $text){ continue }

        $isDimension = Test-PdfTextLayerDimensionBlock $text
        $nominal = ""
        $tolerance = $null
        if($isDimension){
            $nominal = Get-PdfTextLayerNominal $text
            if(-not [string]::IsNullOrWhiteSpace($nominal)){
                $tolerance = Get-PreferredTolerance (Get-PdfTextLayerTolerance $text $nominal) $text $nominal
            }
        }
        $zones += [PSCustomObject]@{
            Text = $text
            RawText = $text
            Rect = $imageRect
            IsDimension = $isDimension
            Source = "PdfTextLayer"
            Nominal = $nominal
            Tolerance = $tolerance
        }
    }

    return @($zones)
}

function Convert-ImageOcrCandidatesToZones($candidates){

    $zones = @()
    foreach($candidate in @($candidates)){
        if(!$candidate -or !$candidate.Rect){ continue }

        $tolText = ""
        if($candidate.Tolerance -and $candidate.Tolerance.Detected){
            $tolText = (" {0} {1}" -f (Format-InvariantSignedTolerance $candidate.Tolerance.TolMinus),(Format-InvariantSignedTolerance $candidate.Tolerance.TolPlus))
        }

        $zones += [PSCustomObject]@{
            Text = (([string]$candidate.Nominal) + $tolText).Trim()
            RawText = [string]$candidate.RawText
            Rect = $candidate.Rect
            IsDimension = $true
            Source = "ImageOcrAuto"
        }
    }

    return @($zones)
}

function Convert-TextZonesToAutoMapCandidates($zones){

    $candidates = @()
    foreach($zone in @($zones)){
        if(!$zone -or !$zone.Rect){ continue }

        $zoneSource = if($zone.PSObject.Properties.Name -contains "Source" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Source)){
            [string]$zone.Source
        }
        else{
            ""
        }
        $zoneOriginalSource = if($zone.PSObject.Properties.Name -contains "OriginalZoneSource" -and -not [string]::IsNullOrWhiteSpace([string]$zone.OriginalZoneSource)){
            [string]$zone.OriginalZoneSource
        }
        else{
            $zoneSource
        }
        $isPdfTextLayerBacked = Test-IsPdfTextLayerBackedZone $zone
        $labelText = [string]$zone.Text
        $rawText = if($zone.PSObject.Properties.Name -contains "RawText" -and -not [string]::IsNullOrWhiteSpace([string]$zone.RawText)){
            [string]$zone.RawText
        }
        else{
            $labelText
        }

        $nominal = if($zone.PSObject.Properties.Name -contains "Nominal" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Nominal)){
            [string]$zone.Nominal
        }
        else{
            ""
        }
        if([string]::IsNullOrWhiteSpace($nominal) -and $isPdfTextLayerBacked){
            $nominal = Get-PdfTextLayerNominal $labelText
        }
        if([string]::IsNullOrWhiteSpace($nominal)){
            $resolved = Resolve-OcrTextAsMechanicalNominal $rawText $zone.Rect $labelText
            $nominal = [string]$resolved.Nominal
            if(-not [string]::IsNullOrWhiteSpace([string]$resolved.RawText)){ $rawText = [string]$resolved.RawText }
        }
        $nominal = Normalize-DegreeNominalSign $nominal
        if([string]::IsNullOrWhiteSpace($nominal)){ continue }

        if(-not $zone.IsDimension){
            $labelHasDimensionSignal = (
                ([string]$labelText -match '[0-9]') -or
                ([string]$rawText -match '[0-9]') -or
                ([string]$nominal -match '[0-9]') -or
                ([string]$nominal -match '[°ºRRCØΦC]')
            )
            if(-not $labelHasDimensionSignal){ continue }
        }

        $allowBareInteger = (
            ([string]$nominal -match '^\d+$') -and
            (([string]$rawText -replace '\s+','') -match '^\d+$')
        )
        if(-not (Test-AutoOcrDimensionCandidate $rawText $nominal -AllowBareInteger:$allowBareInteger)){ continue }

        $tolerance = if($zone.PSObject.Properties.Name -contains "Tolerance" -and $zone.Tolerance){
            $zone.Tolerance
        }
        else{
            $null
        }
        if($isPdfTextLayerBacked){
            $pdfTolerance = $null
            if(!$tolerance){
                $pdfTolerance = Get-PdfTextLayerTolerance $labelText $nominal
            }
            else{
                $pdfTolerance = $tolerance
            }
            $tolerance = Get-PreferredTolerance $pdfTolerance $rawText $nominal
        }
        elseif(!$tolerance){
            $tolerance = Get-PreferredTolerance $null $rawText $nominal
        }

        $candidates += [PSCustomObject]@{
            Nominal = [string]$nominal
            RawText = $rawText
            LabelText = $labelText
            LabelNominal = [string]$nominal
            BboxText = $labelText
            BboxItemIndex = 0
            BboxItemCount = 1
            Rect = $zone.Rect
            Angle = if($zone.PSObject.Properties.Name -contains "ResolvedAngle"){ [int]$zone.ResolvedAngle } else { 0 }
            Tolerance = $tolerance
            Source = "TextZoneLabel"
            OriginalZoneSource = $zoneOriginalSource
        }
    }

    return @(Compress-AutoOcrCandidates $candidates)
}



function Add-OrUpdate-MarkStepTextZone($row,$stepIndex,$rect,$nominal,$rawText,$tolMinus,$tolPlus){
    if(!$rect -or [string]::IsNullOrWhiteSpace([string]$nominal)){ return $false }

    $label = ([string]$nominal).Trim()
    if($null -ne $tolMinus -and $null -ne $tolPlus){
        $minusText = Format-InvariantSignedTolerance $tolMinus
        $plusText = Format-InvariantSignedTolerance $tolPlus
        if(([double]$tolMinus) -ne 0 -or ([double]$tolPlus) -ne 0){
            if(([double]$tolMinus) -eq 0){ $label = ($label + " " + $plusText).Trim() }
            elseif(([double]$tolPlus) -eq 0){ $label = ($label + " " + $minusText).Trim() }
            else{ $label = ($label + " " + $minusText + " / " + $plusText).Trim() }
        }
    }

    $pad = 8
    $left = [Math]::Max(0,([int]$rect.X - $pad))
    $top = [Math]::Max(0,([int]$rect.Y - $pad))
    $right = [int]($rect.X + $rect.Width + $pad)
    $bottom = [int]($rect.Y + $rect.Height + $pad)
    if($script:sourceBitmap){
        $right = [Math]::Min($script:sourceBitmap.Width,$right)
        $bottom = [Math]::Min($script:sourceBitmap.Height,$bottom)
    }
    $hoverRect = New-Object Drawing.Rectangle($left,$top,[Math]::Max(2,($right - $left)),[Math]::Max(2,($bottom - $top)))

    $tolObject = [PSCustomObject]@{
        Detected = (([double]$tolMinus) -ne 0 -or ([double]$tolPlus) -ne 0)
        TolMinus = [double]$tolMinus
        TolPlus = [double]$tolPlus
        NormalizedText = $label
        ParseMode = "MarkStep"
    }

    $zone = [PSCustomObject]@{
        Text = $label
        Nominal = [string]$nominal
        RawText = if([string]::IsNullOrWhiteSpace([string]$rawText)){ [string]$nominal } else { [string]$rawText }
        Rect = $hoverRect
        OriginalRect = (New-Object Drawing.Rectangle($rect.X,$rect.Y,$rect.Width,$rect.Height))
        IsDimension = $true
        Source = "MarkStep"
        MarkStepIndex = [int]$stepIndex
        RowIndex = [int]$row
        Tolerance = $tolObject
        HiddenSuggestAccepted = $false
    }

    $newZones = @()
    $replaced = $false
    foreach($existing in @($script:PdfTextLayerZones)){
        if(
            $existing -and
            $existing.PSObject.Properties.Name -contains "Source" -and [string]$existing.Source -eq "MarkStep" -and
            $existing.PSObject.Properties.Name -contains "MarkStepIndex" -and [int]$existing.MarkStepIndex -eq [int]$stepIndex
        ){
            $newZones += $zone
            $replaced = $true
        }
        else{
            $newZones += $existing
        }
    }
    if(-not $replaced){ $newZones += $zone }
    $script:PdfTextLayerZones = @($newZones)
    Save-CurrentPageTextZoneCache
    return $true
}

function Convert-MarkStepToleranceCellToDouble($value){
    if($null -eq $value){ return 0.0 }

    $text = ([string]$value).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return 0.0 }

    $text = $text -replace '，','.'
    $text = $text -replace '＋','+'
    $text = $text -replace '[−－–—]','-'
    $text = $text -replace '\s+',''

    $parsed = 0.0
    if([double]::TryParse($text,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){
        return $parsed
    }

    if($text -match '^[+]\.([0-9]+)$'){
        $candidate = "0.$($Matches[1])"
        if([double]::TryParse($candidate,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){
            return $parsed
        }
    }
    elseif($text -match '^[-]\.([0-9]+)$'){
        $candidate = "-0.$($Matches[1])"
        if([double]::TryParse($candidate,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){
            return $parsed
        }
    }

    return 0.0
}

function Sync-MarkStepTextZonesFromTable{
    if($null -eq $script:PdfTextLayerZones){
        $script:PdfTextLayerZones = @()
    }

    $baseZones = @()
    foreach($zone in @($script:PdfTextLayerZones)){
        if(!$zone){ continue }
        if(
            $zone.PSObject.Properties.Name -contains "Source" -and
            [string]$zone.Source -eq "MarkStep"
        ){
            continue
        }
        $baseZones += $zone
    }

    $script:PdfTextLayerZones = @($baseZones)

    for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
        if(!$script:StepRects.ContainsKey($rowIndex)){ continue }

        $nominal = ([string]$table.Rows[$rowIndex].Cells[1].Value).Trim()
        if([string]::IsNullOrWhiteSpace($nominal)){ continue }

        $stepIndex = $rowIndex + 1
        $stepText = ([string]$table.Rows[$rowIndex].Cells[0].Value).Trim()
        $parsedStep = 0
        if([int]::TryParse($stepText,[ref]$parsedStep) -and $parsedStep -gt 0){
            $stepIndex = $parsedStep
        }

        $tolMinus = Convert-MarkStepToleranceCellToDouble $table.Rows[$rowIndex].Cells[2].Value
        $tolPlus = Convert-MarkStepToleranceCellToDouble $table.Rows[$rowIndex].Cells[3].Value

        [void](Add-OrUpdate-MarkStepTextZone $rowIndex $stepIndex $script:StepRects[$rowIndex] $nominal $nominal $tolMinus $tolPlus)
    }

    # The hover candidate stores a snapshot of the zone. Any table-side update
    # must force hover to be resolved again, otherwise the visible bbox label can
    # keep the old nominal/tolerance even though the table row is already updated.
    Save-CurrentPageTextZoneCache
    $script:HiddenTextZoneHoverIndex = -1
    $script:HiddenTextZoneHoverCandidate = $null
}

function Clear-HiddenTextZoneHover{
    $script:HiddenTextZoneHoverIndex = -1
    $script:HiddenTextZoneHoverCandidate = $null
    $script:HiddenDuplicateOriginalRect = $null
    $script:HiddenDuplicateGhostRect = $null
    $script:SelectedDuplicateAnchorStep = $null
    $script:SelectedDuplicateSteps = @{}
    $script:PendingManualDuplicateCandidate = $null
}

function Set-PendingManualDuplicateCandidate($candidate,$match){
    if(!$candidate -or !$match){ return $false }

    $candidate | Add-Member -NotePropertyName DuplicateMatch -NotePropertyValue $match -Force
    $script:PendingManualDuplicateCandidate = $candidate
    $script:HiddenTextZoneHoverIndex = -1
    $script:HiddenTextZoneHoverCandidate = $candidate
    $script:HiddenDuplicateOriginalRect = $match.Rect
    $script:HiddenDuplicateGhostRect = $null
    $script:SelectedDuplicateAnchorStep = [string]$match.Step
    $script:SelectedDuplicateSteps = @{}

    if($txtOcrDebug){
        $txtOcrDebug.Text = (
            $txtOcrDebug.Text + [Environment]::NewLine +
            "Duplicate red crop: matches step " + [string]$match.Step + [Environment]::NewLine +
            "Enter = copy/link existing balloon; E = keep as NEW step; right click = cancel"
        )
    }

    Request-CanvasRedraw
    return $true
}

function Cancel-PendingManualDuplicateCandidate{
    if(!$script:PendingManualDuplicateCandidate){ return $false }

    $candidate = $script:PendingManualDuplicateCandidate
    $script:PendingManualDuplicateCandidate = $null
    $script:HiddenTextZoneHoverIndex = -1
    $script:HiddenTextZoneHoverCandidate = $null
    $script:HiddenDuplicateOriginalRect = $null
    $script:HiddenDuplicateGhostRect = $null
    $script:SelectedDuplicateAnchorStep = $null
    $script:SelectedDuplicateSteps = @{}

    if($txtOcrDebug){
        $txtOcrDebug.Text = (
            "Duplicate red crop canceled; bbox kept" + [Environment]::NewLine +
            "Suggest: " + (Get-HiddenTextZoneSuggestLabel $candidate) + [Environment]::NewLine +
            "Red crop is still active"
        )
    }

    Request-CanvasRedraw
    return $true
}

function Copy-RectValue($rect){
    if(!$rect){ return $null }
    return (New-Object Drawing.Rectangle([int]$rect.X,[int]$rect.Y,[int]$rect.Width,[int]$rect.Height))
}

function Test-RectSameRegion($a,$b,$overlapThreshold = 0.72){
    if(!$a -or !$b){ return $false }

    $left = [Math]::Max([double]$a.Left,[double]$b.Left)
    $top = [Math]::Max([double]$a.Top,[double]$b.Top)
    $right = [Math]::Min([double]$a.Right,[double]$b.Right)
    $bottom = [Math]::Min([double]$a.Bottom,[double]$b.Bottom)
    $intersection = [Math]::Max(0.0,($right - $left)) * [Math]::Max(0.0,($bottom - $top))
    if($intersection -le 0){ return $false }

    $areaA = [Math]::Max(1.0,([double]$a.Width * [double]$a.Height))
    $areaB = [Math]::Max(1.0,([double]$b.Width * [double]$b.Height))
    $overlap = $intersection / [Math]::Max(1.0,[Math]::Min($areaA,$areaB))
    return ($overlap -ge [double]$overlapThreshold)
}

function Test-SuppressedTextZoneRect($rect){
    if(!$rect){ return $false }
    foreach($suppressedRect in @($script:SuppressedTextZoneRects)){
        if(Test-RectSameRegion $suppressedRect $rect 0.68){
            return $true
        }
    }
    return $false
}

function Add-SuppressedTextZoneRect($rect){
    if(!$rect){ return }
    if(Test-SuppressedTextZoneRect $rect){ return }
    $script:SuppressedTextZoneRects += (New-Object Drawing.Rectangle([int]$rect.X,[int]$rect.Y,[int]$rect.Width,[int]$rect.Height))
}

function Remove-SuppressedTextZoneRect($rect){
    if(!$rect -or @($script:SuppressedTextZoneRects).Count -le 0){ return }
    $remaining = @()
    foreach($suppressedRect in @($script:SuppressedTextZoneRects)){
        if(Test-RectSameRegion $suppressedRect $rect 0.68){ continue }
        $remaining += $suppressedRect
    }
    $script:SuppressedTextZoneRects = @($remaining)
}

function Filter-SuppressedTextZones($zones){
    if(@($zones).Count -le 0){ return @() }
    if(@($script:SuppressedTextZoneRects).Count -le 0){ return @($zones) }
    return @(
        foreach($zone in @($zones)){
            if(!$zone){ continue }
            if($zone.Rect -and (Test-SuppressedTextZoneRect $zone.Rect)){ continue }
            $zone
        }
    )
}

function Test-DuplicateDeclinedRect($rect){
    if(!$rect){ return $false }
    foreach($declinedRect in @($script:DuplicateDeclinedRects)){
        if(Test-RectSameRegion $declinedRect $rect 0.68){
            return $true
        }
    }
    return $false
}

function Add-DuplicateDeclinedRect($rect){
    if(!$rect){ return $false }
    if(Test-DuplicateDeclinedRect $rect){ return $false }

    $copied = Copy-RectValue $rect
    if(!$copied){ return $false }

    $script:DuplicateDeclinedRects += $copied
    return $true
}

function Get-HiddenTextZoneSuggestLabel($candidate){
    if(!$candidate){ return "" }
    $label = ([string]$candidate.Nominal).Trim()
    if($candidate.PSObject.Properties.Name -contains "Tolerance" -and $candidate.Tolerance -and $candidate.Tolerance.Detected){
        $minus = Format-InvariantSignedTolerance $candidate.Tolerance.TolMinus
        $plus = Format-InvariantSignedTolerance $candidate.Tolerance.TolPlus
        if(([double]$candidate.Tolerance.TolMinus) -eq 0 -and ([double]$candidate.Tolerance.TolPlus) -ne 0){
            $label = ($label + " " + $plus).Trim()
        }
        elseif(([double]$candidate.Tolerance.TolPlus) -eq 0 -and ([double]$candidate.Tolerance.TolMinus) -ne 0){
            $label = ($label + " " + $minus).Trim()
        }
        else{
            $label = ($label + " " + $minus + " / " + $plus).Trim()
        }
    }
    return $label
}

function New-DirectAutoMapCandidateFromZone($zone,$zoneIndex){
    if(!$zone -or !$zone.Rect){ return $null }

    $zoneSource = if($zone.PSObject.Properties.Name -contains "Source" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Source)){
        [string]$zone.Source
    }
    else{
        ""
    }
    $labelText = [string]$zone.Text
    $rawText = if($zone.PSObject.Properties.Name -contains "RawText" -and -not [string]::IsNullOrWhiteSpace([string]$zone.RawText)){
        [string]$zone.RawText
    }
    else{
        $labelText
    }
    $nominal = if($zone.PSObject.Properties.Name -contains "Nominal" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Nominal)){
        [string]$zone.Nominal
    }
    else{
        ""
    }

    if([string]::IsNullOrWhiteSpace($nominal) -and $zoneSource -eq "PdfTextLayer"){
        $nominal = Get-PdfTextLayerNominal $labelText
    }
    $nominal = Normalize-DegreeNominalSign $nominal
    if([string]::IsNullOrWhiteSpace($nominal)){ return $null }

    $tolerance = if($zone.PSObject.Properties.Name -contains "Tolerance" -and $zone.Tolerance){
        $zone.Tolerance
    }
    else{
        $null
    }
    if(Test-IsPdfTextLayerBackedZone $zone){
        $tolerance = Get-PreferredTolerance $tolerance $rawText $nominal
    }

    return [PSCustomObject]@{
        Nominal = $nominal
        RawText = $rawText
        LabelText = $labelText
        LabelNominal = $nominal
        BboxText = $labelText
        BboxItemIndex = 0
        BboxItemCount = 1
        Rect = $zone.Rect
        Angle = if($zone.PSObject.Properties.Name -contains "ResolvedAngle"){ [int]$zone.ResolvedAngle } else { 0 }
        Tolerance = $tolerance
        Source = "TextZoneLabel"
        OriginalZoneSource = if($zone.PSObject.Properties.Name -contains "OriginalZoneSource" -and -not [string]::IsNullOrWhiteSpace([string]$zone.OriginalZoneSource)){ [string]$zone.OriginalZoneSource } else { $zoneSource }
        ZoneIndex = [int]$zoneIndex
    }
}

function Get-CandidateTableDuplicateMatch($candidate){
    if(!$candidate -or [string]::IsNullOrWhiteSpace([string]$candidate.Nominal)){ return $null }

    $tolMinus = 0
    $tolPlus = 0
    if($candidate.PSObject.Properties.Name -contains "Tolerance" -and $candidate.Tolerance){
        $tolMinus = $candidate.Tolerance.TolMinus
        $tolPlus = $candidate.Tolerance.TolPlus
    }
    else{
        $rawText = if($candidate.PSObject.Properties.Name -contains "LabelText" -and -not [string]::IsNullOrWhiteSpace([string]$candidate.LabelText)){ [string]$candidate.LabelText } else { [string]$candidate.RawText }
        $parsedTol = Parse-ToleranceFull $rawText ([string]$candidate.Nominal)
        if($parsedTol -and $parsedTol.Detected){
            $tolMinus = $parsedTol.TolMinus
            $tolPlus = $parsedTol.TolPlus
        }
        else{
            $fallbackTol = Get-GeneralToleranceForNominal ([string]$candidate.Nominal)
            $tolMinus = $fallbackTol.TolMinus
            $tolPlus = $fallbackTol.TolPlus
        }
    }

    $candidateKey = (
        ([string]$candidate.Nominal).Trim() +
        [char]31 +
        (Format-InvariantSignedTolerance $tolMinus) +
        [char]31 +
        (Format-InvariantSignedTolerance $tolPlus)
    )

    for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
        $rowKey = Get-DuplicateGroupKey $rowIndex
        if([string]::IsNullOrWhiteSpace($rowKey)){ continue }
        if($rowKey -ne $candidateKey){ continue }

        if($script:StepRects.ContainsKey($rowIndex) -and $candidate.Rect){
            $rowRect = $script:StepRects[$rowIndex]
            if(
                [Math]::Abs(($rowRect.X + $rowRect.Width / 2.0) - ($candidate.Rect.X + $candidate.Rect.Width / 2.0)) -lt 2 -and
                [Math]::Abs(($rowRect.Y + $rowRect.Height / 2.0) - ($candidate.Rect.Y + $candidate.Rect.Height / 2.0)) -lt 2
            ){
                continue
            }
        }

        $stepText = Get-TableCellText $rowIndex 0
        if([string]::IsNullOrWhiteSpace($stepText)){ continue }

        return [PSCustomObject]@{
            RowIndex = [int]$rowIndex
            Step = [string]$stepText
            Rect = if($script:StepRects.ContainsKey($rowIndex)){ $script:StepRects[$rowIndex] } else { $null }
            TolMinus = $tolMinus
            TolPlus = $tolPlus
            Key = $candidateKey
        }
    }

    return $null
}

function Test-CandidateAlreadyAcceptedAsStep($candidate){
    if(!$candidate -or !$candidate.Rect){ return $false }

    if($candidate.PSObject.Properties.Name -contains "Source" -and [string]$candidate.Source -eq "MarkStep"){
        return $true
    }

    for($rowIndex = 0; $rowIndex -lt $table.Rows.Count; $rowIndex++){
        if(!$script:StepRects.ContainsKey($rowIndex)){ continue }
        if(Test-RectSameRegion $script:StepRects[$rowIndex] $candidate.Rect 0.78){
            return $true
        }
    }

    return $false
}

function Set-HiddenCandidateDuplicateInfo($candidate){
    if(!$candidate){ return $null }

    # A MarkStep zone is already an accepted OCR table row. It must behave as a
    # Result input target, not as a duplicate/link suggestion, even if another
    # row has the same nominal+tolerance.
    if(
        $candidate.PSObject.Properties.Name -contains "Source" -and
        [string]$candidate.Source -eq "MarkStep"
    ){
        $candidate | Add-Member -NotePropertyName DuplicateMatch -NotePropertyValue $null -Force
        $script:HiddenDuplicateOriginalRect = $null
        $script:HiddenDuplicateGhostRect = $null
        $script:SelectedDuplicateAnchorStep = $null
        $script:SelectedDuplicateSteps = @{}
        return $candidate
    }

    $duplicateDeclined = $false
    if($candidate.PSObject.Properties.Name -contains "DuplicateLinkDeclined" -and $candidate.DuplicateLinkDeclined){
        $duplicateDeclined = $true
    }
    if(-not $duplicateDeclined -and $candidate.Rect -and (Test-DuplicateDeclinedRect $candidate.Rect)){
        $duplicateDeclined = $true
    }
    if(
        -not $duplicateDeclined -and
        $candidate.PSObject.Properties.Name -contains "ZoneIndex"
    ){
        $zi = [int]$candidate.ZoneIndex
        if($zi -ge 0 -and $zi -lt @($script:PdfTextLayerZones).Count){
            $zone = $script:PdfTextLayerZones[$zi]
            if($zone -and $zone.PSObject.Properties.Name -contains "DuplicateLinkDeclined" -and $zone.DuplicateLinkDeclined){
                $duplicateDeclined = $true
            }
        }
    }

    if($duplicateDeclined){
        $candidate | Add-Member -NotePropertyName DuplicateMatch -NotePropertyValue $null -Force
        $candidate | Add-Member -NotePropertyName DuplicateLinkDeclined -NotePropertyValue $true -Force
        $script:HiddenDuplicateOriginalRect = $null
        $script:HiddenDuplicateGhostRect = $null
        $script:SelectedDuplicateAnchorStep = $null
        $script:SelectedDuplicateSteps = @{}
        return $candidate
    }

    $match = Get-CandidateTableDuplicateMatch $candidate
    if($match){
        $candidate | Add-Member -NotePropertyName DuplicateMatch -NotePropertyValue $match -Force
        $script:SelectedDuplicateAnchorStep = [string]$match.Step
        $script:SelectedDuplicateSteps = @{}
        $script:HiddenDuplicateOriginalRect = $match.Rect
    }
    else{
        $script:HiddenDuplicateOriginalRect = $null
        $script:HiddenDuplicateGhostRect = $null
        $script:SelectedDuplicateAnchorStep = $null
        $script:SelectedDuplicateSteps = @{}
    }

    return $candidate
}

function Decline-HiddenDuplicateCandidate{
    $candidate = $script:HiddenTextZoneHoverCandidate
    if(!$candidate){ return $false }
    if(-not ($candidate.PSObject.Properties.Name -contains "DuplicateMatch") -or !$candidate.DuplicateMatch){ return $false }

    $candidate | Add-Member -NotePropertyName DuplicateLinkDeclined -NotePropertyValue $true -Force
    $candidate | Add-Member -NotePropertyName DuplicateMatch -NotePropertyValue $null -Force
    Add-DuplicateDeclinedRect $candidate.Rect | Out-Null

    if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){
        $zi = [int]$candidate.ZoneIndex
        if($zi -ge 0 -and $zi -lt @($script:PdfTextLayerZones).Count){
            $script:PdfTextLayerZones[$zi] | Add-Member -NotePropertyName DuplicateLinkDeclined -NotePropertyValue $true -Force
        }
    }

    $script:HiddenTextZoneHoverCandidate = $candidate
    $script:HiddenDuplicateOriginalRect = $null
    $script:HiddenDuplicateGhostRect = $null
    $script:SelectedDuplicateAnchorStep = $null
    $script:SelectedDuplicateSteps = @{}

    if($txtOcrDebug){
        $txtOcrDebug.Text = (
            "Duplicate link declined" + [Environment]::NewLine +
            "Suggest: " + (Get-HiddenTextZoneSuggestLabel $candidate) + [Environment]::NewLine +
            "Enter / double click will add as NEW OCR step"
        )
    }

    Request-CanvasRedraw
    return $true
}

function Keep-HiddenDuplicateCandidateAsNew{
    $candidate = $script:HiddenTextZoneHoverCandidate
    if(!$candidate){ return $false }
    if(-not ($candidate.PSObject.Properties.Name -contains "DuplicateMatch") -or !$candidate.DuplicateMatch){ return $false }

    $candidate | Add-Member -NotePropertyName DuplicateLinkDeclined -NotePropertyValue $true -Force
    $candidate | Add-Member -NotePropertyName DuplicateMatch -NotePropertyValue $null -Force
    Add-DuplicateDeclinedRect $candidate.Rect | Out-Null
    Record-AdaptiveDetectorFeedback $candidate "decline"
    if(-not (Test-IsTextZoneOnlyCandidateSource $candidate.Source)){
        Register-DetectorAnnotationSilent "negative" $candidate.Rect ([ordered]@{
            Source = "HiddenTextZoneDuplicateDeclined"
            Label = [string]$candidate.Nominal
            Raw = [string]$candidate.RawText
            Reason = "duplicate_declined"
        })
    }

    if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){
        $zi = [int]$candidate.ZoneIndex
        if($zi -ge 0 -and $zi -lt @($script:PdfTextLayerZones).Count){
            $script:PdfTextLayerZones[$zi] | Add-Member -NotePropertyName DuplicateLinkDeclined -NotePropertyValue $true -Force
        }
    }

    $candidate | Add-Member -NotePropertyName DuplicateCheckPassed -NotePropertyValue $true -Force
    if(Add-OcrCandidateToTable $candidate){
        Record-AdaptiveDetectorFeedback $candidate "keep_new"
        $lastRow = $table.Rows.Count - 1
        if($lastRow -ge 0){
            $table.ClearSelection()
            $table.Rows[$lastRow].Selected = $true
            $table.CurrentCell = $table.Rows[$lastRow].Cells[0]
            $table.FirstDisplayedScrollingRowIndex = $lastRow
        }
        if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){
            $zi = [int]$candidate.ZoneIndex
            if($zi -ge 0 -and $zi -lt @($script:PdfTextLayerZones).Count){
                $script:PdfTextLayerZones[$zi] | Add-Member -NotePropertyName HiddenSuggestAccepted -NotePropertyValue $true -Force
            }
        }
        Save-CurrentPageState
        Queue-SessionStateSave
        if(-not (Test-IsTextZoneOnlyCandidateSource $candidate.Source)){
            Register-TrainingSignal "duplicate_keep_new" @{
                Nominal = [string]$candidate.Nominal
                Source = [string]$candidate.Source
                Raw = [string]$candidate.RawText
                Rect = $candidate.Rect
            }
        }
        Refresh-DuplicateState
        Apply-TableSearchFilter
        if($txtOcrDebug){
            $newStep = [string]$table.Rows[$lastRow].Cells[0].Value
            $txtOcrDebug.Text = (
                "Duplicate kept as NEW step" + [Environment]::NewLine +
                "New step: " + $newStep + [Environment]::NewLine +
                "Nominal: " + [string]$candidate.Nominal
            )
        }
        Clear-HiddenTextZoneHover
        Request-CanvasRedraw
        return $true
    }

    return $false
}

function Get-HiddenDuplicateGhostRect($candidate){
    if(!$candidate -or !$candidate.Rect -or !$script:sourceBitmap){ return $null }
    if(-not ($candidate.PSObject.Properties.Name -contains "DuplicateMatch") -or !$candidate.DuplicateMatch){ return $null }

    $markScale = Get-CurrentPageBalloonScale
    $pos = Find-BalloonPositionNextToRect $candidate.Rect $script:sourceBitmap.Width $script:sourceBitmap.Height $markScale 0 1
    $radius = (Get-MarkImageRadius) * $markScale
    return (New-Object Drawing.RectangleF(
        [float]($pos.X - $radius),
        [float]($pos.Y - $radius),
        [float]($radius * 2.0),
        [float]($radius * 2.0)
    ))
}

function Test-HiddenDuplicateGhostHit($point){
    if(!$point){ return $false }
    $candidate = $script:HiddenTextZoneHoverCandidate
    if(!$candidate){ return $false }
    $ghostRect = Get-HiddenDuplicateGhostRect $candidate
    if(!$ghostRect){ return $false }
    return $ghostRect.Contains([float]$point.X,[float]$point.Y)
}

function Link-HiddenDuplicateCandidate($candidate){
    if(!$candidate -or !$candidate.Rect){ return $false }
    if(-not ($candidate.PSObject.Properties.Name -contains "DuplicateMatch") -or !$candidate.DuplicateMatch){ return $false }
    if(!$script:sourceBitmap){ return $false }

    $match = $candidate.DuplicateMatch
    $stepText = [string]$match.Step
    if([string]::IsNullOrWhiteSpace($stepText)){ return $false }

    $markScale = Get-CurrentPageBalloonScale
    $pos = Find-BalloonPositionNextToRect $candidate.Rect $script:sourceBitmap.Width $script:sourceBitmap.Height $markScale 0 1

    foreach($existing in @($script:UiCopiedMarks)){
        if(!$existing){ continue }
        if([string]$existing.SourceStep -ne $stepText -and [string]$existing.Index -ne $stepText){ continue }
        if($existing.PSObject.Properties.Name -contains "LinkedRect" -and $existing.LinkedRect -and (Test-RectSameRegion $existing.LinkedRect $candidate.Rect 0.72)){
            Select-UiCopiedMark $existing.Id
            return $true
        }
        $dx = [double]$existing.X - [double]$pos.X
        $dy = [double]$existing.Y - [double]$pos.Y
        if([Math]::Sqrt(($dx * $dx) + ($dy * $dy)) -lt ((Get-MarkImageRadius) * 1.25)){
            Select-UiCopiedMark $existing.Id
            return $true
        }
    }

    $sourceRect = if($match.Rect){ New-Object Drawing.Rectangle($match.Rect.X,$match.Rect.Y,$match.Rect.Width,$match.Rect.Height) } else { $null }
    $newCopy = [PSCustomObject]@{
        Id = [int]$script:NextUiCopiedMarkId
        Index = $stepText
        X = [double]$pos.X
        Y = [double]$pos.Y
        Scale = (Normalize-MarkScale $markScale)
        SourceStep = $stepText
        SourceRect = $sourceRect
        LinkedRect = (New-Object Drawing.Rectangle($candidate.Rect.X,$candidate.Rect.Y,$candidate.Rect.Width,$candidate.Rect.Height))
    }

    $script:NextUiCopiedMarkId++
    $script:UiCopiedMarks += $newCopy
    Select-UiCopiedMark $newCopy.Id
    Update-CopiedUiNote
    Save-CurrentPageState
    Save-SessionState
    return $true
}

function Ensure-HiddenTextZonesLoaded{
    if(-not $script:ShowPdfTextZones){ return $false }
    if(!$script:sourceBitmap){ return $false }
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){ return $false }

    $mapRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
    $key = Get-AutoOcrMapRectKey $mapRect
    if($script:TextZoneCacheKey -eq $key){
        return ($script:PdfTextLayerZones -and @($script:PdfTextLayerZones).Count -gt 0)
    }

    if($txtOcrDebug){
        $txtOcrDebug.Text = "Preparing text zones in background..."
    }
    Schedule-DeferredTextZoneWarmup | Out-Null
    return $false
}

function Test-IsTextZoneOnlyCandidateSource($sourceName){
    $source = [string]$sourceName
    return (
        $source -eq "PdfTextLayer" -or
        $source -eq "TextZoneLabel"
    )
}

function Invoke-DeferredTextZoneWarmup{
    if($script:DeferredTextZoneWarmupTimer){
        $script:DeferredTextZoneWarmupTimer.Stop()
    }
    if($script:IsDeferredTextZoneWarmupRunning){ return }
    if($script:IsLoadingSource -or $script:IsBindingPage){ return }
    if($script:PendingTextZoneWarmupPageIndex -lt 0){ return }
    if($script:PendingTextZoneWarmupPageIndex -ne $script:SelectedPageIndex){
        Stop-DeferredTextZoneWarmup
        return
    }
    if(!$script:sourceBitmap -or [string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){
        Stop-DeferredTextZoneWarmup
        return
    }

    $script:IsDeferredTextZoneWarmupRunning = $true
    try{
        $pageNumber = $script:SelectedPageIndex + 1
        $mapRect = if($script:PendingTextZoneWarmupMapRect){ $script:PendingTextZoneWarmupMapRect } else { New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height) }
        $textZoneKey = Get-AutoOcrMapRectKey $mapRect

        switch($script:PendingTextZoneWarmupStage){
            "PdfTextLayer" {
                if($txtOcrDebug){ $txtOcrDebug.Text = "Preparing text zones..." }
                Begin-TransientInteractiveRender
                Request-CanvasRedraw
                $blocks = @(Get-PdfTextLayerBlocks $script:CurrentSourcePath $pageNumber)
                Set-CurrentPagePdfTextLayerAvailability (@($blocks).Count -gt 0) @($blocks).Count
                if(@($blocks).Count -gt 0){
                    $script:PdfTextLayerZones = @(Filter-SuppressedTextZones (Convert-PdfTextLayerBlocksToZones $blocks))
                    $script:TextZoneCacheKey = $textZoneKey
                    $script:TextZoneCacheResolved = $true
                    Save-CurrentPageTextZoneCache
                    Request-CanvasRedraw
                    $dimensionCount = @($script:PdfTextLayerZones | Where-Object { $_.IsDimension }).Count
                    if($txtOcrDebug){ $txtOcrDebug.Text = "Zone mode: PDF text layer" + [Environment]::NewLine + ("Text zones: {0}" -f $script:PdfTextLayerZones.Count) + [Environment]::NewLine + ("Dimension-like: {0}" -f $dimensionCount) }
                    Queue-SessionStateSave
                    Stop-DeferredTextZoneWarmup
                    return
                }

                $script:PdfTextLayerZones = @()
                $script:TextZoneCacheKey = $textZoneKey
                $script:TextZoneCacheResolved = $true
                Save-CurrentPageTextZoneCache
                if($txtOcrDebug){
                    $txtOcrDebug.Text = "Zone mode: PDF text layer" + [Environment]::NewLine + "Text zones: 0" + [Environment]::NewLine + "Dimension-like: 0" + [Environment]::NewLine + "No PDF text layer detected."
                }
                Queue-SessionStateSave
                Request-CanvasRedraw
                Stop-DeferredTextZoneWarmup
                return
            }
            default {
                Stop-DeferredTextZoneWarmup
                return
            }
        }
    }
    catch{
        if($txtOcrDebug){ $txtOcrDebug.Text = "Text-zone warmup failed: $($_.Exception.Message)" }
        Stop-DeferredTextZoneWarmup
    }
    finally{
        $script:IsDeferredTextZoneWarmupRunning = $false
    }
}

function Get-HiddenTextZoneCandidateAtPoint($point){
    if(!$point){ return $null }
    if(-not (Ensure-HiddenTextZonesLoaded)){ return $null }

    $zones = @($script:PdfTextLayerZones)
    $hitItems = @()

    for($i = $zones.Count - 1; $i -ge 0; $i--){
        $zone = $zones[$i]
        if(!$zone -or !$zone.Rect -or -not $zone.IsDimension){ continue }
        if(-not $zone.Rect.Contains([int]$point.X,[int]$point.Y)){ continue }

        $zoneSource = if($zone.PSObject.Properties.Name -contains "Source"){ [string]$zone.Source } else { "" }

        # Accepted text-zone suggestions create MarkStep boxes. Do not let those accepted
        # boxes sit on top and block nearby unaccepted candidates in dense stacked text.
        if($zoneSource -ne "MarkStep" -and $zone.PSObject.Properties.Name -contains "HiddenSuggestAccepted" -and [bool]$zone.HiddenSuggestAccepted){ continue }

        $area = [double]([Math]::Max(1,$zone.Rect.Width) * [Math]::Max(1,$zone.Rect.Height))
        $priority = if($zoneSource -eq "MarkStep"){ 1 } else { 0 }
        $adaptiveBias = if($zoneSource -eq "MarkStep"){ 0.0 } else { Get-AdaptiveDetectorBias $zone }
        $hitItems += [PSCustomObject]@{
            Index = [int]$i
            Priority = [int]$priority
            Area = [double]$area
            Bias = [double]$adaptiveBias
        }
    }

    $hitItems = @($hitItems | Sort-Object @{ Expression = { $_.Priority }; Descending = $false }, @{ Expression = { $_.Bias }; Descending = $true }, @{ Expression = { $_.Area }; Descending = $false })

    foreach($hitItem in $hitItems){
        $i = [int]$hitItem.Index
        $zone = $zones[$i]
        if(!$zone -or !$zone.Rect -or -not $zone.IsDimension){ continue }
        $zoneSource = if($zone.PSObject.Properties.Name -contains "Source"){ [string]$zone.Source } else { "" }

        if($zoneSource -eq "MarkStep"){
            $nom = if($zone.PSObject.Properties.Name -contains "Nominal" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Nominal)){ [string]$zone.Nominal } else { [string]$zone.Text }
            $candidate = [PSCustomObject]@{
                Nominal = $nom
                RawText = if($zone.PSObject.Properties.Name -contains "RawText"){ [string]$zone.RawText } else { $nom }
                LabelText = [string]$zone.Text
                LabelNominal = $nom
                BboxText = [string]$zone.Text
                BboxItemIndex = 0
                BboxItemCount = 1
                Rect = $zone.Rect
                Angle = 0
                Tolerance = if($zone.PSObject.Properties.Name -contains "Tolerance"){ $zone.Tolerance } else { $null }
                Source = "MarkStep"
                RowIndex = if($zone.PSObject.Properties.Name -contains "RowIndex"){ [int]$zone.RowIndex } else { -1 }
                MarkStepIndex = if($zone.PSObject.Properties.Name -contains "MarkStepIndex"){ [int]$zone.MarkStepIndex } else { -1 }
                ZoneIndex = [int]$i
            }
            return $candidate
        }

        if(Test-IsPdfTextLayerBackedZone $zone){
            $candidate = New-DirectAutoMapCandidateFromZone $zone $i
            if($candidate){ return $candidate }
        }

        $candidates = @(Convert-TextZonesToAutoMapCandidates @($zone))
        if($candidates.Count -le 0){ continue }
        $candidate = $candidates[0]
        if(!$candidate -or [string]::IsNullOrWhiteSpace([string]$candidate.Nominal)){ continue }
        $candidate | Add-Member -NotePropertyName ZoneIndex -NotePropertyValue ([int]$i) -Force

        # If this raw text-zone is the same accepted dimension, skip it and let the
        # MarkStep zone behind it handle hover/result input. This avoids showing
        # "DUP self?" after we changed hit-test priority for dense stacked zones.
        if(Test-CandidateAlreadyAcceptedAsStep $candidate){ continue }

        # Hidden copilot layer is suggestion-only. Show every parseable text-zone;
        # user confirmation via Enter/double-click is the confidence gate.
        return $candidate
    }

    return $null
}

function Update-HiddenTextZoneHoverFromPoint($point){
    if(!$script:sourceBitmap -or !$point){ return }
    if($script:dragging -or $script:isPanning -or $script:isDraggingMark -or $script:IsDraggingTextZone){ return }
    if($script:PendingManualDuplicateCandidate){ return }

    $candidate = Get-HiddenTextZoneCandidateAtPoint $point
    if(!$candidate -and (Test-HiddenDuplicateGhostHit $point)){
        $candidate = $script:HiddenTextZoneHoverCandidate
    }
    if($candidate){
        $candidate = Set-HiddenCandidateDuplicateInfo $candidate
    }
    $newIndex = if($candidate -and $candidate.PSObject.Properties.Name -contains "ZoneIndex"){ [int]$candidate.ZoneIndex } else { -1 }
    if($newIndex -eq $script:HiddenTextZoneHoverIndex -and $candidate -eq $script:HiddenTextZoneHoverCandidate){ return }

    $script:HiddenTextZoneHoverIndex = $newIndex
    $script:HiddenTextZoneHoverCandidate = $candidate

    if($candidate){
        $suggestLabel = Get-HiddenTextZoneSuggestLabel $candidate
        $duplicateLine = ""
        if($candidate.PSObject.Properties.Name -contains "DuplicateMatch" -and $candidate.DuplicateMatch){
            $duplicateLine = "Duplicate: step " + [string]$candidate.DuplicateMatch.Step + " ?  Enter/click = link only; E = keep new" + [Environment]::NewLine
        }
        if($txtOcrDebug){
            $txtOcrDebug.Text = (
                "Suggest: " + $suggestLabel + [Environment]::NewLine +
                $duplicateLine +
                "Raw: " + [string]$candidate.RawText + [Environment]::NewLine +
                "Enter / double click to accept; E = keep new; drag red crop to rescan"
            )
        }
    }
    else{
        $script:HiddenDuplicateOriginalRect = $null
        $script:HiddenDuplicateGhostRect = $null
        $script:SelectedDuplicateAnchorStep = $null
        $script:SelectedDuplicateSteps = @{}
    }

    Request-CanvasRedraw
}

function Accept-HiddenTextZoneHover{
    $candidate = $script:HiddenTextZoneHoverCandidate
    if(!$candidate){ return $false }

    if(Test-CandidateAlreadyAcceptedAsStep $candidate){
        Clear-HiddenTextZoneHover
        Request-CanvasRedraw
        return $true
    }

    if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){
        $ziAccepted = [int]$candidate.ZoneIndex
        if($ziAccepted -ge 0 -and $ziAccepted -lt @($script:PdfTextLayerZones).Count){
            $zone = $script:PdfTextLayerZones[$ziAccepted]
            if($zone -and $zone.PSObject.Properties.Name -contains "HiddenSuggestAccepted" -and [bool]$zone.HiddenSuggestAccepted){
                Clear-HiddenTextZoneHover
                Request-CanvasRedraw
                return $true
            }
        }
    }

    if($candidate.PSObject.Properties.Name -contains "DuplicateMatch" -and $candidate.DuplicateMatch){
        if(Link-HiddenDuplicateCandidate $candidate){
            Record-AdaptiveDetectorFeedback $candidate "link"
            if(-not (Test-IsTextZoneOnlyCandidateSource $candidate.Source)){
                Register-DetectorAnnotationSilent "positive" $candidate.Rect ([ordered]@{
                    Source = (Get-AdaptiveDetectorSourceName $candidate)
                    Label = [string]$candidate.Nominal
                    Raw = [string]$candidate.RawText
                    Origin = "duplicate_link"
                })
            }
            $wasManualDuplicate = ($null -ne $script:PendingManualDuplicateCandidate)
            if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){
                $zi = [int]$candidate.ZoneIndex
                if($zi -ge 0 -and $zi -lt @($script:PdfTextLayerZones).Count){
                    $script:PdfTextLayerZones[$zi] | Add-Member -NotePropertyName HiddenSuggestAccepted -NotePropertyValue $true -Force
                }
            }
            if($wasManualDuplicate){
                $script:selectionRect = $null
                Clear-PreviewImage
                if($txtOcrDebug){
                    $txtOcrDebug.Text = (
                        "Duplicate red crop linked as copy" + [Environment]::NewLine +
                        "Copied step: " + [string]$candidate.DuplicateMatch.Step
                    )
                }
            }
            Clear-HiddenTextZoneHover
            Request-CanvasRedraw
            return $true
        }
    }

    # Final duplicate gate before creating a new OCR row. This is intentionally
    # independent from row duplicate UI: accepted rows are not highlighted, but a
    # new unaccepted candidate with the same nominal/tolerance must stop and ask.
    $candidate = Set-HiddenCandidateDuplicateInfo $candidate
    if($candidate -and $candidate.PSObject.Properties.Name -contains "DuplicateMatch" -and $candidate.DuplicateMatch){
        $script:HiddenTextZoneHoverCandidate = $candidate
        $script:HiddenTextZoneHoverIndex = if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){ [int]$candidate.ZoneIndex } else { -1 }

        if($txtOcrDebug){
            $txtOcrDebug.Text = (
                "Suggest: " + (Get-HiddenTextZoneSuggestLabel $candidate) + [Environment]::NewLine +
                "Duplicate: step " + [string]$candidate.DuplicateMatch.Step + " ?  Enter/click = link only; E/right click = keep new" + [Environment]::NewLine +
                "Raw: " + [string]$candidate.RawText
            )
        }

        Request-CanvasRedraw
        return $true
    }

    $candidate | Add-Member -NotePropertyName DuplicateCheckPassed -NotePropertyValue $true -Force
    if(Add-OcrCandidateToTable $candidate){
        Record-AdaptiveDetectorFeedback $candidate "accept"
        $lastRow = $table.Rows.Count - 1
        if($lastRow -ge 0){
            $table.ClearSelection()
            $table.Rows[$lastRow].Selected = $true
            $table.CurrentCell = $table.Rows[$lastRow].Cells[0]
            $table.FirstDisplayedScrollingRowIndex = $lastRow
        }
        if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){
            $zi = [int]$candidate.ZoneIndex
            if($zi -ge 0 -and $zi -lt @($script:PdfTextLayerZones).Count){
                $script:PdfTextLayerZones[$zi] | Add-Member -NotePropertyName HiddenSuggestAccepted -NotePropertyValue $true -Force
            }
        }
        Clear-HiddenTextZoneHover
        Request-CanvasRedraw
        Queue-AcceptSuggestionPostUpdate
        return $true
    }
    return $false
}

function Draw-HiddenTextZoneSuggestion($graphics){
    if(!$graphics){ return }
    $candidate = $script:HiddenTextZoneHoverCandidate
    if(!$candidate -or !$candidate.Rect){ return }

    $rect = $candidate.Rect
    $isDuplicateSuggest = ($candidate.PSObject.Properties.Name -contains "DuplicateMatch" -and $candidate.DuplicateMatch)
    $isResultReady = (
        -not $isDuplicateSuggest -and
        $candidate.PSObject.Properties.Name -contains "Source" -and
        [string]$candidate.Source -eq "MarkStep" -and
        $candidate.PSObject.Properties.Name -contains "RowIndex" -and
        [int]$candidate.RowIndex -ge 0
    )
    $lineWidth = if($isDuplicateSuggest){
        [float][Math]::Max(2.2,(6.0 / [Math]::Max($script:zoom,0.0001)))
    }
    elseif($isResultReady){
        [float][Math]::Max(1.8,(4.5 / [Math]::Max($script:zoom,0.0001)))
    }
    else{
        [float][Math]::Max(1.0,(2.4 / [Math]::Max($script:zoom,0.0001)))
    }
    $fontSize = if($isDuplicateSuggest){
        [float][Math]::Max(8.0,(15.0 / [Math]::Max($script:zoom,0.0001)))
    }
    elseif($isResultReady){
        [float][Math]::Max(7.0,(12.0 / [Math]::Max($script:zoom,0.0001)))
    }
    else{
        [float][Math]::Max(5.0,(8.0 / [Math]::Max($script:zoom,0.0001)))
    }
    $pen = $null
    $brush = $null
    $labelBrush = $null
    $labelBack = $null
    $font = $null
    $ghostFill = $null
    $ghostPen = $null
    $ghostTextBrush = $null
    $originalPen = $null
    $bannerBrush = $null
    $bannerTextBrush = $null
    $shadowPen = $null
    try{
        # Match the Text Zones layer style closely; hover is only a temporary
        # accept hint, using the same nominal/tolerance candidate as data label.
        $strokeColor = if($isDuplicateSuggest){ [Drawing.Color]::FromArgb(255,255,72,0) } elseif($isResultReady){ [Drawing.Color]::FromArgb(245,0,160,75) } else { [Drawing.Color]::FromArgb(245,0,120,215) }
        $fillColor = if($isDuplicateSuggest){ [Drawing.Color]::FromArgb(118,255,230,0) } elseif($isResultReady){ [Drawing.Color]::FromArgb(42,0,200,90) } else { [Drawing.Color]::FromArgb(22,0,120,215) }
        $textColor = if($isDuplicateSuggest){ [Drawing.Color]::FromArgb(255,180,0,0) } elseif($isResultReady){ [Drawing.Color]::FromArgb(255,0,120,50) } else { [Drawing.Color]::FromArgb(245,0,70,130) }
        $pen = New-Object Drawing.Pen($strokeColor,$lineWidth)
        $brush = New-Object Drawing.SolidBrush($fillColor)
        $labelBrush = New-Object Drawing.SolidBrush($textColor)
        $labelBack = if($isDuplicateSuggest){
            New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(245,255,245,120))
        }
        elseif($isResultReady){
            New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(235,218,255,225))
        }
        else{
            New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(220,255,255,255))
        }
        $font = New-Object Drawing.Font("Segoe UI",$fontSize,[Drawing.FontStyle]::Bold)

        if($isDuplicateSuggest){
            $shadowPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(180,255,255,0),[float]($lineWidth * 2.2))
            $graphics.DrawRectangle($shadowPen,$rect)
        }
        $graphics.FillRectangle($brush,$rect)
        $graphics.DrawRectangle($pen,$rect)

        $label = if($isDuplicateSuggest){
            "DUP " + [string]$candidate.DuplicateMatch.Step + "?"
        }
        else{
            Get-HiddenTextZoneSuggestLabel $candidate
        }
        $pt = New-Object Drawing.PointF([float]$rect.X,[float]([Math]::Max(0,($rect.Y - ($fontSize * 1.85)))))
        $sz = $graphics.MeasureString($label,$font)
        $labelRect = New-Object Drawing.RectangleF($pt.X,$pt.Y,[float]($sz.Width + 6),[float]($sz.Height + 2))
        $graphics.FillRectangle($labelBack,$labelRect)
        $graphics.DrawString($label,$font,$labelBrush,$pt)

        if($isDuplicateSuggest){
            $ghostRect = Get-HiddenDuplicateGhostRect $candidate
            if($ghostRect){
                $inflateBy = [float][Math]::Max(6.0,(10.0 / [Math]::Max($script:zoom,0.0001)))
                $ghostRect.Inflate($inflateBy,$inflateBy)
                $script:HiddenDuplicateGhostRect = $ghostRect
                $ghostFill = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(245,255,246,120))
                $ghostPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,255,72,0),[float][Math]::Max(2.0,(5.0 / [Math]::Max($script:zoom,0.0001))))
                $ghostTextBrush = New-Object Drawing.SolidBrush([Drawing.Color]::Red)
                $graphics.FillEllipse($ghostFill,$ghostRect)
                $graphics.DrawEllipse($ghostPen,$ghostRect)
                $ghostText = [string]$candidate.DuplicateMatch.Step + "?"
                $ghostFontSize = [float][Math]::Max(12.0,(26.0 / [Math]::Max($script:zoom,0.0001)))
                $ghostFont = New-Object Drawing.Font("Arial",$ghostFontSize,[Drawing.FontStyle]::Bold)
                try{
                    $ghostTextSize = $graphics.MeasureString($ghostText,$ghostFont)
                    $graphics.DrawString(
                        $ghostText,
                        $ghostFont,
                        $ghostTextBrush,
                        [float]($ghostRect.X + (($ghostRect.Width - $ghostTextSize.Width) / 2.0)),
                        [float]($ghostRect.Y + (($ghostRect.Height - $ghostTextSize.Height) / 2.0))
                    )
                }
                finally{
                    if($ghostFont){ $ghostFont.Dispose() }
                }
            }

            if($script:HiddenDuplicateOriginalRect){
                $originalPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,255,72,0),[float][Math]::Max(2.5,(5.5 / [Math]::Max($script:zoom,0.0001))))
                $originalPen.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash
                $graphics.DrawRectangle($originalPen,$script:HiddenDuplicateOriginalRect)
            }
        }
    }
    finally{
        if($pen){ $pen.Dispose() }
        if($brush){ $brush.Dispose() }
        if($labelBrush){ $labelBrush.Dispose() }
        if($labelBack){ $labelBack.Dispose() }
        if($font){ $font.Dispose() }
        if($ghostFill){ $ghostFill.Dispose() }
        if($ghostPen){ $ghostPen.Dispose() }
        if($ghostTextBrush){ $ghostTextBrush.Dispose() }
        if($originalPen){ $originalPen.Dispose() }
        if($bannerBrush){ $bannerBrush.Dispose() }
        if($bannerTextBrush){ $bannerTextBrush.Dispose() }
        if($shadowPen){ $shadowPen.Dispose() }
    }
}

function Test-TextZonePreviewDuplicate($candidate,$existingZones){

    if(!$candidate -or !$candidate.Rect){ return $false }

    foreach($existing in @($existingZones)){
        if(!$existing -or !$existing.Rect){ continue }

        $left = [Math]::Max($existing.Rect.Left,$candidate.Rect.Left)
        $top = [Math]::Max($existing.Rect.Top,$candidate.Rect.Top)
        $right = [Math]::Min($existing.Rect.Right,$candidate.Rect.Right)
        $bottom = [Math]::Min($existing.Rect.Bottom,$candidate.Rect.Bottom)
        $intersection = [Math]::Max(0,($right - $left)) * [Math]::Max(0,($bottom - $top))
        if($intersection -le 0){ continue }

        $candidateArea = [Math]::Max(1,([double]$candidate.Rect.Width * [double]$candidate.Rect.Height))
        $existingArea = [Math]::Max(1,([double]$existing.Rect.Width * [double]$existing.Rect.Height))
        $overlap = $intersection / [Math]::Max(1,[Math]::Min($candidateArea,$existingArea))
        if($overlap -gt 0.82){ return $true }
    }

    return $false
}

function Get-UnionTextZoneRect($a,$b,$pad = 6){

    if(!$a -or !$b){ return $null }
    $left = [Math]::Min([int]$a.Left,[int]$b.Left) - [int]$pad
    $top = [Math]::Min([int]$a.Top,[int]$b.Top) - [int]$pad
    $right = [Math]::Max([int]$a.Right,[int]$b.Right) + [int]$pad
    $bottom = [Math]::Max([int]$a.Bottom,[int]$b.Bottom) + [int]$pad

    if($script:sourceBitmap){
        $left = [Math]::Max(0,$left)
        $top = [Math]::Max(0,$top)
        $right = [Math]::Min($script:sourceBitmap.Width,$right)
        $bottom = [Math]::Min($script:sourceBitmap.Height,$bottom)
    }

    if($right -le $left -or $bottom -le $top){ return $null }
    return New-Object Drawing.Rectangle($left,$top,($right - $left),($bottom - $top))
}

function Test-RawTextZoneMergeCandidate($zone){

    if(!$zone -or !$zone.Rect){ return $false }
    if($zone.PSObject.Properties.Name -contains "IsDimension" -and [bool]$zone.IsDimension){ return $false }

    $source = if($zone.PSObject.Properties.Name -contains "Source"){ [string]$zone.Source } else { "" }
    if($source -notmatch 'OpenCvText|OpenCvRailMergedTextLine|RapidOcrDetectedText|PaddleOcrDetectedText|SecondPassCluster'){ return $false }

    $r = $zone.Rect
    if($r.Width -le 2 -or $r.Height -le 2){ return $false }
    if(Test-AutoOcrTitleBlockRect $r){ return $false }

    # Merge small/medium candidate boxes. Very large boxes are usually accidental
    # drawing/table regions and should not pull nearby text into a huge crop.
    $area = [double]$r.Width * [double]$r.Height
    if($area -gt 220000){ return $false }
    return $true
}

function Get-RawTextZoneText($zone){

    if(!$zone){ return "" }
    if($zone.PSObject.Properties.Name -contains "RawText" -and -not [string]::IsNullOrWhiteSpace([string]$zone.RawText)){
        return [string]$zone.RawText
    }
    if($zone.PSObject.Properties.Name -contains "Text" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Text)){
        return [string]$zone.Text
    }
    return ""
}

function Get-RawTextZoneNominalCandidate($zone){

    $text = Get-RawTextZoneText $zone
    $nominal = ""
    if($zone -and $zone.PSObject.Properties.Name -contains "Nominal" -and -not [string]::IsNullOrWhiteSpace([string]$zone.Nominal)){
        $nominal = [string]$zone.Nominal
    }
    if([string]::IsNullOrWhiteSpace($nominal) -and -not [string]::IsNullOrWhiteSpace($text)){
        $nominal = Get-PdfTextLayerNominal $text
    }
    if([string]::IsNullOrWhiteSpace($nominal) -and -not [string]::IsNullOrWhiteSpace($text)){
        $resolved = Resolve-OcrTextAsMechanicalNominal $text $zone.Rect $text
        $nominal = [string]$resolved.Nominal
    }
    if([string]::IsNullOrWhiteSpace($nominal) -and (Test-UseOcrFallbackTextZoneRules)){
        $analysis = Get-RawTextZoneFragmentAnalysis $zone
        if($analysis){
            $nominal = [string]$analysis.Nominal
        }
    }

    return (Normalize-DegreeNominalSign $nominal)
}

function Get-RawTextZoneToleranceCandidate($zone,$nominal = ""){

    $text = Get-RawTextZoneText $zone
    $existing = $null
    if($zone.PSObject.Properties.Name -contains "Tolerance" -and $zone.Tolerance){
        $existing = $zone.Tolerance
    }
    $tolerance = $null
    if(-not [string]::IsNullOrWhiteSpace($text)){
        $tolerance = Get-PreferredTolerance $existing $text $nominal
    }
    if($tolerance -and $tolerance.Detected -and (Test-ExplicitToleranceText $text)){
        return $tolerance
    }
    if(Test-UseOcrFallbackTextZoneRules){
        $analysis = Get-RawTextZoneFragmentAnalysis $zone
        if($analysis -and $analysis.HasExplicitTolerance -and $analysis.Tolerance -and $analysis.Tolerance.Detected){
            return $analysis.Tolerance
        }
    }

    return $null
}

function Get-RawTextClusterText($cluster){

    $items = @($cluster | Where-Object { $_ -and $_.Rect })
    if($items.Count -le 0){ return "" }

    $clusterRect = $null
    foreach($item in $items){
        if(!$clusterRect){
            $clusterRect = New-Object Drawing.Rectangle($item.Rect.X,$item.Rect.Y,$item.Rect.Width,$item.Rect.Height)
        }
        else{
            $clusterRect = Get-UnionTextZoneRect $clusterRect $item.Rect 0
        }
    }

    if(!$clusterRect){ return "" }

    $sortVertical = ($clusterRect.Height -gt ($clusterRect.Width * 1.15))
    $ordered = if($sortVertical){
        @($items | Sort-Object @{ Expression = { $_.Rect.Top }; Descending = $false }, @{ Expression = { $_.Rect.Left }; Descending = $false })
    }
    else{
        @($items | Sort-Object @{ Expression = { $_.Rect.Left }; Descending = $false }, @{ Expression = { $_.Rect.Top }; Descending = $false })
    }

    $parts = @($ordered | ForEach-Object { Get-RawTextZoneText $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if($sortVertical){
        return (Collapse-SpacedMechanicalDimensionText ($parts -join ' '))
    }

    return ($parts -join ' ')
}

function Test-RawTextZonesShouldMerge($a,$b){

    if(-not (Test-RawTextZoneMergeCandidate $a)){ return $false }
    if(-not (Test-RawTextZoneMergeCandidate $b)){ return $false }
    if(-not (Test-UseOcrFallbackTextZoneRules)){ return $false }

    $ra = $a.Rect
    $rb = $b.Rect
    $h = [double][Math]::Max(1,[Math]::Max($ra.Height,$rb.Height))
    $w = [double][Math]::Max(1,[Math]::Max($ra.Width,$rb.Width))

    $gapX = [Math]::Max(0,[Math]::Max($ra.Left,$rb.Left) - [Math]::Min($ra.Right,$rb.Right))
    $gapY = [Math]::Max(0,[Math]::Max($ra.Top,$rb.Top) - [Math]::Min($ra.Bottom,$rb.Bottom))
    $centerYDiff = [Math]::Abs(($ra.Top + ($ra.Height / 2.0)) - ($rb.Top + ($rb.Height / 2.0)))
    $centerXDiff = [Math]::Abs(($ra.Left + ($ra.Width / 2.0)) - ($rb.Left + ($rb.Width / 2.0)))
    $aVertical = $ra.Height -gt ($ra.Width * 1.35)
    $bVertical = $rb.Height -gt ($rb.Width * 1.35)

    $aAnalysis = Get-RawTextZoneFragmentAnalysis $a
    $bAnalysis = Get-RawTextZoneFragmentAnalysis $b
    $aNominal = Get-RawTextZoneNominalCandidate $a
    $bNominal = Get-RawTextZoneNominalCandidate $b
    $aTolerance = Get-RawTextZoneToleranceCandidate $a $aNominal
    $bTolerance = Get-RawTextZoneToleranceCandidate $b $bNominal
    $aHasExplicitTolerance = [bool]($aAnalysis -and $aAnalysis.HasExplicitTolerance)
    $bHasExplicitTolerance = [bool]($bAnalysis -and $bAnalysis.HasExplicitTolerance)
    $pairedNominalTolerance = (
        ((-not [string]::IsNullOrWhiteSpace($aNominal)) -and $bTolerance -and (Test-MechanicalTolerancePlausible $bTolerance $aNominal)) -or
        ((-not [string]::IsNullOrWhiteSpace($bNominal)) -and $aTolerance -and (Test-MechanicalTolerancePlausible $aTolerance $bNominal))
    )
    $mergeOnlyForTolerance = ($pairedNominalTolerance -or $aHasExplicitTolerance -or $bHasExplicitTolerance)
    if(-not $mergeOnlyForTolerance){ return $false }

    if($gapX -le [Math]::Max(14,($h * 1.4)) -and $centerYDiff -le ($h * 0.75)){
        return $true
    }
    if($gapY -le [Math]::Max(12,($h * 0.95)) -and $centerXDiff -le [Math]::Max(24,($w * 0.75))){
        return $true
    }
    if($aVertical -or $bVertical){
        if($gapY -le [Math]::Max(18,($h * 0.55)) -and $centerXDiff -le [Math]::Max(18,($w * 0.85))){
            return $true
        }
        if($gapX -le [Math]::Max(14,($w * 0.75)) -and $centerYDiff -le [Math]::Max(28,($h * 0.55))){
            return $true
        }
    }

    if($pairedNominalTolerance){
        if($gapX -le [Math]::Max(28,($h * 2.1)) -and $centerYDiff -le [Math]::Max(24,($h * 1.15))){
            return $true
        }
        if($gapY -le [Math]::Max(28,($h * 1.45)) -and $centerXDiff -le [Math]::Max(36,($w * 1.2))){
            return $true
        }
        if(($aVertical -or $bVertical) -and $gapY -le [Math]::Max(34,($h * 1.1)) -and $centerXDiff -le [Math]::Max(30,($w * 1.1))){
            return $true
        }
    }

    return $false
}

function Add-RawTextRailMergeZones($rawZones){

    if(-not (Test-UseOcrFallbackTextZoneRules)){ return @($rawZones) }

    $items = @($rawZones | Where-Object { Test-RawTextZoneMergeCandidate $_ })
    if($items.Count -le 1){ return @($rawZones) }

    $extra = @()
    $usedPairs = @{}

    for($i = 0; $i -lt $items.Count; $i++){
        $base = $items[$i]
        if(!$base -or !$base.Rect){ continue }
        $cluster = @($base)
        $r = $base.Rect
        $baseCx = $r.Left + ($r.Width / 2.0)
        $baseCy = $r.Top + ($r.Height / 2.0)
        $baseH = [double][Math]::Max(1,$r.Height)
        $baseW = [double][Math]::Max(1,$r.Width)

        for($j = 0; $j -lt $items.Count; $j++){
            if($j -eq $i){ continue }
            $other = $items[$j]
            if(!$other -or !$other.Rect){ continue }
            $o = $other.Rect
            $ocx = $o.Left + ($o.Width / 2.0)
            $ocy = $o.Top + ($o.Height / 2.0)
            $oh = [double][Math]::Max(1,$o.Height)
            $ow = [double][Math]::Max(1,$o.Width)
            $h = [Math]::Max($baseH,$oh)
            $w = [Math]::Max($baseW,$ow)

            $gapX = [Math]::Max(0,[Math]::Max($r.Left,$o.Left) - [Math]::Min($r.Right,$o.Right))
            $gapY = [Math]::Max(0,[Math]::Max($r.Top,$o.Top) - [Math]::Min($r.Bottom,$o.Bottom))
            $sameHorizontalRail = ([Math]::Abs($baseCy - $ocy) -le [Math]::Max(18,($h * 1.35))) -and ($gapX -le [Math]::Max(90,($h * 5.0)))
            $sameVerticalRail = ([Math]::Abs($baseCx - $ocx) -le [Math]::Max(18,($w * 1.05))) -and ($gapY -le [Math]::Max(72,($h * 2.6)))

            if(($sameHorizontalRail -or $sameVerticalRail) -and (Test-RawTextZonesShouldMerge $base $other)){
                $cluster += $other
            }
        }

        if($cluster.Count -lt 2){ continue }
        $clusterRect = $null
        foreach($z in $cluster){
            if(!$clusterRect){ $clusterRect = New-Object Drawing.Rectangle($z.Rect.X,$z.Rect.Y,$z.Rect.Width,$z.Rect.Height) }
            else{ $clusterRect = Get-UnionTextZoneRect $clusterRect $z.Rect 5 }
        }
        if(!$clusterRect){ continue }
        $area = [double]$clusterRect.Width * [double]$clusterRect.Height
        if($area -gt 280000){ continue }
        if(Test-AutoOcrTitleBlockRect $clusterRect){ continue }

        $key = "{0}:{1}:{2}:{3}" -f $clusterRect.X,$clusterRect.Y,$clusterRect.Width,$clusterRect.Height
        if($usedPairs.ContainsKey($key)){ continue }
        $usedPairs[$key] = $true

        $clusterText = Get-RawTextClusterText $cluster

        $extra += [PSCustomObject]@{
            Text = if([string]::IsNullOrWhiteSpace($clusterText)){ "Text" } else { $clusterText }
            RawText = $clusterText
            Rect = $clusterRect
            IsDimension = $false
            Source = "OpenCvRailMergedTextLine"
            ClusterCount = [int]$cluster.Count
        }
    }

    return @($rawZones) + @($extra)
}

function Merge-RawTextZoneFragments($rawZones){

    $items = @($rawZones | Where-Object { $_ -and $_.Rect })
    if($items.Count -le 1){ return @($items) }

    $used = New-Object bool[] $items.Count
    $merged = @()

    for($i = 0; $i -lt $items.Count; $i++){
        if($used[$i]){ continue }
        $zone = $items[$i]
        if(!$zone -or !$zone.Rect){ continue }

        if(-not (Test-RawTextZoneMergeCandidate $zone)){
            $used[$i] = $true
            $merged += $zone
            continue
        }

        $cluster = @($zone)
        $clusterRect = New-Object Drawing.Rectangle($zone.Rect.X,$zone.Rect.Y,$zone.Rect.Width,$zone.Rect.Height)
        $changed = $true
        while($changed){
            $changed = $false
            for($j = 0; $j -lt $items.Count; $j++){
                if($used[$j] -or $j -eq $i){ continue }
                $other = $items[$j]
                if(!$other -or !$other.Rect){ continue }
                $probe = [PSCustomObject]@{
                    Rect = $clusterRect
                    Source = "OpenCvTextCluster"
                    IsDimension = $false
                    RawText = (Get-RawTextClusterText $cluster)
                }
                if(Test-RawTextZonesShouldMerge $probe $other){
                    $used[$j] = $true
                    $cluster += $other
                    $clusterRect = Get-UnionTextZoneRect $clusterRect $other.Rect 4
                    $changed = $true
                }
            }
        }

        $used[$i] = $true
        if($cluster.Count -gt 1 -and $clusterRect){
            $clusterText = Get-RawTextClusterText $cluster

            $merged += [PSCustomObject]@{
                Text = if([string]::IsNullOrWhiteSpace($clusterText)){ "Text" } else { $clusterText }
                RawText = $clusterText
                Rect = $clusterRect
                IsDimension = $false
                Source = "OpenCvMergedTextLine"
                ClusterCount = [int]$cluster.Count
            }
        }
        else{
            $merged += $zone
        }
    }

    return @(
        $merged |
        Sort-Object @{ Expression = { $_.Rect.Y }; Descending = $false }, @{ Expression = { $_.Rect.X }; Descending = $false }
    )
}

function Merge-TextZonePreviewSources($dimensionZones,$rawZones){

    $merged = @()
    foreach($zone in @($dimensionZones)){
        if($zone -and $zone.Rect){ $merged += $zone }
    }

    # Keep unmatched raw detector zones visible as "needs review" boxes: they can
    # represent real dimensions whose label parsing failed. Only suppress raw
    # zones that are effectively duplicates of an already-labeled preview box.
    foreach($zone in @($rawZones)){
        if(!$zone -or !$zone.Rect){ continue }
        if(Test-TextZonePreviewDuplicate $zone $merged){ continue }
        $merged += $zone
    }

    return @(
        $merged |
        Sort-Object @{ Expression = { $_.Rect.Y }; Descending = $false }, @{ Expression = { $_.Rect.X }; Descending = $false }
    )
}

function Refresh-PdfTextLayerZones{

    if(!$script:sourceBitmap){ return @() }
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){ return @() }

    $pageNumber = 1
    if($script:SelectedPageIndex -ge 0){
        $pageNumber = $script:SelectedPageIndex + 1
    }

    $mapRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)
    $textZoneKey = Get-AutoOcrMapRectKey $mapRect
    $currentPage = Get-CurrentDocumentPage

    if(
        $currentPage -and
        $currentPage.PSObject.Properties.Name -contains 'TextZoneCacheKey' -and
        $currentPage.TextZoneCacheKey -eq $textZoneKey -and
        $currentPage.PSObject.Properties.Name -contains 'PdfTextLayerZones' -and
        (
            (
                @($currentPage.PdfTextLayerZones).Count -gt 0
            ) -or
            (
                $currentPage.PSObject.Properties.Name -contains 'TextZoneCacheResolved' -and
                [bool]$currentPage.TextZoneCacheResolved
            )
        )
    ){
        $script:PdfTextLayerZones = @($currentPage.PdfTextLayerZones)
        $script:TextZoneCacheKey = $currentPage.TextZoneCacheKey
        $script:TextZoneCacheResolved = if($currentPage.PSObject.Properties.Name -contains 'TextZoneCacheResolved'){ [bool]$currentPage.TextZoneCacheResolved } else { $false }
    }

    if(
        $script:TextZoneCacheKey -eq $textZoneKey -and
        (
            (
                $script:PdfTextLayerZones -and
                @($script:PdfTextLayerZones).Count -gt 0
            ) -or
            (
                $script:TextZoneCacheResolved
            )
        )
    ){
        $dimensionCount = @($script:PdfTextLayerZones | Where-Object { $_.IsDimension }).Count
        $zoneMode = "Cached zones"
        $txtOcrDebug.Text = (
            "Zone mode: {0}" -f $zoneMode
        ) + [Environment]::NewLine + (
            "Text zones: {0}" -f $script:PdfTextLayerZones.Count
        ) + [Environment]::NewLine + (
            "Dimension-like: {0}" -f $dimensionCount
        )
        return @()
    }

    $script:PdfTextLayerZones = @()
    $script:TextZoneCacheKey = $textZoneKey
    $script:TextZoneCacheResolved = $false

    try{
        if($txtOcrDebug){
            $txtOcrDebug.Text = (
                "Loading text zones..." + [Environment]::NewLine +
                "Reading PDF text layer..."
            )
        }
        Begin-TransientInteractiveRender
        Request-CanvasRedraw
        [System.Windows.Forms.Application]::DoEvents()

        $blocks = @(Get-PdfTextLayerBlocks $script:CurrentSourcePath $pageNumber)
        $hasPdfTextLayer = (@($blocks).Count -gt 0)
        Set-CurrentPagePdfTextLayerAvailability $hasPdfTextLayer @($blocks).Count

        if($hasPdfTextLayer){
            $script:PdfTextLayerZones = @(Filter-SuppressedTextZones (Convert-PdfTextLayerBlocksToZones $blocks))
            $dimensionCount = @($script:PdfTextLayerZones | Where-Object { $_.IsDimension }).Count
            $zoneMode = "PDF text layer"
            $script:TextZoneCacheResolved = $true
        }
        else{
            $script:PdfTextLayerZones = @()
            $dimensionCount = 0
            $zoneMode = "PDF text layer"
            $script:TextZoneCacheResolved = $true
        }

        $txtOcrDebug.Text = (
            "Zone mode: {0}" -f $zoneMode
        ) + [Environment]::NewLine + (
            "Text zones: {0}" -f $script:PdfTextLayerZones.Count
        ) + [Environment]::NewLine + (
            "Dimension-like: {0}" -f $dimensionCount
        )
        if(-not $hasPdfTextLayer){
            $txtOcrDebug.Text += [Environment]::NewLine + "No PDF text layer detected."
        }
        Save-CurrentPageTextZoneCache
        return @($blocks)
    }
    catch{
        $txtOcrDebug.Text = "Text zones failed: $($_.Exception.Message)"
        return @()
    }
}

function Draw-PdfTextLayerZones($graphics){

    if(!$graphics -or !$script:ShowPdfTextZones){ return }
    if(!$script:PdfTextLayerZones -or @($script:PdfTextLayerZones).Count -le 0){ return }

    $zonePen = $null
    $dimensionPen = $null
    $zoneBrush = $null
    $dimensionBrush = $null
    $labelBrush = $null
    $labelBackBrush = $null
    $labelFont = $null
    $selectedPen = $null
    $handleBrush = $null

    try{
        $lineWidth = [float][Math]::Max(0.8,(1.6 / [Math]::Max($script:zoom,0.0001)))
        $fontSize = [float][Math]::Max(4.5,(7.5 / [Math]::Max($script:zoom,0.0001)))
        $zonePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(130,80,80,80),$lineWidth)
        $dimensionPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(230,0,120,215),[float]($lineWidth * 1.45))
        $zoneBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(20,90,90,90))
        $dimensionBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(34,0,120,215))
        $labelBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(230,0,70,130))
        $labelBackBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(190,255,255,255))
        $labelFont = New-Object Drawing.Font("Segoe UI",$fontSize,[Drawing.FontStyle]::Regular)
        $selectedPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(245,255,140,0),[float]($lineWidth * 2.1))
        $handleBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(245,255,140,0))

        for($zoneIndex = 0; $zoneIndex -lt @($script:PdfTextLayerZones).Count; $zoneIndex++){
            $zone = $script:PdfTextLayerZones[$zoneIndex]
            if(!$zone -or !$zone.Rect){ continue }
            $rect = $zone.Rect

            $zoneSource = ""
            if($zone.PSObject.Properties.Name -contains "Source"){
                $zoneSource = [string]$zone.Source
            }

            if($zone.IsDimension){
                $graphics.FillRectangle($dimensionBrush,$rect)
                $graphics.DrawRectangle($dimensionPen,$rect)
            }
            else{
                $graphics.FillRectangle($zoneBrush,$rect)
                $graphics.DrawRectangle($zonePen,$rect)
            }

            if($zoneIndex -eq $script:SelectedTextZoneIndex){
                $graphics.DrawRectangle($selectedPen,$rect)
                $handleSize = [float][Math]::Max(5.0,(8.0 / [Math]::Max($script:zoom,0.0001)))
                foreach($handlePoint in @(
                    @{ X = $rect.Left; Y = $rect.Top },
                    @{ X = $rect.Right; Y = $rect.Top },
                    @{ X = $rect.Left; Y = $rect.Bottom },
                    @{ X = $rect.Right; Y = $rect.Bottom }
                )){
                    $graphics.FillRectangle($handleBrush,[float]($handlePoint.X - ($handleSize / 2.0)),[float]($handlePoint.Y - ($handleSize / 2.0)),$handleSize,$handleSize)
                }
            }

            if($zone.IsDimension){
                $label = [string]$zone.Text
                if($zoneSource -eq "ImageOcrAuto"){
                    $label = "OCR " + $label
                }
                if($label.Length -gt 28){ $label = $label.Substring(0,28) }
                $labelPoint = New-Object Drawing.PointF(
                    [float]$rect.X,
                    [float]([Math]::Max(0,($rect.Y - ($fontSize * 1.4))))
                )
                $labelSize = $graphics.MeasureString($label,$labelFont)
                $labelRect = New-Object Drawing.RectangleF($labelPoint.X,$labelPoint.Y,$labelSize.Width,$labelSize.Height)
                $graphics.FillRectangle($labelBackBrush,$labelRect)
                $graphics.DrawString($label,$labelFont,$labelBrush,$labelPoint)
            }
        }
    }
    finally{
        if($zonePen){ $zonePen.Dispose() }
        if($dimensionPen){ $dimensionPen.Dispose() }
        if($zoneBrush){ $zoneBrush.Dispose() }
        if($dimensionBrush){ $dimensionBrush.Dispose() }
        if($labelBrush){ $labelBrush.Dispose() }
        if($labelBackBrush){ $labelBackBrush.Dispose() }
        if($labelFont){ $labelFont.Dispose() }
        if($selectedPen){ $selectedPen.Dispose() }
        if($handleBrush){ $handleBrush.Dispose() }
    }
}

function Get-TextZoneHit($point){

    if(!$script:ShowPdfTextZones -or !$point){ return $null }
    $zones = @($script:PdfTextLayerZones)
    $handleRadius = [double][Math]::Max(8.0,(12.0 / [Math]::Max($script:zoom,0.0001)))

    for($i = $zones.Count - 1; $i -ge 0; $i--){
        $zone = $zones[$i]
        if(!$zone -or !$zone.Rect){ continue }
        $r = $zone.Rect
        foreach($handle in @(
            @{ Mode = "ResizeTL"; X = $r.Left; Y = $r.Top },
            @{ Mode = "ResizeTR"; X = $r.Right; Y = $r.Top },
            @{ Mode = "ResizeBL"; X = $r.Left; Y = $r.Bottom },
            @{ Mode = "ResizeBR"; X = $r.Right; Y = $r.Bottom }
        )){
            if([Math]::Abs($point.X - $handle.X) -le $handleRadius -and [Math]::Abs($point.Y - $handle.Y) -le $handleRadius){
                return [PSCustomObject]@{ Index = $i; Mode = $handle.Mode }
            }
        }
        if($r.Contains([int]$point.X,[int]$point.Y)){
            return [PSCustomObject]@{ Index = $i; Mode = "Move" }
        }
    }
    return $null
}

function Get-DraggedTextZoneRect($point){

    if(!$script:TextZoneDragStartRect -or !$script:TextZoneDragStartPoint -or !$point){ return $null }
    $startRect = $script:TextZoneDragStartRect
    $dx = [double]$point.X - [double]$script:TextZoneDragStartPoint.X
    $dy = [double]$point.Y - [double]$script:TextZoneDragStartPoint.Y
    $left = [double]$startRect.Left
    $top = [double]$startRect.Top
    $right = [double]$startRect.Right
    $bottom = [double]$startRect.Bottom

    switch([string]$script:TextZoneDragMode){
        "Move" { $left += $dx; $right += $dx; $top += $dy; $bottom += $dy }
        "ResizeTL" { $left += $dx; $top += $dy }
        "ResizeTR" { $right += $dx; $top += $dy }
        "ResizeBL" { $left += $dx; $bottom += $dy }
        "ResizeBR" { $right += $dx; $bottom += $dy }
    }

    if($script:sourceBitmap){
        $left = [Math]::Max(0,[Math]::Min(($script:sourceBitmap.Width - 2),$left))
        $top = [Math]::Max(0,[Math]::Min(($script:sourceBitmap.Height - 2),$top))
        $right = [Math]::Max(($left + 2),[Math]::Min($script:sourceBitmap.Width,$right))
        $bottom = [Math]::Max(($top + 2),[Math]::Min($script:sourceBitmap.Height,$bottom))
    }

    return New-Object Drawing.Rectangle([int][Math]::Floor($left),[int][Math]::Floor($top),[int][Math]::Max(2,[Math]::Ceiling($right - $left)),[int][Math]::Max(2,[Math]::Ceiling($bottom - $top)))
}

function Get-TextZoneReadRect($rect){

    if(!$script:sourceBitmap -or !$rect){ return $rect }

    $strictRect = Convert-ToImageRect $rect
    if(!$strictRect){ return $rect }

    $readRect = Get-TightImageInkRect $script:sourceBitmap $strictRect
    return $readRect
}

function Test-UseOcrFallbackTextZoneRules{
    if(!$script:sourceBitmap -or [string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){ return $false }
    try{
        $availability = Get-CurrentPagePdfTextLayerAvailability
        return (-not [bool]$availability.HasPdfTextLayer)
    }
    catch{
        return $false
    }
}

function Join-MechanicalTextFragments($primaryText,$secondaryText){
    $left = [string]$primaryText
    $right = [string]$secondaryText
    if([string]::IsNullOrWhiteSpace($left)){ return $right.Trim() }
    if([string]::IsNullOrWhiteSpace($right)){ return $left.Trim() }

    $left = $left.Trim()
    $right = $right.Trim()
    $leftCompact = $left -replace '\s+',''
    $rightCompact = $right -replace '\s+',''

    if($leftCompact -eq $rightCompact){ return $left }
    if($rightCompact.Contains($leftCompact)){ return $right }
    if($leftCompact.Contains($rightCompact)){ return $left }
    return (($left + " " + $right).Trim())
}

function Get-TextZoneToleranceReadRect($rect){
    if(!$script:sourceBitmap -or !$rect){ return $rect }

    $strictRect = Convert-ToImageRect $rect
    if(!$strictRect){ return (Get-TextZoneReadRect $rect) }

    $readRect = Get-TextZoneReadRect $strictRect
    if(!$readRect){ $readRect = $strictRect }

    $orientationHint = Get-TextZoneOrientationHint $strictRect
    $isVertical = ([string]$orientationHint.Orientation -eq "Vertical")

    $padX = if($isVertical){ [Math]::Max(18,[int]($readRect.Width * 0.85)) } else { [Math]::Max(28,[int]($readRect.Width * 0.95)) }
    $padY = if($isVertical){ [Math]::Max(26,[int]($readRect.Height * 0.95)) } else { [Math]::Max(14,[int]($readRect.Height * 0.65)) }

    return (New-AutoOcrClampedRect ($readRect.X - $padX) ($readRect.Y - $padY) ($readRect.Width + ($padX * 2)) ($readRect.Height + ($padY * 2)) 0 0 $script:sourceBitmap.Width $script:sourceBitmap.Height)
}

function Get-TextZoneDualPassReviewCandidates($rect){
    $primaryRect = Get-TextZoneReadRect $rect
    if(!$primaryRect){ return @() }

    $primaryCandidates = @(Get-TextZoneLineReviewCandidates $primaryRect)
    $results = @($primaryCandidates)

    $toleranceRect = Get-TextZoneToleranceReadRect $rect
    $sameRect = (
        $toleranceRect -and
        $primaryRect -and
        $toleranceRect.X -eq $primaryRect.X -and
        $toleranceRect.Y -eq $primaryRect.Y -and
        $toleranceRect.Width -eq $primaryRect.Width -and
        $toleranceRect.Height -eq $primaryRect.Height
    )
    $toleranceCandidates = if($sameRect){ @($primaryCandidates) } else { @(Get-TextZoneLineReviewCandidates $toleranceRect) }

    foreach($nominalCandidate in @($primaryCandidates)){
        if([string]::IsNullOrWhiteSpace([string]$nominalCandidate.Nominal)){ continue }

        foreach($toleranceCandidate in @($toleranceCandidates)){
            $toleranceRawText = [string]$toleranceCandidate.RawText
            if([string]::IsNullOrWhiteSpace($toleranceRawText)){ continue }
            if(-not (Test-ExplicitToleranceText $toleranceRawText)){ continue }

            $combinedTolerance = $null
            if($toleranceCandidate.Tolerance -and $toleranceCandidate.Tolerance.Detected){
                $combinedTolerance = $toleranceCandidate.Tolerance
            }
            if(-not ($combinedTolerance -and $combinedTolerance.Detected)){
                $combinedTolerance = Parse-ToleranceFull $toleranceRawText ([string]$nominalCandidate.Nominal)
            }

            $combinedRawText = Join-MechanicalTextFragments ([string]$nominalCandidate.RawText) $toleranceRawText
            if(-not ($combinedTolerance -and $combinedTolerance.Detected)){
                $combinedTolerance = Parse-ToleranceFull $combinedRawText ([string]$nominalCandidate.Nominal)
            }
            if(-not ($combinedTolerance -and $combinedTolerance.Detected)){ continue }
            if(-not (Test-MechanicalTolerancePlausible $combinedTolerance ([string]$nominalCandidate.Nominal))){ continue }

            $combinedRect = if($nominalCandidate.Rect -and $toleranceCandidate.Rect){
                Get-UnionTextZoneRect $nominalCandidate.Rect $toleranceCandidate.Rect 4
            }
            else{
                $toleranceRect
            }

            $combinedScore = [double]$nominalCandidate.Score + [Math]::Max(0.0,([double]$toleranceCandidate.Score * 0.35)) + 18.0
            if($toleranceRawText -match '±'){ $combinedScore += 4.0 }

            $results += [PSCustomObject]@{
                RawText = $combinedRawText
                Nominal = [string]$nominalCandidate.Nominal
                Tolerance = $combinedTolerance
                Angle = [int]$nominalCandidate.Angle
                Rect = $combinedRect
                Orientation = [string]$nominalCandidate.Orientation
                Score = [double]$combinedScore
            }
        }
    }

    return @($results)
}

function Get-RawTextZoneFragmentAnalysis($zone,[switch]$ForceFresh){
    if(!$zone -or !$zone.Rect){ return $null }

    if(-not $script:TextZoneFragmentAnalysisCache){
        $script:TextZoneFragmentAnalysisCache = @{}
    }

    $cacheKey = "R|" + [string]$script:CurrentSourcePath + "|" + (Get-AutoOcrMapRectKey $zone.Rect)
    if((-not $ForceFresh) -and $script:TextZoneFragmentAnalysisCache.ContainsKey($cacheKey)){
        return $script:TextZoneFragmentAnalysisCache[$cacheKey]
    }

    $review = Get-ReviewedTextZoneData $zone.Rect $null
    $rawText = if($review){ [string]$review.RawText } else { "" }
    $labelText = if($review){ [string]$review.Text } else { "" }
    $nominal = if($review -and $review.PSObject.Properties.Name -contains "Nominal"){ [string]$review.Nominal } else { "" }
    if([string]::IsNullOrWhiteSpace($nominal) -and -not [string]::IsNullOrWhiteSpace($rawText)){
        $resolved = Resolve-OcrTextAsMechanicalNominal $rawText $zone.Rect $rawText
        $nominal = [string]$resolved.Nominal
    }

    $tolerance = $null
    if($review -and $review.PSObject.Properties.Name -contains "Tolerance"){
        $tolerance = $review.Tolerance
    }
    if(-not ($tolerance -and $tolerance.Detected) -and -not [string]::IsNullOrWhiteSpace($rawText)){
        $tolerance = Parse-ToleranceFull $rawText $nominal
    }

    $hasExplicitTolerance = (
        (-not [string]::IsNullOrWhiteSpace($rawText) -and (Test-ExplicitToleranceText $rawText)) -or
        (-not [string]::IsNullOrWhiteSpace($labelText) -and (Test-ExplicitToleranceText $labelText))
    )
    $analysis = [PSCustomObject]@{
        RawText = $rawText
        Text = $labelText
        Nominal = (Normalize-DegreeNominalSign $nominal)
        Tolerance = $tolerance
        HasExplicitTolerance = [bool]$hasExplicitTolerance
    }
    $script:TextZoneFragmentAnalysisCache[$cacheKey] = $analysis
    return $analysis
}

function Get-TextZoneOrientationHint($rect){

    $fallback = [PSCustomObject]@{
        PreferredAngles = @(0,180,90,270)
        Orientation = "Unknown"
    }

    if(!$script:sourceBitmap -or !$rect){ return $fallback }
    if(-not (Initialize-OpenCvSharpForAutoOcr)){ return $fallback }

    $strictRect = Convert-ToImageRect $rect
    if(!$strictRect -or $strictRect.Width -le 8 -or $strictRect.Height -le 8){ return $fallback }

    $crop = $null
    $src = $null
    $bin = $null
    $temp = Join-Path $env:TEMP ("ocrtool_orientation_{0}.png" -f ([guid]::NewGuid().ToString("N")))
    try{
        $crop = $script:sourceBitmap.Clone($strictRect,$script:sourceBitmap.PixelFormat)
        $crop.Save($temp,[System.Drawing.Imaging.ImageFormat]::Png)
        $src = [OpenCvSharp.Cv2]::ImRead($temp,[OpenCvSharp.ImreadModes]::Grayscale)
        if(!$src -or $src.Empty()){ return $fallback }

        $bin = New-Object OpenCvSharp.Mat
        [void][OpenCvSharp.Cv2]::Threshold($src,$bin,0,255,([OpenCvSharp.ThresholdTypes]::BinaryInv -bor [OpenCvSharp.ThresholdTypes]::Otsu))

        $contours = $null
        $hierarchy = $null
        [OpenCvSharp.Cv2]::FindContours($bin,[ref]$contours,[ref]$hierarchy,[OpenCvSharp.RetrievalModes]::External,[OpenCvSharp.ContourApproximationModes]::ApproxSimple)

        $glyphRects = @()
        foreach($contour in @($contours)){
            if(!$contour){ continue }
            $r = [OpenCvSharp.Cv2]::BoundingRect($contour)
            if($r.Width -lt 2 -or $r.Height -lt 2){ continue }
            $aspect = [double][Math]::Max($r.Width,$r.Height) / [double][Math]::Max(1,[Math]::Min($r.Width,$r.Height))
            $looksLeaderLine = (
                ($aspect -gt 12.0 -and [Math]::Max($r.Width,$r.Height) -gt 40) -or
                ($r.Width -gt ($strictRect.Width * 0.72) -and $r.Height -lt 10) -or
                ($r.Height -gt ($strictRect.Height * 0.72) -and $r.Width -lt 10)
            )
            if($looksLeaderLine){ continue }
            $glyphRects += $r
        }

        if($glyphRects.Count -le 0){ return $fallback }

        $minX = (@($glyphRects | ForEach-Object { $_.X }) | Measure-Object -Minimum).Minimum
        $minY = (@($glyphRects | ForEach-Object { $_.Y }) | Measure-Object -Minimum).Minimum
        $maxX = (@($glyphRects | ForEach-Object { $_.X + $_.Width }) | Measure-Object -Maximum).Maximum
        $maxY = (@($glyphRects | ForEach-Object { $_.Y + $_.Height }) | Measure-Object -Maximum).Maximum
        $glyphW = [Math]::Max(1,($maxX - $minX))
        $glyphH = [Math]::Max(1,($maxY - $minY))

        if($glyphH -gt ($glyphW * 1.22)){
            return [PSCustomObject]@{
                PreferredAngles = @(90,270,0,180)
                Orientation = "Vertical"
            }
        }
        if($glyphW -gt ($glyphH * 1.22)){
            return [PSCustomObject]@{
                PreferredAngles = @(0,180,90,270)
                Orientation = "Horizontal"
            }
        }
    }
    catch{}
    finally{
        if($bin){ $bin.Dispose() }
        if($src){ $src.Dispose() }
        if($crop){ $crop.Dispose() }
        try{
            if(Test-Path $temp){ Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        catch{}
    }

    return $fallback
}

function Get-EngineeringTextReviewScore($rawText,$nominal,$tolerance,$angle,$preferredAngles,$rect){

    $candidate = [PSCustomObject]@{
        Nominal = [string]$nominal
        RawText = [string]$rawText
        Rect = $rect
    }
    $score = Get-AutoOcrCandidateScore $candidate
    $raw = ([string]$rawText).ToUpperInvariant()
    $compact = $raw -replace '\s+',''
    $digits = ([regex]::Matches($raw,'\d')).Count
    $score += [Math]::Min(10,$digits)

    if(-not [string]::IsNullOrWhiteSpace([string]$nominal)){
        $score += 12
    }
    if($raw -match '\([^)]+\)'){ $score += 7 }
    if($raw -match 'R\s*\d+(?:\.\d+)?\s*MAX'){ $score += 10 }
    if($raw -match '[±]'){ $score += 8 }
    if($raw -match '[+\-]\s*0?\.\d+'){ $score += 7 }
    if($tolerance -and $tolerance.Detected){ $score += 8 }
    if($compact -match '^\d+$'){ $score -= 10 }
    if($compact.Length -le 2){ $score -= 14 }
    if($raw -match '[A-Z]{5,}' -and $raw -notmatch 'MAX'){ $score -= 6 }

    $preferredIndex = [array]::IndexOf(@($preferredAngles),[int]$angle)
    if($preferredIndex -eq 0){ $score += 6 }
    elseif($preferredIndex -eq 1){ $score += 3 }

    return [double]$score
}

function Get-TextZoneLineReviewCandidates($searchRect){

    $results = @()
    if(!$script:sourceBitmap -or !$searchRect){ return @($results) }

    $crop = $null
    try{
        $crop = $script:sourceBitmap.Clone($searchRect,$script:sourceBitmap.PixelFormat)
        $orientationHint = Get-TextZoneOrientationHint $searchRect

        foreach($angle in @($orientationHint.PreferredAngles)){
            $ocrBitmap = if($angle -eq 0){ $crop } else { Rotate-Bitmap $crop $angle }
            try{
                $detail = Run-OCRDetailed $ocrBitmap
                $angleResults = @()
                foreach($line in @($detail.Lines)){
                    if(!$line -or [string]::IsNullOrWhiteSpace([string]$line.Text) -or !$line.Rect){ continue }

                    $lineRect = Convert-RotatedOcrRectToSourceRect $line.Rect $angle $searchRect.Width $searchRect.Height 1 $searchRect.X $searchRect.Y
                    if(!$lineRect){ continue }
                    $lineRect = Get-TightImageInkRect $script:sourceBitmap $lineRect
                    $rawText = [string]$line.Text
                    $resolved = Resolve-OcrTextAsMechanicalNominal $rawText $lineRect
                    $nominal = [string]$resolved.Nominal
                    $tolerance = if([string]::IsNullOrWhiteSpace($nominal)){ $null } else { Parse-ToleranceFull $rawText $nominal }
                    $score = Get-EngineeringTextReviewScore $rawText $nominal $tolerance $angle $orientationHint.PreferredAngles $lineRect

                    $lineCandidate = [PSCustomObject]@{
                        RawText = $rawText
                        Nominal = [string]$nominal
                        Tolerance = $tolerance
                        Angle = [int]$angle
                        Rect = $lineRect
                        Orientation = [string]$orientationHint.Orientation
                        Score = [double]$score
                    }
                    $results += $lineCandidate
                    $angleResults += $lineCandidate
                }

                # Mechanical dimensions are often split across stacked OCR lines,
                # e.g. "4" + "+0.005" + "0". Keep the single-line candidates, but
                # also synthesize a clustered review candidate so parser/tolerance
                # logic can see the full dimension text at once.
                if($angleResults.Count -ge 2){
                    foreach($anchor in @($angleResults | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Nominal) })){
                        $clusterLines = @(
                            $angleResults |
                            Where-Object {
                                $_ -ne $anchor -and
                                $_.Rect -and
                                (
                                    [Math]::Abs((($_.Rect.X + ($_.Rect.Width / 2.0)) - ($anchor.Rect.X + ($anchor.Rect.Width / 2.0)))) -le [Math]::Max(90,($searchRect.Width * 0.65)) -and
                                    [Math]::Abs((($_.Rect.Y + ($_.Rect.Height / 2.0)) - ($anchor.Rect.Y + ($anchor.Rect.Height / 2.0)))) -le [Math]::Max(90,($searchRect.Height * 0.80))
                                )
                            }
                        )
                        if($clusterLines.Count -le 0){ continue }

                        $combinedParts = @([string]$anchor.RawText) + @(
                            $clusterLines |
                            Sort-Object @{ Expression = { $_.Rect.Y }; Descending = $false }, @{ Expression = { $_.Rect.X }; Descending = $false } |
                            ForEach-Object { [string]$_.RawText }
                        )
                        $combinedRawText = (($combinedParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ").Trim()
                        if([string]::IsNullOrWhiteSpace($combinedRawText)){ continue }

                        $combinedResolved = Resolve-OcrTextAsMechanicalNominal $combinedRawText $searchRect
                        $combinedNominal = [string]$combinedResolved.Nominal
                        if([string]::IsNullOrWhiteSpace($combinedNominal)){ continue }

                        $combinedTolerance = Parse-ToleranceFull $combinedRawText $combinedNominal
                        $combinedScore = Get-EngineeringTextReviewScore $combinedRawText $combinedNominal $combinedTolerance $angle $orientationHint.PreferredAngles $searchRect
                        if($combinedTolerance -and $combinedTolerance.Detected){ $combinedScore += 8 }

                        $results += [PSCustomObject]@{
                            RawText = $combinedRawText
                            Nominal = [string]$combinedNominal
                            Tolerance = $combinedTolerance
                            Angle = [int]$angle
                            Rect = $searchRect
                            Orientation = [string]$orientationHint.Orientation
                            Score = [double]$combinedScore
                        }
                    }
                }
            }
            finally{
                if($angle -ne 0 -and $ocrBitmap){ $ocrBitmap.Dispose() }
            }
        }
    }
    finally{
        if($crop){ $crop.Dispose() }
    }

    return @($results)
}

function Get-ReviewedTextZoneData($rect,$previousReview = $null){

    if(!$script:sourceBitmap -or !$rect){ return $null }
    $searchRect = Get-TextZoneReadRect $rect
    if(!$searchRect -or $searchRect.Width -le 2 -or $searchRect.Height -le 2){ return $null }

    $lineCandidates = if(Test-UseOcrFallbackTextZoneRules){
        @(Get-TextZoneDualPassReviewCandidates $rect)
    }
    else{
        @(Get-TextZoneLineReviewCandidates $searchRect)
    }
    if($lineCandidates.Count -le 0){
        $orientationHint = Get-TextZoneOrientationHint $searchRect
        $lineCandidates = @([PSCustomObject]@{
            RawText = ""
            Nominal = ""
            Tolerance = $null
            Angle = [int]$orientationHint.PreferredAngles[0]
            Rect = $searchRect
            Orientation = [string]$orientationHint.Orientation
            Score = [double]::NegativeInfinity
        })
    }

    $best = @($lineCandidates | Sort-Object Score -Descending | Select-Object -First 1)[0]
    if($previousReview -and $previousReview.PSObject.Properties.Name -contains "StableScore"){
        $previousScore = [double]$previousReview.StableScore
        $previousText = [string]$previousReview.Text
        $bestLabelSeed = if(-not [string]::IsNullOrWhiteSpace([string]$best.Nominal)){ [string]$best.Nominal } else { [string]$best.RawText }
        $sameAsPrevious = (-not [string]::IsNullOrWhiteSpace($previousText)) -and ($bestLabelSeed -eq $previousText)
        if((-not $sameAsPrevious) -and ($best.Score -lt ($previousScore + 8))){
            return $previousReview
        }
    }

    $allowBareInteger = (
        ([string]$best.Nominal -match '^\d+$') -and
        ([string]$best.RawText -replace '\s+','' -match '^\d+$')
    )
    $isDimension = (-not [string]::IsNullOrWhiteSpace([string]$best.Nominal)) -and (Test-AutoOcrDimensionCandidate $best.RawText $best.Nominal -AllowBareInteger:$allowBareInteger)
    $label = if($isDimension){ [string]$best.Nominal } elseif(-not [string]::IsNullOrWhiteSpace([string]$best.RawText)){ [string]$best.RawText } else { "Text" }
    if($isDimension -and $best.Tolerance -and $best.Tolerance.Detected){
        $label = ($label + " " + (Format-InvariantSignedTolerance $best.Tolerance.TolMinus) + " " + (Format-InvariantSignedTolerance $best.Tolerance.TolPlus)).Trim()
    }

    return [PSCustomObject]@{
        Text = $label
        RawText = [string]$best.RawText
        Nominal = [string]$best.Nominal
        Tolerance = $best.Tolerance
        IsDimension = [bool]$isDimension
        ResolvedAngle = [int]$best.Angle
        ReadRect = $best.Rect
        Orientation = [string]$best.Orientation
        StableScore = [double]$best.Score
    }
}

function Update-TextZoneReviewAtIndex($index,[switch]$ForceFresh){
    if($index -lt 0 -or $index -ge @($script:PdfTextLayerZones).Count){ return $false }
    $zone = $script:PdfTextLayerZones[$index]
    if(!$zone -or !$zone.Rect){ return $false }
    $wasPdfTextLayerBacked = Test-IsPdfTextLayerBackedZone $zone
    $previousSource = if($zone.PSObject.Properties.Name -contains "Source"){ [string]$zone.Source } else { "" }
    $previousReview = $null
    if((-not $ForceFresh) -and ($zone.PSObject.Properties.Name -contains "StableScore")){
        $previousReview = [PSCustomObject]@{
            Text = [string]$zone.Text
            RawText = if($zone.PSObject.Properties.Name -contains "RawText"){ [string]$zone.RawText } else { [string]$zone.Text }
            Nominal = if($zone.PSObject.Properties.Name -contains "Nominal"){ [string]$zone.Nominal } else { "" }
            Tolerance = if($zone.PSObject.Properties.Name -contains "Tolerance"){ $zone.Tolerance } else { $null }
            IsDimension = [bool]$zone.IsDimension
            ResolvedAngle = if($zone.PSObject.Properties.Name -contains "ResolvedAngle"){ [int]$zone.ResolvedAngle } else { 0 }
            ReadRect = if($zone.PSObject.Properties.Name -contains "ReadRect"){ $zone.ReadRect } else { $zone.Rect }
            Orientation = if($zone.PSObject.Properties.Name -contains "Orientation"){ [string]$zone.Orientation } else { "Unknown" }
            StableScore = [double]$zone.StableScore
        }
    }
    $review = Get-ReviewedTextZoneData $zone.Rect $previousReview
    if(!$review){ return $false }
    $zone.Text = [string]$review.Text
    $zone.RawText = [string]$review.RawText
    $zone.IsDimension = [bool]$review.IsDimension
    $zone | Add-Member -NotePropertyName ResolvedAngle -NotePropertyValue ([int]$review.ResolvedAngle) -Force
    $zone | Add-Member -NotePropertyName ReadRect -NotePropertyValue $review.ReadRect -Force
    $zone | Add-Member -NotePropertyName Orientation -NotePropertyValue ([string]$review.Orientation) -Force
    $zone | Add-Member -NotePropertyName StableScore -NotePropertyValue ([double]$review.StableScore) -Force
    $zone | Add-Member -NotePropertyName Nominal -NotePropertyValue ([string]$review.Nominal) -Force
    $zone | Add-Member -NotePropertyName Tolerance -NotePropertyValue $review.Tolerance -Force
    if(-not ($zone.PSObject.Properties.Name -contains "OriginalZoneSource")){
        $zone | Add-Member -NotePropertyName OriginalZoneSource -NotePropertyValue $previousSource -Force
    }
    elseif([string]::IsNullOrWhiteSpace([string]$zone.OriginalZoneSource)){
        $zone.OriginalZoneSource = $previousSource
    }

    if($wasPdfTextLayerBacked){
        $reviewNominal = Get-PdfTextLayerNominal ([string]$review.Text)
        if([string]::IsNullOrWhiteSpace([string]$reviewNominal)){
            $reviewNominal = Get-PdfTextLayerNominal ([string]$review.RawText)
        }
        $reviewNominal = Normalize-DegreeNominalSign $reviewNominal
        $reviewTolerance = $null
        if(-not [string]::IsNullOrWhiteSpace([string]$reviewNominal)){
            $reviewTolerance = Get-PreferredTolerance (Get-PdfTextLayerTolerance ([string]$review.Text) $reviewNominal) ([string]$review.RawText) $reviewNominal
        }
        $zone | Add-Member -NotePropertyName Nominal -NotePropertyValue ([string]$reviewNominal) -Force
        $zone | Add-Member -NotePropertyName Tolerance -NotePropertyValue $reviewTolerance -Force
    }

    $zone.Source = "EditedTextZone"
    return $true
}

function Update-AllTextZoneReviews{
    if(!$script:PdfTextLayerZones -or @($script:PdfTextLayerZones).Count -le 0){ return 0 }

    $updated = 0
    for($i = 0; $i -lt @($script:PdfTextLayerZones).Count; $i++){
        if(Update-TextZoneReviewAtIndex $i){
            $updated++
        }
    }

    return $updated
}

function Duplicate-SelectedTextZone{
    if(-not $script:ShowPdfTextZones){ return $false }
    if($script:SelectedTextZoneIndex -lt 0 -or $script:SelectedTextZoneIndex -ge @($script:PdfTextLayerZones).Count){ return $false }
    $zone = $script:PdfTextLayerZones[$script:SelectedTextZoneIndex]
    if(!$zone -or !$zone.Rect){ return $false }
    $offset = 16
    $rect = New-Object Drawing.Rectangle(
        [Math]::Min(($script:sourceBitmap.Width - $zone.Rect.Width),($zone.Rect.X + $offset)),
        [Math]::Min(($script:sourceBitmap.Height - $zone.Rect.Height),($zone.Rect.Y + $offset)),
        $zone.Rect.Width,
        $zone.Rect.Height
    )
    $script:PdfTextLayerZones += [PSCustomObject]@{
        Text = [string]$zone.Text
        RawText = if($zone.PSObject.Properties.Name -contains "RawText"){ [string]$zone.RawText } else { [string]$zone.Text }
        Rect = $rect
        IsDimension = [bool]$zone.IsDimension
        ResolvedAngle = if($zone.PSObject.Properties.Name -contains "ResolvedAngle"){ [int]$zone.ResolvedAngle } else { 0 }
        ReadRect = if($zone.PSObject.Properties.Name -contains "ReadRect"){ $zone.ReadRect } else { $rect }
        Orientation = if($zone.PSObject.Properties.Name -contains "Orientation"){ [string]$zone.Orientation } else { "Unknown" }
        StableScore = if($zone.PSObject.Properties.Name -contains "StableScore"){ [double]$zone.StableScore } else { 0 }
        Source = "DuplicatedTextZone"
    }
    $script:SelectedTextZoneIndex = @($script:PdfTextLayerZones).Count - 1
    Save-CurrentPageTextZoneCache
    Update-TextZoneReviewAtIndex $script:SelectedTextZoneIndex -ForceFresh | Out-Null
    Request-CanvasRedraw
    return $true
}

function Remove-SelectedTextZone{
    if(-not $script:ShowPdfTextZones){ return $false }
    if($script:SelectedTextZoneIndex -lt 0 -or $script:SelectedTextZoneIndex -ge @($script:PdfTextLayerZones).Count){ return $false }
    $removedZone = $script:PdfTextLayerZones[$script:SelectedTextZoneIndex]
    $zones = [System.Collections.Generic.List[object]]::new()
    foreach($zone in @($script:PdfTextLayerZones)){
        [void]$zones.Add($zone)
    }
    $zones.RemoveAt($script:SelectedTextZoneIndex)
    $script:PdfTextLayerZones = @($zones)
    $removedZoneSource = if($removedZone -and $removedZone.PSObject.Properties.Name -contains "Source"){ [string]$removedZone.Source } else { "" }
    if($removedZone -and $removedZone.Rect -and $removedZoneSource -ne "MarkStep"){
        Add-SuppressedTextZoneRect $removedZone.Rect
    }
    $script:SelectedTextZoneIndex = -1
    Save-CurrentPageTextZoneCache
    Queue-SessionStateSave
    Request-CanvasRedraw
    return $true
}

function Confirm-KeepDuplicateOcrCandidate($candidate,$tolMinus,$tolPlus){

    if(!$candidate -or !$candidate.Rect){ return $true }

    if($candidate.PSObject.Properties.Name -contains "DuplicateLinkDeclined" -and $candidate.DuplicateLinkDeclined){ return $true }
    if(Test-DuplicateDeclinedRect $candidate.Rect){ return $true }

    $duplicateProbe = [PSCustomObject]@{
        Nominal = [string]$candidate.Nominal
        RawText = if($candidate.PSObject.Properties.Name -contains "RawText"){ [string]$candidate.RawText } else { [string]$candidate.Nominal }
        LabelText = if($candidate.PSObject.Properties.Name -contains "LabelText"){ [string]$candidate.LabelText } else { [string]$candidate.RawText }
        Rect = $candidate.Rect
        Tolerance = [PSCustomObject]@{
            Detected = $true
            TolMinus = [double]$tolMinus
            TolPlus = [double]$tolPlus
        }
    }

    $match = Get-CandidateTableDuplicateMatch $duplicateProbe
    if(!$match){ return $true }

    if($txtOcrDebug){
        $txtOcrDebug.Text = (
            "Duplicate skipped" + [Environment]::NewLine +
            "Existing step: " + [string]$match.Step + [Environment]::NewLine +
            "Suggest: " + [string]$candidate.Nominal + " " + (Format-InvariantSignedTolerance $tolMinus) + " / " + (Format-InvariantSignedTolerance $tolPlus)
        )
    }

    return $false
}

function Add-OcrCandidateToTable($candidate){

    if(!$candidate -or !$candidate.Rect -or [string]::IsNullOrWhiteSpace([string]$candidate.Nominal)){ return $false }
    if(!$script:sourceBitmap){ return $false }

    $realRect = $candidate.Rect
    $tolMinus = ""
    $tolPlus = ""
    $isPdfTextLayerCandidate = ($candidate.PSObject.Properties.Name -contains "Source" -and [string]$candidate.Source -eq "PdfTextLayer")
    $isImageOcrAutoCandidate = ($candidate.PSObject.Properties.Name -contains "Source" -and [string]$candidate.Source -eq "ImageOcrAuto")
    $isTextZoneLabelCandidate = ($candidate.PSObject.Properties.Name -contains "Source" -and [string]$candidate.Source -eq "TextZoneLabel")
    $candidateToleranceText = [string]$candidate.RawText
    if($candidate.PSObject.Properties.Name -contains "LabelText" -and -not [string]::IsNullOrWhiteSpace([string]$candidate.LabelText)){
        $candidateToleranceText = [string]$candidate.LabelText
    }
    if($candidate.PSObject.Properties.Name -contains "Tolerance" -and $candidate.Tolerance -and $candidate.Tolerance.Detected){
        $tolMinus = $candidate.Tolerance.TolMinus
        $tolPlus = $candidate.Tolerance.TolPlus
    }
    else{
        $selectionTolerance = Parse-ToleranceFull $candidateToleranceText ([string]$candidate.Nominal)
        $selectionHasExplicitTolerance = Test-ExplicitToleranceText $candidateToleranceText
        if($selectionTolerance -and $selectionTolerance.Detected -and $selectionHasExplicitTolerance -and (([double]$selectionTolerance.TolPlus) -ne 0 -or ([double]$selectionTolerance.TolMinus) -ne 0)){
            $tolMinus = $selectionTolerance.TolMinus
            $tolPlus = $selectionTolerance.TolPlus
        }
        elseif($isPdfTextLayerCandidate -or $isTextZoneLabelCandidate){
            $fallbackTolerance = Get-GeneralToleranceForNominal ([string]$candidate.Nominal)
            $tolMinus = $fallbackTolerance.TolMinus
            $tolPlus = $fallbackTolerance.TolPlus
        }
        else{
            $toleranceSearchRect = Get-AutoOcrToleranceSearchRect $candidate
            if(!$toleranceSearchRect){ $toleranceSearchRect = $realRect }
            $detectedTolerance = Extract-ToleranceFromRegion $script:sourceBitmap $toleranceSearchRect.X $toleranceSearchRect.Y $toleranceSearchRect.Width $toleranceSearchRect.Height ([string]$candidate.Nominal)
            $detectedHasExplicitTolerance = ($detectedTolerance -and (Test-ExplicitToleranceText ([string]$detectedTolerance.OcrText)))
            if($detectedTolerance -and $detectedTolerance.Detected -and $detectedHasExplicitTolerance -and (([double]$detectedTolerance.TolPlus) -ne 0 -or ([double]$detectedTolerance.TolMinus) -ne 0)){
                $tolMinus = $detectedTolerance.TolMinus
                $tolPlus = $detectedTolerance.TolPlus
            }
            elseif($isImageOcrAutoCandidate){
                $tolMinus = 0
                $tolPlus = 0
            }
            else{
                $fallbackTolerance = Get-GeneralToleranceForNominal ([string]$candidate.Nominal)
                $tolMinus = $fallbackTolerance.TolMinus
                $tolPlus = $fallbackTolerance.TolPlus
            }
        }
    }

    if($null -eq $tolMinus -or $tolMinus -eq ""){ $tolMinus = 0 }
    if($null -eq $tolPlus -or $tolPlus -eq ""){ $tolPlus = 0 }

    $duplicateCheckPassed = (
        $candidate.PSObject.Properties.Name -contains "DuplicateCheckPassed" -and
        [bool]$candidate.DuplicateCheckPassed
    )
    if((-not $duplicateCheckPassed) -and -not (Confirm-KeepDuplicateOcrCandidate $candidate $tolMinus $tolPlus)){
        return $false
    }

    $index = Get-NextStepNumber -SkipSaveCurrentPageState
    $row = $table.Rows.Add()
    $script:StepRects[$row] = $realRect

    $table.Rows[$row].Cells[0].Value = $index
    $table.Rows[$row].Cells[1].Value = [string]$candidate.Nominal
    $table.Rows[$row].Cells[2].Value = Format-InvariantSignedTolerance $tolMinus
    $table.Rows[$row].Cells[3].Value = Format-InvariantSignedTolerance $tolPlus
    $table.Rows[$row].Cells[6].Value = "View"
    $table.Rows[$row].Cells[7].Value = "C"
    $table.Rows[$row].Cells[8].Value = $false
    Add-OrUpdate-MarkStepTextZone $row $index $realRect ([string]$candidate.Nominal) ([string]$candidate.RawText) $tolMinus $tolPlus | Out-Null

    $preferTextMapBalloon = (
        $candidate.PSObject.Properties.Name -contains "Source" -and
        ([string]$candidate.Source -eq "PdfTextLayer" -or [string]$candidate.Source -eq "ImageOcrAuto" -or [string]$candidate.Source -eq "TextZoneLabel")
    )
    $markScale = Get-CurrentPageBalloonScale
    if($preferTextMapBalloon){
        $slotIndex = 0
        $slotCount = 1
        if($candidate.PSObject.Properties.Name -contains "BboxItemIndex"){ $slotIndex = [int]$candidate.BboxItemIndex }
        if($candidate.PSObject.Properties.Name -contains "BboxItemCount"){ $slotCount = [int]$candidate.BboxItemCount }
        $pos = Find-BalloonPositionNextToRect $realRect $script:sourceBitmap.Width $script:sourceBitmap.Height $markScale $slotIndex $slotCount
    }
    else{
        $pos = Find-BalloonPosition $realRect $script:sourceBitmap.Width $script:sourceBitmap.Height $false
    }
    $script:marks += [PSCustomObject]@{
        Index = $index
        X = $pos.X
        Y = $pos.Y
        Scale = $markScale
    }

    $sourceName = [string]$candidate.Source
    if(-not (Test-IsTextZoneOnlyCandidateSource $sourceName)){
        Register-TrainingSignal "auto_candidate_accept" @{
            Nominal = [string]$candidate.Nominal
            Source = $sourceName
            Raw = [string]$candidate.RawText
            Rect = $realRect
            ZoneIndex = if($candidate.PSObject.Properties.Name -contains "ZoneIndex"){ [int]$candidate.ZoneIndex } else { $null }
            CaptureImage = $false
        }
        Register-DetectorAnnotationSilent "positive" $realRect ([ordered]@{
            Source = $sourceName
            Label = [string]$candidate.Nominal
            Raw = [string]$candidate.RawText
            Origin = "auto_candidate_accept"
            Orientation = if($candidate.PSObject.Properties.Name -contains "Angle"){ [int]$candidate.Angle } else { 0 }
        })
    }

    return $true
}

function Sort-AutoMapCandidatesReadingOrder($candidates){

    $items = @(
        @($candidates) |
        Where-Object { $_ -and $_.Rect }
    )
    if($items.Count -le 1){ return @($items) }

    $heights = @(
        $items |
        ForEach-Object { [double]$_.Rect.Height } |
        Where-Object { $_ -gt 0 } |
        Sort-Object
    )
    $medianHeight = if($heights.Count -gt 0){
        [double]$heights[[int][Math]::Floor(($heights.Count - 1) / 2.0)]
    }
    else{
        24.0
    }
    $rowTolerance = [Math]::Max(18.0,[Math]::Min(72.0,($medianHeight * 1.15)))

    $rows = @()
    foreach($item in @(
        $items |
        Sort-Object `
            @{ Expression = { [double]$_.Rect.Y + ([double]$_.Rect.Height / 2.0) }; Descending = $false }, `
            @{ Expression = { [double]$_.Rect.X + ([double]$_.Rect.Width / 2.0) }; Descending = $false }
    )){
        $centerY = [double]$item.Rect.Y + ([double]$item.Rect.Height / 2.0)
        $targetRow = $null
        foreach($row in @($rows)){
            if([Math]::Abs($centerY - [double]$row.CenterY) -le $rowTolerance){
                $targetRow = $row
                break
            }
        }
        if(!$targetRow){
            $targetRow = [PSCustomObject]@{
                CenterY = $centerY
                Items = @()
            }
            $rows += $targetRow
        }
        $targetRow.Items += $item
        $targetRow.CenterY = (@($targetRow.Items | ForEach-Object { [double]$_.Rect.Y + ([double]$_.Rect.Height / 2.0) }) | Measure-Object -Average).Average
    }

    $ordered = @()
    foreach($row in @($rows | Sort-Object CenterY)){
        $ordered += @(
            $row.Items |
            Sort-Object `
                @{ Expression = { [double]$_.Rect.X + ([double]$_.Rect.Width / 2.0) }; Descending = $false }, `
                @{ Expression = {
                    if($_.PSObject.Properties.Name -contains "BboxItemIndex"){
                        return [int]$_.BboxItemIndex
                    }
                    return 0
                }; Descending = $false }
        )
    }

    return @($ordered)
}

function Invoke-AutoMapPdfTextLayer{

    if(!$script:sourceBitmap){ return }
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){ return }
    if($table.Rows.Count -gt 0 -or @($script:marks).Count -gt 0){
        if($txtOcrDebug){
            $txtOcrDebug.Text = (
                "Auto Map PDF blocked" + [Environment]::NewLine +
                "Current drawing already has MarkStep data." + [Environment]::NewLine +
                "Clear existing steps first if you want to map again."
            )
        }
        return
    }

    $pageNumber = 1
    if($script:SelectedPageIndex -ge 0){
        $pageNumber = $script:SelectedPageIndex + 1
    }

    $mapRect = New-Object Drawing.Rectangle(0,0,$script:sourceBitmap.Width,$script:sourceBitmap.Height)

    $oldCursor = $form.Cursor
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $txtOcrDebug.Text = "Auto Map PDF text layer..."

    try{
        $blocks = @()
        $candidates = @()
        $autoMapMode = ""
        $currentZoneKey = Get-AutoOcrMapRectKey $mapRect
        $currentPage = Get-CurrentDocumentPage
        $useVisibleZones = $false

        if(
            $script:ShowPdfTextZones -and
            $script:TextZoneCacheKey -eq $currentZoneKey -and
            $script:PdfTextLayerZones -and
            @($script:PdfTextLayerZones).Count -gt 0
        ){
            $useVisibleZones = $true
        }

        if($useVisibleZones){
            $candidates = @(Convert-TextZonesToAutoMapCandidates $script:PdfTextLayerZones)
            $autoMapMode = "Visible text zones"
        }
        else{
            $blocks = @(Get-PdfTextLayerBlocks $script:CurrentSourcePath $pageNumber)
        }

        if((-not $useVisibleZones) -and @($blocks).Count -gt 0){
            Stop-DeferredTextZoneWarmup
            $script:PdfTextLayerZones = @(Filter-SuppressedTextZones (Convert-PdfTextLayerBlocksToZones $blocks))
            $script:TextZoneCacheKey = $currentZoneKey
            if($currentPage){
                $currentPage.PdfTextLayerZones = @($script:PdfTextLayerZones)
                $currentPage.TextZoneCacheKey = $currentZoneKey
            }
            Save-CurrentPageTextZoneCache
            $candidates = @(Convert-TextZonesToAutoMapCandidates $script:PdfTextLayerZones)
            if($candidates.Count -gt 0){
                $autoMapMode = "PDF text layer"
            }
            else{
                $candidates = @(Find-PdfTextLayerDimensionCandidates $blocks $mapRect)
                $autoMapMode = "PDF text layer"
            }
        }
        elseif(-not $useVisibleZones){
            $txtOcrDebug.Text = "Auto Map PDF requires embedded PDF text layer." + [Environment]::NewLine + "No OCR fallback is used in this workflow."
            return
        }
        $candidates = @(Sort-AutoMapCandidatesReadingOrder $candidates)
        $added = 0

        foreach($candidate in $candidates){
            if(Add-OcrCandidateToTable $candidate){
                $added++
            }
        }

        if($table.Rows.Count -gt 0){
            $lastRow = $table.Rows.Count - 1
            $table.ClearSelection()
            $table.Rows[$lastRow].Selected = $true
            $table.CurrentCell = $table.Rows[$lastRow].Cells[0]
            $table.FirstDisplayedScrollingRowIndex = $lastRow
        }

        $txtOcrDebug.Text = (
            "Mode: {0}" -f $autoMapMode
        ) + [Environment]::NewLine + (
            "PDF blocks: {0}" -f $blocks.Count
        ) + [Environment]::NewLine + (
            "Mapped dims: {0}" -f $candidates.Count
        ) + [Environment]::NewLine + (
            "Added rows: {0}" -f $added
        )

        $script:selectionRect = $null
        Clear-PreviewImage
        Save-CurrentPageState
        Validate-StepState
        Refresh-DuplicateState
        Apply-TableSearchFilter
        Request-CanvasRedraw
        Save-SessionState
    }
    catch{
        [System.Windows.Forms.MessageBox]::Show("Auto Map PDF failed: $($_.Exception.Message)")
    }
    finally{
        $form.Cursor = $oldCursor
    }
}
function Test-BalloonCandidateClear($point,$avoidRadius,$edgeMargin,$balloonSpacing,$rectPadding,$imgW,$imgH){

    if(!$point){ return $false }

    if($point.X -lt $edgeMargin -or $point.Y -lt $edgeMargin -or $point.X -gt ($imgW-$edgeMargin) -or $point.Y -gt ($imgH-$edgeMargin)){
        return $false
    }

    $candidateBounds = New-Object Drawing.RectangleF(
        [float]($point.X - $avoidRadius),
        [float]($point.Y - $avoidRadius),
        [float]($avoidRadius * 2.0),
        [float]($avoidRadius * 2.0)
    )

    foreach($m in $script:marks){
        if(!$m){ continue }

        $dx=$m.X-$point.X
        $dy=$m.Y-$point.Y

        if([math]::Sqrt($dx*$dx+$dy*$dy) -lt $balloonSpacing){
            return $false
        }
    }

    foreach($zone in @($script:PdfTextLayerZones)){
        if(!$zone -or !$zone.Rect){ continue }

        $textPadding = if($zone.IsDimension){ $rectPadding } else { [int][Math]::Ceiling($avoidRadius * 0.35) }
        $zoneRect = New-Object Drawing.RectangleF(
            [float]($zone.Rect.X - $textPadding),
            [float]($zone.Rect.Y - $textPadding),
            [float]($zone.Rect.Width + ($textPadding * 2)),
            [float]($zone.Rect.Height + ($textPadding * 2))
        )

        if($candidateBounds.IntersectsWith($zoneRect)){
            return $false
        }
    }

    foreach($r2 in $script:StepRects.Values){
        if(!$r2){ continue }

        $avoidRect = New-Object Drawing.RectangleF(
            [float]($r2.X - $rectPadding),
            [float]($r2.Y - $rectPadding),
            [float]($r2.Width + ($rectPadding * 2)),
            [float]($r2.Height + ($rectPadding * 2))
        )

        if($candidateBounds.IntersectsWith($avoidRect)){
            return $false
        }
    }

    return $true
}

function Find-BalloonPosition($rect,$imgW,$imgH,$preferTextMap = $false){

    $cx = $rect.X + ($rect.Width/2)
    $cy = $rect.Y + ($rect.Height/2)
    $markRadius = Get-MarkImageRadius
    $avoidRadius = [Math]::Max(($markRadius * 1.25),($markRadius + 8.0))
    $edgeMargin = [int][Math]::Ceiling($avoidRadius + 4)
    $balloonSpacing = [int][Math]::Ceiling(($avoidRadius * 2.0) + 18.0)
    $rectPadding = [int][Math]::Ceiling($avoidRadius + 12.0)
    $fallbackOffset = [int][Math]::Ceiling(($avoidRadius * 2.0) + 18.0)

    $step = [int][Math]::Max(24,[Math]::Ceiling($avoidRadius * 0.75))
    $max = [int][Math]::Max(260,[Math]::Ceiling($avoidRadius * 7.0))

    if($preferTextMap){
        $near = [Math]::Max(($avoidRadius * 2.4),28.0)
        $preferredCandidates = @(
            @{X=$rect.Left-$near;Y=$rect.Top-$near}
            @{X=$rect.Right+$near;Y=$rect.Top-$near}
            @{X=$rect.Left-$near;Y=$rect.Bottom+$near}
            @{X=$rect.Right+$near;Y=$rect.Bottom+$near}
            @{X=$rect.Left-$near;Y=$cy}
            @{X=$rect.Right+$near;Y=$cy}
            @{X=$cx;Y=$rect.Top-$near}
            @{X=$cx;Y=$rect.Bottom+$near}
        )

        foreach($p in $preferredCandidates){
            if(Test-BalloonCandidateClear $p $avoidRadius $edgeMargin $balloonSpacing $rectPadding $imgW $imgH){
                return $p
            }
        }
    }

    for($r=$step;$r -le $max;$r+=$step){

        $candidates = @(
            @{X=$cx+$r;Y=$cy-$r}
            @{X=$cx-$r;Y=$cy-$r}
            @{X=$cx+$r;Y=$cy+$r}
            @{X=$cx-$r;Y=$cy+$r}
            @{X=$cx+$r;Y=$cy}
            @{X=$cx-$r;Y=$cy}
            @{X=$cx;Y=$cy-$r}
            @{X=$cx;Y=$cy+$r}
        )

        foreach($p in $candidates){

            if(Test-BalloonCandidateClear $p $avoidRadius $edgeMargin $balloonSpacing $rectPadding $imgW $imgH){
                return $p
            }
        }

    }

    return @{X=$rect.Right+$fallbackOffset;Y=$rect.Top-$fallbackOffset}
}

function Find-BalloonPositionNextToRect($rect,$imgW,$imgH,$markScale = 1.0,$slotIndex = 0,$slotCount = 1){

    if(!$rect){ return @{X=0;Y=0} }

    $markRadius = (Get-MarkImageRadius) * (Normalize-MarkScale $markScale)
    $gap = [Math]::Max(1.0,[Math]::Min(4.0,($markRadius * 0.06)))
    $edgeMargin = [int][Math]::Ceiling($markRadius + 3)
    $cx = $rect.X + ($rect.Width / 2.0)
    $cy = $rect.Y + ($rect.Height / 2.0)
    $safeSlotCount = [Math]::Max(1,[int]$slotCount)
    $safeSlotIndex = [Math]::Max(0,[Math]::Min(([int]$slotIndex),($safeSlotCount - 1)))
    $slotOffset = 0.0
    if($safeSlotCount -gt 1){
        $slotOffset = (($safeSlotIndex - (($safeSlotCount - 1) / 2.0)) * ($markRadius * 2.25))
    }
    $slotY = $cy + $slotOffset
    $slotY = [Math]::Max($edgeMargin,[Math]::Min(($imgH - $edgeMargin),$slotY))

    $candidatePoints = @(
        @{X=($rect.Right + $markRadius + $gap);Y=$slotY}
        @{X=($rect.Left - $markRadius - $gap);Y=$slotY}
        @{X=$cx;Y=($rect.Top - $markRadius - $gap + $slotOffset)}
        @{X=$cx;Y=($rect.Bottom + $markRadius + $gap + $slotOffset)}
        @{X=($rect.Right + $markRadius + $gap);Y=($rect.Top - $markRadius - $gap)}
        @{X=($rect.Right + $markRadius + $gap);Y=($rect.Bottom + $markRadius + $gap)}
        @{X=($rect.Left - $markRadius - $gap);Y=($rect.Top - $markRadius - $gap)}
        @{X=($rect.Left - $markRadius - $gap);Y=($rect.Bottom + $markRadius + $gap)}
    )

    foreach($p in $candidatePoints){
        $x = [double]$p.X
        $y = [double]$p.Y
        if($x -lt $edgeMargin -or $y -lt $edgeMargin -or $x -gt ($imgW - $edgeMargin) -or $y -gt ($imgH - $edgeMargin)){
            continue
        }
        return @{X=$x;Y=$y}
    }

    return @{
        X = [Math]::Max($edgeMargin,[Math]::Min(($imgW - $edgeMargin),($rect.Right + $markRadius + $gap)))
        Y = $slotY
    }
}

function Draw-MarkBalloons($graphics,$renderScale,$showDuplicateHighlight = $false,$copyViewOnly = $false){

    if(!$graphics -or !$script:marks){ return }

    $metrics = $null
    $defaultBrush = $null
    $duplicateBrush = $null
    $selectedBrush = $null
    $selectedCopyBrush = $null
    $copyViewSourceBrush = $null
    $textBrush = $null
    $copyViewSourceTextBrush = $null

    try{
        $metrics = Get-MarkLayoutMetrics $renderScale
        $balloonStrokeColor = Get-BalloonStrokeColor
        $defaultBrush = New-Object Drawing.SolidBrush([Drawing.Color]::White)
        $duplicateBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255,255,247,200))
        $selectedBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255,255,234,160))
        $selectedCopyBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255,214,238,255))
        $copyViewSourceBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255,235,74,74))
        $textBrush = New-Object Drawing.SolidBrush($balloonStrokeColor)
        $copyViewSourceTextBrush = New-Object Drawing.SolidBrush([Drawing.Color]::White)

        $copyViewSourceSteps = @{}
        foreach($uiCopiedMark in @($script:UiCopiedMarks)){
            if(!$uiCopiedMark){ continue }
            $sourceStepKey = [string]$uiCopiedMark.SourceStep
            if([string]::IsNullOrWhiteSpace($sourceStepKey)){
                $sourceStepKey = [string]$uiCopiedMark.Index
            }
            if([string]::IsNullOrWhiteSpace($sourceStepKey)){ continue }
            $copyViewSourceSteps[$sourceStepKey] = $true
        }

        $drawMark = {
            param($markItem,$isUiCopy,$rowIndex)

            if(!$markItem){ return }

            $markScale = Get-MarkScale $markItem
            $radius = [float]($metrics.Radius * $markScale)
            $diameter = [float]($metrics.Diameter * $markScale)
            $fontSize = [float]($metrics.FontSize * $markScale)
            $outlineWidth = [float][Math]::Max(($metrics.OutlineWidth * $markScale),0.8)
            $font = New-Object Drawing.Font("Arial",$fontSize,[Drawing.FontStyle]::Bold)
            $pen = New-Object Drawing.Pen($balloonStrokeColor,$outlineWidth)
            $duplicateHaloPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,230,213,101),[float][Math]::Max(($outlineWidth * 1.2),1.0))
            $selectedHaloPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,210,170,48),[float][Math]::Max(($outlineWidth * 1.8),1.2))
            $selectedOutlinePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,192,98,16),[float][Math]::Max(($outlineWidth * 1.15),1.0))
            $selectedCopyHaloPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,96,168,235),[float][Math]::Max(($outlineWidth * 1.8),1.2))
            $selectedCopyOutlinePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255,52,120,198),[float][Math]::Max(($outlineWidth * 1.15),1.0))

            try{
            $text = [string]$markItem.Index
            $sx = [float]($markItem.X * $renderScale)
            $sy = [float]($markItem.Y * $renderScale)
            $cx = $sx - $radius
            $cy = $sy - $radius
            $stepKey = [string]$markItem.Index

            $isDuplicate = (-not $isUiCopy) -and $showDuplicateHighlight -and $script:DuplicateStepMap.ContainsKey($stepKey)
            $isSelectedMatch =
                (-not $isUiCopy) -and
                $showDuplicateHighlight -and
                $script:SelectedDuplicateSteps.ContainsKey($stepKey)
            $isSelectedAnchor =
                (-not $isUiCopy) -and
                $showDuplicateHighlight -and
                (-not [string]::IsNullOrWhiteSpace($script:SelectedDuplicateAnchorStep)) -and
                ($script:SelectedDuplicateAnchorStep -eq $stepKey)
            $isDirectlySelected =
                (($isUiCopy -and $script:SelectedMarkKind -eq "Copy" -and $markItem.Id -eq $script:SelectedUiCopyId)) -or
                ((-not $isUiCopy) -and $script:SelectedMarkKind -eq "Original" -and $rowIndex -eq $script:SelectedMarkRowIndex)
            $isCopyViewSourceOriginal =
                (-not $isUiCopy) -and
                $copyViewOnly -and
                $copyViewSourceSteps.ContainsKey($stepKey)
            $isInteractiveDraw = $script:IsInteractiveCanvasUpdate

            $fillBrush =
                if($isUiCopy -and $isDirectlySelected){ $selectedCopyBrush }
                elseif($isCopyViewSourceOriginal){ $copyViewSourceBrush }
                elseif($isSelectedAnchor -or $isDirectlySelected){ $selectedBrush }
                elseif($isDuplicate){ $duplicateBrush }
                else { $defaultBrush }
            $outlinePen =
                if($isUiCopy -and $isDirectlySelected){ $selectedCopyOutlinePen }
                elseif($isSelectedAnchor -or $isDirectlySelected){ $selectedOutlinePen }
                else { $pen }

            if((-not $isInteractiveDraw) -and ($isSelectedMatch -or $isSelectedAnchor -or $isDirectlySelected)){
                $haloPadding = [float][Math]::Max(($outlineWidth * 3.0),2.0)
                $haloDiameter = $diameter + ($haloPadding * 2.0)
                $haloX = $sx - ($haloDiameter / 2.0)
                $haloY = $sy - ($haloDiameter / 2.0)
                $haloPen =
                    if($isUiCopy -and $isDirectlySelected){ $selectedCopyHaloPen }
                    elseif($isSelectedAnchor -or $isDirectlySelected){ $selectedHaloPen }
                    else { $duplicateHaloPen }
                $graphics.DrawEllipse($haloPen,$haloX,$haloY,$haloDiameter,$haloDiameter)
            }

            $graphics.FillEllipse($fillBrush,$cx,$cy,$diameter,$diameter)
            $graphics.DrawEllipse($outlinePen,$cx,$cy,$diameter,$diameter)

            $size = $graphics.MeasureString($text,$font)
            $tx = $sx - ($size.Width / 2)
            $ty = $sy - ($size.Height / 2)
            $effectiveTextBrush = if($isCopyViewSourceOriginal){ $copyViewSourceTextBrush } else { $textBrush }

            $graphics.DrawString($text,$font,$effectiveTextBrush,$tx,$ty)
            }
            finally{
                if($font){ $font.Dispose() }
                if($pen){ $pen.Dispose() }
                if($duplicateHaloPen){ $duplicateHaloPen.Dispose() }
                if($selectedHaloPen){ $selectedHaloPen.Dispose() }
                if($selectedOutlinePen){ $selectedOutlinePen.Dispose() }
                if($selectedCopyHaloPen){ $selectedCopyHaloPen.Dispose() }
                if($selectedCopyOutlinePen){ $selectedCopyOutlinePen.Dispose() }
            }
        }

        if($copyViewOnly){
            for($rowIndex = 0; $rowIndex -lt $script:marks.Count; $rowIndex++){
                $mark = $script:marks[$rowIndex]
                if(!$mark){ continue }
                $stepKey = [string]$mark.Index
                if($copyViewSourceSteps.ContainsKey($stepKey)){
                    & $drawMark $mark $false $rowIndex
                }
            }
        }
        else{
            for($rowIndex = 0; $rowIndex -lt $script:marks.Count; $rowIndex++){
                & $drawMark $script:marks[$rowIndex] $false $rowIndex
            }
        }

        foreach($uiCopiedMark in @($script:UiCopiedMarks)){
            & $drawMark $uiCopiedMark $true -1
        }
    }
    finally{
        if($defaultBrush){
            $defaultBrush.Dispose()
        }
        if($duplicateBrush){
            $duplicateBrush.Dispose()
        }
        if($selectedBrush){
            $selectedBrush.Dispose()
        }
        if($selectedCopyBrush){
            $selectedCopyBrush.Dispose()
        }
        if($copyViewSourceBrush){
            $copyViewSourceBrush.Dispose()
        }
        if($textBrush){
            $textBrush.Dispose()
        }
        if($copyViewSourceTextBrush){
            $copyViewSourceTextBrush.Dispose()
        }
    }
}

function Repair-ManualVerticalMissingDecimalNominal($nominal,$rawText,$cleanedText,$rect){

    $value = ([string]$nominal).Trim()

    # Preserve explicit mechanical prefixes. C0.5 / R0.5 / Ø0.5 must not be
    # treated as leading-zero shorthand like 05 -> 0.5.
    if($value -match '^[CRØ]\s*[-+]?\d*\.?\d+$'){
        return ($value -replace '\s+','')
    }
    foreach($sourceText in @([string]$rawText,[string]$cleanedText)){
        $src = ([string]$sourceText).ToUpperInvariant() -replace ',', '.'
        if($src -match '(?:^|[^A-Z0-9])([CRØ])\s*([-+]?\d+(?:\.\d+)?|\.\d+)'){
            $prefix = [string]$Matches[1]
            $num = [string]$Matches[2]
            if($num -match '^\.'){ $num = '0' + $num }
            return ($prefix + $num)
        }
    }

    # Leading-zero short decimals: 02 / 0 2 / 0. 2 should be 0.2.
    # This must run for both horizontal and vertical crops.
    foreach($sourceText in @($value,[string]$rawText,[string]$cleanedText)){
        if([string]::IsNullOrWhiteSpace($sourceText)){ continue }
        $s = ([string]$sourceText).ToUpperInvariant() -replace ',', '.'
        $s = $s -replace '[\(\)\[\]]',' '
        $s = $s.Trim()
        if($s -match '^0\s*\.?\s*([1-9])$'){
            return ('0.' + [string]$Matches[1])
        }
        $digitsOnly = ($s -replace '[^0-9]','')
        if($digitsOnly -match '^0([1-9])$'){
            return ('0.' + [string]$Matches[1])
        }
    }

    if(!$rect){ return $value }

    $isVerticalCrop = ([double]$rect.Height -gt ([double]$rect.Width * 1.25))
    if(-not $isVerticalCrop){ return $value }

    $contextText = ((([string]$rawText) + " " + ([string]$cleanedText)).ToUpperInvariant() -replace ',', '.')
    $rawCompact = ($contextText -replace '[^0-9RCMAX]','')
    $valueCompact = ($value -replace '[^0-9]','')

    # Vertical OCR often drops the decimal point in tiny Rmax/C dimensions:
    # Rmax0.015 -> 015 / 0015. Repair only in vertical manual crop path.
    foreach($digits in @($valueCompact,$rawCompact)){
        if([string]::IsNullOrWhiteSpace($digits)){ continue }
        if($digits -match '^(?:RMAX|MAX|R)?0?015$'){ return '0.015' }
        if($digits -match '^(?:RMAX|MAX|R)?0?010$'){ return '0.010' }
        if($digits -match '^(?:RMAX|MAX|R)?0?005$'){ return '0.005' }
        if($digits -match '^(?:RMAX|MAX|R)?0?002$'){ return '0.002' }
        if($digits -match '^(?:RMAX|MAX|R)?0?001$'){ return '0.001' }
    }

    return $value
}

function Clear-AiVisionResult{

    $script:AiVisionResult = $null
    if($btnAiAccept){ $btnAiAccept.Enabled = $false }
}

function Append-AiVisionLog($message){

    if(!$txtAiResult){ return }
    $timestamp = Get-Date -Format "HH:mm:ss"
    $entry = ("[{0}] {1}" -f $timestamp,[string]$message)
    if([string]::IsNullOrWhiteSpace([string]$txtAiResult.Text)){
        $txtAiResult.Text = $entry
    }
    else{
        $txtAiResult.AppendText([Environment]::NewLine + $entry)
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-OcrDebugAiHeader($title){

    if(!$txtOcrDebug){ return }
    $txtOcrDebug.Text = [string]$title
    [System.Windows.Forms.Application]::DoEvents()
}

function Append-OcrDebugAiProgress($message){

    if(!$txtOcrDebug){ return }
    $entry = [string]$message
    if([string]::IsNullOrWhiteSpace([string]$txtOcrDebug.Text)){
        $txtOcrDebug.Text = $entry
    }
    else{
        $txtOcrDebug.Text += ([Environment]::NewLine + $entry)
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Save-ManualSelectionCropToTemp($realRect){

    return Save-ManualSelectionCropToTempAtAngle $realRect 0
}

function Save-ManualSelectionCropToTempAtAngle($realRect,$angle){

    if(!$script:sourceBitmap -or !$realRect){ return $null }
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rapidocr-ai-" + [guid]::NewGuid().ToString("N") + ".png")
    $cropBitmap = $null
    $outputBitmap = $null
    try{
        $cropBitmap = $script:sourceBitmap.Clone($realRect,$script:sourceBitmap.PixelFormat)
        if([int]$angle -eq 0){
            $outputBitmap = $cropBitmap
        }
        else{
            $outputBitmap = Rotate-Bitmap $cropBitmap ([int]$angle)
        }
        $outputBitmap.Save($tempPath,[System.Drawing.Imaging.ImageFormat]::Png)
        return $tempPath
    }
    catch{
        try{ if(Test-Path -LiteralPath $tempPath){ Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } } catch{}
        return $null
    }
    finally{
        if(($outputBitmap -is [System.IDisposable]) -and -not [object]::ReferenceEquals($outputBitmap,$cropBitmap)){ $outputBitmap.Dispose() }
        if($cropBitmap -is [System.IDisposable]){ $cropBitmap.Dispose() }
    }
}

function Get-HttpErrorDetail($errorRecord){

    if(!$errorRecord){ return $null }

    $detail = $null
    try{
        $detail = [string]$errorRecord.ErrorDetails.Message
    }
    catch{}

    if(-not [string]::IsNullOrWhiteSpace($detail)){
        return $detail.Trim()
    }

    return $null
}

function Warm-OllamaVisionModel($modelName){

    if([string]::IsNullOrWhiteSpace($modelName)){ return $false }

    $bareModelName = [string]$modelName
    if($bareModelName.StartsWith("ollama:",[System.StringComparison]::OrdinalIgnoreCase)){
        $bareModelName = $bareModelName.Substring(7)
    }

    Append-AiVisionLog ("Warmup request: " + $bareModelName)
    $warmStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try{
        $payload = @{
            model = $bareModelName
            prompt = ""
            keep_alive = $script:OllamaVisionKeepAlive
            stream = $false
        } | ConvertTo-Json -Depth 4
        $response = Invoke-RestMethod -Method Post -Uri ($script:OllamaVisionBaseUrl.TrimEnd('/') + "/api/generate") -ContentType "application/json" -Body $payload -TimeoutSec 180
        $warmStopwatch.Stop()
        $loadSeconds = if($null -ne $response.load_duration){ [Math]::Round(([double]$response.load_duration / 1000000000.0),2) } else { $null }
        if($null -ne $loadSeconds){
            Append-AiVisionLog ("Warmup done in " + [Math]::Round($warmStopwatch.Elapsed.TotalSeconds,2) + "s, load_duration=" + $loadSeconds + "s")
        }
        else{
            Append-AiVisionLog ("Warmup done in " + [Math]::Round($warmStopwatch.Elapsed.TotalSeconds,2) + "s")
        }
        return $true
    }
    catch{
        $errorBody = Get-HttpErrorDetail $_
        if([string]::IsNullOrWhiteSpace($errorBody)){
            Append-AiVisionLog ("Warmup failed: " + $_.Exception.Message)
        }
        else{
            Append-AiVisionLog ("Warmup failed: " + $_.Exception.Message + " | " + $errorBody)
        }
        return $false
    }
}

function Warm-StartupAiVisionModel{

    $startupModel = if($cmbAiModel){ [string]$cmbAiModel.Text } else { "" }
    if([string]::IsNullOrWhiteSpace($startupModel)){
        $startupModel = "ollama:qwen2.5vl:3b"
    }
    if(-not $startupModel.StartsWith("ollama:",[System.StringComparison]::OrdinalIgnoreCase)){
        return $false
    }

    Update-StartupSplashStatus ("Loading AI model from HDD: " + $startupModel)
    return (Warm-OllamaVisionModel $startupModel)
}

function Get-AiVisionMechanicalPrompt{
    return @'
You are reading one cropped mechanical-drawing dimension.
Return exactly one normalized dimension string only. No explanation. No markdown. No JSON.

Normalization rules:
- Keep only the final mechanical dimension text.
- The crop may be rotated 0, 90, 180, or 270 degrees. Mentally rotate it to the correct reading direction before reading.
- Preserve mechanical prefixes and symbols: R, C, O/, Ø, Φ, degree.
- Add missing leading zero for decimals: .2 -> 0.2, .35 -> 0.35, 0. 5 -> 0.5.
- Remove spacing inside decimals: 0. 012 -> 0.012, 2 . 6 -> 2.6.
- Remove trailing garbage around the nominal when it is clearly OCR noise.
- If tolerance is visible, preserve it in normalized mechanical form.
- Hard rule: the nominal value is always larger than any tolerance magnitude. If one reading violates this, choose the plausible mechanical reading instead.
- Supported tolerance forms:
  NOMINAL
  NOMINAL ±T
  NOMINAL +T
  NOMINAL -T
  NOMINAL +A -B
  NOMINAL ++A ++B
  NOMINAL --A --B
  R0.05 MAX
  C0.2
  45°

Special cases learned from user corrections:
- RO.03 -> R0.03
- co.5 -> C0.5
- CO.2 -> C0.2
- CO 2 -> C2
- :0.2 -> 0.2
- .2 -> 0.2
- 2. 6 -> 2.6
- 0. 012 -> 0.012
- 0.005DP -> 0.005
- 0.100 +8.002 -> 0.100+0.002
- 0.100 +8.8882 -> 0.100+0.002
- C0.1 all round -> C0.1
- 0.471- -> 0.471
- 19.800- -> 19.800
- 9.600- -> 9.600
- -R0.02 MAX -> R0.02 MAX
- 0.75 ±0.02 -> 0.75±0.02
- 0.405+0.003 -> 0.405+0.003
- 5.000+0.003 +0.001 -> 5.000+0.003+0.001
- 4.000+0.003 +0.001 -> 4.000+0.003+0.001
- If OCR mixes nominal and tolerance fragments, prefer the valid mechanical reading.

Return one line only.
'@
}

function Get-AiVisionExperimentPrompt{
    return @'
Extract all numbers from this dimension.

Return only:
0.200 -0.020 -0.010
'@
}

function Test-AiVisionExperimentMode{

    if($chkAiExperiment){
        return [bool]$chkAiExperiment.Checked
    }
    return $false
}

function Get-AiVisionActivePrompt([switch]$ForceExperiment){

    if($ForceExperiment -or (Test-AiVisionExperimentMode)){
        return (Get-AiVisionExperimentPrompt)
    }
    return (Get-AiVisionMechanicalPrompt)
}

function Get-AiRecoveryPrompt{
    return 'CHI TRA VE DUNG 1 DONG DUY NHAT. BAT BUOC BAT DAU BANG TU FINAL:. KHONG GIAI THICH. KHONG GO DAU DONG THU 2. Doc dimension co khi trong anh va suy luan dap an dung nhat theo ngu canh ban ve co khi. Neu co ky hieu co khi nhu R, C, O/, Ø, Φ, do, B, A thi giu nguyen trong Nominal. Dung dung format nay va khong duoc sai: FINAL: Nominal=<gia tri> Tol+=<gia tri> Tol-=<gia tri>'
}

function Get-ChromeExecutablePath{

    foreach($candidate in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )){
        if(-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)){
            return $candidate
        }
    }

    return $null
}

if(-not ("RapidOcrNativeWindow" -as [type])){
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RapidOcrNativeWindow {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@
}

function Get-ChromeMainWindowHandle{

    $processes = @(
        Get-Process chrome -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -and $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending
    )
    if($processes.Count -le 0){ return [IntPtr]::Zero }
    return [IntPtr]$processes[0].MainWindowHandle
}

function Test-AiRecoveryChromeSessionAlive{

    $targetPid = [int]$script:AiRecoveryChromeProcessId
    if($targetPid -le 0){ return $false }
    try{
        $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if($process -and -not $process.HasExited){
            return $true
        }
    }
    catch{}
    return $false
}

function Get-AiRecoveryChromeWindowHandle{

    $targetPid = [int]$script:AiRecoveryChromeProcessId
    if($targetPid -le 0){ return [IntPtr]::Zero }
    try{
        $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if($process -and $process.MainWindowHandle -and $process.MainWindowHandle -ne 0){
            return [IntPtr]$process.MainWindowHandle
        }
    }
    catch{}
    return [IntPtr]::Zero
}

function Activate-ChromeWindow([int]$waitMs = 4000){

    $deadline = [DateTime]::UtcNow.AddMilliseconds([double]$waitMs)
    do{
        $handle = Get-AiRecoveryChromeWindowHandle
        if($handle -eq [IntPtr]::Zero){
            $handle = Get-ChromeMainWindowHandle
        }
        if($handle -ne [IntPtr]::Zero -and [RapidOcrNativeWindow]::IsWindow($handle)){
            [void][RapidOcrNativeWindow]::ShowWindowAsync($handle,5)
            Start-Sleep -Milliseconds 120
            if([RapidOcrNativeWindow]::SetForegroundWindow($handle)){
                Start-Sleep -Milliseconds 250
                return $true
            }
        }
        Start-Sleep -Milliseconds 180
    } while([DateTime]::UtcNow -lt $deadline)

    return $false
}

function Wait-AiRecoveryChromeReady([int]$waitMs = 9000,[int]$stableMs = 700){

    $deadline = [DateTime]::UtcNow.AddMilliseconds([double]$waitMs)
    do{
        $handle = Get-AiRecoveryChromeWindowHandle
        if($handle -eq [IntPtr]::Zero){
            $handle = Get-ChromeMainWindowHandle
        }
        if($handle -ne [IntPtr]::Zero -and [RapidOcrNativeWindow]::IsWindow($handle)){
            if(Activate-ChromeWindow 1800){
                Start-Sleep -Milliseconds ([Math]::Max(0,$stableMs))
                return $true
            }
        }
        Start-Sleep -Milliseconds 250
    } while([DateTime]::UtcNow -lt $deadline)

    return $false
}

function Minimize-AiRecoveryChromeWindow{

    if(-not $script:AiRecoverySilentMode){ return }

    $handle = Get-AiRecoveryChromeWindowHandle
    if($handle -eq [IntPtr]::Zero){
        $handle = Get-ChromeMainWindowHandle
    }
    if($handle -ne [IntPtr]::Zero -and [RapidOcrNativeWindow]::IsWindow($handle)){
        [void][RapidOcrNativeWindow]::ShowWindowAsync($handle,6)
    }
}

function Restore-RapidOcrWindowFocus{

    if(-not $script:AiRecoverySilentMode){ return }

    try{
        if($form -and $form.Handle -and [RapidOcrNativeWindow]::IsWindow($form.Handle)){
            [void][RapidOcrNativeWindow]::ShowWindowAsync($form.Handle,5)
            [void][RapidOcrNativeWindow]::SetForegroundWindow($form.Handle)
        }
    }
    catch{}
}

function Hide-AiRecoveryChromeTemporarily{

    if(-not $script:AiRecoverySilentMode){ return }
    Minimize-AiRecoveryChromeWindow
    Restore-RapidOcrWindowFocus
}

function Click-ChromeRecoveryAnswerArea{

    $handle = Get-AiRecoveryChromeWindowHandle
    if($handle -eq [IntPtr]::Zero){
        $handle = Get-ChromeMainWindowHandle
    }
    if($handle -eq [IntPtr]::Zero){ return $false }

    $rect = New-Object RapidOcrNativeWindow+RECT
    if(-not [RapidOcrNativeWindow]::GetWindowRect($handle,[ref]$rect)){ return $false }

    $width = [Math]::Max(0,($rect.Right - $rect.Left))
    $height = [Math]::Max(0,($rect.Bottom - $rect.Top))
    if($width -le 0 -or $height -le 0){ return $false }

    $targetX = [int]($rect.Left + ($width * 0.34))
    $targetY = [int]($rect.Top + ($height * 0.66))
    [void][RapidOcrNativeWindow]::SetCursorPos($targetX,$targetY)
    Start-Sleep -Milliseconds 80
    [RapidOcrNativeWindow]::mouse_event([RapidOcrNativeWindow]::MOUSEEVENTF_LEFTDOWN,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [RapidOcrNativeWindow]::mouse_event([RapidOcrNativeWindow]::MOUSEEVENTF_LEFTUP,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    return $true
}

function Set-AiRecoveryUiBusy([bool]$isBusy,[string]$message = ""){

    if($pnlAiRecoveryOverlay){
        $pnlAiRecoveryOverlay.Visible = $false
    }

    if($isBusy -and $txtOcrDebug){
        $txtOcrDebug.Text = [string]$message
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-AiRecoveryChromeSession{

    $targetPid = [int]$script:AiRecoveryChromeProcessId
    $script:AiRecoveryChromeProcessId = 0
    $script:AiRecoveryChromeWarmed = $false
    if($targetPid -le 0){ return }

    try{
        $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if($process){
            try{
                $null = $process.CloseMainWindow()
                Start-Sleep -Milliseconds 900
            }
            catch{}
            if(-not $process.HasExited){
                Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch{}
}

function Open-ChromeAiRecoveryPage{

    $chromePath = Get-ChromeExecutablePath
    if(!$chromePath){ throw "Google Chrome not found." }

    if(Test-AiRecoveryChromeSessionAlive){
        $reuseWaitMs = if($script:AiRecoveryChromeWarmed -and $script:AiRecoveryTurboMode){ 3500 } else { 8000 }
        $reuseStableMs = if($script:AiRecoveryChromeWarmed -and $script:AiRecoveryTurboMode){ 220 } else { 650 }
        if(-not (Wait-AiRecoveryChromeReady $reuseWaitMs $reuseStableMs)){
            throw "Could not activate Chrome recovery window."
        }
        $script:AiRecoveryChromeWarmed = $true
        return
    }

    $chromeProcess = Start-Process -FilePath $chromePath -ArgumentList '--new-window',$script:AiRecoveryChromeUrl -PassThru
    if($chromeProcess){ $script:AiRecoveryChromeProcessId = [int]$chromeProcess.Id }
    Start-Sleep -Milliseconds 700

    if(-not (Wait-AiRecoveryChromeReady 12000 1200)){
        throw "Could not activate Chrome window."
    }
    # The tab is already opened with the target AI Mode URL.
    Start-Sleep -Milliseconds 1200
    $script:AiRecoveryChromeWarmed = $true
}

function Set-ClipboardImageFromPath($imagePath){

    if([string]::IsNullOrWhiteSpace([string]$imagePath) -or !(Test-Path -LiteralPath $imagePath)){ return $false }
    $bitmap = $null
    $clone = $null
    try{
        $bitmap = [System.Drawing.Bitmap]::FromFile($imagePath)
        $clone = New-Object System.Drawing.Bitmap($bitmap)
        [System.Windows.Forms.Clipboard]::SetImage($clone)
        return $true
    }
    catch{
        return $false
    }
    finally{
        if($clone -is [System.IDisposable]){ $clone.Dispose() }
        if($bitmap -is [System.IDisposable]){ $bitmap.Dispose() }
    }
}

function Set-ClipboardTextSafe([string]$text){
    try{
        [System.Windows.Forms.Clipboard]::SetText([string]$text)
        return $true
    }
    catch{
        return $false
    }
}

function Get-ClipboardTextSafe{
    try{
        if([System.Windows.Forms.Clipboard]::ContainsText()){
            return [string]([System.Windows.Forms.Clipboard]::GetText())
        }
    }
    catch{}
    return ""
}

function Send-KeysWithPause([string]$keys,[int]$pauseMs = 350){
    if([string]::IsNullOrWhiteSpace([string]$keys)){ return }
    [System.Windows.Forms.SendKeys]::SendWait($keys)
    Start-Sleep -Milliseconds $pauseMs
}

function Parse-AiRecoveryTriplet($text){

    $result = [PSCustomObject]@{
        Raw = ""
        Nominal = ""
        TolPlus = 0.0
        TolMinus = 0.0
        Success = $false
    }

    if([string]::IsNullOrWhiteSpace([string]$text)){ return $result }

    $sourceText = [string]$text
    $lines = @(
        ([string]$text) -split "(`r`n|`n|`r)" |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_ -notmatch 'Doc dimension|Khong can giai thich|Nominal TolPlus TolMinus|Vi du'
        }
    )

    $finalLine = @(
        $lines |
        Where-Object { $_ -match 'FINAL\s*:' } |
        Select-Object -Last 1
    )
    if($finalLine.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$finalLine[0])){
        $sourceText = [string]$finalLine[0]
    }

    $nominalLabeled = [regex]::Match($sourceText,'Nominal\s*=\s*(.+?)(?=\s+Tol\+\s*=|\s+Tol-\s*=|$)','IgnoreCase')
    $tolPlusLabeled = [regex]::Match($sourceText,'Tol\s*\+\s*=\s*([+\-]?\d+(?:\.\d+)?)','IgnoreCase')
    $tolMinusLabeled = [regex]::Match($sourceText,'Tol\s*\-\s*=\s*([+\-]?\d+(?:\.\d+)?)','IgnoreCase')
    if($nominalLabeled.Success -and $tolPlusLabeled.Success -and $tolMinusLabeled.Success){
        $nominal = ([string]$nominalLabeled.Groups[1].Value).Trim()
        if([string]::IsNullOrWhiteSpace($nominal)){ return $result }
        $tolPlusText = [string]$tolPlusLabeled.Groups[1].Value
        $tolMinusText = [string]$tolMinusLabeled.Groups[1].Value
        $tolPlus = 0.0
        $tolMinus = 0.0
        if(-not [double]::TryParse($tolPlusText,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$tolPlus)){ return $result }
        if(-not [double]::TryParse($tolMinusText,[System.Globalization.NumberStyles]::Float,[System.Globalization.CultureInfo]::InvariantCulture,[ref]$tolMinus)){ return $result }
        $result.Raw = ("FINAL: Nominal=" + $nominal + " Tol+=" + $tolPlusText + " Tol-=" + $tolMinusText)
        $result.Nominal = $nominal
        $result.TolPlus = [double]$tolPlus
        $result.TolMinus = [double]$tolMinus
        $result.Success = $true
        return $result
    }

    return $result
}

function Set-StepAiRecoveryMetadata($rowIndex,[string]$status,[string]$source,[string]$rawText){

    if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){ return }

    $table.Rows[$rowIndex].Tag = [PSCustomObject]@{
        Status = [string]$status
        Source = [string]$source
        RawText = [string]$rawText
        UpdatedAt = (Get-Date)
    }
    if([string]::IsNullOrWhiteSpace([string]$table.Rows[$rowIndex].Cells[4].Value)){
        $table.Rows[$rowIndex].Cells[4].Value = [string]$status
    }
    $table.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::Honeydew

    $stepIndex = 0
    [void][int]::TryParse(([string]$table.Rows[$rowIndex].Cells[0].Value),[ref]$stepIndex)
    foreach($zone in @($script:PdfTextLayerZones)){
        if(
            $zone -and
            $zone.PSObject.Properties.Name -contains "Source" -and [string]$zone.Source -eq "MarkStep" -and
            $zone.PSObject.Properties.Name -contains "MarkStepIndex" -and [int]$zone.MarkStepIndex -eq $stepIndex
        ){
            $zone | Add-Member -NotePropertyName AiRecoveryStatus -NotePropertyValue ([string]$status) -Force
            $zone | Add-Member -NotePropertyName AiRecoverySource -NotePropertyValue ([string]$source) -Force
            $zone | Add-Member -NotePropertyName AiRecoveryRawText -NotePropertyValue ([string]$rawText) -Force
        }
    }
}

function Invoke-ChromeAiRecoveryTextFromImagePath($imagePath){

    if([string]::IsNullOrWhiteSpace([string]$imagePath) -or !(Test-Path -LiteralPath $imagePath)){ throw "Recovery image not found." }

    if(-not (Set-ClipboardImageFromPath $imagePath)){
        throw "Could not put crop image on clipboard."
    }

    Open-ChromeAiRecoveryPage
    if(-not (Test-AiRecoveryChromeSessionAlive)){
        throw "Chrome AI recovery window was closed."
    }
    if(-not (Wait-AiRecoveryChromeReady 9000 700)){
        throw "Chrome AI tab was not ready for paste."
    }

    # AI Mode sometimes needs one extra click/focus cycle after navigation.
    Send-KeysWithPause '{TAB}' 180
    Send-KeysWithPause '+{TAB}' 180
    Send-KeysWithPause '^v' 1250
    if(-not (Set-ClipboardTextSafe (Get-AiRecoveryPrompt))){
        throw "Could not put AI recovery prompt on clipboard."
    }
    Send-KeysWithPause '^v' 420
    Send-KeysWithPause '{ENTER}' 1500
    Hide-AiRecoveryChromeTemporarily

    $bestText = ""
    $lastPageText = ""
    $maxAttempts = if($script:AiRecoveryTurboMode){ 10 } else { 12 }
    $pollDelayMs = if($script:AiRecoveryTurboMode){ 1100 } else { 1800 }
    for($attempt = 0; $attempt -lt $maxAttempts; $attempt++){
        Start-Sleep -Milliseconds $pollDelayMs
        if(-not (Test-AiRecoveryChromeSessionAlive)){
            throw "Chrome AI recovery window was closed."
        }
        if(-not (Wait-AiRecoveryChromeReady 5000 250)){ continue }
        [void](Click-ChromeRecoveryAnswerArea)
        Send-KeysWithPause '^a' 120
        Send-KeysWithPause '^c' 260
        $pageText = Get-ClipboardTextSafe
        $lastPageText = [string]$pageText
        $parsed = Parse-AiRecoveryTriplet $pageText
        if($parsed.Success){
            $bestText = [string]$parsed.Raw
            break
        }
        Hide-AiRecoveryChromeTemporarily
    }

    Hide-AiRecoveryChromeTemporarily

    if([string]::IsNullOrWhiteSpace($bestText)){
        if(-not [string]::IsNullOrWhiteSpace($lastPageText)){
            throw ("Google AI mode did not return a usable numeric triplet. Clipboard=" + (($lastPageText -replace '\s+',' ').Trim()))
        }
        throw "Google AI mode did not return a usable numeric triplet."
    }

    return $bestText
}

function Invoke-AiRecoveryModeForSelectedStep{

    if($script:AiVisionBusy){ return }
    if(!$table -or !$script:sourceBitmap){ return }

    $rowIndex = Get-SelectedStepRowIndex
    if($rowIndex -lt 0 -or $rowIndex -ge $table.Rows.Count){ return }
    if(-not $script:StepRects.ContainsKey($rowIndex)){ return }

    $realRect = $script:StepRects[$rowIndex]
    $tempPath = Save-ManualSelectionCropToTemp $realRect
    if([string]::IsNullOrWhiteSpace([string]$tempPath)){ return }

    $script:AiVisionBusy = $true
    $aiRecoverySucceeded = $false
    $stepLabel = [string]$table.Rows[$rowIndex].Cells[0].Value
    Set-AiRecoveryUiBusy $true ("AI Recovery is processing step " + $stepLabel + "..." + [Environment]::NewLine + "Waiting for Chrome AI Mode to be ready, then Chrome will close after this session.")
    Set-OcrDebugAiHeader ("AI Recovery Step " + $stepLabel)
    Append-OcrDebugAiProgress "Mode: Chrome Google AI"
    Append-AiVisionLog ("AI Recovery step " + $stepLabel)

    try{
        $rawText = Invoke-ChromeAiRecoveryTextFromImagePath $tempPath
        $parsed = Parse-AiRecoveryTriplet $rawText
        if(-not $parsed.Success){
            throw "AI recovery parse failed."
        }

        $resolvedTolMinus = [double]$parsed.TolMinus
        $resolvedTolPlus = [double]$parsed.TolPlus
        if($resolvedTolMinus -eq 0 -and $resolvedTolPlus -eq 0){
            $fallbackTolerance = Get-GeneralToleranceForNominal ([string]$parsed.Nominal)
            $resolvedTolMinus = [double]$fallbackTolerance.TolMinus
            $resolvedTolPlus = [double]$fallbackTolerance.TolPlus
        }

        $table.Rows[$rowIndex].Cells[1].Value = [string]$parsed.Nominal
        $table.Rows[$rowIndex].Cells[2].Value = Format-InvariantSignedTolerance $resolvedTolMinus
        $table.Rows[$rowIndex].Cells[3].Value = Format-InvariantSignedTolerance $resolvedTolPlus
        Add-OrUpdate-MarkStepTextZone $rowIndex ([int]$table.Rows[$rowIndex].Cells[0].Value) $realRect ([string]$parsed.Nominal) ([string]$parsed.Raw) $resolvedTolMinus $resolvedTolPlus | Out-Null
        Set-StepAiRecoveryMetadata $rowIndex "AI Fixed" "Gemini" ([string]$parsed.Raw)
        Save-CurrentPageState
        Queue-SessionStateSave
        Refresh-DuplicateState
        Apply-TableSearchFilter
        Request-CanvasRedraw
        Append-AiVisionLog ("AI Recovery raw: " + [string]$parsed.Raw)
        Append-OcrDebugAiProgress ("Raw: " + [string]$parsed.Raw)
        Append-OcrDebugAiProgress ("Nominal: " + [string]$parsed.Nominal)
        Append-OcrDebugAiProgress ("Tol-: " + (Format-InvariantSignedTolerance $resolvedTolMinus))
        Append-OcrDebugAiProgress ("Tol+: " + (Format-InvariantSignedTolerance $resolvedTolPlus))
        if($txtAiResult){ $txtAiResult.Text = [string]$parsed.Raw }
        $aiRecoverySucceeded = $true
    }
    catch{
        Append-AiVisionLog ("AI Recovery failed: " + $_.Exception.Message)
        Append-OcrDebugAiProgress ("Failed: " + $_.Exception.Message)
    }
    finally{
        try{
            if(Test-Path -LiteralPath $tempPath){
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch{}
        Close-AiRecoveryChromeSession
        Restore-RapidOcrWindowFocus
        Set-AiRecoveryUiBusy $false
        $script:AiVisionBusy = $false
    }
}

function Get-AiVisionMechanicalReview($rawText,$rect,$angle,$preferredAngles){

    $cleanedText = Clean-OCRText $rawText
    $mechanicalText = Normalize-MechanicalOcrText $rawText
    $parsedText = Parse-Dimension $mechanicalText
    if([string]::IsNullOrWhiteSpace($parsedText)){ $parsedText = Parse-Dimension $cleanedText }

    $resolvedText = Resolve-MechanicalDimensionText $mechanicalText $cleanedText $parsedText
    $resolvedText = Repair-ManualMechanicalNominalFromRaw $resolvedText $rawText $cleanedText $rect
    $resolvedText = Repair-ManualVerticalMissingDecimalNominal $resolvedText $rawText $cleanedText $rect

    $tolerance = $null
    if(-not [string]::IsNullOrWhiteSpace($resolvedText)){
        $tolerance = Parse-ToleranceFull $mechanicalText $resolvedText
        if(((-not $tolerance) -or (-not $tolerance.Detected)) -and -not [string]::IsNullOrWhiteSpace($cleanedText)){
            $tolerance = Parse-ToleranceFull $cleanedText $resolvedText
        }
        if(((-not $tolerance) -or (-not $tolerance.Detected)) -and (Test-UsefulMechanicalRawText $rawText)){
            $tolerance = Parse-ToleranceFull $rawText $resolvedText
        }
    }

    $score = Get-EngineeringTextReviewScore $rawText $resolvedText $tolerance $angle $preferredAngles $rect
    if([string]::IsNullOrWhiteSpace($resolvedText)){ $score -= 20 }
    if($tolerance -and $tolerance.Detected){
        if(Test-MechanicalTolerancePlausible $tolerance $resolvedText){
            $score += 10
        }
        else{
            $score -= 30
        }
    }

    return [PSCustomObject]@{
        RawText = [string]$rawText
        Nominal = [string]$resolvedText
        Tolerance = $tolerance
        Angle = [int]$angle
        Score = [double]$score
    }
}

function Invoke-OllamaVisionFromSelectionRect($modelName,$realRect,[switch]$FastSingleAngle){

    $orientationHint = Get-TextZoneOrientationHint $realRect
    $preferredAngles = @($orientationHint.PreferredAngles | Select-Object -Unique)
    if($preferredAngles.Count -le 0){
        $preferredAngles = @(0,180,90,270)
    }

    if($FastSingleAngle){
        $primaryAngle = if($preferredAngles.Count -gt 0){ [int]$preferredAngles[0] } else { 0 }
        $preferredAngles = @($primaryAngle)
    }

    Append-AiVisionLog ("AI orientation: " + [string]$orientationHint.Orientation + " | angles=" + (($preferredAngles -join ",")))
    Append-OcrDebugAiProgress ("Orientation: " + [string]$orientationHint.Orientation)
    Append-OcrDebugAiProgress ("Angles: " + (($preferredAngles -join ",")))

    $reviews = @()
    foreach($angle in @($preferredAngles)){
        $tempPath = Save-ManualSelectionCropToTempAtAngle $realRect $angle
        if([string]::IsNullOrWhiteSpace([string]$tempPath)){ continue }

        try{
            Append-AiVisionLog ("AI angle " + [string]$angle + "...")
            Append-OcrDebugAiProgress ("Running angle " + [string]$angle + "...")
            $rawText = Invoke-OllamaVisionFromImagePath $modelName $tempPath
            $review = Get-AiVisionMechanicalReview $rawText $realRect $angle $preferredAngles
            $reviews += $review
            Append-AiVisionLog ("Angle " + [string]$angle + " raw: " + [string]$review.RawText)
            Append-AiVisionLog ("Angle " + [string]$angle + " score: " + [string][Math]::Round([double]$review.Score,1))
            Append-OcrDebugAiProgress ("Angle " + [string]$angle + " Raw: " + [string]$review.RawText)
            Append-OcrDebugAiProgress ("Angle " + [string]$angle + " Score: " + [string][Math]::Round([double]$review.Score,1))
        }
        finally{
            try{ if(Test-Path -LiteralPath $tempPath){ Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } } catch{}
        }
    }

    if($reviews.Count -le 0){
        throw "AI vision did not return any usable result."
    }

    $bestReview = @(
        $reviews |
        Sort-Object @{ Expression = { [double]$_.Score }; Descending = $true }, @{ Expression = { [int]$_.Angle }; Descending = $false } |
        Select-Object -First 1
    )[0]
    Append-AiVisionLog ("Best AI angle: " + [string]$bestReview.Angle)
    Append-OcrDebugAiProgress ("Best Angle: " + [string]$bestReview.Angle)
    return $bestReview
}

function Invoke-AiVisionFromImagePath($modelName,$imagePath,[switch]$ForceExperiment){

    if([string]::IsNullOrWhiteSpace([string]$modelName)){ throw "AI model is empty." }

    if($modelName.StartsWith("ollama:",[System.StringComparison]::OrdinalIgnoreCase)){
        return (Invoke-OllamaVisionFromImagePath $modelName $imagePath)
    }
    if($modelName.StartsWith("gemini:",[System.StringComparison]::OrdinalIgnoreCase)){
        return (Invoke-GeminiVisionFromImagePath $modelName $imagePath -ForceExperiment:$ForceExperiment)
    }

    throw ("Unsupported AI model: " + [string]$modelName)
}

function Invoke-AiVisionFromSelectionRect($modelName,$realRect,[switch]$FastSingleAngle,[switch]$ForceExperiment){

    $orientationHint = Get-TextZoneOrientationHint $realRect
    $preferredAngles = @($orientationHint.PreferredAngles | Select-Object -Unique)
    if($preferredAngles.Count -le 0){
        $preferredAngles = @(0,180,90,270)
    }

    if($FastSingleAngle -or $ForceExperiment -or (Test-AiVisionExperimentMode)){
        $primaryAngle = if($preferredAngles.Count -gt 0){ [int]$preferredAngles[0] } else { 0 }
        $preferredAngles = @($primaryAngle)
    }

    Append-AiVisionLog ("AI orientation: " + [string]$orientationHint.Orientation + " | angles=" + (($preferredAngles -join ",")))
    Append-OcrDebugAiProgress ("Orientation: " + [string]$orientationHint.Orientation)
    Append-OcrDebugAiProgress ("Angles: " + (($preferredAngles -join ",")))

    $reviews = @()
    foreach($angle in @($preferredAngles)){
        $tempPath = Save-ManualSelectionCropToTempAtAngle $realRect $angle
        if([string]::IsNullOrWhiteSpace([string]$tempPath)){ continue }

        try{
            Append-AiVisionLog ("AI angle " + [string]$angle + "...")
            Append-OcrDebugAiProgress ("Running angle " + [string]$angle + "...")
            $rawText = Invoke-AiVisionFromImagePath $modelName $tempPath -ForceExperiment:$ForceExperiment
            $review = Get-AiVisionMechanicalReview $rawText $realRect $angle $preferredAngles
            $reviews += $review
            Append-AiVisionLog ("Angle " + [string]$angle + " raw: " + [string]$review.RawText)
            Append-AiVisionLog ("Angle " + [string]$angle + " score: " + [string][Math]::Round([double]$review.Score,1))
            Append-OcrDebugAiProgress ("Angle " + [string]$angle + " Raw: " + [string]$review.RawText)
            Append-OcrDebugAiProgress ("Angle " + [string]$angle + " Score: " + [string][Math]::Round([double]$review.Score,1))
        }
        finally{
            try{ if(Test-Path -LiteralPath $tempPath){ Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue } } catch{}
        }
    }

    if($reviews.Count -le 0){
        throw "AI vision did not return any usable result."
    }

    $bestReview = @(
        $reviews |
        Sort-Object @{ Expression = { [double]$_.Score }; Descending = $true }, @{ Expression = { [int]$_.Angle }; Descending = $false } |
        Select-Object -First 1
    )[0]
    Append-AiVisionLog ("Best AI angle: " + [string]$bestReview.Angle)
    Append-OcrDebugAiProgress ("Best Angle: " + [string]$bestReview.Angle)
    return $bestReview
}

function Set-AiVisionModelSelection($modelName){

    $targetModel = [string]$modelName
    if([string]::IsNullOrWhiteSpace($targetModel) -or !$cmbAiModel){ return }
    $modelIndex = $cmbAiModel.Items.IndexOf($targetModel)
    if($modelIndex -ge 0){
        $cmbAiModel.SelectedIndex = $modelIndex
    }
    else{
        $cmbAiModel.Text = $targetModel
    }
    if($miAdvanceAiModelQwen){
        $miAdvanceAiModelQwen.Checked = ([string]$cmbAiModel.Text -eq "ollama:qwen2.5vl:3b")
    }
    if($miAdvanceAiModelMiniCpm){
        $miAdvanceAiModelMiniCpm.Checked = ([string]$cmbAiModel.Text -eq "ollama:minicpm-v")
    }
}

function Invoke-AiVisionRescanSelectedStep{

    if(!$table.SelectedRows.Count -or !$script:sourceBitmap){ return }
    $rowIndex = [int]$table.SelectedRows[0].Index
    if($rowIndex -lt 0 -or -not $script:StepRects.ContainsKey($rowIndex)){ return }

    $selectedModel = if($cmbAiModel){ [string]$cmbAiModel.Text } else { "" }
    if([string]::IsNullOrWhiteSpace($selectedModel)){ return }

    $realRect = $script:StepRects[$rowIndex]
    if($script:AiVisionBusy){ return }
    $script:AiVisionBusy = $true
    Append-AiVisionLog ("Rescanning step " + [string]$table.Rows[$rowIndex].Cells[0].Value + " with " + $selectedModel)
    Set-OcrDebugAiHeader ("AI Rescan Step " + [string]$table.Rows[$rowIndex].Cells[0].Value)
    Append-OcrDebugAiProgress ("Model: " + $selectedModel)
    try{
        $visionReview = Invoke-AiVisionFromSelectionRect $selectedModel $realRect -FastSingleAngle
        $rawText = [string]$visionReview.RawText
        $candidate = New-ManualSelectionCandidate $realRect $rawText $rawText ("AiVision:" + $selectedModel)
        $table.Rows[$rowIndex].Cells[1].Value = [string]$candidate.Nominal
        $table.Rows[$rowIndex].Cells[2].Value = Format-InvariantSignedTolerance $candidate.Tolerance.TolMinus
        $table.Rows[$rowIndex].Cells[3].Value = Format-InvariantSignedTolerance $candidate.Tolerance.TolPlus
        Add-OrUpdate-MarkStepTextZone $rowIndex ([int]$table.Rows[$rowIndex].Cells[0].Value) $realRect ([string]$candidate.Nominal) ([string]$candidate.RawText) $candidate.Tolerance.TolMinus $candidate.Tolerance.TolPlus | Out-Null
        Save-CurrentPageState
        Queue-SessionStateSave
        Refresh-DuplicateState
        Apply-TableSearchFilter
        Request-CanvasRedraw
        Append-AiVisionLog ("Rescan raw: " + [string]$rawText)
        Append-AiVisionLog ("Rescan resolved: " + [string]$candidate.Nominal)
        Append-OcrDebugAiProgress ("Raw: " + [string]$rawText)
        Append-OcrDebugAiProgress ("Resolved: " + [string]$candidate.Nominal)
        Append-OcrDebugAiProgress ("Tol-: " + (Format-InvariantSignedTolerance $candidate.Tolerance.TolMinus))
        Append-OcrDebugAiProgress ("Tol+: " + (Format-InvariantSignedTolerance $candidate.Tolerance.TolPlus))
        if($txtAiResult){ $txtAiResult.Text = [string]$rawText }
    }
    catch{
        Append-AiVisionLog ("Rescan failed: " + $_.Exception.Message)
        Append-OcrDebugAiProgress ("Failed: " + $_.Exception.Message)
    }
    finally{
        $script:AiVisionBusy = $false
    }
}

function Invoke-OllamaVisionFromImagePath($modelName,$imagePath){

    if([string]::IsNullOrWhiteSpace($modelName)){ throw "Ollama model is empty." }
    if([string]::IsNullOrWhiteSpace($imagePath) -or !(Test-Path -LiteralPath $imagePath)){ throw "Crop image was not created." }

    $bareModelName = [string]$modelName
    if($bareModelName.StartsWith("ollama:",[System.StringComparison]::OrdinalIgnoreCase)){
        $bareModelName = $bareModelName.Substring(7)
    }

    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Append-AiVisionLog ("Ollama prepare: " + $bareModelName)

    $ioStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $bytes = [System.IO.File]::ReadAllBytes($imagePath)
    $ioStopwatch.Stop()
    Append-AiVisionLog ("Crop read done in " + [Math]::Round($ioStopwatch.Elapsed.TotalSeconds,2) + "s")

    $encodeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $base64Image = [System.Convert]::ToBase64String($bytes)
    $encodeStopwatch.Stop()
    Append-AiVisionLog ("Image encode done in " + [Math]::Round($encodeStopwatch.Elapsed.TotalSeconds,2) + "s")

    $payload = @{
        model = $bareModelName
        stream = $false
        keep_alive = $script:OllamaVisionKeepAlive
        messages = @(
            @{
                role = "user"
                content = (Get-AiVisionActivePrompt)
                images = @($base64Image)
            }
        )
    } | ConvertTo-Json -Depth 6

    Append-AiVisionLog ("Request sent. Waiting for model load / HDD...")
    $inferStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try{
        $response = Invoke-RestMethod -Method Post -Uri ($script:OllamaVisionBaseUrl.TrimEnd('/') + "/api/chat") -ContentType "application/json" -Body $payload -TimeoutSec 180
    }
    catch{
        $errorBody = Get-HttpErrorDetail $_
        if([string]::IsNullOrWhiteSpace($errorBody)){ throw }
        throw ("Ollama chat failed: " + $_.Exception.Message + " | " + $errorBody)
    }
    $inferStopwatch.Stop()
    Append-AiVisionLog ("Model response received in " + [Math]::Round($inferStopwatch.Elapsed.TotalSeconds,2) + "s")
    if($null -ne $response.load_duration){
        $loadSeconds = [Math]::Round(([double]$response.load_duration / 1000000000.0),2)
        Append-AiVisionLog ("Ollama load_duration " + $loadSeconds + "s")
    }
    $text = [string]$response.message.content
    if([string]::IsNullOrWhiteSpace($text)){ throw "Ollama returned an empty response." }
    $totalStopwatch.Stop()
    Append-AiVisionLog ("Ollama total time " + [Math]::Round($totalStopwatch.Elapsed.TotalSeconds,2) + "s")
    return $text.Trim()
}

function Get-GeminiApiKey{

    foreach($candidate in @(
        [string]$env:GEMINI_API_KEY,
        [string]$env:GOOGLE_API_KEY
    )){
        if(-not [string]::IsNullOrWhiteSpace($candidate)){
            return $candidate.Trim()
        }
    }

    return ""
}

function Invoke-GeminiVisionFromImagePath($modelName,$imagePath,[switch]$ForceExperiment){

    if([string]::IsNullOrWhiteSpace($modelName)){ throw "Gemini model is empty." }
    if([string]::IsNullOrWhiteSpace($imagePath) -or !(Test-Path -LiteralPath $imagePath)){ throw "Crop image was not created." }

    $apiKey = Get-GeminiApiKey
    if([string]::IsNullOrWhiteSpace($apiKey)){
        throw "Gemini API key not found. Set GEMINI_API_KEY or GOOGLE_API_KEY."
    }

    $bareModelName = [string]$modelName
    if($bareModelName.StartsWith("gemini:",[System.StringComparison]::OrdinalIgnoreCase)){
        $bareModelName = $bareModelName.Substring(7)
    }

    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Append-AiVisionLog ("Gemini prepare: " + $bareModelName)

    $bytes = [System.IO.File]::ReadAllBytes($imagePath)
    $base64Image = [System.Convert]::ToBase64String($bytes)
    $promptText = Get-AiVisionActivePrompt -ForceExperiment:$ForceExperiment
    $payload = @{
        contents = @(
            @{
                parts = @(
                    @{ text = $promptText },
                    @{
                        inline_data = @{
                            mime_type = "image/png"
                            data = $base64Image
                        }
                    }
                )
            }
        )
        generationConfig = @{
            temperature = 0
            topP = 0.1
            topK = 1
            maxOutputTokens = 48
        }
    } | ConvertTo-Json -Depth 8

    Append-AiVisionLog "Gemini request sent."
    try{
        $response = Invoke-RestMethod -Method Post -Uri ($script:GeminiVisionBaseUrl.TrimEnd('/') + "/models/" + $bareModelName + ":generateContent") -Headers @{ "x-goog-api-key" = $apiKey } -ContentType "application/json" -Body $payload -TimeoutSec 60
    }
    catch{
        $errorBody = Get-HttpErrorDetail $_
        if([string]::IsNullOrWhiteSpace($errorBody)){ throw }
        throw ("Gemini request failed: " + $_.Exception.Message + " | " + $errorBody)
    }

    $parts = @()
    foreach($candidate in @($response.candidates)){
        if($candidate.content -and $candidate.content.parts){
            foreach($part in @($candidate.content.parts)){
                if(-not [string]::IsNullOrWhiteSpace([string]$part.text)){
                    $parts += [string]$part.text
                }
            }
        }
    }

    $text = ($parts -join " ").Trim()
    if([string]::IsNullOrWhiteSpace($text)){ throw "Gemini returned an empty response." }
    $totalStopwatch.Stop()
    Append-AiVisionLog ("Gemini total time " + [Math]::Round($totalStopwatch.Elapsed.TotalSeconds,2) + "s")
    return $text
}

function New-ManualSelectionCandidate($realRect,$bestText,$bestRawText,$source){

    $img = $script:sourceBitmap
    $cleanedBestText = Clean-OCRText $bestText
    $mechanicalBestText = Normalize-MechanicalOcrText $bestRawText
    $parsedBestText = Parse-Dimension $mechanicalBestText
    if([string]::IsNullOrWhiteSpace($parsedBestText)){ $parsedBestText = Parse-Dimension $cleanedBestText }
    $resolvedText = Resolve-MechanicalDimensionText $mechanicalBestText $cleanedBestText $parsedBestText
    $resolvedText = Repair-ManualMechanicalNominalFromRaw $resolvedText $bestRawText $cleanedBestText $realRect
    $resolvedText = Repair-ManualVerticalMissingDecimalNominal $resolvedText $bestRawText $cleanedBestText $realRect

    $tolMinus = ""
    $tolPlus = ""

    if($resolvedText){
        $selectionTolerance = Parse-ToleranceFull $mechanicalBestText $resolvedText
        if(((-not $selectionTolerance) -or (-not $selectionTolerance.Detected) -or ((([double]$selectionTolerance.TolMinus) -eq 0) -and (([double]$selectionTolerance.TolPlus) -eq 0))) -and -not [string]::IsNullOrWhiteSpace($cleanedBestText)){
            $selectionTolerance = Parse-ToleranceFull $cleanedBestText $resolvedText
        }
        if(((-not $selectionTolerance) -or (-not $selectionTolerance.Detected) -or ((([double]$selectionTolerance.TolMinus) -eq 0) -and (([double]$selectionTolerance.TolPlus) -eq 0))) -and (Test-UsefulMechanicalRawText $bestRawText)){
            $selectionTolerance = Parse-ToleranceFull $bestRawText $resolvedText
        }

        $selectionToleranceValueCount = 0
        if($selectionTolerance){
            if(([double]$selectionTolerance.TolMinus) -ne 0){ $selectionToleranceValueCount++ }
            if(([double]$selectionTolerance.TolPlus) -ne 0){ $selectionToleranceValueCount++ }
        }

        $selectionHasExplicitToleranceSign = (
            (([string]$bestRawText) -match '[\+\-±]') -or
            (([string]$cleanedBestText) -match '[\+\-±]')
        )
        $isAiVisionCandidate = ([string]$source -like 'AiVision:*')

        if($isAiVisionCandidate -and $selectionTolerance -and $selectionTolerance.Detected -and $selectionHasExplicitToleranceSign){
            $tolMinus = $selectionTolerance.TolMinus
            $tolPlus = $selectionTolerance.TolPlus
        }
        else{
            $detectedTolerance = Extract-ToleranceFromRegion $img $realRect.X $realRect.Y $realRect.Width $realRect.Height $resolvedText
            $detectedToleranceValueCount = 0
            if($detectedTolerance){
                if(([double]$detectedTolerance.TolMinus) -ne 0){ $detectedToleranceValueCount++ }
                if(([double]$detectedTolerance.TolPlus) -ne 0){ $detectedToleranceValueCount++ }
            }

            if($selectionTolerance -and $selectionTolerance.Detected -and (Test-MechanicalTolerancePlausible $selectionTolerance $resolvedText) -and $selectionToleranceValueCount -gt $detectedToleranceValueCount){
                $detectedTolerance = $selectionTolerance
            }

            if(
                $detectedTolerance -and
                $detectedTolerance.Detected -and
                (Test-MechanicalTolerancePlausible $detectedTolerance $resolvedText) -and
                (([double]$detectedTolerance.TolPlus) -ne 0 -or ([double]$detectedTolerance.TolMinus) -ne 0)
            ){
                $tolMinus = $detectedTolerance.TolMinus
                $tolPlus = $detectedTolerance.TolPlus
            }
            else{
                $fallbackTolerance = Get-GeneralToleranceForNominal $resolvedText
                $tolMinus = $fallbackTolerance.TolMinus
                $tolPlus = $fallbackTolerance.TolPlus
            }
        }
    }

    if ($null -eq $tolMinus -or $tolMinus -eq "") { $tolMinus = 0 }
    if ($null -eq $tolPlus  -or $tolPlus  -eq "") { $tolPlus  = 0 }

    $manualTolerance = [PSCustomObject]@{
        Detected = (([double]$tolMinus) -ne 0 -or ([double]$tolPlus) -ne 0)
        TolMinus = [double]$tolMinus
        TolPlus = [double]$tolPlus
        NormalizedText = [string]$resolvedText
        ParseMode = [string]$source
    }
    return [PSCustomObject]@{
        Nominal = [string]$resolvedText
        RawText = [string]$bestRawText
        CleanedText = [string]$cleanedBestText
        LabelText = [string]$mechanicalBestText
        ParsedText = [string]$parsedBestText
        Rect = $realRect
        Tolerance = $manualTolerance
        Source = [string]$source
    }
}

function Commit-ManualSelectionCandidate($manualCandidate){

    if(!$manualCandidate -or !$manualCandidate.Rect){ return $false }

    $img = $script:sourceBitmap
    $realRect = $manualCandidate.Rect
    $bestText = [string]$manualCandidate.Nominal
    $bestRawText = [string]$manualCandidate.RawText
    $tolMinus = if($manualCandidate.Tolerance){ $manualCandidate.Tolerance.TolMinus } else { 0 }
    $tolPlus = if($manualCandidate.Tolerance){ $manualCandidate.Tolerance.TolPlus } else { 0 }

    $duplicateMatch = Get-CandidateTableDuplicateMatch $manualCandidate
    if($duplicateMatch){
        Set-PendingManualDuplicateCandidate $manualCandidate $duplicateMatch | Out-Null
        return $false
    }

    $index = Get-NextStepNumber -SkipSaveCurrentPageState
    Add-OcrLog $index $bestText
    $row = $table.Rows.Add()
    $script:StepRects[$row] = $realRect

    $table.Rows[$row].Cells[0].Value = $index
    $table.Rows[$row].Cells[1].Value = $bestText
    $table.Rows[$row].Cells[6].Value = "View"
    $table.Rows[$row].Cells[7].Value = "C"
    $table.Rows[$row].Cells[8].Value = $false
    $table.Rows[$row].Cells[2].Value = Format-InvariantSignedTolerance $tolMinus
    $table.Rows[$row].Cells[3].Value = Format-InvariantSignedTolerance $tolPlus
    $table.ClearSelection()
    $table.Rows[$row].Selected = $true
    $table.CurrentCell = $table.Rows[$row].Cells[0]
    $table.FirstDisplayedScrollingRowIndex = $row
    Add-OrUpdate-MarkStepTextZone $row $index $realRect $bestText $bestRawText $tolMinus $tolPlus | Out-Null
    $table.FirstDisplayedScrollingRowIndex = $row

    $script:selectionRect = $null
    Clear-PreviewImage
    Clear-AiVisionResult

    $markScale = Get-CurrentPageBalloonScale
    $pos = Find-BalloonPositionNextToRect $realRect $img.Width $img.Height $markScale 0 1

    $mark = [PSCustomObject]@{
        Index = $index
        X = $pos.X
        Y = $pos.Y
        Scale = $markScale
    }

    $script:marks += $mark
    Save-CurrentPageState
    Refresh-DuplicateState
    Apply-TableSearchFilter
    Request-CanvasRedraw
    Queue-SessionStateSave
    Register-TrainingSignal "manual_red_crop" @{
        Nominal = [string]$bestText
        Raw = [string]$bestRawText
        Width = [int]$realRect.Width
        Height = [int]$realRect.Height
        Rect = $realRect
    }
    Register-DetectorAnnotationSilent "positive" $realRect ([ordered]@{
        Source = [string]$manualCandidate.Source
        Label = [string]$bestText
        Raw = [string]$bestRawText
        Origin = "manual_red_crop"
    })
    return $true
}

function Invoke-AiVisionForSelection{
    param([switch]$ForceExperiment)

    if($script:AiVisionBusy){ return }
    if(!$script:sourceBitmap -or !$script:selectionRect){ return }

    $selectedModel = if($cmbAiModel){ [string]$cmbAiModel.Text } else { "" }
    if([string]::IsNullOrWhiteSpace($selectedModel)){
        if($txtAiResult){ $txtAiResult.Text = "Choose an AI vision model first." }
        return
    }
    if(
        -not $selectedModel.StartsWith("ollama:",[System.StringComparison]::OrdinalIgnoreCase) -and
        -not $selectedModel.StartsWith("gemini:",[System.StringComparison]::OrdinalIgnoreCase)
    ){
        if($txtAiResult){ $txtAiResult.Text = "Only ollama:* and gemini:* models are enabled in this build." }
        return
    }

    $realRect = Convert-ToImageRect $script:selectionRect
    if(
        $realRect.X -lt 0 -or
        $realRect.Y -lt 0 -or
        $realRect.Right -gt $script:sourceBitmap.Width -or
        $realRect.Bottom -gt $script:sourceBitmap.Height -or
        $realRect.Width -le 2 -or
        $realRect.Height -le 2
    ){
        return
    }

    $script:AiVisionBusy = $true
    if($btnAiTest){ $btnAiTest.Enabled = $false }
    if($btnAiAccept){ $btnAiAccept.Enabled = $false }
    Append-AiVisionLog ("Running " + $selectedModel)
    try{
        $visionReview = Invoke-AiVisionFromSelectionRect $selectedModel $realRect -ForceExperiment:$ForceExperiment
        $rawText = [string]$visionReview.RawText
        $candidate = New-ManualSelectionCandidate $realRect $rawText $rawText ("AiVision:" + $selectedModel)
        $script:AiVisionResult = [PSCustomObject]@{
            Model = [string]$selectedModel
            RawText = [string]$rawText
            CropPath = $null
            Candidate = $candidate
        }
        Append-AiVisionLog ("Raw: " + [string]$rawText)
        Append-AiVisionLog ("Resolved: " + [string]$candidate.Nominal)
        if($txtOcrDebug){
            $txtOcrDebug.Text = (
                'AI Model: ' + [string]$selectedModel + [Environment]::NewLine +
                'AI Raw: ' + [string]$rawText + [Environment]::NewLine +
                'AI Resolved: ' + [string]$candidate.Nominal
            )
        }
        if($txtAiResult){ $txtAiResult.Text = [string]$rawText }
        if($btnAiAccept){ $btnAiAccept.Enabled = $true }
    }
    catch{
        Clear-AiVisionResult
        Append-AiVisionLog ("AI test failed: " + $_.Exception.Message)
    }
    finally{
        $script:AiVisionBusy = $false
        if($btnAiTest){ $btnAiTest.Enabled = $true }
    }
}

function Accept-AiVisionResult{

    if(!$script:AiVisionResult -or !$script:AiVisionResult.Candidate){ return }
    Append-AiVisionLog ("Accepting result from " + [string]$script:AiVisionResult.Model)
    [void](Commit-ManualSelectionCandidate $script:AiVisionResult.Candidate)
}

function Invoke-SelectedOcr{

    if(!$script:sourceBitmap){ return }
    if(!$script:selectionRect){ return }
    if($script:AiTestOnlyEnabled){
        Invoke-AiVisionForSelection
        return
    }

    $img = $script:sourceBitmap
    $realRect = Convert-ToImageRect $script:selectionRect

    if(
        $realRect.X -lt 0 -or
        $realRect.Y -lt 0 -or
        $realRect.Right -gt $img.Width -or
        $realRect.Bottom -gt $img.Height -or
        $realRect.Width -le 2 -or
        $realRect.Height -le 2
    ){
        return
    }

    $crop = $img.Clone($realRect,$img.PixelFormat)

    # Manual red-crop hot path: keep scale moderate. Scale 10 is accurate but
    # expensive; scale 4 is much faster and sufficient for user-selected crops.
    $scale = 4
    $big = New-Object Drawing.Bitmap ($crop.Width*$scale),($crop.Height*$scale)

    $g=[Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode="HighQualityBicubic"
    $g.DrawImage($crop,0,0,$big.Width,$big.Height)
    $g.Dispose()
    $crop.Dispose()

    $bestText=""
    $bestRawText=""
    $bestScore=[double]::NegativeInfinity

    $manualAngles = if($realRect.Height -gt ($realRect.Width * 1.25)){ @(0,90,270) } else { @(0) }
    foreach($a in $manualAngles){

        if($a -eq 0){
            $test=$big
        }
        else{
            $test=Rotate-Bitmap $big $a
        }

        $ocrBitmaps = @(@{ Bitmap = $test; Label = "raw" })
        $preparedBitmap = Prepare-FastOcrCropBitmap $test
        if($preparedBitmap -is [System.Drawing.Bitmap]){ $ocrBitmaps += @{ Bitmap = $preparedBitmap; Label = "clean-line" } }

        foreach($ocrCandidate in $ocrBitmaps){
            $text = Run-FastOcr $ocrCandidate.Bitmap
            $score = ($text -replace '[^0-9\.\+\-\±°º''"()]','').Length
            if($text -match '[±]|[+\-]\s*0?\.\d+'){ $score += 8 }
            if($text -match '\d+\.\d+'){ $score += 5 }
            if($ocrCandidate.Label -eq "clean-line" -and $text -match '\d+\.\d+'){ $score += 2 }

            if($score -gt $bestScore){
                $bestScore = [double]$score
                $bestRawText = $text
                $bestText = $text
            }
        }

        if($preparedBitmap -is [System.IDisposable]){ $preparedBitmap.Dispose() }

        if($a -ne 0){
            $test.Dispose()
        }

        if($bestScore -ge 18){ break }
    }

    $manualCandidate = New-ManualSelectionCandidate $realRect $bestText $bestRawText "ManualRedCrop"
    $cleanedBestText = [string]$manualCandidate.CleanedText
    $mechanicalBestText = [string]$manualCandidate.LabelText
    $parsedBestText = [string]$manualCandidate.ParsedText
    $bestText = [string]$manualCandidate.Nominal
    $txtOcrDebug.Text = (
        'Raw: ' + [string]$bestRawText + [Environment]::NewLine +
        'Clean: ' + [string]$cleanedBestText + [Environment]::NewLine +
        'Mechanical: ' + [string]$mechanicalBestText + [Environment]::NewLine +
        'Parsed: ' + [string]$parsedBestText + [Environment]::NewLine +
        'Resolved: ' + [string]$bestText + [Environment]::NewLine + 'Mode: Fast red crop / RapidOCR / scale 4'
    )

    $big.Dispose()
    [void](Commit-ManualSelectionCandidate $manualCandidate)
}
# =========================
# Save image
# =========================
$btnSave.Add_Click({

    if($script:DocumentPages.Count -eq 0){ return }
    if($script:IsExportInProgress){ return }

    $jobInfo = Get-ExportJobInfo
    if(!$jobInfo){ return }
    $pdfPath = Join-Path $jobInfo.JobFolder ("MarkStep " + $jobInfo.JobName + ".pdf")
    $importantPdfPath = Get-ImportantMarkedPdfPath $jobInfo.JobFolder $jobInfo.JobName
    $savedPdfPath = $null
    $savedImportantPdfPath = $null

    $script:IsExportInProgress = $true
    $btnSave.Enabled = $false
    $btnExcel.Enabled = $false

    try{
        Save-SessionState
        $savedPdfPath = Export-MarkedDocumentPdf $pdfPath
        if([string]::IsNullOrWhiteSpace([string]$savedPdfPath) -or !(Test-Path -LiteralPath $savedPdfPath)){
            throw "PDF export finished without creating the output file."
        }
        $savedImportantPdfPath = Export-MarkedDocumentPdf $importantPdfPath $true
        if([string]::IsNullOrWhiteSpace([string]$savedImportantPdfPath) -or !(Test-Path -LiteralPath $savedImportantPdfPath)){
            throw "Important PDF export finished without creating the output file."
        }
        [void](Try-QueueBackgroundTrainingFlush)
    }
    catch{
        [System.Windows.Forms.MessageBox]::Show("Save PDF failed: $($_.Exception.Message)")
    }
    finally{
        $script:IsExportInProgress = $false
        $btnSave.Enabled = $true
        $btnExcel.Enabled = $true
    }

})
# =========================
# export exel
# =========================
$btnExcel.Add_Click({

    if($script:IsExportInProgress){ return }

    if(!$script:ExcelTemplate){
        [System.Windows.Forms.MessageBox]::Show("Please select Excel template first.")
        return
    }

    $jobInfo = Get-ExportJobInfo
    if(!$jobInfo){ return }

    $jobName = [string]$jobInfo.JobName
    $jobFolder = [string]$jobInfo.JobFolder
    $pdfPath = Join-Path $jobFolder ("MarkStep " + $jobName + ".pdf")
    $importantPdfPath = Get-ImportantMarkedPdfPath $jobFolder $jobName
    $savedPdfPath = $null
    $savedImportantPdfPath = $null
    $model = if(-not [string]::IsNullOrWhiteSpace([string]$script:PartNo)){ [string]$script:PartNo } else { $jobName }
    $mold = [string]$script:MoldName
    $qty = [string]$script:PartQuantity
    $material = [string]$script:PartMaterial
    $hrc = [string]$script:PartHrc
    $user = if([string]::IsNullOrWhiteSpace([string]$script:PartUser)){ "7139" } else { [string]$script:PartUser }
    $sampleBatches = @(Get-InspectionSampleBatches $qty)
    $savedExcelPaths = New-Object System.Collections.Generic.List[string]
    $hasImportantSteps = Test-AnyImportantInspectionSteps

    $excel = $null
    $wb = $null
    $templateSheet = $null
    $ws = $null
    $saveSucceeded = $false
    $originalAutomationSecurity = $null
    $originalEnableEvents = $null
    $pdfExportWarning = $null
    $successMessage = $null
    $exportStage = "Initialize"
    $script:IsExportInProgress = $true
    $script:IsInspectionExportGeneratingSamples = $true
    $btnSave.Enabled = $false
    $btnExcel.Enabled = $false

    try{
        $exportStage = "Save session"
        if($script:CurrentSourcePath){
            [void](Ensure-CanonicalSessionFileForSource $script:CurrentSourcePath $null -PreferCurrentState)
        }
        Save-SessionState

        $exportStage = "Start Excel"
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $originalAutomationSecurity = $excel.AutomationSecurity
        $originalEnableEvents = $excel.EnableEvents
        $excel.AutomationSecurity = 3
        $excel.EnableEvents = $false
        $excel.DisplayAlerts = $false

        $maxPerPage = 40
        $rowStart = 14
        $exportRows = @(Get-AllInspectionRows)

        foreach($sampleBatch in $sampleBatches){
            $batchStart = [int]$sampleBatch.Start
            $batchEnd = [int]$sampleBatch.End
            $batchSuffix = if($sampleBatches.Count -gt 1){ " Sample $batchStart-$batchEnd" } else { "" }
            $requestedExcelPath = Join-Path $jobFolder ("Inspection " + $jobName + $batchSuffix + [System.IO.Path]::GetExtension($script:ExcelTemplate))
            $saveInfo = Get-ExcelSaveInfo $requestedExcelPath $script:ExcelTemplate
            $excelPath = [string]$saveInfo.Path
            $excelFormat = [int]$saveInfo.Format

            $exportStage = "Open template"
            $wb = $excel.Workbooks.Open([string]$script:ExcelTemplate)
            $ws = $wb.Worksheets.Item([int]1)

            $exportStage = "Prepare sheet"
            Clear-InspectionSheet $ws $rowStart $maxPerPage
            Set-InspectionHeader $ws $model $mold $qty $material $hrc $user
            Set-InspectionSampleHeaders $ws $batchStart $batchEnd
            $initialEnd = if($exportRows.Count -gt 0){ [Math]::Min($maxPerPage,$exportRows.Count) } else { 1 }
            $ws.Name = [string](Get-InspectionSheetName 1 $initialEnd)

            $page = 1
            $count = 0
            $row = $rowStart

            foreach($rowData in $exportRows){

                if($count -ge $maxPerPage){
                    $page++

                    $exportStage = "Copy sheet"
                    $ws.Copy($wb.Worksheets.Item([int]$wb.Worksheets.Count))
                    if($ws){
                        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($ws) | Out-Null
                        $ws = $null
                    }

                    $ws = $wb.Worksheets.Item([int]$wb.Worksheets.Count)
                    $exportStage = "Prepare copied sheet"
                    Clear-InspectionSheet $ws $rowStart $maxPerPage
                    Set-InspectionHeader $ws $model $mold $qty $material $hrc $user
                    Set-InspectionSampleHeaders $ws $batchStart $batchEnd

                    $pageStartIndex = (($page - 1) * $maxPerPage) + 1
                    $pageEndIndex = [Math]::Min($page * $maxPerPage,$exportRows.Count)
                    $ws.Name = [string](Get-InspectionSheetName $pageStartIndex $pageEndIndex)

                    $row = $rowStart
                    $count = 0
                }

                $exportStage = "Write rows"
                Set-ExcelCellTextValue $ws $row 1 ([string]$rowData.Step)
                Set-ExcelCellTextValue $ws $row 2 ([string]$rowData.Nominal)
                Set-ExcelCellBold $ws $row 2 (Convert-ToStepImportantFlag $rowData.ImportantStep)
                Set-ExcelCellTextValue $ws $row 3 ([string]$rowData.TolMinus)
                Set-ExcelCellTextValue $ws $row 4 ([string]$rowData.TolPlus)
                Set-ExcelCellTextValue $ws $row 5 (Get-ExportToolCode $rowData)
                Write-InspectionSampleResults $ws $row $rowData $batchStart $batchEnd

                $row++
                $count++
            }

            $exportStage = "Save workbook"
            $wb.SaveAs($excelPath,$excelFormat)
            if(!(Test-Path -LiteralPath $excelPath)){
                throw "Excel export finished without creating the output file."
            }
            [void]$savedExcelPaths.Add($excelPath)
            $saveSucceeded = $true

            $exportStage = "Close workbook"
            $wb.Close($true)
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($ws) | Out-Null
            $ws = $null
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null
            $wb = $null
        }

        if($script:DocumentPages.Count -gt 0){
            try{
                $exportStage = "Export PDF"
                $savedPdfPath = Export-MarkedDocumentPdf $pdfPath $false $script:PdfExportJpegQualityFast
                if([string]::IsNullOrWhiteSpace([string]$savedPdfPath) -or !(Test-Path -LiteralPath $savedPdfPath)){
                    throw "PDF export finished without creating the output file."
                }
                if($hasImportantSteps){
                    $savedImportantPdfPath = Export-MarkedDocumentPdf $importantPdfPath $true $script:PdfExportJpegQualityFast
                    if([string]::IsNullOrWhiteSpace([string]$savedImportantPdfPath) -or !(Test-Path -LiteralPath $savedImportantPdfPath)){
                        throw "Important PDF export finished without creating the output file."
                    }
                }
            }
            catch{
                $pdfExportWarning = "Excel file exported, but PDF export failed: $($_.Exception.Message)"
            }
        }

        $exportStage = "Build success message"
        $successMessage = "Saved Excel:"
        foreach($savedPath in @($savedExcelPaths)){
            $successMessage += "`r`n$savedPath"
        }
        if($savedPdfPath -and (Test-Path -LiteralPath $savedPdfPath)){
            $successMessage += "`r`n`r`nSaved PDF:`r`n$savedPdfPath"
            if($savedImportantPdfPath -and (Test-Path -LiteralPath $savedImportantPdfPath)){
                $successMessage += "`r`n$savedImportantPdfPath"
            }
        }

        $exportStage = "Queue background training"
        [void](Try-QueueBackgroundTrainingFlush)

        $exportStage = "Done"

    }
    catch{
        [System.Windows.Forms.MessageBox]::Show("Export failed at " + $exportStage + ": " + $_.Exception.Message)
    }
    finally{
        $script:IsInspectionExportGeneratingSamples = $false
        if($excel){
            if($originalEnableEvents -ne $null){
                $excel.EnableEvents = $originalEnableEvents
            }

            if($originalAutomationSecurity -ne $null){
                $excel.AutomationSecurity = $originalAutomationSecurity
            }
        }

        if($wb){
            $wb.Close($saveSucceeded)
        }

        if($excel){
            $excel.Quit()
        }

        if($ws){
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($ws) | Out-Null
        }

        if($templateSheet){
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($templateSheet) | Out-Null
        }

        if($wb){
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wb) | Out-Null
        }

        if($excel){
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
        }

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $script:IsExportInProgress = $false
        $btnSave.Enabled = $true
        $btnExcel.Enabled = $true

        if($pdfExportWarning){
            [System.Windows.Forms.MessageBox]::Show($pdfExportWarning)
        }
        elseif($saveSucceeded -and $successMessage){
            [System.Windows.Forms.MessageBox]::Show($successMessage,"Export Complete",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    }

})
# =========================
# chooose template
# =========================
$btnTemplate.Add_Click({

    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = "Excel Files|*.xlsx;*.xlsm;*.xls;*.xlsb;*.xltx;*.xltm;*.xlt|Excel Template and Workbook|*.xlsx;*.xlsm;*.xls;*.xlsb;*.xltx;*.xltm;*.xlt"

    if($dialog.ShowDialog() -ne "OK"){ return }

    $script:ExcelTemplate = $dialog.FileName
    Save-SessionState

})

Update-StartupSplashStatus "Restoring session..."
Restore-SessionState

Update-StartupSplashStatus "Skipping startup AI warmup..."

Update-StartupSplashStatus "Finalizing..."
Initialize-TrayBehavior
Update-JudgeOkMenuItem
Update-AnnotationToolButtons
Set-AiVisionModelSelection ([string]$cmbAiModel.Text)

$form.Enabled = $false
$form.Opacity = 0.01
$script:StartupReadyTimer = New-Object System.Windows.Forms.Timer
$script:StartupReadyTimer.Interval = 1400
$script:StartupReadyTimer.Add_Tick({
    $script:StartupReadyTimer.Stop()
    $script:StartupUiReady = $true
    Update-UiLayout
    Update-TrainingReadinessUi
    Update-CopyViewButton
    Update-PdfTextZonesButton
    Update-TranslateLensButton
    Update-ZoomStatus
    Update-CanvasCursor
    try{ [System.Windows.Forms.Application]::DoEvents() } catch{}
    $form.Opacity = 1.0
    $form.Enabled = $true
    try{ $form.Activate() } catch{}
    Close-ExternalStartupSplash
    Close-StartupSplash
})

[System.Windows.Forms.Application]::Run($form)








function Get-TrainingMetricsDefault{
    return [PSCustomObject]@{
        Version = 1
        CreatedAt = [DateTime]::UtcNow
        UpdatedAt = [DateTime]::UtcNow
        SignalCounts = [ordered]@{
            nominal_edit = 0
            tolerance_edit = 0
            tool_edit = 0
            result_edit = 0
            tolerance_apply = 0
            nominal_decoration = 0
            duplicate_keep_new = 0
            manual_red_crop = 0
            auto_candidate_accept = 0
            auto_candidate_accept_pdf = 0
            auto_candidate_accept_image = 0
            auto_candidate_accept_textzone = 0
            hard_negative = 0
        }
        LastSignals = [ordered]@{}
    }
}

if(-not $script:PendingTrainingEventRecords){
    $script:PendingTrainingEventRecords = New-Object System.Collections.Generic.List[object]
}
if(-not $script:PendingDetectorAnnotationRecords){
    $script:PendingDetectorAnnotationRecords = New-Object System.Collections.Generic.List[object]
}
if($null -eq $script:IsDeferredTrainingFlushQueued){
    $script:IsDeferredTrainingFlushQueued = $false
}
if($null -eq $script:TrainingManifestExportIntervalSeconds){
    $script:TrainingManifestExportIntervalSeconds = 180
}
if($null -eq $script:TrainingMetricsSaveIntervalSeconds){
    $script:TrainingMetricsSaveIntervalSeconds = 30
}
if($null -eq $script:TrainingManifestDirty){
    $script:TrainingManifestDirty = $false
}
if($null -eq $script:TrainingMetricsDirty){
    $script:TrainingMetricsDirty = $false
}

function Get-TrainingRecordCount($records){
    if($null -eq $records){ return 0 }
    try{
        if($records -is [System.Collections.ICollection]){
            return [int]$records.Count
        }
        if($records.PSObject.Properties.Name -contains "Count"){
            return [int]$records.Count
        }
    }
    catch{}
    return [int](@($records).Count)
}

function Ensure-TrainingDatasetStore{
    if(-not (Test-Path -LiteralPath $script:TrainingDatasetRoot)){
        [void][System.IO.Directory]::CreateDirectory($script:TrainingDatasetRoot)
    }
    foreach($childName in @("crops","crops\\manual","crops\\duplicate","crops\\auto","crops\\edit","crops\\negative","crops\\misc")){
        $childPath = Join-Path $script:TrainingDatasetRoot $childName
        if(-not (Test-Path -LiteralPath $childPath)){
            [void][System.IO.Directory]::CreateDirectory($childPath)
        }
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$script:DetectorDatasetRoot)){
        foreach($childName in @("","images","labels")){
            $childPath = if([string]::IsNullOrWhiteSpace($childName)){ $script:DetectorDatasetRoot } else { Join-Path $script:DetectorDatasetRoot $childName }
            if(-not (Test-Path -LiteralPath $childPath)){
                [void][System.IO.Directory]::CreateDirectory($childPath)
            }
        }
    }
}

function Get-TrainingEventValue($details,$name){
    if(-not $details){ return $null }
    if($details -is [System.Collections.IDictionary]){
        if($details.Contains($name)){ return $details[$name] }
        return $null
    }
    if($details.PSObject.Properties.Name -contains $name){
        return $details.$name
    }
    return $null
}

function Remove-TrainingEventValue($details,$name){
    if(-not $details){ return }
    if($details -is [System.Collections.IDictionary]){
        if($details.Contains($name)){ [void]$details.Remove($name) }
        return
    }
    if($details.PSObject.Properties.Name -contains $name){
        $details.PSObject.Properties.Remove($name)
    }
}

function Get-TrainingCaptureBucket($signalType){
    switch([string]$signalType){
        "manual_red_crop" { return "manual" }
        "duplicate_keep_new" { return "duplicate" }
        "auto_candidate_accept" { return "auto" }
        "hard_negative" { return "negative" }
        "nominal_edit" { return "edit" }
        "tolerance_edit" { return "edit" }
        "tool_edit" { return "edit" }
        "result_edit" { return "edit" }
        default { return "misc" }
    }
}

function Get-TrainingSourceFingerprintSafe{
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){ return "nosource" }
    try{
        $fingerprint = [string](Get-SourceFingerprint $script:CurrentSourcePath)
        if([string]::IsNullOrWhiteSpace($fingerprint)){ return "nosource" }
        return $fingerprint
    }
    catch{
        return "nosource"
    }
}

function New-TrainingSampleId($signalType){
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfff")
    $fingerprint = Get-TrainingSourceFingerprintSafe
    $pageIndex = [Math]::Max(0,[int]$script:SelectedPageIndex)
    return ("{0}_{1}_p{2}_{3}" -f $signalType,$fingerprint,$pageIndex,$stamp)
}

function Get-TrainingImageRelativePath($bucket,$sampleId){
    return ("crops/{0}/{1}.png" -f $bucket,$sampleId)
}

function Save-TrainingRectCrop($rect,$signalType,$sampleId){
    if(-not $rect -or -not $script:sourceBitmap){ return $null }
    $strictRect = Convert-ToImageRect $rect
    if(-not $strictRect -or $strictRect.Width -le 1 -or $strictRect.Height -le 1){ return $null }

    Ensure-TrainingDatasetStore
    $bucket = Get-TrainingCaptureBucket $signalType
    $relativePath = Get-TrainingImageRelativePath $bucket $sampleId
    $fullPath = Join-Path $script:TrainingDatasetRoot ($relativePath -replace '/', '\')
    $crop = $null
    try{
        $crop = $script:sourceBitmap.Clone($strictRect,$script:sourceBitmap.PixelFormat)
        $crop.Save($fullPath,[System.Drawing.Imaging.ImageFormat]::Png)
        return $relativePath
    }
    catch{
        return $null
    }
    finally{
        if($crop){ $crop.Dispose() }
    }
}

function Get-TrainingBitmapForPageIndex($pageIndex){
    $targetIndex = [Math]::Max(0,[int]$pageIndex)
    if($script:DocumentPages -and $targetIndex -lt @($script:DocumentPages).Count){
        $page = $script:DocumentPages[$targetIndex]
        if($page -and $page.PSObject.Properties.Name -contains "Bitmap" -and $page.Bitmap){
            return $page.Bitmap
        }
    }
    if($targetIndex -eq [Math]::Max(0,[int]$script:SelectedPageIndex) -and $script:sourceBitmap){
        return $script:sourceBitmap
    }
    return $null
}

function Save-TrainingRectCropFromQueuedEvent($event){
    if(!$event){ return $null }
    $captureRect = Get-TrainingEventValue $event "__CaptureRect"
    $signalType = [string](Get-TrainingEventValue $event "signal")
    $sampleId = [string](Get-TrainingEventValue $event "SampleId")
    if(!$captureRect -or [string]::IsNullOrWhiteSpace($signalType) -or [string]::IsNullOrWhiteSpace($sampleId)){ return $null }

    $bitmap = Get-TrainingBitmapForPageIndex (Get-TrainingEventValue $event "page")
    if(!$bitmap){ return $null }

    $strictRect = Convert-ToImageRect $captureRect
    if(-not $strictRect -or $strictRect.Width -le 1 -or $strictRect.Height -le 1){ return $null }

    Ensure-TrainingDatasetStore
    $bucket = Get-TrainingCaptureBucket $signalType
    $relativePath = Get-TrainingImageRelativePath $bucket $sampleId
    $fullPath = Join-Path $script:TrainingDatasetRoot ($relativePath -replace '/', '\')
    $crop = $null
    try{
        $crop = $bitmap.Clone($strictRect,$bitmap.PixelFormat)
        $crop.Save($fullPath,[System.Drawing.Imaging.ImageFormat]::Png)
        return $relativePath
    }
    catch{
        return $null
    }
    finally{
        if($crop){ $crop.Dispose() }
    }
}

function Save-DetectorPageImageForPageIndex($pageIndex){
    if([string]::IsNullOrWhiteSpace([string]$script:DetectorDatasetRoot)){ return $null }
    $bitmap = Get-TrainingBitmapForPageIndex $pageIndex
    if(!$bitmap){ return $null }

    Ensure-TrainingDatasetStore
    $fingerprint = Get-TrainingSourceFingerprintSafe
    $normalizedPageIndex = [Math]::Max(0,[int]$pageIndex)
    $pageId = ("{0}_p{1}" -f $fingerprint,$normalizedPageIndex)
    if(-not $script:DetectorPageImageCache){
        $script:DetectorPageImageCache = @{}
    }
    if($script:DetectorPageImageCache.ContainsKey($pageId)){
        return [string]$script:DetectorPageImageCache[$pageId]
    }

    $relativePath = ("images/{0}.png" -f $pageId)
    $fullPath = Join-Path $script:DetectorDatasetRoot ($relativePath -replace '/', '\')
    if(Test-Path -LiteralPath $fullPath){
        $script:DetectorPageImageCache[$pageId] = $relativePath
        return $relativePath
    }

    try{
        $bitmap.Save($fullPath,[System.Drawing.Imaging.ImageFormat]::Png)
        $script:DetectorPageImageCache[$pageId] = $relativePath
        return $relativePath
    }
    catch{
        return $null
    }
}

function Convert-TrainingRectToMetadata($rect){
    if(-not $rect){ return $null }
    return [ordered]@{
        RectX = [int]$rect.X
        RectY = [int]$rect.Y
        RectW = [int]$rect.Width
        RectH = [int]$rect.Height
    }
}

function Get-TrainingRectSignature($rect){
    if(-not $rect){ return "" }
    return ("{0},{1},{2},{3}" -f [int]$rect.X,[int]$rect.Y,[int]$rect.Width,[int]$rect.Height)
}

function Get-TrainingRenderDpi{
    if([string]::IsNullOrWhiteSpace([string]$script:CurrentSourcePath)){ return 0 }
    if(([System.IO.Path]::GetExtension([string]$script:CurrentSourcePath)).ToLowerInvariant() -eq ".pdf"){
        return 300
    }
    return 0
}

function Get-TrainingEventContextMetadata{
    $pageWidth = 0
    $pageHeight = 0
    if($script:sourceBitmap){
        $pageWidth = [int]$script:sourceBitmap.Width
        $pageHeight = [int]$script:sourceBitmap.Height
    }

    return [ordered]@{
        SourcePath = [string]$script:CurrentSourcePath
        SourceFingerprint = [string](Get-TrainingSourceFingerprintSafe)
        PageIndex = [int]([Math]::Max(0,[int]$script:SelectedPageIndex))
        PageWidthPx = $pageWidth
        PageHeightPx = $pageHeight
        RenderDpi = [int](Get-TrainingRenderDpi)
        Rotation = 0
    }
}

function Get-TrainingSymbolType($text){
    $value = ([string]$text).Trim()
    if([string]::IsNullOrWhiteSpace($value)){ return "" }
    if($value -match '±'){ return "PM" }
    if($value -match '\+\+'){ return "PP" }
    if($value -match '--'){ return "MM" }
    if($value -match '[ØΦ⌀]'){ return "DIAMETER" }
    if($value -match '^\s*R'){ return "R" }
    if($value -match '^\s*C'){ return "C" }
    if($value -match '°'){ return "ANGLE" }
    if($value -match '\+'){ return "PLUS" }
    if($value -match '-'){ return "MINUS" }
    return ""
}

function Get-TrainingEngineName($event){
    $sourceName = ""
    if($event.PSObject.Properties.Name -contains "Source"){
        $sourceName = [string]$event.Source
    }
    elseif($event.PSObject.Properties.Name -contains "source"){
        $sourceName = [string]$event.source
    }

    switch -Regex ($sourceName){
        '^PdfTextLayer$' { return "TextLayer" }
        '^RapidOcr' { return "RapidOCR" }
        '^PaddleOcr' { return "PaddleOCR" }
        '^ImageOcrAuto$' { return "WindowsOCR" }
        '^TextZoneLabel$' { return "WindowsOCR" }
        '^ManualRedCrop$' { return "WindowsOCR" }
        default { return $sourceName }
    }
}

function Get-TrainingSignalDedupeKey($signalType,$eventDetails){
    $normalizedSignal = ([string]$signalType).Trim().ToLowerInvariant()
    if($normalizedSignal -ne "auto_candidate_accept"){ return $null }

    $fingerprint = [string](Get-TrainingSourceFingerprintSafe)
    $page = [string](Get-TrainingEventValue $eventDetails "Page")
    if([string]::IsNullOrWhiteSpace($page)){
        $page = [string]([Math]::Max(0,[int]$script:SelectedPageIndex))
    }

    $source = [string](Get-TrainingEventValue $eventDetails "Source")
    $nominal = [string](Get-TrainingEventValue $eventDetails "Nominal")
    $raw = [string](Get-TrainingEventValue $eventDetails "Raw")
    $zoneIndex = [string](Get-TrainingEventValue $eventDetails "ZoneIndex")

    if(-not [string]::IsNullOrWhiteSpace($zoneIndex)){
        return (($normalizedSignal,$fingerprint,$page,$source,("zone:" + $zoneIndex),$nominal,$raw) -join "|").ToUpperInvariant()
    }

    $rectSignature = [string](Get-TrainingEventValue $eventDetails "RectSignature")
    if([string]::IsNullOrWhiteSpace($rectSignature)){
        $rectX = [string](Get-TrainingEventValue $eventDetails "RectX")
        $rectY = [string](Get-TrainingEventValue $eventDetails "RectY")
        $rectW = [string](Get-TrainingEventValue $eventDetails "RectW")
        $rectH = [string](Get-TrainingEventValue $eventDetails "RectH")
        $rectSignature = ("{0},{1},{2},{3}" -f $rectX,$rectY,$rectW,$rectH)
    }

    return (($normalizedSignal,$fingerprint,$page,$source,("rect:" + $rectSignature),$nominal,$raw) -join "|").ToUpperInvariant()
}

function Register-HardNegativeSample($rect,$rawText,$reason,$source,$details = $null){
    if(-not $rect){ return }
    $trimmedRawText = ([string]$rawText).Trim()
    if([string]::IsNullOrWhiteSpace($trimmedRawText)){ return }

    if(-not $script:TrainingHardNegativeCache){
        $script:TrainingHardNegativeCache = @{}
    }

    $dedupeKey = (
        [string](Get-TrainingSourceFingerprintSafe) + "|" +
        [string]([Math]::Max(0,[int]$script:SelectedPageIndex)) + "|" +
        [string](Get-TrainingRectSignature $rect) + "|" +
        [string]$reason + "|" +
        [string]$source + "|" +
        $trimmedRawText.ToUpperInvariant()
    )
    if($script:TrainingHardNegativeCache.ContainsKey($dedupeKey)){ return }
    $script:TrainingHardNegativeCache[$dedupeKey] = $true

    $payload = [ordered]@{
        Rect = $rect
        Raw = $trimmedRawText
        Reason = [string]$reason
        Source = [string]$source
        CaptureImage = $true
    }
    if($details){
        if($details -is [System.Collections.IDictionary]){
            foreach($key in $details.Keys){ $payload[$key] = $details[$key] }
        }
        else{
            foreach($prop in $details.PSObject.Properties){ $payload[$prop.Name] = $prop.Value }
        }
    }

    Register-TrainingSignal "hard_negative" $payload
}

function Load-TrainingMetrics{
    if($script:TrainingMetrics){ return $script:TrainingMetrics }

    $metrics = $null
    if(Test-Path -LiteralPath $script:TrainingMetricsPath){
        $metrics = Import-ClixmlSafe $script:TrainingMetricsPath
    }
    if(-not $metrics){
        $metrics = Get-TrainingMetricsDefault
    }
    elseif(-not ($metrics.PSObject.Properties.Name -contains "SignalCounts") -or -not $metrics.SignalCounts){
        $metrics = Get-TrainingMetricsDefault
    }

    foreach($name in @((Get-TrainingMetricsDefault).SignalCounts.Keys)){
        if(-not $metrics.SignalCounts.Contains($name)){
            $metrics.SignalCounts[$name] = 0
        }
    }
    if(-not ($metrics.PSObject.Properties.Name -contains "LastSignals") -or -not $metrics.LastSignals){
        $metrics | Add-Member -NotePropertyName LastSignals -NotePropertyValue ([ordered]@{}) -Force
    }

    $script:TrainingMetrics = $metrics
    return $script:TrainingMetrics
}

function Save-TrainingMetrics{
    Ensure-TrainingDatasetStore
    if(-not $script:TrainingMetrics){
        $script:TrainingMetrics = Get-TrainingMetricsDefault
    }
    $nowUtc = [DateTime]::UtcNow
    if(
        -not $script:TrainingMetricsDirty -and
        $script:TrainingLastMetricsSaveUtc -is [DateTime] -and
        (($nowUtc - [DateTime]$script:TrainingLastMetricsSaveUtc).TotalSeconds -lt [double]$script:TrainingMetricsSaveIntervalSeconds)
    ){
        return
    }
    $script:TrainingMetrics.UpdatedAt = [DateTime]::UtcNow
    [void](Export-ClixmlSafe $script:TrainingMetricsPath $script:TrainingMetrics)
    $script:TrainingLastMetricsSaveUtc = $nowUtc
    $script:TrainingMetricsDirty = $false
}

function Invoke-TrainingDatasetFlush{
    $flushedTrainingEvents = $false
    if((Get-TrainingRecordCount $script:PendingTrainingEventRecords) -gt 0){
        Ensure-TrainingDatasetStore
        $jsonLines = New-Object System.Collections.Generic.List[string]
        foreach($event in $script:PendingTrainingEventRecords){
            if(!$event){ continue }
            $captureImage = $false
            if($event.PSObject.Properties.Name -contains "CaptureImage"){
                $captureImage = [bool]$event.CaptureImage
            }
            if($captureImage -and $event.PSObject.Properties.Name -contains "__CaptureRect"){
                $imageRelativePath = Save-TrainingRectCropFromQueuedEvent $event
                if($imageRelativePath){
                    if($event.PSObject.Properties.Name -contains "ImagePath"){
                        $event.ImagePath = $imageRelativePath
                    }
                    else{
                        $event | Add-Member -NotePropertyName ImagePath -NotePropertyValue $imageRelativePath -Force
                    }
                }
            }
            $json = "{" + (($event.PSObject.Properties.Name | Where-Object { $_ -notin @("CaptureImage","__CaptureRect") } | ForEach-Object {
                '"' + $_ + '":' + (Convert-TrainingValueToJsonLiteral $event.$_)
            }) -join ",") + "}"
            $jsonLines.Add($json) | Out-Null
        }
        if($jsonLines.Count -gt 0){
            Add-Content -LiteralPath $script:TrainingEventsPath -Value ($jsonLines -join [Environment]::NewLine) -Encoding UTF8
        }
        $script:PendingTrainingEventRecords.Clear()
        $flushedTrainingEvents = ($jsonLines.Count -gt 0)
        if($flushedTrainingEvents){
            $script:TrainingManifestDirty = $true
            $script:TrainingMetricsDirty = $true
        }
    }

    Save-TrainingMetrics

    $nowUtc = [DateTime]::UtcNow
    $shouldExportManifest = $false
    if($script:TrainingLastManifestExportUtc -is [DateTime]){
        $elapsed = ($nowUtc - [DateTime]$script:TrainingLastManifestExportUtc).TotalSeconds
        $shouldExportManifest = (
            $script:TrainingManifestDirty -and
            ($elapsed -ge [double]$script:TrainingManifestExportIntervalSeconds)
        )
    }
    else{
        $shouldExportManifest = [bool]$script:TrainingManifestDirty
    }

    if($shouldExportManifest){
        Export-TrainingDatasetManifest
        $script:TrainingLastManifestExportUtc = $nowUtc
        $script:TrainingManifestDirty = $false
    }

    Update-TrainingReadinessUi
}

if(-not $script:TrainingSignalFlushTimer){
    $script:TrainingSignalFlushTimer = New-Object Windows.Forms.Timer
    $script:TrainingSignalFlushTimer.Interval = 5000
    $script:TrainingSignalFlushTimer.Add_Tick({
        $script:TrainingSignalFlushTimer.Stop()
    })
}

function Queue-TrainingSignalFlush{
    return
}

function Convert-TrainingValueToJsonLiteral($value){
    if($null -eq $value){ return "null" }
    if($value -is [bool]){ return $(if($value){ "true" } else { "false" }) }
    if($value -is [byte] -or $value -is [int16] -or $value -is [int32] -or $value -is [int64] -or $value -is [double] -or $value -is [decimal] -or $value -is [single]){
        return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture,"{0}",$value))
    }
    $text = [string]$value
    $text = $text.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n')
    return '"' + $text + '"'
}

function Append-TrainingEvent($signalType,$details){
    $pairs = [ordered]@{
        ts = ([DateTime]::UtcNow.ToString("o"))
        signal = [string]$signalType
        source = [string]$script:CurrentSourcePath
        page = [int]$script:SelectedPageIndex
    }
    foreach($pair in (Get-TrainingEventContextMetadata).GetEnumerator()){
        $pairs[$pair.Key] = $pair.Value
    }
    if($details){
        foreach($name in $details.Keys){
            $pairs[$name] = $details[$name]
        }
    }
    if(-not $script:PendingTrainingEventRecords){
        $script:PendingTrainingEventRecords = New-Object System.Collections.Generic.List[object]
    }
    $script:PendingTrainingEventRecords.Add([PSCustomObject]$pairs) | Out-Null
}

function Get-DetectorPageSampleId{
    $fingerprint = Get-TrainingSourceFingerprintSafe
    $pageIndex = [Math]::Max(0,[int]$script:SelectedPageIndex)
    return ("{0}_p{1}" -f $fingerprint,$pageIndex)
}

function Save-DetectorPageImageSilent{
    if(-not $script:sourceBitmap){ return $null }
    if([string]::IsNullOrWhiteSpace([string]$script:DetectorDatasetRoot)){ return $null }

    Ensure-TrainingDatasetStore
    $pageId = Get-DetectorPageSampleId
    if(-not $script:DetectorPageImageCache){
        $script:DetectorPageImageCache = @{}
    }
    if($script:DetectorPageImageCache.ContainsKey($pageId)){
        return [string]$script:DetectorPageImageCache[$pageId]
    }
    $relativePath = ("images/{0}.png" -f $pageId)
    $fullPath = Join-Path $script:DetectorDatasetRoot ($relativePath -replace '/', '\')
    if(Test-Path -LiteralPath $fullPath){
        $script:DetectorPageImageCache[$pageId] = $relativePath
        return $relativePath
    }

    try{
        $script:sourceBitmap.Save($fullPath,[System.Drawing.Imaging.ImageFormat]::Png)
        $script:DetectorPageImageCache[$pageId] = $relativePath
        return $relativePath
    }
    catch{
        return $null
    }
}

if(-not $script:DetectorAnnotationFlushTimer){
    $script:DetectorAnnotationFlushTimer = New-Object Windows.Forms.Timer
    $script:DetectorAnnotationFlushTimer.Interval = 700
    $script:DetectorAnnotationFlushTimer.Add_Tick({
        $script:DetectorAnnotationFlushTimer.Stop()
    })
}

function Queue-DetectorAnnotationJson($jsonLine){
    return
}

function Flush-DetectorAnnotations{
    $pendingRecords = $script:PendingDetectorAnnotationRecords
    if((Get-TrainingRecordCount $pendingRecords) -le 0){ return }
    if([string]::IsNullOrWhiteSpace([string]$script:DetectorAnnotationsPath)){ return }

    Ensure-TrainingDatasetStore
    $jsonLines = New-Object System.Collections.Generic.List[string]
    foreach($record in $pendingRecords){
        if(!$record){ continue }
        $pageImage = Save-DetectorPageImageForPageIndex (Get-TrainingEventValue $record "page_index")
        if($record.PSObject.Properties.Name -contains "page_image"){
            $record.page_image = if($pageImage){ $pageImage } else { "" }
        }
        $json = "{" + (($record.PSObject.Properties.Name | Where-Object { $_ -notlike '__*' } | ForEach-Object {
            '"' + $_ + '":' + (Convert-TrainingValueToJsonLiteral $record.$_)
        }) -join ",") + "}"
        $jsonLines.Add($json) | Out-Null
    }
    $payload = ($jsonLines -join [Environment]::NewLine)
    if(-not [string]::IsNullOrWhiteSpace($payload)){
        Add-Content -LiteralPath $script:DetectorAnnotationsPath -Value $payload -Encoding UTF8
    }

    if($script:PendingDetectorAnnotationRecords){
        $script:PendingDetectorAnnotationRecords.Clear()
    }
}

if(-not $script:DeferredTrainingFlushTimer){
    $script:DeferredTrainingFlushTimer = New-Object Windows.Forms.Timer
    $script:DeferredTrainingFlushTimer.Interval = 3000
    $script:DeferredTrainingFlushTimer.Add_Tick({
        $script:DeferredTrainingFlushTimer.Stop()
        $script:IsDeferredTrainingFlushQueued = $false
        try{
            if($txtOcrDebug){
                $txtOcrDebug.Text = "Export completed. Saving training data in background..."
                [System.Windows.Forms.Application]::DoEvents()
            }
            Flush-DetectorAnnotations
            Invoke-TrainingDatasetFlush
            if($txtOcrDebug){
                $txtOcrDebug.Text += [Environment]::NewLine + "Background training save done."
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        catch{
            if($txtOcrDebug){
                $txtOcrDebug.Text += [Environment]::NewLine + ("Background training save failed: " + $_.Exception.Message)
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    })
}

function Queue-DeferredTrainingDatasetFlush{
    if($script:IsDeferredTrainingFlushQueued){ return }
    if(
        ((Get-TrainingRecordCount $script:PendingDetectorAnnotationRecords) -le 0) -and
        ((Get-TrainingRecordCount $script:PendingTrainingEventRecords) -le 0)
    ){
        return
    }
    $script:IsDeferredTrainingFlushQueued = $true
    $script:DeferredTrainingFlushTimer.Stop()
    $script:DeferredTrainingFlushTimer.Start()
}

function Register-DetectorAnnotationSilent($kind,$rect,$details = $null){
    if(-not $rect -or -not $script:sourceBitmap){ return }
    if([string]::IsNullOrWhiteSpace([string]$script:DetectorAnnotationsPath)){ return }

    $strictRect = Convert-ToImageRect $rect
    if(-not $strictRect -or $strictRect.Width -le 1 -or $strictRect.Height -le 1){ return }

    if(-not $script:DetectorAnnotationCache){
        $script:DetectorAnnotationCache = @{}
    }

    $pageId = Get-DetectorPageSampleId
    $dedupeKey = (
        [string]$pageId + "|" +
        [string]$kind + "|" +
        [string](Get-TrainingRectSignature $strictRect)
    )
    if($details){
        $label = [string](Get-TrainingEventValue $details "Label")
        $raw = [string](Get-TrainingEventValue $details "Raw")
        $dedupeKey += "|" + $label.ToUpperInvariant() + "|" + $raw.ToUpperInvariant()
    }
    if($script:DetectorAnnotationCache.ContainsKey($dedupeKey)){ return }
    $script:DetectorAnnotationCache[$dedupeKey] = $true

    $pairs = [ordered]@{
        ts = ([DateTime]::UtcNow.ToString("o"))
        page_id = $pageId
        page_image = ""
        source = [string]$script:CurrentSourcePath
        source_path = [string]$script:CurrentSourcePath
        source_fingerprint = [string](Get-TrainingSourceFingerprintSafe)
        page = [int]$script:SelectedPageIndex
        page_index = [int]([Math]::Max(0,[int]$script:SelectedPageIndex))
        kind = [string]$kind
        class = "dimension_text"
        rect_x = [int]$strictRect.X
        rect_y = [int]$strictRect.Y
        rect_w = [int]$strictRect.Width
        rect_h = [int]$strictRect.Height
        image_w = [int]$script:sourceBitmap.Width
        image_h = [int]$script:sourceBitmap.Height
        render_dpi = [int](Get-TrainingRenderDpi)
        rotation = 0
    }
    if($details){
        if($details -is [System.Collections.IDictionary]){
            foreach($key in $details.Keys){ $pairs[$key] = $details[$key] }
        }
        else{
            foreach($prop in $details.PSObject.Properties){ $pairs[$prop.Name] = $prop.Value }
        }
    }
    if(-not $script:PendingDetectorAnnotationRecords){
        $script:PendingDetectorAnnotationRecords = New-Object System.Collections.Generic.List[object]
    }
    $script:PendingDetectorAnnotationRecords.Add([PSCustomObject]$pairs) | Out-Null
}

function Convert-TrainingCsvValue($value){
    if($null -eq $value){ return "" }
    $text = [string]$value
    $text = $text.Replace('"','""')
    return '"' + $text + '"'
}

function Get-TrainingManifestRecord($event){
    if(-not $event){ return $null }

    $signal = [string]$event.signal
    $labelText = ""
    if($signal -eq "hard_negative"){
        $labelText = ""
    }
    elseif($event.PSObject.Properties.Name -contains "After" -and -not [string]::IsNullOrWhiteSpace([string]$event.After)){
        $labelText = [string]$event.After
    }
    elseif($event.PSObject.Properties.Name -contains "Nominal" -and -not [string]::IsNullOrWhiteSpace([string]$event.Nominal)){
        $labelText = [string]$event.Nominal
    }
    elseif($event.PSObject.Properties.Name -contains "Raw" -and -not [string]::IsNullOrWhiteSpace([string]$event.Raw)){
        $labelText = [string]$event.Raw
    }

    $isPositive = ($signal -ne "hard_negative")
    $nominal = if($event.PSObject.Properties.Name -contains "Nominal"){ [string]$event.Nominal } else { "" }
    $correctedText = if($event.PSObject.Properties.Name -contains "After"){ [string]$event.After } elseif(-not [string]::IsNullOrWhiteSpace($nominal)){ $nominal } else { $labelText }
    $tolMinus = if($event.PSObject.Properties.Name -contains "TolMinus"){ [string]$event.TolMinus } else { "" }
    $tolPlus = if($event.PSObject.Properties.Name -contains "TolPlus"){ [string]$event.TolPlus } else { "" }
    $pageIndex = if($event.PSObject.Properties.Name -contains "PageIndex"){ [int]$event.PageIndex } elseif($event.PSObject.Properties.Name -contains "page"){ [int]$event.page } else { 0 }
    $symbolSeed = if([string]::IsNullOrWhiteSpace($correctedText)){ $labelText } else { $correctedText }
    $bboxPx = $null
    if(
        ($event.PSObject.Properties.Name -contains "RectX") -and
        ($event.PSObject.Properties.Name -contains "RectY") -and
        ($event.PSObject.Properties.Name -contains "RectW") -and
        ($event.PSObject.Properties.Name -contains "RectH")
    ){
        $bboxPx = [ordered]@{
            x = [int]$event.RectX
            y = [int]$event.RectY
            w = [int]$event.RectW
            h = [int]$event.RectH
        }
    }

    return [ordered]@{
        sample_id = [string]$event.SampleId
        signal = $signal
        is_positive = $isPositive
        label = $labelText
        raw = if($event.PSObject.Properties.Name -contains "Raw"){ [string]$event.Raw } else { "" }
        source = if($event.PSObject.Properties.Name -contains "Source"){ [string]$event.Source } else { [string]$event.source }
        source_path = if($event.PSObject.Properties.Name -contains "SourcePath"){ [string]$event.SourcePath } else { [string]$event.source }
        source_pdf_hash = if($event.PSObject.Properties.Name -contains "SourceFingerprint"){ [string]$event.SourceFingerprint } else { "" }
        page = if($event.PSObject.Properties.Name -contains "page"){ [int]$event.page } else { 0 }
        page_index = $pageIndex
        page_width_px = if($event.PSObject.Properties.Name -contains "PageWidthPx"){ [int]$event.PageWidthPx } else { 0 }
        page_height_px = if($event.PSObject.Properties.Name -contains "PageHeightPx"){ [int]$event.PageHeightPx } else { 0 }
        render_dpi = if($event.PSObject.Properties.Name -contains "RenderDpi"){ [int]$event.RenderDpi } else { 0 }
        rotation = if($event.PSObject.Properties.Name -contains "Rotation"){ [int]$event.Rotation } else { 0 }
        rect_x = if($event.PSObject.Properties.Name -contains "RectX"){ [int]$event.RectX } else { 0 }
        rect_y = if($event.PSObject.Properties.Name -contains "RectY"){ [int]$event.RectY } else { 0 }
        rect_w = if($event.PSObject.Properties.Name -contains "RectW"){ [int]$event.RectW } else { 0 }
        rect_h = if($event.PSObject.Properties.Name -contains "RectH"){ [int]$event.RectH } else { 0 }
        bbox_px = $bboxPx
        bbox_pdf = $null
        image_path = if($event.PSObject.Properties.Name -contains "ImagePath"){ [string]$event.ImagePath } else { "" }
        crop_path = if($event.PSObject.Properties.Name -contains "ImagePath"){ [string]$event.ImagePath } else { "" }
        raw_ocr_text = if($event.PSObject.Properties.Name -contains "Raw"){ [string]$event.Raw } else { "" }
        corrected_text = $correctedText
        nominal = $nominal
        tol_minus = $tolMinus
        tol_plus = $tolPlus
        symbol_type = (Get-TrainingSymbolType $symbolSeed)
        confidence = if($event.PSObject.Properties.Name -contains "StableScore"){ [double]$event.StableScore } else { 0.0 }
        engine = Get-TrainingEngineName $event
        created_at = if($event.PSObject.Properties.Name -contains "ts"){ [string]$event.ts } else { "" }
        reviewed = [bool]($signal -notin @("hard_negative","important_step_toggle","tolerance_apply","nominal_decoration","tool_edit","result_edit"))
        reason = if($event.PSObject.Properties.Name -contains "Reason"){ [string]$event.Reason } else { "" }
        timestamp = if($event.PSObject.Properties.Name -contains "ts"){ [string]$event.ts } else { "" }
    }
}

function Export-TrainingDatasetManifest{
    Ensure-TrainingDatasetStore
    if(-not (Test-Path -LiteralPath $script:TrainingEventsPath)){ return }

    $records = New-Object System.Collections.ArrayList
    foreach($line in @(Get-Content -LiteralPath $script:TrainingEventsPath -ErrorAction SilentlyContinue)){
        $jsonLine = ([string]$line).Trim()
        if([string]::IsNullOrWhiteSpace($jsonLine)){ continue }
        try{
            $event = $jsonLine | ConvertFrom-Json -ErrorAction Stop
            $record = Get-TrainingManifestRecord $event
            if($record){ [void]$records.Add([PSCustomObject]$record) }
        }
        catch{}
    }

    $manifest = [ordered]@{
        version = 1
        exported_at = [DateTime]::UtcNow.ToString("o")
        dataset_root = $script:TrainingDatasetRoot
        sample_count = $records.Count
        positive_count = @($records | Where-Object { $_.is_positive }).Count
        negative_count = @($records | Where-Object { -not $_.is_positive }).Count
        samples = @($records)
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    Write-TextFileSafe $script:TrainingManifestPath $manifestJson

    $csvHeaders = @("sample_id","signal","is_positive","label","raw","source","source_path","source_pdf_hash","page","page_index","page_width_px","page_height_px","render_dpi","rotation","rect_x","rect_y","rect_w","rect_h","image_path","crop_path","raw_ocr_text","corrected_text","nominal","tol_minus","tol_plus","symbol_type","confidence","engine","reviewed","reason","timestamp")
    $csvLines = New-Object System.Collections.Generic.List[string]
    $csvLines.Add(($csvHeaders -join ",")) | Out-Null
    foreach($record in @($records)){
        $line = ($csvHeaders | ForEach-Object { Convert-TrainingCsvValue $record.$_ }) -join ","
        $csvLines.Add($line) | Out-Null
    }
    Write-TextFileSafe $script:TrainingLabelsCsvPath ($csvLines -join [Environment]::NewLine)

    $enrichedJsonlPath = Join-Path $script:TrainingDatasetRoot "training-samples-v2.jsonl"
    $enrichedJsonPath = Join-Path $script:TrainingDatasetRoot "training-samples-v2.json"
    $jsonlLines = New-Object System.Collections.Generic.List[string]
    foreach($record in @($records)){
        $jsonlLines.Add((([PSCustomObject]$record) | ConvertTo-Json -Depth 8 -Compress)) | Out-Null
    }
    Write-TextFileSafe $enrichedJsonlPath ($jsonlLines -join [Environment]::NewLine)
    Write-TextFileSafe $enrichedJsonPath (([ordered]@{
        version = 2
        exported_at = [DateTime]::UtcNow.ToString("o")
        dataset_root = $script:TrainingDatasetRoot
        sample_count = $records.Count
        samples = @($records)
    } | ConvertTo-Json -Depth 8))
}

function Register-TrainingSignal($signalType,$details){
    if([string]::IsNullOrWhiteSpace([string]$signalType)){ return }
    $eventDetails = [ordered]@{}
    if($details){
        if($details -is [System.Collections.IDictionary]){
            foreach($key in $details.Keys){ $eventDetails[$key] = $details[$key] }
        }
        else{
            foreach($prop in $details.PSObject.Properties){ $eventDetails[$prop.Name] = $prop.Value }
        }
    }

    $rect = Get-TrainingEventValue $eventDetails "Rect"
    Remove-TrainingEventValue $eventDetails "Rect"
    if($rect){
        foreach($pair in (Convert-TrainingRectToMetadata $rect).GetEnumerator()){
            $eventDetails[$pair.Key] = $pair.Value
        }
        $eventDetails["RectSignature"] = Get-TrainingRectSignature $rect
    }

    $tolerance = Get-TrainingEventValue $eventDetails "Tolerance"
    Remove-TrainingEventValue $eventDetails "Tolerance"
    if($tolerance){
        $eventDetails["ToleranceDetected"] = [bool](Get-TrainingEventValue $tolerance "Detected")
        $eventDetails["TolMinus"] = [string](Get-TrainingEventValue $tolerance "TolMinus")
        $eventDetails["TolPlus"] = [string](Get-TrainingEventValue $tolerance "TolPlus")
        $eventDetails["ToleranceText"] = [string](Get-TrainingEventValue $tolerance "NormalizedText")
        $eventDetails["ToleranceParseMode"] = [string](Get-TrainingEventValue $tolerance "ParseMode")
    }

    $dedupeKey = Get-TrainingSignalDedupeKey $signalType $eventDetails
    if(-not [string]::IsNullOrWhiteSpace($dedupeKey)){
        if(-not $script:TrainingSignalDedupeCache){
            $script:TrainingSignalDedupeCache = @{}
        }
        if($script:TrainingSignalDedupeCache.ContainsKey($dedupeKey)){
            return
        }
        $script:TrainingSignalDedupeCache[$dedupeKey] = $true
    }
    $captureImageExplicit = $false
    if($eventDetails -is [System.Collections.IDictionary] -and $eventDetails.Contains("CaptureImage")){
        $captureImageExplicit = $true
    }
    $captureImage = Get-TrainingEventValue $eventDetails "CaptureImage"
    Remove-TrainingEventValue $eventDetails "CaptureImage"
    if($null -eq $captureImage){ $captureImage = [bool]$rect }
    if(
        -not $captureImageExplicit -and
        [string]$signalType -in @("auto_candidate_accept","auto_candidate_accept_pdf","auto_candidate_accept_image","auto_candidate_accept_textzone")
    ){
        $captureImage = $false
    }

    $sampleId = New-TrainingSampleId $signalType
    $eventDetails["SampleId"] = $sampleId
    $eventDetails["CaptureImage"] = [bool]$captureImage
    if($captureImage -and $rect){
        $eventDetails["__CaptureRect"] = $rect
    }

    $metrics = Load-TrainingMetrics
    if(-not $metrics.SignalCounts.Contains($signalType)){
        $metrics.SignalCounts[$signalType] = 0
    }
    $metrics.SignalCounts[$signalType] = [int]$metrics.SignalCounts[$signalType] + 1
    $metrics.LastSignals[$signalType] = [DateTime]::UtcNow
    Append-TrainingEvent $signalType $eventDetails
    $script:TrainingMetricsDirty = $true
    $script:TrainingManifestDirty = $true
    Queue-TrainingSignalFlush
}

function Get-TrainingReadinessSnapshot{
    $metrics = Load-TrainingMetrics
    $goals = @(
        @{ Name = "manual_red_crop"; Goal = 120.0; Weight = 0.24 }
        @{ Name = "nominal_edit"; Goal = 240.0; Weight = 0.18 }
        @{ Name = "tolerance_edit"; Goal = 240.0; Weight = 0.18 }
        @{ Name = "result_edit"; Goal = 300.0; Weight = 0.10 }
        @{ Name = "duplicate_keep_new"; Goal = 40.0; Weight = 0.10 }
        @{ Name = "auto_candidate_accept"; Goal = 500.0; Weight = 0.12 }
        @{ Name = "nominal_decoration"; Goal = 120.0; Weight = 0.04 }
        @{ Name = "tolerance_apply"; Goal = 120.0; Weight = 0.04 }
    )

    $weighted = 0.0
    foreach($goal in $goals){
        $count = 0.0
        if($metrics.SignalCounts.Contains($goal.Name)){
            $count = [double]$metrics.SignalCounts[$goal.Name]
        }
        $progress = [Math]::Min(1.0,($count / $goal.Goal))
        $weighted += ($progress * [double]$goal.Weight)
    }

    return [PSCustomObject]@{
        Percent = [Math]::Max(0,[Math]::Min(100,[int][Math]::Round($weighted * 100.0)))
        Manual = [int]$metrics.SignalCounts["manual_red_crop"]
        Nominal = [int]$metrics.SignalCounts["nominal_edit"]
        Tol = [int]$metrics.SignalCounts["tolerance_edit"]
        Result = [int]$metrics.SignalCounts["result_edit"]
        Duplicate = [int]$metrics.SignalCounts["duplicate_keep_new"]
        Auto = [int]$metrics.SignalCounts["auto_candidate_accept"]
        Negative = [int]$metrics.SignalCounts["hard_negative"]
        UpdatedAt = $metrics.UpdatedAt
    }
}

function Get-TrainingReadinessDebugSummary($snapshot){
    $updatedText = "never"
    if($snapshot.UpdatedAt -is [DateTime]){
        $updatedText = ([DateTime]$snapshot.UpdatedAt).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    }

    return @(
        ("Training Ready: {0}%" -f $snapshot.Percent)
        ("Manual Crop: {0}" -f $snapshot.Manual)
        ("Nominal Edit: {0}" -f $snapshot.Nominal)
        ("Tolerance Edit: {0}" -f $snapshot.Tol)
        ("Result Edit: {0}" -f $snapshot.Result)
        ("Duplicate Keep: {0}" -f $snapshot.Duplicate)
        ("Auto Accept: {0}" -f $snapshot.Auto)
        ("Hard Negative: {0}" -f $snapshot.Negative)
        ("Updated: {0}" -f $updatedText)
    ) -join [Environment]::NewLine
}

function Update-TrainingReadinessUi{
    if(-not $grpOcrDebug){ return }
    $snapshot = Get-TrainingReadinessSnapshot
    $grpOcrDebug.Text = ("OCR Debug | Ready {0}%" -f $snapshot.Percent)
    if($txtOcrDebug){
        $summary = Get-TrainingReadinessDebugSummary $snapshot
        $existingText = [string]$txtOcrDebug.Text
        $existingText = [System.Text.RegularExpressions.Regex]::Replace(
            $existingText,
            '^Training Ready:.*?(?:\r?\n){2}',
            '',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        ).TrimStart()

        if([string]::IsNullOrWhiteSpace($existingText)){
            $txtOcrDebug.Text = $summary
        } else {
            $txtOcrDebug.Text = $summary + [Environment]::NewLine + [Environment]::NewLine + $existingText
        }
    }
}

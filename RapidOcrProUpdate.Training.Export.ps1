param(
    [string]$DatasetRoot = (Join-Path $PSScriptRoot "TrainingDataset"),
    [string]$OutputRoot = (Join-Path $PSScriptRoot "PreparedDataset"),
    [double]$ValidationRatio = 0.15
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Ensure-Directory($path){
    if(-not (Test-Path -LiteralPath $path)){
        [void][System.IO.Directory]::CreateDirectory($path)
    }
}

function Convert-CsvValue($value){
    if($null -eq $value){ return "" }
    $text = [string]$value
    $text = $text.Replace('"','""')
    return '"' + $text + '"'
}

function Test-TrueLike($value){
    if($value -is [bool]){ return [bool]$value }
    return (([string]$value).Trim().ToLowerInvariant() -eq "true")
}

function Test-NonNegativeSignal($signal){
    return ([string]$signal).Trim().ToLowerInvariant() -eq "hard_negative"
}

function Test-RecognizerEligibleSignal($signal){
    switch(([string]$signal).Trim().ToLowerInvariant()){
        "manual_red_crop" { return $true }
        "duplicate_keep_new" { return $true }
        "nominal_edit" { return $true }
        "tolerance_edit" { return $true }
        "auto_candidate_accept" { return $true }
        "auto_candidate_accept_pdf" { return $true }
        "auto_candidate_accept_image" { return $true }
        "auto_candidate_accept_textzone" { return $true }
        default { return $false }
    }
}

function Test-RectIsValid($record){
    return (
        ([int]$record.rect_w -gt 1) -and
        ([int]$record.rect_h -gt 1) -and
        ([int]$record.rect_x -ge 0) -and
        ([int]$record.rect_y -ge 0)
    )
}

function Get-NormalizedRelativePath($path){
    $value = ([string]$path).Trim()
    if([string]::IsNullOrWhiteSpace($value)){ return "" }
    return ($value -replace '/','\')
}

function Test-CropExists($datasetRoot,$record){
    $cropPath = Get-NormalizedRelativePath $record.crop_path
    if([string]::IsNullOrWhiteSpace($cropPath)){ return $false }
    return (Test-Path -LiteralPath (Join-Path $datasetRoot $cropPath))
}

function Get-ResolvedLabelText($record){
    foreach($value in @($record.corrected_text,$record.label,$record.nominal,$record.raw_ocr_text,$record.raw)){
        $text = ([string]$value).Trim()
        if(-not [string]::IsNullOrWhiteSpace($text)){ return $text }
    }
    return ""
}

function Get-CleanupDecision($datasetRoot,$record){
    $isPositive = Test-TrueLike $record.is_positive
    $signal = ([string]$record.signal).Trim()
    $labelText = Get-ResolvedLabelText $record
    $hasCrop = Test-CropExists $datasetRoot $record
    $rectValid = Test-RectIsValid $record

    if($isPositive){
        if(-not (Test-RecognizerEligibleSignal $signal)){
            return [PSCustomObject]@{ Keep = $false; Reason = "telemetry_signal" }
        }
        if(-not $hasCrop){
            return [PSCustomObject]@{ Keep = $false; Reason = "missing_crop" }
        }
        if(-not $rectValid){
            return [PSCustomObject]@{ Keep = $false; Reason = "invalid_bbox" }
        }
        if([string]::IsNullOrWhiteSpace($labelText)){
            return [PSCustomObject]@{ Keep = $false; Reason = "empty_label" }
        }
        return [PSCustomObject]@{ Keep = $true; Reason = "recognizer_positive" }
    }

    if(-not (Test-NonNegativeSignal $signal)){
        return [PSCustomObject]@{ Keep = $false; Reason = "unsupported_negative_signal" }
    }
    if(-not $hasCrop){
        return [PSCustomObject]@{ Keep = $false; Reason = "missing_crop" }
    }
    if(-not $rectValid){
        return [PSCustomObject]@{ Keep = $false; Reason = "invalid_bbox" }
    }
    return [PSCustomObject]@{ Keep = $true; Reason = "detector_negative" }
}

function Get-CropContentHash($datasetRoot,$record,$hashCache){
    $cropPath = Get-NormalizedRelativePath $record.crop_path
    if([string]::IsNullOrWhiteSpace($cropPath)){ return "" }
    $fullPath = Join-Path $datasetRoot $cropPath
    if(-not (Test-Path -LiteralPath $fullPath)){ return "" }
    if($hashCache.ContainsKey($fullPath)){ return [string]$hashCache[$fullPath] }
    try{
        $hash = [string](Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        $hashCache[$fullPath] = $hash
        return $hash
    }
    catch{
        return ""
    }
}

function Remove-DuplicatePreparedRecords($datasetRoot,$records){
    $hashCache = @{}
    $seen = @{}
    $deduped = New-Object System.Collections.Generic.List[object]
    $duplicateCount = 0

    foreach($record in @($records)){
        $labelKey = (Get-ResolvedLabelText $record).Trim().ToUpperInvariant()
        $cropHash = Get-CropContentHash $datasetRoot $record $hashCache
        if([string]::IsNullOrWhiteSpace($cropHash)){
            $cropHash = ([string]$record.crop_path).Trim().ToLowerInvariant()
        }
        $dedupeKey = (
            ([string]$record.task).Trim().ToLowerInvariant() + "|" +
            ([string]$record.class).Trim().ToLowerInvariant() + "|" +
            $labelKey + "|" +
            $cropHash
        )
        if($seen.ContainsKey($dedupeKey)){
            $duplicateCount++
            continue
        }
        $seen[$dedupeKey] = $true
        $deduped.Add($record) | Out-Null
    }

    return [PSCustomObject]@{
        Records = @($deduped)
        DuplicateCount = $duplicateCount
    }
}

function Get-MechanicalLabelKind($label){
    $text = ([string]$label).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return "negative" }
    if($text -match '^\s*[ØΦ]'){ return "diameter" }
    if($text -match '^\s*R'){ return "radius" }
    if($text -match '^\s*C'){ return "chamfer" }
    if($text -match '°') {
        if($text -match '''|\"'){ return "angle_dms" }
        return "angle"
    }
    if($text -match '[\+\-±]'){ return "tolerance" }
    return "linear"
}

function Get-StableSplit($sampleId,$validationRatio){
    $id = [string]$sampleId
    if([string]::IsNullOrWhiteSpace($id)){ return "train" }
    $sum = 0
    foreach($ch in $id.ToCharArray()){
        $sum = ($sum + [int][char]$ch) % 10000
    }
    $threshold = [int][Math]::Round([Math]::Max(0.0,[Math]::Min(0.9,$validationRatio)) * 1000.0)
    if(($sum % 1000) -lt $threshold){ return "val" }
    return "train"
}

function New-PreparedRecord($row,$validationRatio){
    $sampleId = [string]$row.sample_id
    $label = [string]$row.label
    $isPositive = $false
    if($row.is_positive -is [bool]){
        $isPositive = [bool]$row.is_positive
    }
    else{
        $isPositive = ([string]$row.is_positive).Trim().ToLowerInvariant() -eq "true"
    }

    return [ordered]@{
        sample_id = $sampleId
        split = Get-StableSplit $sampleId $validationRatio
        task = if($isPositive){ "recognizer" } else { "detector_negative" }
        class = Get-MechanicalLabelKind $label
        is_positive = $isPositive
        label = $label
        raw = [string]$row.raw
        signal = [string]$row.signal
        source = [string]$row.source
        source_path = if($row.PSObject.Properties.Name -contains "source_path"){ [string]$row.source_path } else { "" }
        source_pdf_hash = if($row.PSObject.Properties.Name -contains "source_pdf_hash"){ [string]$row.source_pdf_hash } else { "" }
        page = [int]$row.page
        page_index = if($row.PSObject.Properties.Name -contains "page_index"){ [int]$row.page_index } else { [int]$row.page }
        page_width_px = if($row.PSObject.Properties.Name -contains "page_width_px"){ [int]$row.page_width_px } else { 0 }
        page_height_px = if($row.PSObject.Properties.Name -contains "page_height_px"){ [int]$row.page_height_px } else { 0 }
        render_dpi = if($row.PSObject.Properties.Name -contains "render_dpi"){ [int]$row.render_dpi } else { 0 }
        rotation = if($row.PSObject.Properties.Name -contains "rotation"){ [int]$row.rotation } else { 0 }
        rect_x = [int]$row.rect_x
        rect_y = [int]$row.rect_y
        rect_w = [int]$row.rect_w
        rect_h = [int]$row.rect_h
        image_path = [string]$row.image_path
        crop_path = if($row.PSObject.Properties.Name -contains "crop_path"){ [string]$row.crop_path } else { [string]$row.image_path }
        raw_ocr_text = if($row.PSObject.Properties.Name -contains "raw_ocr_text"){ [string]$row.raw_ocr_text } else { [string]$row.raw }
        corrected_text = if($row.PSObject.Properties.Name -contains "corrected_text"){ [string]$row.corrected_text } else { [string]$row.label }
        nominal = if($row.PSObject.Properties.Name -contains "nominal"){ [string]$row.nominal } else { "" }
        tol_minus = if($row.PSObject.Properties.Name -contains "tol_minus"){ [string]$row.tol_minus } else { "" }
        tol_plus = if($row.PSObject.Properties.Name -contains "tol_plus"){ [string]$row.tol_plus } else { "" }
        symbol_type = if($row.PSObject.Properties.Name -contains "symbol_type"){ [string]$row.symbol_type } else { "" }
        confidence = if($row.PSObject.Properties.Name -contains "confidence"){ [string]$row.confidence } else { "0" }
        engine = if($row.PSObject.Properties.Name -contains "engine"){ [string]$row.engine } else { "" }
        reviewed = if($row.PSObject.Properties.Name -contains "reviewed"){ [string]$row.reviewed } else { "" }
        reason = [string]$row.reason
        timestamp = [string]$row.timestamp
    }
}

function Write-CsvFile($path,$records,$headers){
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($headers -join ",")) | Out-Null
    foreach($record in @($records)){
        $line = ($headers | ForEach-Object { Convert-CsvValue $record.$_ }) -join ","
        $lines.Add($line) | Out-Null
    }
    [System.IO.File]::WriteAllText($path,($lines -join [Environment]::NewLine),[System.Text.Encoding]::UTF8)
}

Ensure-Directory $OutputRoot

$labelsPath = Join-Path $DatasetRoot "labels.csv"
if(-not (Test-Path -LiteralPath $labelsPath)){
    throw "Training labels file not found: $labelsPath"
}

$rows = @(Import-Csv -LiteralPath $labelsPath)
$prepared = @(
    $rows |
    ForEach-Object { [PSCustomObject](New-PreparedRecord $_ $ValidationRatio) }
)

$cleanDecisions = @(
    foreach($record in @($prepared)){
        $decision = Get-CleanupDecision $DatasetRoot $record
        [PSCustomObject]@{
            Record = $record
            Keep = [bool]$decision.Keep
            Reason = [string]$decision.Reason
        }
    }
)

$cleanupReasonCounts = [ordered]@{}
foreach($group in @($cleanDecisions | Group-Object Reason | Sort-Object Name)){
    $cleanupReasonCounts[$group.Name] = [int]$group.Count
}

$keptPrepared = @($cleanDecisions | Where-Object Keep | ForEach-Object { $_.Record })
$dedupeResult = Remove-DuplicatePreparedRecords $DatasetRoot $keptPrepared
$cleanPrepared = @($dedupeResult.Records)

$manifest = [ordered]@{
    version = 1
    exported_at = [DateTime]::UtcNow.ToString("o")
    dataset_root = $DatasetRoot
    output_root = $OutputRoot
    sample_count = $prepared.Count
    train_count = @($prepared | Where-Object { $_.split -eq "train" }).Count
    val_count = @($prepared | Where-Object { $_.split -eq "val" }).Count
    positive_count = @($prepared | Where-Object { $_.is_positive }).Count
    negative_count = @($prepared | Where-Object { -not $_.is_positive }).Count
    class_counts = [ordered]@{}
}

foreach($group in @($prepared | Group-Object class | Sort-Object Name)){
    $manifest.class_counts[$group.Name] = [int]$group.Count
}

$cleanManifest = [ordered]@{
    version = 1
    exported_at = [DateTime]::UtcNow.ToString("o")
    dataset_root = $DatasetRoot
    output_root = $OutputRoot
    sample_count = $cleanPrepared.Count
    train_count = @($cleanPrepared | Where-Object { $_.split -eq "train" }).Count
    val_count = @($cleanPrepared | Where-Object { $_.split -eq "val" }).Count
    positive_count = @($cleanPrepared | Where-Object { $_.is_positive }).Count
    negative_count = @($cleanPrepared | Where-Object { -not $_.is_positive }).Count
    duplicate_rows_removed = [int]$dedupeResult.DuplicateCount
    cleanup_reason_counts = $cleanupReasonCounts
    class_counts = [ordered]@{}
}

foreach($group in @($cleanPrepared | Group-Object class | Sort-Object Name)){
    $cleanManifest.class_counts[$group.Name] = [int]$group.Count
}

$preparedManifestPath = Join-Path $OutputRoot "prepared-manifest.json"
$preparedCsvPath = Join-Path $OutputRoot "prepared-labels.csv"
$recognizerCsvPath = Join-Path $OutputRoot "recognizer-labels.csv"
$detectorNegativeCsvPath = Join-Path $OutputRoot "detector-negatives.csv"
$cleanPreparedManifestPath = Join-Path $OutputRoot "clean-prepared-manifest.json"
$cleanPreparedCsvPath = Join-Path $OutputRoot "clean-prepared-labels.csv"
$cleanRecognizerCsvPath = Join-Path $OutputRoot "clean-recognizer-labels.csv"
$cleanDetectorNegativeCsvPath = Join-Path $OutputRoot "clean-detector-negatives.csv"
$cleanupReportPath = Join-Path $OutputRoot "cleanup-report.json"

[System.IO.File]::WriteAllText($preparedManifestPath,($manifest | ConvertTo-Json -Depth 6),[System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($cleanPreparedManifestPath,($cleanManifest | ConvertTo-Json -Depth 8),[System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($cleanupReportPath,(
    [ordered]@{
        exported_at = [DateTime]::UtcNow.ToString("o")
        total_input_rows = $prepared.Count
        kept_before_dedupe = $keptPrepared.Count
        kept_after_dedupe = $cleanPrepared.Count
        duplicate_rows_removed = [int]$dedupeResult.DuplicateCount
        reason_counts = $cleanupReasonCounts
    } | ConvertTo-Json -Depth 8
),[System.Text.Encoding]::UTF8)

$headers = @("sample_id","split","task","class","is_positive","label","raw","signal","source","source_path","source_pdf_hash","page","page_index","page_width_px","page_height_px","render_dpi","rotation","rect_x","rect_y","rect_w","rect_h","image_path","crop_path","raw_ocr_text","corrected_text","nominal","tol_minus","tol_plus","symbol_type","confidence","engine","reviewed","reason","timestamp")
Write-CsvFile $preparedCsvPath $prepared $headers
Write-CsvFile $recognizerCsvPath (@($prepared | Where-Object { $_.is_positive })) $headers
Write-CsvFile $detectorNegativeCsvPath (@($prepared | Where-Object { -not $_.is_positive })) $headers
Write-CsvFile $cleanPreparedCsvPath $cleanPrepared $headers
Write-CsvFile $cleanRecognizerCsvPath (@($cleanPrepared | Where-Object { $_.is_positive })) $headers
Write-CsvFile $cleanDetectorNegativeCsvPath (@($cleanPrepared | Where-Object { -not $_.is_positive })) $headers

Write-Output ("Prepared dataset exported to: {0}" -f $OutputRoot)
Write-Output ("Samples: {0} | Train: {1} | Val: {2}" -f $manifest.sample_count,$manifest.train_count,$manifest.val_count)
Write-Output ("Clean samples: {0} | Train: {1} | Val: {2}" -f $cleanManifest.sample_count,$cleanManifest.train_count,$cleanManifest.val_count)

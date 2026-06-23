$form = New-Object Windows.Forms.Form
$form.Text = "RapidOCR PDF Scan Tool"
$form.Width = 1800
$form.Height = 900
$form.MinimumSize = New-Object Drawing.Size(1200,700)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.StartPosition = "CenterScreen"
$form.WindowState = "Maximized"
$form.KeyPreview = $true
Enable-DoubleBuffer $form

$uiFont = New-Object System.Drawing.Font("Segoe UI",10)
$uiBoldFont = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$buttonFont = New-Object System.Drawing.Font("Segoe UI",11,[System.Drawing.FontStyle]::Bold)
$groupFont = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$sectionFont = New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)
$tagFont = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)

$script:CommercialLogHistory = New-Object System.Collections.Generic.List[string]
$script:CommercialLastOcrDebugText = ""
$script:CommercialRecentToleranceValue = $null
$script:CommercialRecentToleranceButton = $null
$script:CommercialPresetToggleButton = $null
$script:CommercialToleranceExpanded = $false
$script:CommercialDefaultAngleTolerance = "0.5"
$script:CommercialLayoutRefreshTimer = $null
$script:CommercialAdvanceMenuGrouped = $false
$script:CommercialSidebarExpanded = $true
$script:CommercialSidebarToggleButton = $null
$script:CommercialLayoutBusy = $false
$script:CommercialNumericPresetButtons = @()
$script:CommercialSidebarCurrentWidth = 0
$script:CommercialSidebarTargetWidth = 0
$script:CommercialSidebarAnimationTimer = $null
$script:CommercialUiLanguage = "en"

function Add-CommercialLogEntry([string]$text){
    if([string]::IsNullOrWhiteSpace([string]$text)){ return }
    $normalized = ([string]$text).Trim()
    if($normalized -eq $script:CommercialLastOcrDebugText){ return }
    $script:CommercialLastOcrDebugText = $normalized
    [void]$script:CommercialLogHistory.Add(("[" + [DateTime]::Now.ToString("HH:mm:ss") + "]" + [Environment]::NewLine + $normalized))
    while($script:CommercialLogHistory.Count -gt 200){
        $script:CommercialLogHistory.RemoveAt(0)
    }
}

function Show-CommercialLogHistoryDialog{
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = "Log History"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object Drawing.Size(760,520)
    $dialog.MinimumSize = New-Object Drawing.Size(620,420)

    $txtLog = New-Object Windows.Forms.TextBox
    $txtLog.Dock = "Fill"
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = "Vertical"
    $txtLog.WordWrap = $false
    $txtLog.Font = New-Object System.Drawing.Font("Consolas",9)
    $txtLog.Text = if($script:CommercialLogHistory.Count -gt 0){
        $script:CommercialLogHistory -join ([Environment]::NewLine + [Environment]::NewLine)
    }
    else{
        "No log history yet."
    }

    $dialog.Controls.Add($txtLog)
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

function Show-CommercialDefaultToleranceDialog{
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = "Default Tolerance"
    $dialog.StartPosition = "CenterParent"
    $dialog.Size = New-Object Drawing.Size(340,280)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $labels = @("0 =","0.0 =","0.00 =","0.000 =")
    $sources = @($txtTol0,$txtTol1,$txtTol2,$txtTol3)
    $boxes = @()

    for($i = 0; $i -lt $labels.Count; $i++){
        $label = New-Object Windows.Forms.Label
        $label.Text = $labels[$i]
        $label.AutoSize = $true
        $label.Location = New-Object Drawing.Point(20,(24 + ($i * 34)))
        $dialog.Controls.Add($label)

        $box = New-Object Windows.Forms.TextBox
        $box.Location = New-Object Drawing.Point(100,(20 + ($i * 34)))
        $box.Size = New-Object Drawing.Size(150,24)
        $box.Text = [string]$sources[$i].Text
        $dialog.Controls.Add($box)
        $boxes += $box
    }

    $lblAngle = New-Object Windows.Forms.Label
    $lblAngle.Text = "0.0" + [char]176 + " = +/-"
    $lblAngle.AutoSize = $true
    $lblAngle.Location = New-Object Drawing.Point(20,160)
    $dialog.Controls.Add($lblAngle)

    $txtAngleTol = New-Object Windows.Forms.TextBox
    $txtAngleTol.Location = New-Object Drawing.Point(100,156)
    $txtAngleTol.Size = New-Object Drawing.Size(150,24)
    $txtAngleTol.Text = [string]$script:CommercialDefaultAngleTolerance
    $dialog.Controls.Add($txtAngleTol)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOk.Location = New-Object Drawing.Point(134,204)
    $dialog.Controls.Add($btnOk)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object Drawing.Point(214,204)
    $dialog.Controls.Add($btnCancel)

    $dialog.AcceptButton = $btnOk
    $dialog.CancelButton = $btnCancel

    if($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK){
        for($i = 0; $i -lt $sources.Count; $i++){
            $sources[$i].Text = [string]$boxes[$i].Text
        }
        $script:CommercialDefaultAngleTolerance = [string]$txtAngleTol.Text
    }

    $dialog.Dispose()
}

function Get-CommercialDefaultAiModels{
    return @(
        "ollama:qwen2.5vl:3b",
        "ollama:minicpm-v"
    )
}

function Write-CommercialAiVisionLog($message){
    $line = [string]$message
    if([string]::IsNullOrWhiteSpace($line)){ return }
    if($txtAiLog){
        try{
            $txtAiLog.AppendText((Get-Date).ToString("HH:mm:ss") + " " + $line + [Environment]::NewLine)
            return
        }
        catch{}
    }
    if($txtOcrDebug){
        try{
            $txtOcrDebug.Text = $line
        }
        catch{}
    }
}

function Set-CommercialAiModelSelection($modelName){
    $selectedModel = [string]$modelName
    if([string]::IsNullOrWhiteSpace($selectedModel) -or !$cmbAiModel){ return }

    $mainSelector = Get-Command Set-AiVisionModelSelection -ErrorAction SilentlyContinue
    if($mainSelector){
        try{
            Set-AiVisionModelSelection $selectedModel
            return
        }
        catch{}
    }

    if(-not $cmbAiModel.Items.Contains($selectedModel)){
        [void]$cmbAiModel.Items.Add($selectedModel)
    }
    $cmbAiModel.Text = $selectedModel
}

function Update-CommercialAiModelMenu{
    if(!$miAdvanceAiModel -or !$cmbAiModel){ return }

    $miAdvanceAiModel.DropDownItems.Clear()
    foreach($modelName in @($cmbAiModel.Items)){
        $label = [string]$modelName
        if([string]::IsNullOrWhiteSpace($label)){ continue }
        $item = New-Object Windows.Forms.ToolStripMenuItem($label)
        $item.Checked = ($label -eq [string]$cmbAiModel.Text)
        $item.Add_Click({
            Set-CommercialAiModelSelection ([string]$this.Text)
            Update-CommercialAiModelMenu
        })
        [void]$miAdvanceAiModel.DropDownItems.Add($item)
    }

    if($miAdvanceAiModel.DropDownItems.Count -gt 0){
        [void]$miAdvanceAiModel.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
    }

    $refreshItem = New-Object Windows.Forms.ToolStripMenuItem("Refresh Ollama Models")
    $refreshItem.Add_Click({
        Refresh-CommercialOllamaModelList
    })
    [void]$miAdvanceAiModel.DropDownItems.Add($refreshItem)
}

function Refresh-CommercialOllamaModelList{
    if(!$cmbAiModel){ return }

    $currentModel = [string]$cmbAiModel.Text
    $models = New-Object System.Collections.Generic.List[string]
    foreach($defaultModel in (Get-CommercialDefaultAiModels)){
        if(-not $models.Contains($defaultModel)){
            [void]$models.Add($defaultModel)
        }
    }

    try{
        $response = Invoke-RestMethod -Method Get -Uri ($script:OllamaVisionBaseUrl.TrimEnd('/') + "/api/tags") -TimeoutSec 15
        foreach($entry in @($response.models)){
            $entryName = [string]$entry.name
            if([string]::IsNullOrWhiteSpace($entryName)){ continue }
            $qualifiedName = if($entryName.StartsWith("ollama:",[System.StringComparison]::OrdinalIgnoreCase)){ $entryName } else { "ollama:" + $entryName }
            if(-not $models.Contains($qualifiedName)){
                [void]$models.Add($qualifiedName)
            }
        }
    }
    catch{
        Write-CommercialAiVisionLog ("Refresh Ollama models failed: " + $_.Exception.Message)
    }

    $cmbAiModel.Items.Clear()
    foreach($modelName in $models){
        [void]$cmbAiModel.Items.Add($modelName)
    }

    if(-not [string]::IsNullOrWhiteSpace($currentModel)){
        Set-CommercialAiModelSelection $currentModel
    }
    elseif($cmbAiModel.Items.Count -gt 0){
        $cmbAiModel.SelectedIndex = 0
    }

    Update-CommercialAiModelMenu
}

function Set-CommercialRecentToleranceValue($value){
    try{
        $script:CommercialRecentToleranceValue = [double]$value
    }
    catch{
        return
    }

    if($script:CommercialRecentToleranceButton){
        $script:CommercialRecentToleranceButton.Text = "Recent " + (Format-InvariantDecimal $script:CommercialRecentToleranceValue)
        $script:CommercialRecentToleranceButton.Tag = $script:CommercialRecentToleranceValue
    }
}

function Reset-CommercialNumericPresetLabels{
    param([System.Collections.IEnumerable]$Buttons)

    foreach($button in @($Buttons)){
        if(-not (Test-CommercialControl $button)){ continue }
        if($button -eq $script:CommercialRecentToleranceButton){ continue }
        if(-not [string]::IsNullOrWhiteSpace([string]$button.AccessibleDescription)){
            $button.Text = [string]$button.AccessibleDescription
        }
    }
}

function Test-CommercialControl($value){
    return ($value -is [System.Windows.Forms.Control])
}

function Update-CommercialTolerancePresetState{
    if(!$grpPreset){ return }

    if($script:CommercialPresetToggleButton){
        $script:CommercialPresetToggleButton.Visible = $false
    }

    $symbolButtons = @($btnDegreeSymbol,$btnDiameterSymbol,$btnRadiusSymbol,$btnChamferSymbol) | Where-Object { Test-CommercialControl $_ }
    $numericButtons = @($script:CommercialNumericPresetButtons | Where-Object { Test-CommercialControl $_ })

    if($numericButtons.Count -gt 0){
        $script:CommercialRecentToleranceButton = $numericButtons[0]
        if($null -eq $script:CommercialRecentToleranceValue){
            try{
                $script:CommercialRecentToleranceValue = [double]$script:CommercialRecentToleranceButton.Tag
            }
            catch{
                $script:CommercialRecentToleranceValue = 0.5
            }
        }

        Reset-CommercialNumericPresetLabels $numericButtons
        Set-CommercialRecentToleranceValue $script:CommercialRecentToleranceValue

        for($i = 1; $i -lt $numericButtons.Count; $i++){
            $numericButtons[$i].Visible = $script:CommercialToleranceExpanded
        }
    }

    foreach($symbolButton in $symbolButtons){
        if($symbolButton){ $symbolButton.Visible = $true }
    }

    $grpPreset.Height = 178
}

function Update-CommercialToleranceButtonLayout{
    if(!$grpPreset){ return }

    $symbolButtons = @($btnDegreeSymbol,$btnDiameterSymbol,$btnRadiusSymbol,$btnChamferSymbol) | Where-Object { Test-CommercialControl $_ }
    $numericButtons = @($script:CommercialNumericPresetButtons | Where-Object { Test-CommercialControl $_ })

    $gap = 6
    $left = 10
    $topY = 28
    $buttonHeight = 28
    $contentWidth = [Math]::Max(180,($grpPreset.ClientSize.Width - 20))
    $gridColWidth = [Math]::Max(56,[int](($contentWidth - ($gap * 3)) / 4))
    $row2Top = $topY + $buttonHeight + $gap
    $row3Top = $row2Top + $buttonHeight + $gap
    $row4Top = $row3Top + $buttonHeight + $gap

    Reset-CommercialNumericPresetLabels $numericButtons

    if($numericButtons.Count -gt 0){
        Set-CommercialRecentToleranceValue $script:CommercialRecentToleranceValue
        for($i = 0; $i -lt $numericButtons.Count; $i++){
            $button = $numericButtons[$i]
            $col = $i % 4
            $row = [int][Math]::Floor($i / 4)
            $targetTop = switch($row){
                0 { $topY }
                1 { $row2Top }
                default { $row3Top }
            }

            $button.Location = New-Object Drawing.Point(($left + ($col * ($gridColWidth + $gap))),$targetTop)
            $button.Size = New-Object Drawing.Size($gridColWidth,$buttonHeight)
            $button.Visible = $true
            $button.BringToFront()
        }
    }

    for($i = 0; $i -lt $symbolButtons.Count; $i++){
        $symbolButtons[$i].Location = New-Object Drawing.Point(($left + ($i * ($gridColWidth + $gap))),$row4Top)
        $symbolButtons[$i].Size = New-Object Drawing.Size($gridColWidth,$buttonHeight)
        $symbolButtons[$i].Visible = $true
        $symbolButtons[$i].BringToFront()
    }
}

function Update-CommercialAdvanceMenuLayout{
    if(!$advanceMenu -or $script:CommercialAdvanceMenuGrouped){ return }

    $itemsByText = @{}
    foreach($menuItem in @($advanceMenu.Items)){
        if($menuItem -is [System.Windows.Forms.ToolStripMenuItem]){
            $itemsByText[[string]$menuItem.Text] = $menuItem
        }
    }

    $advanceMenu.SuspendLayout()
    try{
        $advanceMenu.Items.Clear()

        $miEdit = New-Object Windows.Forms.ToolStripMenuItem("Edit")
        $miView = New-Object Windows.Forms.ToolStripMenuItem("View")
        $miOcr = New-Object Windows.Forms.ToolStripMenuItem("OCR")
        $miDev = New-Object Windows.Forms.ToolStripMenuItem("Developer")
        $miDanger = New-Object Windows.Forms.ToolStripMenuItem("Danger")

        foreach($name in @("Choose Template","Edit Steps","Sort Steps","Search Sessions")){
            if($itemsByText.ContainsKey($name)){ [void]$miEdit.DropDownItems.Add($itemsByText[$name]) }
        }
        foreach($name in @("Copy View Off","Text Zones Off","Auto Map PDF","Clear Gray Boxes","Rotate Drawing 90°")){
            if($itemsByText.ContainsKey($name)){ [void]$miView.DropDownItems.Add($itemsByText[$name]) }
        }
        foreach($name in @("Language","Google AI Recovery","AI Model","Default Tolerance","Log History","Sample Auto Fill On")){
            if($itemsByText.ContainsKey($name)){ [void]$miOcr.DropDownItems.Add($itemsByText[$name]) }
        }
        foreach($name in @("Yellow Pen Off","Eraser Off")){
            if($itemsByText.ContainsKey($name)){ [void]$miDev.DropDownItems.Add($itemsByText[$name]) }
        }
        foreach($name in @("Delete Current Session")){
            if($itemsByText.ContainsKey($name)){ [void]$miDanger.DropDownItems.Add($itemsByText[$name]) }
        }

        foreach($rootItem in @($miEdit,$miView,$miOcr,$miDev,$miDanger)){
            if($rootItem.DropDownItems.Count -gt 0){
                [void]$advanceMenu.Items.Add($rootItem)
            }
        }

        $script:CommercialAdvanceMenuGrouped = $true
    }
    finally{
        $advanceMenu.ResumeLayout()
    }
}

function Ensure-CommercialSidebarAnimationTimer{
    if($script:CommercialSidebarAnimationTimer){ return }

    $script:CommercialSidebarAnimationTimer = New-Object Windows.Forms.Timer
    $script:CommercialSidebarAnimationTimer.Interval = 15
    $script:CommercialSidebarAnimationTimer.Add_Tick({
        $delta = ([int]$script:CommercialSidebarTargetWidth - [int]$script:CommercialSidebarCurrentWidth)
        if([Math]::Abs($delta) -le 8){
            $script:CommercialSidebarCurrentWidth = [int]$script:CommercialSidebarTargetWidth
            $script:CommercialSidebarAnimationTimer.Stop()
        }
        else{
            $step = [Math]::Max(12,[int]([Math]::Abs($delta) * 0.35))
            if($delta -gt 0){
                $script:CommercialSidebarCurrentWidth += $step
            }
            else{
                $script:CommercialSidebarCurrentWidth -= $step
            }
        }

        Update-CommercialLayoutEnhancements
    })
}

function Start-CommercialSidebarAnimation{
    param([int]$ExpandedWidth)

    Ensure-CommercialSidebarAnimationTimer
    $script:CommercialSidebarTargetWidth = if($script:CommercialSidebarExpanded){ $ExpandedWidth } else { 28 }
    $script:CommercialSidebarAnimationTimer.Start()
}

function Update-CommercialLayoutEnhancements{
    if(!$form -or !$tabDraw -or !$viewer -or !$table){ return }
    if($tabDraw.ClientSize.Width -le 0 -or $tabDraw.ClientSize.Height -le 0){ return }
    if($script:CommercialLayoutBusy){ return }

    $script:CommercialLayoutBusy = $true
    $tabDraw.SuspendLayout()
    try{
        Update-CommercialAdvanceMenuLayout
        Update-CommercialTolerancePresetState

        $margin = 12
        $collapsedWidth = 28
        $expandedSidebarWidth = [Math]::Max(320,[Math]::Min(430,[int]($tabDraw.ClientSize.Width * 0.31)))
        if([int]$script:CommercialSidebarCurrentWidth -le 0){
            $script:CommercialSidebarCurrentWidth = if($script:CommercialSidebarExpanded){ $expandedSidebarWidth } else { $collapsedWidth }
        }
        $script:CommercialSidebarCurrentWidth = [Math]::Max($collapsedWidth,[Math]::Min($expandedSidebarWidth,[int]$script:CommercialSidebarCurrentWidth))
        $viewerWidth = [Math]::Max(360,($tabDraw.ClientSize.Width - ($margin * 3) - [int]$script:CommercialSidebarCurrentWidth))
        $pageNavVisible = $false
        try{
            $pageNavVisible = ($script:DocumentPages -and $script:DocumentPages.Count -gt 1)
        }
        catch{}

        $pageNavHeight = if($pageNavVisible){ 30 } else { 0 }
        $viewerTop = $margin + $(if($pageNavVisible){ $pageNavHeight + 8 } else { 0 })
        $viewerHeight = [Math]::Max(260,($tabDraw.ClientSize.Height - $viewerTop - $margin))
        $viewer.Location = New-Object Drawing.Point($margin,$viewerTop)
        $viewer.Size = New-Object Drawing.Size($viewerWidth,$viewerHeight)

        if((Test-CommercialControl $btnPrevPage) -and (Test-CommercialControl $lblPageInfo) -and (Test-CommercialControl $btnNextPage)){
            $btnPrevPage.Visible = $pageNavVisible
            $lblPageInfo.Visible = $pageNavVisible
            $btnNextPage.Visible = $pageNavVisible
            if($pageNavVisible){
                $pageNavButtonWidth = 90
                $pageNavLabelWidth = 110
                $pageNavGapX = 8
                $pageNavTotalWidth = ($pageNavButtonWidth * 2) + $pageNavLabelWidth + ($pageNavGapX * 2)
                $pageNavLeft = $margin + [Math]::Max(0,[int](($viewerWidth - $pageNavTotalWidth) / 2))
                $btnPrevPage.Location = New-Object Drawing.Point($pageNavLeft,$margin)
                $btnPrevPage.Size = New-Object Drawing.Size($pageNavButtonWidth,$pageNavHeight)
                $lblPageInfo.Location = New-Object Drawing.Point(($btnPrevPage.Right + $pageNavGapX),$margin)
                $lblPageInfo.Size = New-Object Drawing.Size($pageNavLabelWidth,$pageNavHeight)
                $btnNextPage.Location = New-Object Drawing.Point(($lblPageInfo.Right + $pageNavGapX),$margin)
                $btnNextPage.Size = New-Object Drawing.Size($pageNavButtonWidth,$pageNavHeight)
            }
            else{
                $btnPrevPage.Location = New-Object Drawing.Point(-3000,-3000)
                $lblPageInfo.Location = New-Object Drawing.Point(-3000,-3000)
                $btnNextPage.Location = New-Object Drawing.Point(-3000,-3000)
            }
        }

        $sidebarWidth = [int]$script:CommercialSidebarCurrentWidth
        $sidebarX = $viewer.Right + $margin
        $topRowY = $btnLoad.Top
        $topButtonGap = 8
        $topButtonWidth = [int](($expandedSidebarWidth - ($topButtonGap * 2)) / 3)
        $sidebarActive = $sidebarWidth -gt ($collapsedWidth + 18)

        if($script:CommercialSidebarToggleButton){
            $script:CommercialSidebarToggleButton.Text = if($script:CommercialSidebarExpanded){ ">" } else { "<" }
            $script:CommercialSidebarToggleButton.Location = New-Object Drawing.Point(($sidebarX + $sidebarWidth - 28),($topRowY + 4))
            $script:CommercialSidebarToggleButton.Size = New-Object Drawing.Size(28,28)
            $script:CommercialSidebarToggleButton.BringToFront()
        }

        $sidebarControls = @(
            $btnLoad,$btnExcel,$btnAdvance,$grpTableResult,$lblPreviewTitle,$preview,$grpPreset,$grpTolMode
        ) | Where-Object { Test-CommercialControl $_ }

        if(-not $sidebarActive){
            foreach($sidebarControl in $sidebarControls){
                $sidebarControl.Visible = $false
            }
            if(Test-CommercialControl $script:CommercialSidebarToggleButton){
                $script:CommercialSidebarToggleButton.BackColor = [System.Drawing.Color]::WhiteSmoke
            }
            return
        }

        foreach($sidebarControl in $sidebarControls){
            $sidebarControl.Visible = $true
        }
        if(Test-CommercialControl $script:CommercialSidebarToggleButton){
            $script:CommercialSidebarToggleButton.BackColor = [System.Drawing.Color]::WhiteSmoke
        }

        $btnLoad.Location = New-Object Drawing.Point($sidebarX,$topRowY)
        $btnLoad.Size = New-Object Drawing.Size($topButtonWidth,36)
        $btnExcel.Location = New-Object Drawing.Point(($btnLoad.Right + $topButtonGap),$topRowY)
        $btnExcel.Size = New-Object Drawing.Size($topButtonWidth,36)
        $btnAdvance.Location = New-Object Drawing.Point(($btnExcel.Right + $topButtonGap),$topRowY)
        $btnAdvance.Size = New-Object Drawing.Size(($sidebarWidth - ($topButtonWidth * 2) - ($topButtonGap * 2)),36)

        foreach($hiddenToolButton in @($btnYellowPen,$btnEraser,$btnTranslateLens) | Where-Object { Test-CommercialControl $_ }){
            $hiddenToolButton.Visible = $false
            $hiddenToolButton.Location = New-Object Drawing.Point(-3000,-3000)
            $hiddenToolButton.Size = New-Object Drawing.Size(1,1)
        }

        $grpDefaultTol.Visible = $false
        $grpOcrDebug.Visible = $false
        $txtOcrDebug.Visible = $false

        if($grpTableResult){
            if($table.Parent -ne $grpTableResult){ $grpTableResult.Controls.Add($table) }
            if($lblTableSearch.Parent -ne $grpTableResult){ $grpTableResult.Controls.Add($lblTableSearch) }
            if($txtTableSearch.Parent -ne $grpTableResult){ $grpTableResult.Controls.Add($txtTableSearch) }
            $grpTableResult.Text = if($script:CommercialUiLanguage -eq "vi"){ "Ket qua OCR" } else { "OCR Results" }
        $grpTableResult.Location = New-Object Drawing.Point($sidebarX,($btnLoad.Bottom + 8))
        $grpTableResult.Size = New-Object Drawing.Size($sidebarWidth,[Math]::Max(250,[int]($tabDraw.ClientSize.Height * 0.40)))

            $lblTableSearch.Text = if($script:CommercialUiLanguage -eq "vi"){ "Tim" } else { "Search" }
            $lblTableSearch.Location = New-Object Drawing.Point(12,25)
            $txtTableSearch.Location = New-Object Drawing.Point(($lblTableSearch.Right + 8),21)
            $txtTableSearch.Size = New-Object Drawing.Size([Math]::Max(110,($grpTableResult.ClientSize.Width - $txtTableSearch.Location.X - 10)),28)
            $table.Location = New-Object Drawing.Point(10,56)
            $table.Size = New-Object Drawing.Size(($grpTableResult.ClientSize.Width - 20),($grpTableResult.ClientSize.Height - 66))
        }

        $previewTop = $grpTableResult.Bottom + 10
        $lblPreviewTitle.Visible = $false
        $lblPreviewTitle.Location = New-Object Drawing.Point(-3000,-3000)
        $preview.Visible = $false
        $preview.Location = New-Object Drawing.Point(-3000,-3000)
        $preview.Size = New-Object Drawing.Size(1,1)

        $grpTolMode.Height = 96

        $presetPanelHeight = 178
        $presetWidth = $sidebarWidth
        $grpPreset.Location = New-Object Drawing.Point($sidebarX,($previewTop - 2))
        $grpPreset.Size = New-Object Drawing.Size($presetWidth,$presetPanelHeight)

        $grpTolMode.Location = New-Object Drawing.Point($sidebarX,($grpPreset.Bottom + 12))
        $grpTolMode.Size = New-Object Drawing.Size($sidebarWidth,$grpTolMode.Height)

        Update-CommercialToleranceButtonLayout
        $grpPreset.BringToFront()
    }
    finally{
        $tabDraw.ResumeLayout()
        $script:CommercialLayoutBusy = $false
    }
}

function Schedule-CommercialUiRefresh{
    if(!$script:CommercialLayoutRefreshTimer){
        $script:CommercialLayoutRefreshTimer = New-Object Windows.Forms.Timer
        $script:CommercialLayoutRefreshTimer.Interval = 140
        $script:CommercialLayoutRefreshTimer.Add_Tick({
            $script:CommercialLayoutRefreshTimer.Stop()
            Update-CommercialLayoutEnhancements
        })
    }

    $script:CommercialLayoutRefreshTimer.Stop()
    $script:CommercialLayoutRefreshTimer.Start()
}

# =========================
# MAIN LAYOUT
# =========================

$mainSplit = New-Object Windows.Forms.SplitContainer
$mainSplit.Dock = "Fill"
$mainSplit.Orientation = "Vertical"
$mainSplit.SplitterWidth = 6
$mainSplit.Panel2Collapsed = $true
$mainSplit.IsSplitterFixed = $true
$form.Controls.Add($mainSplit)

$tabDraw = New-Object Windows.Forms.Panel
$tabDraw.Dock = "Fill"
$tabDraw.BackColor = [System.Drawing.Color]::WhiteSmoke
$tabDraw.AutoScroll = $true
$mainSplit.Panel1.Controls.Add($tabDraw)

$tabInspect = New-Object Windows.Forms.Panel
$tabInspect.Dock = "Fill"
$tabInspect.BackColor = [System.Drawing.Color]::WhiteSmoke
$mainSplit.Panel2.Controls.Add($tabInspect)

$lblDrawTitle = New-Object Windows.Forms.Label
$lblDrawTitle.Text = "Drawing Workspace"
$lblDrawTitle.Font = $sectionFont
$lblDrawTitle.AutoSize = $true
$lblDrawTitle.Location = New-Object Drawing.Point(12,12)
$lblDrawTitle.Visible = $false
$tabDraw.Controls.Add($lblDrawTitle)

$lblInspectTitle = New-Object Windows.Forms.Label
$lblInspectTitle.Text = "Inspection Table"
$lblInspectTitle.Font = $sectionFont
$lblInspectTitle.AutoSize = $true
$lblInspectTitle.Location = New-Object Drawing.Point(12,12)
$tabInspect.Controls.Add($lblInspectTitle)
# =========================
# VIEWER
# =========================

$pageList = New-Object Windows.Forms.ListBox
$pageList.Font = $uiFont
$pageList.IntegralHeight = $false
$pageList.Visible = $false
$pageList.TabStop = $false
$tabDraw.Controls.Add($pageList)

$btnPrevPage = New-Object Windows.Forms.Button
$btnPrevPage.Text = "Previous"
$btnPrevPage.Font = $uiFont
$btnPrevPage.Visible = $false
$btnPrevPage.Location = New-Object Drawing.Point(-3000,-3000)
$tabDraw.Controls.Add($btnPrevPage)

$lblPageInfo = New-Object Windows.Forms.Label
$lblPageInfo.Text = ""
$lblPageInfo.Font = $uiBoldFont
$lblPageInfo.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblPageInfo.Visible = $false
$lblPageInfo.Location = New-Object Drawing.Point(-3000,-3000)
$tabDraw.Controls.Add($lblPageInfo)

$btnNextPage = New-Object Windows.Forms.Button
$btnNextPage.Text = "Next"
$btnNextPage.Font = $uiFont
$btnNextPage.Visible = $false
$btnNextPage.Location = New-Object Drawing.Point(-3000,-3000)
$tabDraw.Controls.Add($btnNextPage)

$viewer = New-Object Windows.Forms.Panel
$viewer.Location = New-Object Drawing.Point(10,10)
$viewer.Size = New-Object Drawing.Size(1200,770)
$viewer.AutoScroll = $false
$viewer.BackColor = [System.Drawing.Color]::White
$viewer.BorderStyle = "FixedSingle"
Enable-DoubleBuffer $tabDraw
Enable-DoubleBuffer $viewer
$tabDraw.Controls.Add($viewer)

$btnToggleSidebarPanel = New-Object Windows.Forms.Button
$btnToggleSidebarPanel.Text = ">"
$btnToggleSidebarPanel.Font = New-Object System.Drawing.Font("Segoe UI",11,[System.Drawing.FontStyle]::Bold)
$btnToggleSidebarPanel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnToggleSidebarPanel.FlatAppearance.BorderColor = [System.Drawing.Color]::Gainsboro
$btnToggleSidebarPanel.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(235,242,250)
$btnToggleSidebarPanel.Width = 28
$btnToggleSidebarPanel.Height = 28
$btnToggleSidebarPanel.TabStop = $false
$btnToggleSidebarPanel.Add_Click({
    $script:CommercialSidebarExpanded = -not $script:CommercialSidebarExpanded
    Start-CommercialSidebarAnimation ([Math]::Max(320,[Math]::Min(430,[int]($tabDraw.ClientSize.Width * 0.31))))
})
$tabDraw.Controls.Add($btnToggleSidebarPanel)
$script:CommercialSidebarToggleButton = $btnToggleSidebarPanel

$picture = New-Object Windows.Forms.Panel
Enable-DoubleBuffer $picture
$picture.Dock = "Fill"
$picture.BackColor = [System.Drawing.Color]::White
$picture.TabStop = $true
$script:CanvasControl = $picture
$viewer.Controls.Add($picture)

# =========================
# Default tolerance
# =========================

$grpDefaultTol = New-Object Windows.Forms.GroupBox
$grpDefaultTol.Text = "Default Tolerance"
$grpDefaultTol.Font = $groupFont
$grpDefaultTol.Location = New-Object Drawing.Point(1250,660)
$grpDefaultTol.Size = New-Object Drawing.Size(220,130)
$grpDefaultTol.Visible = $false
$tabDraw.Controls.Add($grpDefaultTol)

# ----- 0 -----
$lblTol0 = New-Object Windows.Forms.Label
$lblTol0.Text = "0 ="
$lblTol0.Font = $uiBoldFont
$lblTol0.Width = 60
$lblTol0.Location = New-Object Drawing.Point(12,55)
$txtTol0 = New-Object Windows.Forms.TextBox
$txtTol0.Font = $uiFont
$txtTol0.Location = New-Object Drawing.Point(82,52)
$txtTol0.Width = 60
$txtTol0.Text = "0.2"

$grpDefaultTol.Controls.Add($lblTol0)
$grpDefaultTol.Controls.Add($txtTol0)


# ----- 0.0 -----
$lblTol1 = New-Object Windows.Forms.Label
$lblTol1.Text = "0.0="
$lblTol1.Font = $uiBoldFont
$lblTol1.Location = New-Object Drawing.Point(12,80)
$lblTol1.Width = 60
$txtTol1 = New-Object Windows.Forms.TextBox
$txtTol1.Font = $uiFont
$txtTol1.Location = New-Object Drawing.Point(82,77)
$txtTol1.Width = 60
$txtTol1.Text = "0.05"

$grpDefaultTol.Controls.Add($lblTol1)
$grpDefaultTol.Controls.Add($txtTol1)


# ----- 0.00 -----
$lblTol2 = New-Object Windows.Forms.Label
$lblTol2.Text = "0.00="
$lblTol2.Font = $uiBoldFont
$lblTol2.Location = New-Object Drawing.Point(12,105)
$lblTol2.Width = 60
$txtTol2 = New-Object Windows.Forms.TextBox
$txtTol2.Font = $uiFont
$txtTol2.Location = New-Object Drawing.Point(82,102)
$txtTol2.Width = 60
$txtTol2.Text = "0.01"

$grpDefaultTol.Controls.Add($lblTol2)
$grpDefaultTol.Controls.Add($txtTol2)


# ----- 0.000 -----
$lblTol3 = New-Object Windows.Forms.Label
$lblTol3.Text = "0.000="
$lblTol3.Font = $uiBoldFont
$lblTol3.Location = New-Object Drawing.Point(150,55)
$lblTol3.Width = 60
$txtTol3 = New-Object Windows.Forms.TextBox
$txtTol3.Font = $uiFont
$txtTol3.Location = New-Object Drawing.Point(150,80)
$txtTol3.Width = 60
$txtTol3.Text = "0.003"

$grpDefaultTol.Controls.Add($lblTol3)
$grpDefaultTol.Controls.Add($txtTol3)
# =========================
# PREVIEW
# =========================

$preview = New-Object Windows.Forms.PictureBox
$preview.Location = New-Object Drawing.Point(1240,200)
$preview.Size = New-Object Drawing.Size(180,120)
$preview.BorderStyle = "FixedSingle"
$preview.SizeMode = "Zoom"
Enable-DoubleBuffer $preview
$tabDraw.Controls.Add($preview)

$lblPreviewTitle = New-Object Windows.Forms.Label
$lblPreviewTitle.Text = "OCR Preview"
$lblPreviewTitle.Font = $uiBoldFont
$lblPreviewTitle.AutoSize = $true
$lblPreviewTitle.Location = New-Object Drawing.Point(1240,170)
$lblPreviewTitle.Visible = $false
$tabDraw.Controls.Add($lblPreviewTitle)
$grpOcrDebug = New-Object Windows.Forms.GroupBox
$grpOcrDebug.Text = "OCR Debug"
$grpOcrDebug.Font = $groupFont
$grpOcrDebug.Location = New-Object Drawing.Point(1240,320)
$grpOcrDebug.Size = New-Object Drawing.Size(400,120)
$grpOcrDebug.Visible = $false
$tabDraw.Controls.Add($grpOcrDebug)

$txtOcrDebug = New-Object Windows.Forms.TextBox
$txtOcrDebug.Font = New-Object System.Drawing.Font("Consolas",8)
$txtOcrDebug.Location = New-Object Drawing.Point(10,22)
$txtOcrDebug.Size = New-Object Drawing.Size(380,88)
$txtOcrDebug.Multiline = $true
$txtOcrDebug.ReadOnly = $true
$txtOcrDebug.ScrollBars = "Vertical"
$txtOcrDebug.WordWrap = $false
$txtOcrDebug.Visible = $false
$txtOcrDebug.Add_TextChanged({
    Add-CommercialLogEntry ([string]$this.Text)
})
$grpOcrDebug.Controls.Add($txtOcrDebug)

$grpAiVision = New-Object Windows.Forms.GroupBox
$grpAiVision.Text = "AI Vision"
$grpAiVision.Font = $groupFont
$grpAiVision.Location = New-Object Drawing.Point(1240,446)
$grpAiVision.Size = New-Object Drawing.Size(400,192)
$grpAiVision.Visible = $false
$tabDraw.Controls.Add($grpAiVision)

$lblAiModel = New-Object Windows.Forms.Label
$lblAiModel.Text = "Model"
$lblAiModel.Font = $uiFont
$lblAiModel.AutoSize = $true
$lblAiModel.Location = New-Object Drawing.Point(10,26)
$grpAiVision.Controls.Add($lblAiModel)

$cmbAiModel = New-Object Windows.Forms.ComboBox
$cmbAiModel.Font = $uiFont
$cmbAiModel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$cmbAiModel.Location = New-Object Drawing.Point(62,22)
$cmbAiModel.Size = New-Object Drawing.Size(192,28)
[void]$cmbAiModel.Items.AddRange((Get-CommercialDefaultAiModels))
$cmbAiModel.SelectedIndex = 0
$grpAiVision.Controls.Add($cmbAiModel)

$btnAiUseEnv = New-Object Windows.Forms.Button
$btnAiUseEnv.Text = "Rescan AI"
$btnAiUseEnv.Font = $uiFont
$btnAiUseEnv.Location = New-Object Drawing.Point(262,21)
$btnAiUseEnv.Size = New-Object Drawing.Size(124,28)
$grpAiVision.Controls.Add($btnAiUseEnv)

$chkAiTestOnly = New-Object Windows.Forms.CheckBox
$chkAiTestOnly.Text = "AI test only on"
$chkAiTestOnly.Font = $uiFont
$chkAiTestOnly.AutoSize = $true
$chkAiTestOnly.Location = New-Object Drawing.Point(10,58)
$grpAiVision.Controls.Add($chkAiTestOnly)

$chkAiExperiment = New-Object Windows.Forms.CheckBox
$chkAiExperiment.Text = "Experiment mode"
$chkAiExperiment.Font = $uiFont
$chkAiExperiment.AutoSize = $true
$chkAiExperiment.Location = New-Object Drawing.Point(150,58)
$grpAiVision.Controls.Add($chkAiExperiment)

$btnAiTest = New-Object Windows.Forms.Button
$btnAiTest.Text = "Test AI Only"
$btnAiTest.Font = $uiFont
$btnAiTest.Location = New-Object Drawing.Point(10,85)
$btnAiTest.Size = New-Object Drawing.Size(118,30)
$grpAiVision.Controls.Add($btnAiTest)

$btnAiAccept = New-Object Windows.Forms.Button
$btnAiAccept.Text = "Accept AI"
$btnAiAccept.Font = $uiFont
$btnAiAccept.Location = New-Object Drawing.Point(136,85)
$btnAiAccept.Size = New-Object Drawing.Size(118,30)
$btnAiAccept.Enabled = $false
$grpAiVision.Controls.Add($btnAiAccept)

$btnAiClear = New-Object Windows.Forms.Button
$btnAiClear.Text = "Clear"
$btnAiClear.Font = $uiFont
$btnAiClear.Location = New-Object Drawing.Point(262,85)
$btnAiClear.Size = New-Object Drawing.Size(124,30)
$grpAiVision.Controls.Add($btnAiClear)

$txtAiResult = New-Object Windows.Forms.TextBox
$txtAiResult.Font = New-Object System.Drawing.Font("Consolas",8)
$txtAiResult.Location = New-Object Drawing.Point(10,120)
$txtAiResult.Size = New-Object Drawing.Size(376,62)
$txtAiResult.Multiline = $true
$txtAiResult.ReadOnly = $true
$txtAiResult.ScrollBars = "Vertical"
$txtAiResult.WordWrap = $true
$grpAiVision.Controls.Add($txtAiResult)

# =========================
# TOLERANCE MODE
# =========================

$grpTolMode = New-Object Windows.Forms.GroupBox
$grpTolMode.Text = "Tolerance Mode"
$grpTolMode.Font = $groupFont
$grpTolMode.Location = New-Object Drawing.Point(1250,250)
$grpTolMode.Size = New-Object Drawing.Size(400,135)

$tabDraw.Controls.Add($grpTolMode)

$rbPM = New-Object Windows.Forms.RadioButton
$rbPM.Text = "±"
$rbPM.Font = $uiFont
$rbPM.Location = "12,28"
$rbPM.Checked = $true
$rbPM.Width = 40
$grpTolMode.Controls.Add($rbPM)

$rbPlus = New-Object Windows.Forms.RadioButton
$rbPlus.Text = "+"
$rbPlus.Font = $uiFont
$rbPlus.Location = "12,60"
$rbPlus.Width = 40
$grpTolMode.Controls.Add($rbPlus)

$rbMinus = New-Object Windows.Forms.RadioButton
$rbMinus.Text = "-"
$rbMinus.Font = $uiFont
$rbMinus.Location = "232,28"
$rbMinus.Width = 50
$grpTolMode.Controls.Add($rbMinus)

$rbPP = New-Object Windows.Forms.RadioButton
$rbPP.Text = "++"
$rbPP.Font = $uiFont
$rbPP.Location = "122,28"
$rbPP.Width = 60
$grpTolMode.Controls.Add($rbPP)

$rbMM = New-Object Windows.Forms.RadioButton
$rbMM.Text = "--"
$rbMM.Font = $uiFont
$rbMM.Location = "122,60"
$rbMM.Width = 60
$grpTolMode.Controls.Add($rbMM)
# =========================
# BUTTONS
# =========================
# =========================
# TOLERANCE PRESETS
# =========================

$grpPreset = New-Object Windows.Forms.GroupBox
$grpPreset.Text = "Tolerance"
$grpPreset.Font = $groupFont
$grpPreset.Location = New-Object Drawing.Point(1250,390)
$grpPreset.Size = New-Object Drawing.Size(400,188)

$tabDraw.Controls.Add($grpPreset)

$btnToggleTolerancePreset = New-Object Windows.Forms.Button
$btnToggleTolerancePreset.Text = "Collapse"
$btnToggleTolerancePreset.Font = New-Object System.Drawing.Font("Segoe UI",8,[System.Drawing.FontStyle]::Bold)
$btnToggleTolerancePreset.Width = 70
$btnToggleTolerancePreset.Height = 24
$btnToggleTolerancePreset.Location = New-Object Drawing.Point(318,8)
$btnToggleTolerancePreset.Add_Click({
    $script:CommercialToleranceExpanded = -not $script:CommercialToleranceExpanded
    Update-CommercialTolerancePresetState
})
$grpPreset.Controls.Add($btnToggleTolerancePreset)
$script:CommercialPresetToggleButton = $btnToggleTolerancePreset

$presetValues = @(
0.5,0.3,0.2,0.1,
0.05,0.03,0.02,0.01,
0.005,0.003,0.002,0.001
)

$x=10
$y=32
$i=0

foreach($val in $presetValues){

    $btn = New-Object Windows.Forms.Button
    $btn.Text = Format-InvariantDecimal $val
    $btn.Font = $uiBoldFont
    $btn.Width = 70
    $btn.Height = 32
    $btn.Location = New-Object Drawing.Point($x,$y)

    $btn.Tag = $val

    $btn.Add_Click({
        Apply-Tolerance $this.Tag
        Set-CommercialRecentToleranceValue $this.Tag
    })
    $btn.AccessibleDescription = $btn.Text

    $grpPreset.Controls.Add($btn)
    $script:CommercialNumericPresetButtons += $btn

    $x += 75
    $i++

    if($i % 4 -eq 0){
        $x = 10
        $y += 38
    }
}

$btnDegreeSymbol = New-Object Windows.Forms.Button
$btnDegreeSymbol.Text = "°"
$btnDegreeSymbol.Font = $uiBoldFont
$btnDegreeSymbol.Width = 70
$btnDegreeSymbol.Height = 32
$btnDegreeSymbol.Location = New-Object Drawing.Point(10,($y + 2))
$grpPreset.Controls.Add($btnDegreeSymbol)

$btnDiameterSymbol = New-Object Windows.Forms.Button
$btnDiameterSymbol.Text = "Ø"
$btnDiameterSymbol.Font = $uiBoldFont
$btnDiameterSymbol.Width = 70
$btnDiameterSymbol.Height = 32
$btnDiameterSymbol.Location = New-Object Drawing.Point(85,($y + 2))
$grpPreset.Controls.Add($btnDiameterSymbol)

$btnRadiusSymbol = New-Object Windows.Forms.Button
$btnRadiusSymbol.Text = "R"
$btnRadiusSymbol.Font = $uiBoldFont
$btnRadiusSymbol.Width = 70
$btnRadiusSymbol.Height = 32
$btnRadiusSymbol.Location = New-Object Drawing.Point(160,($y + 2))
$grpPreset.Controls.Add($btnRadiusSymbol)

$btnChamferSymbol = New-Object Windows.Forms.Button
$btnChamferSymbol.Text = "C"
$btnChamferSymbol.Font = $uiBoldFont
$btnChamferSymbol.Width = 70
$btnChamferSymbol.Height = 32
$btnChamferSymbol.Location = New-Object Drawing.Point(235,($y + 2))
$grpPreset.Controls.Add($btnChamferSymbol)

$btnLoad = New-Object Windows.Forms.Button
$btnLoad.Text = "Open PDF"
$btnLoad.Font = $buttonFont
$btnLoad.Location = New-Object Drawing.Point(1250,60)
$btnLoad.Width = 150
$tabDraw.Controls.Add($btnLoad)

$btnTranslateLens = New-Object Windows.Forms.Button
$btnTranslateLens.Text = "Translator"
$btnTranslateLens.Font = $uiFont
$btnTranslateLens.Visible = $false
$btnTranslateLens.Location = New-Object Drawing.Point(-3000,-3000)
$btnTranslateLens.Size = New-Object Drawing.Size(1,1)
$tabDraw.Controls.Add($btnTranslateLens)

$btnAdvance = New-Object Windows.Forms.Button
$btnAdvance.Text = "Advanced"
$btnAdvance.Font = $uiFont
$tabDraw.Controls.Add($btnAdvance)

$btnYellowPen = New-Object Windows.Forms.Button
$btnYellowPen.Text = "Yellow Pen Off"
$btnYellowPen.Font = $uiFont
$btnYellowPen.Visible = $false
$btnYellowPen.Location = New-Object Drawing.Point(-3000,-3000)
$btnYellowPen.Size = New-Object Drawing.Size(1,1)
$tabDraw.Controls.Add($btnYellowPen)

$btnEraser = New-Object Windows.Forms.Button
$btnEraser.Text = "Eraser Off"
$btnEraser.Font = $uiFont
$btnEraser.Visible = $false
$btnEraser.Location = New-Object Drawing.Point(-3000,-3000)
$btnEraser.Size = New-Object Drawing.Size(1,1)
$tabDraw.Controls.Add($btnEraser)

$advanceMenu = New-Object Windows.Forms.ContextMenuStrip

$miAdvanceTemplate = New-Object Windows.Forms.ToolStripMenuItem("Choose Template")
$miAdvanceTranslate = New-Object Windows.Forms.ToolStripMenuItem("Translate")
$miAdvanceLanguage = New-Object Windows.Forms.ToolStripMenuItem("Language")
$miAdvanceLanguageEnglish = New-Object Windows.Forms.ToolStripMenuItem("English")
$miAdvanceLanguageVietnamese = New-Object Windows.Forms.ToolStripMenuItem("Tieng Viet")
[void]$miAdvanceLanguage.DropDownItems.Add($miAdvanceLanguageEnglish)
[void]$miAdvanceLanguage.DropDownItems.Add($miAdvanceLanguageVietnamese)
$miAdvanceEditSteps = New-Object Windows.Forms.ToolStripMenuItem("Edit Steps")
$miAdvanceSearchSessions = New-Object Windows.Forms.ToolStripMenuItem("Search Sessions")
$miAdvanceYellowPen = New-Object Windows.Forms.ToolStripMenuItem("Yellow Pen Off")
$miAdvanceEraser = New-Object Windows.Forms.ToolStripMenuItem("Eraser Off")
$miAdvanceSortSteps = New-Object Windows.Forms.ToolStripMenuItem("Sort Steps")
$miAdvanceCopyView = New-Object Windows.Forms.ToolStripMenuItem("Copy View Off")
$miAdvanceAutoMapPdf = New-Object Windows.Forms.ToolStripMenuItem("Auto Map PDF")
$miAdvancePdfTextZones = New-Object Windows.Forms.ToolStripMenuItem("Text Zones Off")
$miAdvanceClearGray = New-Object Windows.Forms.ToolStripMenuItem("Clear Gray Boxes")
$miAdvanceAiModel = New-Object Windows.Forms.ToolStripMenuItem("AI Model")
$miAdvanceAiRecovery = New-Object Windows.Forms.ToolStripMenuItem("Google AI Recovery")
$miAdvanceAiRecovery.ShortcutKeyDisplayString = "Ctrl+S"
$miAdvanceDefaultTolerance = New-Object Windows.Forms.ToolStripMenuItem("Default Tolerance")
$miAdvanceLogHistory = New-Object Windows.Forms.ToolStripMenuItem("Log History")

[void]$advanceMenu.Items.Add($miAdvanceTemplate)
[void]$advanceMenu.Items.Add($miAdvanceLanguage)
[void]$advanceMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$advanceMenu.Items.Add($miAdvanceEditSteps)
[void]$advanceMenu.Items.Add($miAdvanceSearchSessions)
[void]$advanceMenu.Items.Add($miAdvanceYellowPen)
[void]$advanceMenu.Items.Add($miAdvanceEraser)
[void]$advanceMenu.Items.Add($miAdvanceSortSteps)
[void]$advanceMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$advanceMenu.Items.Add($miAdvanceCopyView)
[void]$advanceMenu.Items.Add($miAdvanceAiModel)
[void]$advanceMenu.Items.Add($miAdvanceAiRecovery)
[void]$advanceMenu.Items.Add($miAdvancePdfTextZones)
[void]$advanceMenu.Items.Add($miAdvanceAutoMapPdf)
[void]$advanceMenu.Items.Add($miAdvanceClearGray)
[void]$advanceMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$advanceMenu.Items.Add($miAdvanceDefaultTolerance)
[void]$advanceMenu.Items.Add($miAdvanceLogHistory)

$miAdvanceDefaultTolerance.Add_Click({
    Show-CommercialDefaultToleranceDialog
})

$miAdvanceLogHistory.Add_Click({
    Show-CommercialLogHistoryDialog
})

$btnEditStep = New-Object Windows.Forms.Button
$btnEditStep.Text = "Edit Steps"
$btnEditStep.Font = $uiFont

$btnSortStepAsc = New-Object Windows.Forms.Button
$btnSortStepAsc.Text = "Sort Steps"
$btnSortStepAsc.Font = $uiFont

# ===============================
# BUTTON: CHOOSE TEMPLATE
# ===============================
$btnTemplate = New-Object System.Windows.Forms.Button
$btnTemplate.Text = "Choose Template"
$btnTemplate.Font = $uiBoldFont
$btnTemplate.Size = New-Object System.Drawing.Size(120,34)
$btnTemplate.Location = New-Object System.Drawing.Point(1250,20)


# ==============================
# BUTTON: EXPORT EXCEL
# ===============================
$btnExcel = New-Object System.Windows.Forms.Button
$btnExcel.Text = "Export Excel"
$btnExcel.Font = $uiBoldFont
$btnExcel.Size = New-Object System.Drawing.Size(120,34)
$btnExcel.Location = New-Object System.Drawing.Point(1250,80)

$tabDraw.Controls.Add($btnExcel)

$btnCopyView = New-Object System.Windows.Forms.Button
$btnCopyView.Text = "Copy View Off"
$btnCopyView.Font = $uiFont
$btnCopyView.Size = New-Object System.Drawing.Size(120,28)
$btnCopyView.Location = New-Object System.Drawing.Point(1250,114)

$btnAutoMapPdf = New-Object System.Windows.Forms.Button
$btnAutoMapPdf.Text = "Auto Map PDF"
$btnAutoMapPdf.Font = $uiFont
$btnAutoMapPdf.Size = New-Object System.Drawing.Size(150,28)
$btnAutoMapPdf.Location = New-Object System.Drawing.Point(1250,146)

$btnPdfTextZones = New-Object System.Windows.Forms.Button
$btnPdfTextZones.Text = "Text Zones Off"
$btnPdfTextZones.Font = $uiFont
$btnPdfTextZones.Size = New-Object System.Drawing.Size(150,28)
$btnPdfTextZones.Location = New-Object System.Drawing.Point(1410,146)

$btnClearGrayZones = New-Object System.Windows.Forms.Button
$btnClearGrayZones.Text = "Clear Gray Boxes"
$btnClearGrayZones.Font = $uiFont
$btnClearGrayZones.Size = New-Object System.Drawing.Size(150,28)
$btnClearGrayZones.Location = New-Object System.Drawing.Point(1250,178)

# =========================
# Save MarkImage
# =========================
$btnSave = New-Object Windows.Forms.Button
$btnSave.Text = "Export PDF"
$btnSave.Font = $buttonFont
$btnSave.Location = New-Object Drawing.Point(1250,320)
$btnSave.Width = 150
$btnSave.Visible = $false
# =========================
# OCR RESULT TABLE
# =========================

$table = New-Object System.Windows.Forms.DataGridView
$table.Location = New-Object System.Drawing.Point(10,10)
$table.Size = New-Object System.Drawing.Size(1200,800)

# -------- Columns --------
[void]$table.Columns.Add("Step","No.")
[void]$table.Columns.Add("Nominal","Nominal")
[void]$table.Columns.Add("TolMinus","Tol -")
[void]$table.Columns.Add("TolPlus","Tol +")
[void]$table.Columns.Add("Result","Result")
[void]$table.Columns.Add("Duplicate","Dup")
[void]$table.Columns.Add("Position","Position")
[void]$table.Columns.Add("Flag","Status")
$importantColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$importantColumn.Name = "Important"
$importantColumn.HeaderText = "Important"
$importantColumn.ThreeState = $false
$importantColumn.TrueValue = $true
$importantColumn.FalseValue = $false
$importantColumn.IndeterminateValue = $false
$importantColumn.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
[void]$table.Columns.Add($importantColumn)

# -------- Column Sizing --------
$table.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$table.Columns[0].FillWeight = 11
$table.Columns[1].FillWeight = 33
$table.Columns[2].FillWeight = 14
$table.Columns[3].FillWeight = 14
$table.Columns[4].FillWeight = 1
$table.Columns[5].FillWeight = 1
$table.Columns[6].FillWeight = 1
$table.Columns[7].FillWeight = 16
$table.Columns[8].FillWeight = 12

$table.Columns[0].MinimumWidth = 52
$table.Columns[1].MinimumWidth = 110
$table.Columns[2].MinimumWidth = 72
$table.Columns[3].MinimumWidth = 72
$table.Columns[4].MinimumWidth = 2
$table.Columns[5].MinimumWidth = 2
$table.Columns[6].MinimumWidth = 2
$table.Columns[7].MinimumWidth = 92
$table.Columns[8].MinimumWidth = 88

# -------- Table Behavior --------
$table.RowHeadersVisible = $false
$table.AllowUserToAddRows = $false
$table.AllowUserToDeleteRows = $false
$table.AllowUserToResizeRows = $false
$table.AllowUserToResizeColumns = $false

$table.SelectionMode = "FullRowSelect"
$table.MultiSelect = $false

# -------- Readability --------
$table.Font = New-Object System.Drawing.Font("Segoe UI",10)
$table.RowTemplate.Height = 28
$table.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$table.ColumnHeadersHeight = 32
$table.Columns[7].DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(2,0,2,0)
$table.Columns[8].DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8,0,8,0)

# -------- Duplicate / Position Column Style --------
$table.Columns[4].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245,252,255)
$table.Columns[4].Visible = $false
$table.Columns[5].Visible = $false
$table.Columns[6].Visible = $false
$table.Columns[5].ReadOnly = $true
$table.Columns[6].ReadOnly = $true
$table.Columns[7].ReadOnly = $true
$table.Columns[8].ReadOnly = $false
$table.Columns[6].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Blue
$table.Columns[6].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Underline)
$table.Columns[7].DefaultCellStyle.NullValue = ""
$table.Columns[8].DefaultCellStyle.NullValue = $false

# lock columns
$table.Columns[0].ReadOnly = $true
$table.Columns[5].ReadOnly = $true
$table.Columns[6].ReadOnly = $true

# center text
for($i=0;$i -lt $table.Columns.Count;$i++){
    $table.Columns[$i].DefaultCellStyle.Alignment = "MiddleCenter"
    $table.Columns[$i].SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
}
$table.Add_CellPainting({
    param($sender,$e)

    if($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0){ return }
    if($table.Columns[$e.ColumnIndex].Name -ne "Flag"){ return }

    $e.PaintBackground($e.CellBounds,$true)
    $duplicateValue = [string]$table.Rows[$e.RowIndex].Cells["Duplicate"].Value
    $flagValue = if($null -eq $e.Value){ "" } else { ([string]$e.Value).Trim().ToUpperInvariant() }
    $statusParts = New-Object System.Collections.Generic.List[string]
    $tagTextColor = [System.Drawing.Color]::FromArgb(255,110,110,110)

    if(-not [string]::IsNullOrWhiteSpace($duplicateValue)){
        [void]$statusParts.Add("Dup")
        $tagTextColor = [System.Drawing.Color]::FromArgb(255,176,92,0)
    }

    switch($flagValue){
        "B" {
            [void]$statusParts.Add("B")
            if($statusParts.Count -eq 1){
                $tagTextColor = [System.Drawing.Color]::FromArgb(255,196,72,0)
            }
        }
        "I" {
            [void]$statusParts.Add("Imp")
            if($statusParts.Count -eq 1){
                $tagTextColor = [System.Drawing.Color]::FromArgb(255,196,72,0)
            }
        }
    }

    $stateText = ($statusParts -join " | ")
    if(-not [string]::IsNullOrWhiteSpace($stateText)){
        $textRect = New-Object System.Drawing.Rectangle(
            ($e.CellBounds.X + 4),
            $e.CellBounds.Y,
            [Math]::Max(0,($e.CellBounds.Width - 8)),
            $e.CellBounds.Height
        )
        [System.Windows.Forms.TextRenderer]::DrawText(
            $e.Graphics,
            $stateText,
            $tagFont,
            $textRect,
            $tagTextColor,
            ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter)
        )
    }

    $e.Handled = $true
})
# position jump
$table.Add_CellClick({

    $row = $_.RowIndex
    $col = $_.ColumnIndex

    if($row -lt 0){ return }

    if($table.Columns[$col].Name -ne "Position"){ return }

    if(!$script:StepRects.ContainsKey($row)){ return }

    $rect = $script:StepRects[$row]

    Focus-OnRect $rect

})
$tabDraw.Controls.Add($table)

$grpTableResult = New-Object Windows.Forms.GroupBox
$grpTableResult.Text = "OCR Results"
$grpTableResult.Font = $groupFont
$grpTableResult.Location = New-Object Drawing.Point(1240,450)
$grpTableResult.Size = New-Object Drawing.Size(400,260)
$tabDraw.Controls.Add($grpTableResult)

$lblTableSearch = New-Object Windows.Forms.Label
$lblTableSearch.Text = "Search OCR #"
$lblTableSearch.Font = $uiFont
$lblTableSearch.AutoSize = $true
$tabDraw.Controls.Add($lblTableSearch)

$txtTableSearch = New-Object Windows.Forms.TextBox
$txtTableSearch.Font = $uiFont
$tabDraw.Controls.Add($txtTableSearch)

$txtCopiedUi = New-Object Windows.Forms.TextBox
$txtCopiedUi.Font = $uiFont
$txtCopiedUi.ReadOnly = $true
$txtCopiedUi.Visible = $false
$tabDraw.Controls.Add($txtCopiedUi)

foreach($textInput in @($txtTol0,$txtTol1,$txtTol2,$txtTol3,$txtTableSearch)){
    $textInput.Add_Enter({
        Set-LastTextInsertTarget $this
    })
    $textInput.Add_MouseDown({
        Set-LastTextInsertTarget $this
    })
}

$table.Add_EditingControlShowing({
    param($sender,$e)
    if($e.Control -is [System.Windows.Forms.TextBoxBase]){
        Set-LastTextInsertTarget $e.Control
        $e.Control.Add_Enter({
            Set-LastTextInsertTarget $this
        })
    }
})
$table.Add_RowsAdded({ Schedule-CommercialUiRefresh })
$table.Add_RowsRemoved({ Schedule-CommercialUiRefresh })
$table.Add_SelectionChanged({ Schedule-CommercialUiRefresh })

function Set-CommercialUiLanguage([string]$language){
    $isVietnamese = ([string]$language -eq "vi")
    $script:CommercialUiLanguage = if($isVietnamese){ "vi" } else { "en" }

    if($form){ $form.Text = if($isVietnamese){ "RapidOCR - Cong cu quet ban ve PDF" } else { "RapidOCR PDF Scan Tool" } }
    if($btnLoad){ $btnLoad.Text = if($isVietnamese){ "Mo PDF" } else { "Open PDF" } }
    if($btnExcel){ $btnExcel.Text = if($isVietnamese){ "Xuat Excel" } else { "Export Excel" } }
    if($btnAdvance){ $btnAdvance.Text = if($isVietnamese){ "Nang cao" } else { "Advanced" } }
    if($btnSave){ $btnSave.Text = if($isVietnamese){ "Xuat PDF" } else { "Export PDF" } }
    if($btnTemplate){ $btnTemplate.Text = if($isVietnamese){ "Chon mau" } else { "Choose Template" } }
    if($btnEditStep){ $btnEditStep.Text = if($isVietnamese){ "Sua step" } else { "Edit Steps" } }
    if($btnSortStepAsc){ $btnSortStepAsc.Text = if($isVietnamese){ "Sap xep step" } else { "Sort Steps" } }
    if($btnCopyView){ $btnCopyView.Text = if($isVietnamese){ "Copy View Tat" } else { "Copy View Off" } }
    if($btnAutoMapPdf){ $btnAutoMapPdf.Text = if($isVietnamese){ "Tu map PDF" } else { "Auto Map PDF" } }
    if($btnPdfTextZones){ $btnPdfTextZones.Text = if($isVietnamese){ "Text Zones Tat" } else { "Text Zones Off" } }
    if($btnClearGrayZones){ $btnClearGrayZones.Text = if($isVietnamese){ "Xoa vung xam" } else { "Clear Gray Boxes" } }
    if($btnAiUseEnv){ $btnAiUseEnv.Text = if($isVietnamese){ "Quet lai AI" } else { "Rescan AI" } }
    if($btnAiTest){ $btnAiTest.Text = if($isVietnamese){ "Thu AI" } else { "Test AI Only" } }
    if($btnAiAccept){ $btnAiAccept.Text = if($isVietnamese){ "Nhan AI" } else { "Accept AI" } }
    if($btnAiClear){ $btnAiClear.Text = if($isVietnamese){ "Xoa" } else { "Clear" } }
    if($chkAiTestOnly){ $chkAiTestOnly.Text = if($isVietnamese){ "Chi test AI" } else { "AI test only on" } }
    if($chkAiExperiment){ $chkAiExperiment.Text = if($isVietnamese){ "Che do thu nghiem" } else { "Experiment mode" } }
    if($btnYellowPen){ $btnYellowPen.Text = if($isVietnamese){ "But vang Tat" } else { "Yellow Pen Off" } }
    if($btnEraser){ $btnEraser.Text = if($isVietnamese){ "Tay Tat" } else { "Eraser Off" } }
    if($btnPrevPage){ $btnPrevPage.Text = if($isVietnamese){ "Trang truoc" } else { "Previous" } }
    if($btnNextPage){ $btnNextPage.Text = if($isVietnamese){ "Trang sau" } else { "Next" } }

    if($grpTableResult){ $grpTableResult.Text = if($isVietnamese){ "Ket qua OCR" } else { "OCR Results" } }
    if($grpDefaultTol){ $grpDefaultTol.Text = if($isVietnamese){ "Dung sai mac dinh" } else { "Default Tolerance" } }
    if($grpOcrDebug){ $grpOcrDebug.Text = if($isVietnamese){ "Nhat ky OCR" } else { "OCR Debug" } }
    if($grpAiVision){ $grpAiVision.Text = if($isVietnamese){ "AI Vision" } else { "AI Vision" } }
    if($grpTolMode){ $grpTolMode.Text = if($isVietnamese){ "Che do dung sai" } else { "Tolerance Mode" } }
    if($grpPreset){ $grpPreset.Text = if($isVietnamese){ "Dung sai" } else { "Tolerance" } }
    if($lblPreviewTitle){ $lblPreviewTitle.Text = if($isVietnamese){ "Xem truoc OCR" } else { "OCR Preview" } }
    if($lblTableSearch){ $lblTableSearch.Text = if($isVietnamese){ "Tim" } else { "Search" } }
    if($lblAiModel){ $lblAiModel.Text = if($isVietnamese){ "Model" } else { "Model" } }

    if($table){
        try{
            $table.Columns["Step"].HeaderText = if($isVietnamese){ "So" } else { "No." }
            $table.Columns["Nominal"].HeaderText = if($isVietnamese){ "Kich thuoc" } else { "Nominal" }
            $table.Columns["TolMinus"].HeaderText = "Tol -"
            $table.Columns["TolPlus"].HeaderText = "Tol +"
            $table.Columns["Duplicate"].HeaderText = if($isVietnamese){ "Trung" } else { "Dup" }
            $table.Columns["Flag"].HeaderText = if($isVietnamese){ "Trang thai" } else { "Status" }
            $table.Columns["Important"].HeaderText = if($isVietnamese){ "Quan trong" } else { "Important" }
        }
        catch{}
    }

    if($miAdvanceTemplate){ $miAdvanceTemplate.Text = if($isVietnamese){ "Chon mau" } else { "Choose Template" } }
    if($miAdvanceLanguage){ $miAdvanceLanguage.Text = if($isVietnamese){ "Ngon ngu" } else { "Language" } }
    if($miAdvanceLanguageEnglish){ $miAdvanceLanguageEnglish.Text = "English"; $miAdvanceLanguageEnglish.Checked = -not $isVietnamese }
    if($miAdvanceLanguageVietnamese){ $miAdvanceLanguageVietnamese.Text = "Tieng Viet"; $miAdvanceLanguageVietnamese.Checked = $isVietnamese }
    if($miAdvanceEditSteps){ $miAdvanceEditSteps.Text = if($isVietnamese){ "Sua step" } else { "Edit Steps" } }
    if($miAdvanceSearchSessions){ $miAdvanceSearchSessions.Text = if($isVietnamese){ "Tim session" } else { "Search Sessions" } }
    if($miAdvanceYellowPen){ $miAdvanceYellowPen.Text = if($isVietnamese){ "But vang Tat" } else { "Yellow Pen Off" } }
    if($miAdvanceEraser){ $miAdvanceEraser.Text = if($isVietnamese){ "Tay Tat" } else { "Eraser Off" } }
    if($miAdvanceSortSteps){ $miAdvanceSortSteps.Text = if($isVietnamese){ "Sap xep step" } else { "Sort Steps" } }
    if($miAdvanceCopyView){ $miAdvanceCopyView.Text = if($isVietnamese){ "Copy View Tat" } else { "Copy View Off" } }
    if($miAdvanceAutoMapPdf){ $miAdvanceAutoMapPdf.Text = if($isVietnamese){ "Tu map PDF" } else { "Auto Map PDF" } }
    if($miAdvancePdfTextZones){ $miAdvancePdfTextZones.Text = if($isVietnamese){ "Text Zones Tat" } else { "Text Zones Off" } }
    if($miAdvanceClearGray){ $miAdvanceClearGray.Text = if($isVietnamese){ "Xoa vung xam" } else { "Clear Gray Boxes" } }
    if($miAdvanceAiModel){ $miAdvanceAiModel.Text = if($isVietnamese){ "Model AI" } else { "AI Model" } }
    if($miAdvanceAiRecovery){ $miAdvanceAiRecovery.Text = if($isVietnamese){ "Sua bang Google AI" } else { "Google AI Recovery" } }
    if($miAdvanceDefaultTolerance){ $miAdvanceDefaultTolerance.Text = if($isVietnamese){ "Dung sai mac dinh" } else { "Default Tolerance" } }
    if($miAdvanceLogHistory){ $miAdvanceLogHistory.Text = if($isVietnamese){ "Lich su log" } else { "Log History" } }

    Schedule-CommercialUiRefresh
}

if($miAdvanceLanguageEnglish){
    $miAdvanceLanguageEnglish.Add_Click({ Set-CommercialUiLanguage "en" })
}
if($miAdvanceLanguageVietnamese){
    $miAdvanceLanguageVietnamese.Add_Click({ Set-CommercialUiLanguage "vi" })
}
if($miAdvanceAiRecovery){
    $miAdvanceAiRecovery.Add_Click({
        if((Get-SelectedStepRowIndex) -ge 0){
            Invoke-AiRecoveryModeForSelectedStep
        }
    })
}

$btnAiUseEnv.Add_Click({
    Invoke-AiVisionRescanSelectedStep
})

$cmbAiModel.Add_TextChanged({
    Update-CommercialAiModelMenu
})

Refresh-CommercialOllamaModelList

Set-CommercialUiLanguage "en"
Update-CommercialTolerancePresetState
Schedule-CommercialUiRefresh
$form.Add_Shown({ Schedule-CommercialUiRefresh })
$form.Add_Resize({ Schedule-CommercialUiRefresh })
$tabDraw.Add_Resize({ Schedule-CommercialUiRefresh })

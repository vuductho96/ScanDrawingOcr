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
$tabDraw.Controls.Add($btnPrevPage)

$lblPageInfo = New-Object Windows.Forms.Label
$lblPageInfo.Text = ""
$lblPageInfo.Font = $uiBoldFont
$lblPageInfo.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$tabDraw.Controls.Add($lblPageInfo)

$btnNextPage = New-Object Windows.Forms.Button
$btnNextPage.Text = "Next"
$btnNextPage.Font = $uiFont
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

$picture = New-Object Windows.Forms.Panel
Enable-DoubleBuffer $picture
$picture.Dock = "Fill"
$picture.BackColor = [System.Drawing.Color]::White
$picture.TabStop = $true
$script:CanvasControl = $picture
$viewer.Controls.Add($picture)

$pnlAiRecoveryOverlay = New-Object Windows.Forms.Panel
$pnlAiRecoveryOverlay.Dock = "Fill"
$pnlAiRecoveryOverlay.BackColor = [System.Drawing.Color]::FromArgb(210,25,25,25)
$pnlAiRecoveryOverlay.Visible = $false
$pnlAiRecoveryOverlay.Enabled = $true
$pnlAiRecoveryOverlay.BringToFront()
$form.Controls.Add($pnlAiRecoveryOverlay)
$pnlAiRecoveryOverlay.BringToFront()

$lblAiRecoveryOverlay = New-Object Windows.Forms.Label
$lblAiRecoveryOverlay.AutoSize = $false
$lblAiRecoveryOverlay.Dock = "Fill"
$lblAiRecoveryOverlay.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblAiRecoveryOverlay.Font = New-Object System.Drawing.Font("Segoe UI",20,[System.Drawing.FontStyle]::Bold)
$lblAiRecoveryOverlay.ForeColor = [System.Drawing.Color]::White
$lblAiRecoveryOverlay.BackColor = [System.Drawing.Color]::Transparent
$lblAiRecoveryOverlay.Text = "AI Recovery is processing..." + [Environment]::NewLine + "Please do not use Chrome until this finishes."
$pnlAiRecoveryOverlay.Controls.Add($lblAiRecoveryOverlay)

# =========================
# Default tolerance
# =========================

$grpDefaultTol = New-Object Windows.Forms.GroupBox
$grpDefaultTol.Text = "Default Tolerance"
$grpDefaultTol.Font = $groupFont
$grpDefaultTol.Location = New-Object Drawing.Point(1250,660)
$grpDefaultTol.Size = New-Object Drawing.Size(220,130)
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
$tabDraw.Controls.Add($grpOcrDebug)

$txtOcrDebug = New-Object Windows.Forms.TextBox
$txtOcrDebug.Font = New-Object System.Drawing.Font("Consolas",8)
$txtOcrDebug.Location = New-Object Drawing.Point(10,22)
$txtOcrDebug.Size = New-Object Drawing.Size(380,88)
$txtOcrDebug.Multiline = $true
$txtOcrDebug.ReadOnly = $true
$txtOcrDebug.ScrollBars = "Vertical"
$txtOcrDebug.WordWrap = $false
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
$cmbAiModel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbAiModel.Location = New-Object Drawing.Point(62,22)
$cmbAiModel.Size = New-Object Drawing.Size(192,28)
[void]$cmbAiModel.Items.AddRange(@(
    "ollama:qwen2.5vl:3b",
    "ollama:minicpm-v"
))
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
$grpPreset.Text = "Tolerance Preset"
$grpPreset.Font = $groupFont
$grpPreset.Location = New-Object Drawing.Point(1250,390)
$grpPreset.Size = New-Object Drawing.Size(400,188)

$tabDraw.Controls.Add($grpPreset)

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
    })

    $grpPreset.Controls.Add($btn)

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
$tabDraw.Controls.Add($btnTranslateLens)

$btnAdvance = New-Object Windows.Forms.Button
$btnAdvance.Text = "Advance"
$btnAdvance.Font = $uiFont
$tabDraw.Controls.Add($btnAdvance)

$btnToggleSidePanel = New-Object Windows.Forms.Button
$btnToggleSidePanel.Text = ">"
$btnToggleSidePanel.Font = New-Object System.Drawing.Font("Segoe UI",11,[System.Drawing.FontStyle]::Bold)
$btnToggleSidePanel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnToggleSidePanel.FlatAppearance.BorderColor = [System.Drawing.Color]::Gainsboro
$btnToggleSidePanel.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(235,242,250)
$btnToggleSidePanel.TabStop = $false
$tabDraw.Controls.Add($btnToggleSidePanel)

$btnYellowPen = New-Object Windows.Forms.Button
$btnYellowPen.Text = "Yellow Pen Off"
$btnYellowPen.Font = $uiFont
$tabDraw.Controls.Add($btnYellowPen)

$btnEraser = New-Object Windows.Forms.Button
$btnEraser.Text = "Eraser Off"
$btnEraser.Font = $uiFont
$tabDraw.Controls.Add($btnEraser)

$advanceMenu = New-Object Windows.Forms.ContextMenuStrip

$miAdvanceTemplate = New-Object Windows.Forms.ToolStripMenuItem("Choose Template")
$miAdvanceTranslate = New-Object Windows.Forms.ToolStripMenuItem("Translate")
$miAdvanceEditSteps = New-Object Windows.Forms.ToolStripMenuItem("Edit Steps")
$miAdvanceSearchSessions = New-Object Windows.Forms.ToolStripMenuItem("Search Sessions")
$miAdvanceYellowPen = New-Object Windows.Forms.ToolStripMenuItem("Yellow Pen Off")
$miAdvanceEraser = New-Object Windows.Forms.ToolStripMenuItem("Eraser Off")
$miAdvanceSortSteps = New-Object Windows.Forms.ToolStripMenuItem("Sort Steps")
$miAdvanceCopyView = New-Object Windows.Forms.ToolStripMenuItem("Copy View Off")
$miAdvanceAutoMapPdf = New-Object Windows.Forms.ToolStripMenuItem("Auto Map PDF")
$miAdvancePdfTextZones = New-Object Windows.Forms.ToolStripMenuItem("Text Zones Off")
$miAdvanceToggleSidePanel = New-Object Windows.Forms.ToolStripMenuItem("Hide Side Panel")
$miAdvanceToggleSidePanel.ShortcutKeyDisplayString = "Ctrl+B"
$miAdvanceClearGray = New-Object Windows.Forms.ToolStripMenuItem("Clear Gray Boxes")
$miAdvanceAiModel = New-Object Windows.Forms.ToolStripMenuItem("AI Model")
$miAdvanceAiModelQwen = New-Object Windows.Forms.ToolStripMenuItem("Qwen2.5VL 3B")
$miAdvanceAiModelMiniCpm = New-Object Windows.Forms.ToolStripMenuItem("MiniCPM-V")
[void]$miAdvanceAiModel.DropDownItems.Add($miAdvanceAiModelQwen)
[void]$miAdvanceAiModel.DropDownItems.Add($miAdvanceAiModelMiniCpm)

$miAdvanceEditMenu = New-Object Windows.Forms.ToolStripMenuItem("Edit")
$miAdvanceViewMenu = New-Object Windows.Forms.ToolStripMenuItem("View")
$miAdvanceOcrMenu = New-Object Windows.Forms.ToolStripMenuItem("OCR")
$miAdvanceDevMenu = New-Object Windows.Forms.ToolStripMenuItem("Developer")
$miAdvanceDangerMenu = New-Object Windows.Forms.ToolStripMenuItem("Danger")

$miAdvanceBalloonColor = New-Object Windows.Forms.ToolStripMenuItem("Balloon Color")
$miAdvanceBalloonWhite = New-Object Windows.Forms.ToolStripMenuItem("White")
$miAdvanceBalloonYellow = New-Object Windows.Forms.ToolStripMenuItem("Yellow")
$miAdvanceBalloonBlue = New-Object Windows.Forms.ToolStripMenuItem("Blue")
$miAdvanceBalloonGreen = New-Object Windows.Forms.ToolStripMenuItem("Green")
$miAdvanceBalloonOrange = New-Object Windows.Forms.ToolStripMenuItem("Orange")
[void]$miAdvanceBalloonColor.DropDownItems.Add($miAdvanceBalloonWhite)
[void]$miAdvanceBalloonColor.DropDownItems.Add($miAdvanceBalloonYellow)
[void]$miAdvanceBalloonColor.DropDownItems.Add($miAdvanceBalloonBlue)
[void]$miAdvanceBalloonColor.DropDownItems.Add($miAdvanceBalloonGreen)
[void]$miAdvanceBalloonColor.DropDownItems.Add($miAdvanceBalloonOrange)

$miAdvanceTrainingExport = New-Object Windows.Forms.ToolStripMenuItem("Training Save/Export On")

[void]$miAdvanceEditMenu.DropDownItems.Add($miAdvanceTemplate)
[void]$miAdvanceEditMenu.DropDownItems.Add($miAdvanceEditSteps)
[void]$miAdvanceEditMenu.DropDownItems.Add($miAdvanceSearchSessions)
[void]$miAdvanceEditMenu.DropDownItems.Add($miAdvanceSortSteps)

[void]$miAdvanceViewMenu.DropDownItems.Add($miAdvanceCopyView)
[void]$miAdvanceViewMenu.DropDownItems.Add($miAdvancePdfTextZones)
[void]$miAdvanceViewMenu.DropDownItems.Add($miAdvanceToggleSidePanel)
[void]$miAdvanceViewMenu.DropDownItems.Add($miAdvanceAutoMapPdf)
[void]$miAdvanceViewMenu.DropDownItems.Add($miAdvanceClearGray)
[void]$miAdvanceViewMenu.DropDownItems.Add($miAdvanceBalloonColor)

[void]$miAdvanceOcrMenu.DropDownItems.Add($miAdvanceTranslate)
[void]$miAdvanceOcrMenu.DropDownItems.Add($miAdvanceAiModel)

[void]$miAdvanceDevMenu.DropDownItems.Add($miAdvanceYellowPen)
[void]$miAdvanceDevMenu.DropDownItems.Add($miAdvanceEraser)
[void]$miAdvanceDevMenu.DropDownItems.Add($miAdvanceTrainingExport)

[void]$advanceMenu.Items.Add($miAdvanceEditMenu)
[void]$advanceMenu.Items.Add($miAdvanceViewMenu)
[void]$advanceMenu.Items.Add($miAdvanceOcrMenu)
[void]$advanceMenu.Items.Add($miAdvanceDevMenu)
[void]$advanceMenu.Items.Add($miAdvanceDangerMenu)

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
[void]$table.Columns.Add("Step","Step")
[void]$table.Columns.Add("Nominal","Nominal")
[void]$table.Columns.Add("TolMinus","Tol -")
[void]$table.Columns.Add("TolPlus","Tol +")
[void]$table.Columns.Add("Result","Result")
[void]$table.Columns.Add("Duplicate","Dup")
[void]$table.Columns.Add("Position","Position")
[void]$table.Columns.Add("Flag","Flag")
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
$table.Columns[0].FillWeight = 12
$table.Columns[1].FillWeight = 28
$table.Columns[2].FillWeight = 15
$table.Columns[3].FillWeight = 15
$table.Columns[4].FillWeight = 18
$table.Columns[5].FillWeight = 10
$table.Columns[6].FillWeight = 1
$table.Columns[7].FillWeight = 8
$table.Columns[8].FillWeight = 14

$table.Columns[0].MinimumWidth = 50
$table.Columns[1].MinimumWidth = 90
$table.Columns[2].MinimumWidth = 65
$table.Columns[3].MinimumWidth = 65
$table.Columns[4].MinimumWidth = 80
$table.Columns[5].MinimumWidth = 48
$table.Columns[6].MinimumWidth = 2
$table.Columns[7].MinimumWidth = 42
$table.Columns[8].MinimumWidth = 82

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
$table.Columns[5].ReadOnly = $true
$table.Columns[6].ReadOnly = $true
$table.Columns[7].ReadOnly = $true
$table.Columns[8].ReadOnly = $false
$table.Columns[6].Visible = $false
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

    $stateText = ""
    $stateValue = if($null -eq $e.Value){ "" } else { ([string]$e.Value).Trim().ToUpperInvariant() }
    $e.PaintBackground($e.CellBounds,$true)

    switch($stateValue){
        "B" {
            $stateText = "B"
            $tagTextColor = [System.Drawing.Color]::FromArgb(255,196,72,0)
        }
        "I" {
            $stateText = "I"
            $tagTextColor = [System.Drawing.Color]::FromArgb(255,196,72,0)
        }
        default {
            $stateText = ""
        }
    }

    if(-not [string]::IsNullOrWhiteSpace($stateText)){
        $textRect = New-Object System.Drawing.Rectangle(
            ($e.CellBounds.X + 2),
            $e.CellBounds.Y,
            [Math]::Max(0,($e.CellBounds.Width - 4)),
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

$lblTableSearch = New-Object Windows.Forms.Label
$lblTableSearch.Text = "Search OCR #"
$lblTableSearch.Font = $uiFont
$lblTableSearch.AutoSize = $true
$tabDraw.Controls.Add($lblTableSearch)

$txtTableSearch = New-Object Windows.Forms.TextBox
$txtTableSearch.Font = $uiFont
$tabDraw.Controls.Add($txtTableSearch)

$btnResultsView = New-Object Windows.Forms.Button
$btnResultsView.Text = "Results View"
$btnResultsView.Font = $uiFont
$tabDraw.Controls.Add($btnResultsView)

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

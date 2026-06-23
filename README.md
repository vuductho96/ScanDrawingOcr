# ScanDrawingOcr

PowerShell-based OCR and inspection assistant for technical drawings.

Designed for QA, dimensional inspection, injection molding, manufacturing engineering, and drawing review workflows where operators need to quickly extract dimensions from PDF drawings, create inspection steps, recover failed OCR results, and export inspection reports.

---

# Overview

ScanDrawingOcr is a desktop OCR tool built around a PDF drawing workspace.

Instead of manually reading dimensions from engineering drawings and typing them into Excel inspection sheets, the tool allows users to:

* Open drawing PDFs
* Create MarkSteps directly on drawings
* OCR dimensions and tolerances
* Recover OCR failures using AI Vision
* Track inspection steps
* Highlight important dimensions
* Export inspection reports
* Export marked-up PDFs
* Save and restore inspection sessions

The project is optimized for manufacturing environments where hundreds of dimensions must be processed quickly.

---

# Main Features

## PDF Drawing Workspace

* Open multi-page PDF drawings
* Fast PDF rendering through PDFium
* Page navigation
* Zoom at cursor
* Drawing pan mode
* Page rotation
* Fit-screen view
* Actual-size view
* Session persistence
* Cached page rendering

---

## MarkStep System

The core workflow revolves around MarkSteps.

A MarkStep represents a dimension or inspection point on the drawing.

Each MarkStep stores:

* Step Number
* Nominal Value
* Tolerance -
* Tolerance +
* Result
* Tool Type
* Important Flag
* Position on Drawing

Capabilities:

* Create new MarkSteps
* Move MarkSteps
* Copy/Paste MarkSteps
* Duplicate MarkSteps
* Delete MarkSteps
* Renumber MarkSteps
* Color-coded MarkSteps
* Important Step highlighting

---

## OCR System

Supported OCR workflows:

### PDF Text Layer Detection

Reads dimensions directly from embedded PDF text when available.

Advantages:

* Fast
* Accurate
* No OCR required

---

### Image OCR

Used when PDF text layer is unavailable.

Supports:

* Cropped OCR regions
* Manual OCR zones
* Batch OCR
* Hidden text recovery

---

### Manual Bounding Box OCR

Allows users to manually draw OCR regions.

Useful for:

* Poor scans
* Complex drawings
* Rotated dimensions
* OCR recovery cases

---

## AI Vision Recovery

When OCR fails, the system can send the selected crop to AI Vision models.

Supported modes:

### Gemini Vision

Cloud-based AI recovery.

Useful for:

* Complex dimensions
* Poor scan quality
* Multi-line tolerances

---

### Ollama Vision

Local AI recovery.

Example model:

```text
qwen2.5vl:3b
```

Useful when:

* Data must remain local
* Internet is unavailable
* Fast repeated recovery is required

---

## Mechanical Dimension Parsing

The parser supports common engineering formats:

Examples:

```text
12.500 ±0.020

12.500 +0.020
       -0.010

R5.00

Ø3.20

90°
```

Automatically extracts:

* Nominal
* Minus tolerance
* Plus tolerance

---

## Important Step Workflow

Inspection-critical dimensions can be flagged.

Benefits:

* Visual highlighting
* Easy filtering
* Dedicated export workflows
* Focus inspection review

---

## Export Functions

### Excel Export

Generate inspection sheets from collected MarkSteps.

Exports:

* Step Number
* Nominal
* Tolerances
* Results
* Notes

---

### PDF Export

Generate marked drawing PDFs containing:

* Balloons
* Step numbers
* Important step indicators

---

### Session Export

Save and reload inspection progress.

---

# AI Functions

The project includes AI-assisted dimension recovery.

Typical workflow:

1. OCR fails
2. User selects dimension
3. AI Vision receives crop
4. AI returns:

```text
Nominal
Tol -
Tol +
```

5. User accepts result

---

# Main Files

## RapidOcrProUpdate.ps1

Primary application logic.

Contains:

* OCR workflow
* PDF processing
* AI recovery
* Session handling
* Export functions
* MarkStep management

---

## RapidOcrProUpdate.UI.ps1

Windows Forms user interface.

Contains:

* Drawing workspace
* Toolbars
* OCR controls
* AI controls
* Results table
* Export UI

---

## AiDrawingExtractor.ps1

Drawing extraction helper.

---

## WindowsOcr_Helper.ps1

Windows OCR integration.

---

## RapidOcrProUpdate.ManualBBoxBatchOCR.ps1

Manual bounding-box OCR workflow.

---

## RapidOcrProUpdate.Training.ps1

Training support.

---

## RapidOcrProUpdate.Training.Export.ps1

Training export support.

---

# Dependencies

Required:

```text
PdfiumViewer.dll
pdfium.dll
lib/
```

Recommended:

* Windows 10+
* PowerShell 7
* .NET Runtime

Optional:

* Gemini API Key
* Ollama

---

# Keyboard Shortcuts

| Key                 | Action                                 |
| ------------------- | -------------------------------------- |
| Space Hold          | Pan Mode                               |
| Middle Mouse Drag   | Pan Drawing                            |
| Space + Left Drag   | Pan Drawing                            |
| Mouse Wheel         | Zoom At Cursor                         |
| Shift + Mouse Wheel | Zoom + Horizontal Scroll               |
| Esc                 | Cancel Selection / Close Lens          |
| Enter               | Accept Hidden Text Zone                |
| E                   | Keep Hidden Duplicate Candidate        |
| Ctrl + Shift + R    | Rotate Page 90°                        |
| Ctrl + R            | AI Vision Rescan                       |
| Ctrl + B            | Toggle Draw Side Panel                 |
| Ctrl + S            | AI Recovery For Selected Step          |
| Ctrl + Z            | Undo Deleted Step                      |
| Ctrl + C            | Copy Selected Mark                     |
| Ctrl + V            | Paste Selected Mark                    |
| Ctrl + D            | Duplicate Selected Text Zone           |
| Ctrl + 0            | Fit Screen                             |
| Ctrl + 1            | Actual Size                            |
| +                   | Increase Balloon Size                  |
| -                   | Decrease Balloon Size                  |
| B                   | Set Tool State B                       |
| C                   | Set Tool State C                       |
| I                   | Set Tool State I                       |
| Delete              | Delete Selected Item                   |
| Right Click         | Remove Last Balloon / Cancel Duplicate |
| Double Left Click   | Accept Hidden Text Zone                |

---

# Mouse Controls

| Action               | Description          |
| -------------------- | -------------------- |
| Left Drag            | Draw OCR Region      |
| Left Drag on Balloon | Move MarkStep        |
| Middle Drag          | Pan                  |
| Wheel                | Zoom                 |
| Double Click         | Accept OCR Candidate |
| Right Click          | Undo Balloon         |

---

# Running

Clone repository:

```bash
git clone https://github.com/vuductho96/ScanDrawingOcr.git
cd ScanDrawingOcr
```

Launch:

```powershell
pwsh -ExecutionPolicy Bypass -File .\RapidOcrProUpdate.ps1
```

or

```cmd
Run-RapidOcrProUpdate-PS7.bat
```

---

# Git Policy

The repository intentionally excludes large runtime data:

```text
tools/
SecureBuild/
TrainingDataset/
PreparedDataset/
ocrtool-pdfscan-sessions/
ocrtool-pdfscan-render-cache/
```

and generated files:

```text
*.png
*.jpg
*.jpeg
*.pdf
*.xlsm
*.zip
*.clixml
*.json
*.lnk
```

---

# Intended Users

* QA Engineers
* Injection Molding Engineers
* Manufacturing Engineers
* Quality Inspectors
* Drawing Review Teams
* Process Engineers

---

# Project Status

Active development.

Current focus:

* PDF OCR
* AI Vision Recovery
* MarkStep Workflow
* Excel Export
* Drawing Inspection Automation
* Manufacturing QA Productivity

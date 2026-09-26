# DimensionOCR — RapidOCR PDF Scan Tool

**A Windows desktop tool for extracting mechanical dimensions from PDF drawings, reviewing OCR results, correcting tolerances, and exporting inspection data to Excel.**

---

## Screenshots

**Main workspace — balloon marks & dimension table**

![Main workspace](docs/assets/screenshot-main.png)

**Auto Scan result — YOLO detection with numbered balloons**

![Auto scan result](docs/assets/screenshot-scan-result.png)

**Bulk Google AI Recovery — contact sheet preview**

![Bulk AI recovery](docs/assets/screenshot-bulk-recovery.png)

---

## Features

| Category | Feature |
|----------|---------|
| **PDF** | Open / drag-drop mechanical PDF drawings, rendered via Pdfium |
| **Auto Scan** | YOLO ONNX detects text zones → RapidOcrNet reads dimensions, sorted in CAD reading order |
| **Manual crop** | Draw bounding boxes manually for difficult callouts |
| **Auto Map PDF** | Select inspection regions in order, generate MarkSteps per region |
| **Table editing** | Edit Nominal / Tol− / Tol+ / Tool / Result directly in the grid |
| **Duplicate detection** | Automatically flags duplicate dimension marks |
| **Balloon marks** | Numbered balloons drawn on the PDF, resizable, copy/paste/duplicate |
| **Bulk Google AI Recovery** | Sends a crop contact-sheet image to Google AI via Chrome → parses results back into the table |
| **Excel export** | Export inspection table to `.xlsx` with OK/NG formulas |
| **Print** | Print the marked drawing directly from the app (`Ctrl+P`) |
| **Training pipeline** | Silently collects OCR corrections and YOLO annotations for model retraining |
| **Session save/restore** | State is saved and restored per PDF file |
| **System tray** | Minimize to tray, restore on demand |

---

## Requirements

| Component | Requirement |
|-----------|------------|
| **OS** | Windows 10 / 11 (64-bit) |
| **PowerShell** | PowerShell 7 (`pwsh`) — recommended; Windows PowerShell 5.1 also works |
| **.NET Runtime** | .NET 8 (used by `RapidOcrNet.dll`, `YoloCadOnnxModel.dll`) |
| **Google Chrome** | Required for Bulk Google AI Recovery (Chrome automation) |

---

## Quick Start

```powershell
# Clone
git clone https://github.com/vuductho96/ScanDrawingOcr.git
cd ScanDrawingOcr

# Run
.\Run-RapidOcrProUpdate-PS7.bat
```

Or launch directly:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -STA -File .\RapidOcrProUpdate.ps1
```

> The `-STA` flag is required for WinForms to function correctly.

---

## Usage

### Open a drawing

Click **Open PDF** or drag a PDF file into the window. Navigate pages using the top bar.

### Auto Scan (YOLO + RapidOCR)

Click **Scan** or go to **Advance → Auto Scan**:

1. YOLO ONNX detects mechanical text and dimension zones.
2. RapidOcrNet reads each zone.
3. Results are sorted in standard CAD reading order (top-to-bottom bands, left-to-right).
4. Numbered MarkSteps are created and balloons are placed on the drawing.
5. The table is filled automatically (Step / Nominal / Tol− / Tol+).

Press `T` to toggle text zone bounding box visibility.

### Auto Map PDF

1. Click **Auto Map PDF**.
2. Drag Region 1, Region 2, … in the desired inspection order.
3. Use **Text Zones**, **Clear Gray Box**, and **Delete BBox** to clean bad boxes.
4. Check for duplicate warnings inside the selected regions.
5. Click **Finish** to create MarkSteps in region order.

### Manual editing

- Click any cell to edit Nominal / Tol− / Tol+ / Tool / Result directly.
- Drag bounding boxes on the drawing to adjust crop regions.
- Press `Ctrl+Z` to undo a deleted step.

### Bulk Google AI Recovery

Use when OCR misreads several dimensions at once:

1. Select the rows that need recovery.
2. Open **Advance → Bulk Google AI Recovery**.
3. Tick the steps to recover and review the crop previews.
4. Click **Recover** — the app builds a single contact-sheet image and sends it to Google AI via Chrome.
5. The returned values are parsed and written back into the table.

Expected AI response format:

```
STEP=1 Nominal=7,003 Tol+=0,001 Tol-=0,000
STEP=2 Nominal=1,490 Tol+=0,000 Tol-=0,000
STEP=3 Nominal=2,002 Tol+=0,000 Tol-=0,000
```

### Export to Excel

Click **Export Excel** to export the inspection table to `.xlsx` with OK/NG formulas and standard mechanical tolerance formatting.

---

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `T` | Toggle text zone bounding boxes |
| `C` | Toggle copy view |
| `B` | Toggle balloon view |
| `R` | Rotate page 90° clockwise |
| `L` | Toggle leader lines |
| `S` | Sort steps ascending |
| `I` | Mark selected step as Important |
| `E` | Keep hidden duplicate candidate as a new step |
| `Enter` | Accept hidden text-zone suggestion |
| `Esc` | Cancel current selection |
| `Space` (hold) | Pan mode |
| `Middle Mouse Drag` | Pan drawing |
| `Mouse Wheel` | Zoom at cursor |
| `Shift + Mouse Wheel` | Horizontal scroll |
| `Ctrl + B` | Toggle side panel |
| `Ctrl + P` | Print marked drawing |
| `Ctrl + Z` | Undo deleted step |
| `Ctrl + C` | Copy selected mark |
| `Ctrl + V` | Paste mark |
| `Ctrl + D` | Duplicate selected text zone |
| `Ctrl + 0` | Fit to screen |
| `Ctrl + 1` | Actual size (100%) |
| `+` / `-` | Increase / decrease balloon size |
| `Delete` | Delete selected item |

---

## Project Structure

```
RapidOcrProUpdateBundle/
│
├── RapidOcrProUpdate.ps1            # Main script — business logic
├── RapidOcrProUpdate.UI.ps1         # Windows Forms UI module
├── RapidOcrProUpdate.Training.ps1   # Training data collection module
├── WindowsOcr_Helper.ps1            # Windows OCR helper (WinRT API)
├── RapidOcrStartupSplash.hta        # Startup splash screen
│
├── Run-RapidOcrProUpdate-PS7.bat    # Launcher (visible console window)
├── Run-RapidOcrProUpdate-PS7.vbs    # Launcher (hidden, no console)
│
├── PdfiumViewer.dll                 # .NET PDF rendering wrapper
├── pdfium.dll                       # Pdfium native library (x64)
│
├── lib/
│   ├── OcrAi/
│   │   ├── RapidOcrNet/             # RapidOCR .NET engine
│   │   │   ├── lib/net8.0/          # RapidOcrNet.dll
│   │   │   └── models/v5/           # ONNX models (det, rec, cls)
│   │   ├── YoloCadOnnxModel/        # YOLO CAD detector (C# wrapper)
│   │   │   ├── cache/best.onnx      # Trained YOLO model
│   │   │   └── lib/net8.0/          # YoloCadOnnxModel.dll
│   │   ├── YoloCadDetector/         # YOLO inference wrapper
│   │   ├── Microsoft.ML.OnnxRuntime.*/ # ONNX Runtime
│   │   ├── SkiaSharp/               # Image processing (managed)
│   │   ├── SkiaSharp.NativeAssets.Win32/ # SkiaSharp native
│   │   ├── Clipper2/                # Polygon clipping
│   │   └── System.Numerics.Tensors/
│   └── OpenCvSharp/
│       ├── opencvsharp4/            # OpenCvSharp managed DLL
│       └── opencvsharp4.runtime.win/  # OpenCvSharpExtern.dll (native)
│
├── tools/
│   ├── autoscan_bridge.py           # Python bridge for Auto Scan
│   ├── cad_ocr_pipeline.py          # Full-page CAD OCR pipeline
│   ├── cad_geometric_preprocessor.py # Geometric pre-processing
│   ├── rapidocr_worker.ps1          # Parallel OCR worker process
│   └── Capture2Text/
│       └── Capture2Text_463/        # Capture2Text binary (OCR fallback)
│
├── SecureBuild/                     # EXE wrapper build (encrypted script)
│   ├── Loader/                      # C# loader — decrypts payload.dat in memory
│   ├── EncryptTool/                 # Encrypts .ps1 → payload.dat
│   └── README.md                    # Build instructions
│
├── docs/
│   └── assets/                      # README screenshots
│
└── .gitignore
```

---

## Building the EXE Distribution

To distribute as a standalone `.exe` with the PowerShell source encrypted:

```powershell
cd SecureBuild

# Restore NuGet packages
dotnet restore .\Loader\SecurePs1Loader.csproj
dotnet restore .\EncryptTool\EncryptTool.csproj

# Publish both projects
dotnet publish .\Loader\SecurePs1Loader.csproj -c Release -r win-x64
dotnet publish .\EncryptTool\EncryptTool.csproj -c Release -r win-x64

# Encrypt scripts into payload.dat
.\EncryptTool\bin\Release\net8.0\win-x64\publish\EncryptTool.exe `
    ..\RapidOcrProUpdate.ps1 `
    .\Release-SimpleDrag\payload.dat

# Copy runtime dependencies
.\Copy-AppSupportFiles.ps1
```

> The loader never writes the decrypted script to disk — it runs entirely in memory.  
> See [`SecureBuild/README.md`](SecureBuild/README.md) for full details.

---

## Training Pipeline

The app silently collects training data in the background as the operator corrects OCR results:

- **OCR corrections** → `training_dataset/ocr_corrections/` (cropped images + correct labels)
- **YOLO annotations** → `training_dataset/yolo_detection/` (images + YOLO label files)

This data can be used to fine-tune the YOLO and OCR models for specific drawing styles.

---

## Status

**Active development.**

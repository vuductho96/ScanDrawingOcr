# RapidOCR PDF Scan Tool — DimensionOCR

> **Công cụ OCR bản vẽ PDF cơ khí trên Windows** — trích xuất kích thước, dung sai, duyệt kết quả và xuất Excel kiểm tra.

![Demo](docs/assets/dimensionocr-app.gif)

---

## Tính năng chính

| Nhóm | Tính năng |
|------|-----------|
| **PDF** | Mở / kéo thả PDF bản vẽ cơ khí, render trang với Pdfium |
| **OCR tự động** | YOLO11 ONNX phát hiện text-zone → RapidOcrNet / PaddleOCR / Windows OCR |
| **Auto Scan** | Quét toàn trang tự động, sắp xếp theo thứ tự đọc CAD (top-to-bottom, left-to-right) |
| **Manual crop** | Vẽ bounding box tay cho các vùng OCR khó |
| **Auto Map PDF** | Chọn vùng theo thứ tự kiểm tra, tạo MarkStep theo vùng |
| **Duyệt bảng** | Chỉnh sửa Nominal / Tol− / Tol+ / Tool / Result trực tiếp trên bảng |
| **Duplicate detect** | Phát hiện và đánh dấu dimension trùng tự động |
| **Balloon** | Vẽ số balloon trên bản vẽ, điều chỉnh kích thước, copy/paste |
| **Google AI (Gemini)** | Recovery đơn lẻ hoặc Bulk (contact sheet → AI → parse kết quả) |
| **Excel export** | Xuất bảng kiểm tra sang `.xlsx` (có formula OK/NG, định dạng chuẩn) |
| **In ấn** | In bản vẽ đã đánh dấu trực tiếp từ app |
| **Training pipeline** | Tự động thu thập dữ liệu training (OCR correction, YOLO annotation) trong nền |
| **Session** | Lưu/khôi phục trạng thái làm việc theo file PDF |
| **Tray icon** | Chạy ẩn hệ thống, hiện lại khi cần |

---

## Ảnh chụp màn hình

| Workspace chính | Bulk Recovery |
|---|---|
| ![Main workspace](docs/assets/dimensionocr-app.png) | ![Bulk recovery](docs/assets/bulk-recovery-dialog.png) |

| Contact sheet gửi AI | Kết quả trả về từ Google AI |
|---|---|
| ![Contact sheet](docs/assets/bulk-contact-sheet.png) | ![Google AI result](docs/assets/google-ai-result.png) |

---

## Yêu cầu hệ thống

| Thành phần | Yêu cầu |
|------------|---------|
| **OS** | Windows 10 / 11 (64-bit) |
| **PowerShell** | PowerShell 7 (`pwsh`) — khuyến nghị; hoặc Windows PowerShell 5.1 |
| **.NET Runtime** | .NET 8 (dùng bởi `RapidOcrNet.dll`, `YoloCadOnnxModel.dll`) |
| **Python** | Python 3.9+ (tuỳ chọn — dùng bởi `autoscan_bridge.py`, `cad_ocr_pipeline.py`) |
| **Google AI API key** | Cần thiết cho tính năng Gemini Vision recovery |

---

## Cài đặt nhanh (chạy từ source)

```powershell
# 1. Clone repo
git clone https://github.com/vuductho96/ScanDrawingOcr.git
cd ScanDrawingOcr

# 2. Chạy app (PowerShell 7)
.\Run-RapidOcrProUpdate-PS7.bat
```

Hoặc chạy trực tiếp:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -STA -File .\RapidOcrProUpdate.ps1
```

> **Lưu ý:** App cần chạy với `-STA` (Single-Threaded Apartment) để WinForms hoạt động đúng.

---

## Hướng dẫn sử dụng

### 1 · Mở bản vẽ

- Click **Open PDF**, hoặc **kéo thả file PDF** vào cửa sổ.
- Chọn trang cần xem trên thanh điều hướng.

### 2 · Phát hiện kích thước tự động (YOLO)

Nhấn **Auto YOLO** hoặc `Ctrl + Y`:

1. Chạy YOLO11 ONNX phát hiện text/dimension zones.
2. Trích xuất Nominal, Tol−, Tol+ từ các zone.
3. Sắp xếp theo thứ tự đọc CAD chuẩn.
4. Tạo MarkStep có đánh số, đặt balloon lên bản vẽ.
5. Điền tự động vào bảng (Step / Nominal / Tol− / Tol+).

Nhấn `T` để bật/tắt hiển thị bounding box text zone.

### 3 · Auto Map PDF theo vùng

1. Click **Auto Map PDF**.
2. Kéo vùng Region 1, Region 2, … theo thứ tự kiểm tra.
3. Dùng **Text Zones**, **Clear Gray Box**, **Delete BBox** để làm sạch box xấu.
4. Kiểm tra cảnh báo duplicate trong vùng đã chọn.
5. Click **Finish** để tạo MarkStep theo thứ tự vùng.

### 4 · Sửa thủ công

- Click vào ô bảng để sửa trực tiếp Nominal / Tol− / Tol+ / Tool / Result.
- Kéo bounding box trên bản vẽ để điều chỉnh vùng crop.
- Dùng `Ctrl + Z` để undo xoá step.

### 5 · Bulk Google AI Recovery

Dùng khi OCR đọc sai nhiều dimension cùng lúc:

1. Chọn các row cần recovery.
2. Mở **Advance** → **Bulk Google AI Recovery**.
3. Chọn các step cần phục hồi, xem preview crop.
4. Click **Recover** — app gửi một contact-sheet image lên Gemini.
5. Kết quả tự động parse và điền vào bảng.

**Định dạng kết quả AI:**

```
STEP=1 Nominal=7,003 Tol+=0,001 Tol-=0,000
STEP=2 Nominal=1,490 Tol+=0,000 Tol-=0,000
STEP=3 Nominal=2,002 Tol+=0,000 Tol-=0,000
```

### 6 · Xuất Excel

Click **Export Excel** để xuất bảng kết quả kiểm tra sang `.xlsx`:
- Có công thức OK/NG tự động.
- Định dạng tolerance chuẩn cơ khí.

---

## Phím tắt

| Phím | Chức năng |
|------|-----------|
| `T` | Bật/tắt hiển thị Text Zones |
| `C` | Bật/tắt Copy View |
| `Space` (giữ) | Chế độ Pan |
| `Middle Mouse Drag` | Pan bản vẽ |
| `Mouse Wheel` | Zoom tại con trỏ |
| `Shift + Mouse Wheel` | Cuộn ngang |
| `Esc` | Huỷ selection |
| `Enter` | Chấp nhận gợi ý text-zone ẩn |
| `E` | Giữ duplicate candidate ẩn làm step mới |
| `Ctrl + Y` | Auto YOLO Detect & Auto-Fill Table |
| `Ctrl + S` | Google AI recovery cho step đang chọn |
| `Ctrl + Shift + R` | Xoay trang 90° |
| `Ctrl + B` | Bật/tắt side panel |
| `Ctrl + P` | In bản vẽ đã đánh dấu |
| `Ctrl + Z` | Undo xoá step |
| `Ctrl + C` | Copy mark đang chọn |
| `Ctrl + V` | Paste mark |
| `Ctrl + D` | Duplicate text zone |
| `Ctrl + 0` | Fit screen |
| `Ctrl + 1` | Kích thước thực (100%) |
| `+` / `-` | Tăng / giảm kích thước balloon |
| `Delete` | Xoá item đang chọn |

---

## Cấu trúc dự án

```
RapidOcrProUpdateBundle/
│
├── RapidOcrProUpdate.ps1          # Script chính — logic nghiệp vụ
├── RapidOcrProUpdate.UI.ps1       # Module giao diện Windows Forms
├── RapidOcrProUpdate.Training.ps1 # Module thu thập dữ liệu training
├── WindowsOcr_Helper.ps1          # Helper Windows OCR (WinRT API)
├── RapidOcrStartupSplash.hta      # Màn hình splash khi khởi động
│
├── Run-RapidOcrProUpdate-PS7.bat  # Launcher (BAT — hiện cửa sổ)
├── Run-RapidOcrProUpdate-PS7.vbs  # Launcher (VBS — chạy ẩn)
│
├── PdfiumViewer.dll               # .NET wrapper render PDF
├── pdfium.dll                     # Pdfium native (x64)
│
├── lib/
│   ├── OcrAi/
│   │   ├── RapidOcrNet/           # RapidOCR .NET (detect + recognize)
│   │   │   ├── lib/net8.0/        # RapidOcrNet.dll
│   │   │   └── models/v5/         # Model ONNX (det, rec, cls)
│   │   ├── YoloCadOnnxModel/      # YOLO11 CAD detector
│   │   │   ├── cache/best.onnx    # Model YOLO đã train (dùng trực tiếp)
│   │   │   ├── lib/net8.0/        # YoloCadOnnxModel.dll
│   │   │   └── src/               # Source C# wrapper
│   │   ├── YoloCadDetector/       # Wrapper inference YOLO
│   │   ├── Microsoft.ML.OnnxRuntime.*/  # ONNX Runtime (native + managed)
│   │   ├── SkiaSharp/             # Xử lý ảnh (managed)
│   │   ├── SkiaSharp.NativeAssets.Win32/  # Native SkiaSharp
│   │   ├── PaddleOCR.Onnx/        # PaddleOCR engine (fallback)
│   │   ├── Emgu.CV/               # OpenCV wrapper (managed)
│   │   ├── Emgu.CV.runtime.windows/ # OpenCV native
│   │   ├── Clipper2/              # Polygon clipping
│   │   ├── clipper_standard/      # Clipper legacy
│   │   └── System.Numerics.Tensors/  # Tensor math
│   └── OpenCvSharp/
│       ├── opencvsharp4/          # OpenCvSharp managed (.dll)
│       └── opencvsharp4.runtime.win/  # OpenCvSharpExtern.dll (native)
│
├── tools/
│   ├── autoscan_bridge.py         # Bridge Python cho Auto Scan
│   ├── cad_ocr_pipeline.py        # Pipeline OCR toàn bộ bản vẽ CAD
│   ├── cad_geometric_preprocessor.py  # Tiền xử lý hình học
│   ├── rapidocr_worker.ps1        # Worker process OCR (chạy song song)
│   └── Capture2Text/
│       └── Capture2Text_463/      # Capture2Text binary (OCR fallback)
│
├── SecureBuild/                   # Build wrapper EXE (mã hoá script)
│   ├── Loader/                    # C# loader giải mã payload.dat
│   ├── EncryptTool/               # Tool mã hoá .ps1 → payload.dat
│   └── README.md                  # Hướng dẫn build EXE
│
├── docs/
│   └── assets/                    # Ảnh cho README
│
└── .gitignore
```

---

## Build EXE (phân phối đã mã hoá)

Nếu muốn phân phối dạng `.exe` thay vì `.ps1`:

```powershell
cd SecureBuild

# 1. Restore NuGet
dotnet restore .\Loader\SecurePs1Loader.csproj
dotnet restore .\EncryptTool\EncryptTool.csproj

# 2. Publish loader
dotnet publish .\Loader\SecurePs1Loader.csproj -c Release -r win-x64

# 3. Publish encrypt tool
dotnet publish .\EncryptTool\EncryptTool.csproj -c Release -r win-x64

# 4. Mã hoá scripts thành payload.dat
.\EncryptTool\bin\Release\net8.0\win-x64\publish\EncryptTool.exe `
    ..\RapidOcrProUpdate.ps1 `
    .\Release-SimpleDrag\payload.dat

# 5. Copy dependencies
.\Copy-AppSupportFiles.ps1
```

> Script `.ps1` không bao giờ được ghi ra disk bởi loader — chỉ giải mã trong bộ nhớ.  
> Xem chi tiết tại [`SecureBuild/README.md`](SecureBuild/README.md).

---

## Cấu hình Google AI API

1. Lấy API key tại [Google AI Studio](https://aistudio.google.com/apikey).
2. Mở app → **Advance** → nhập API key vào ô **Gemini API Key**.
3. Key được lưu trong session state, không cần nhập lại mỗi lần.

---

## Training pipeline

App tự động thu thập dữ liệu training trong nền khi người dùng sửa OCR:

- **OCR corrections** → `training_dataset/ocr_corrections/` (ảnh crop + nhãn đúng)
- **YOLO annotations** → `training_dataset/yolo_detection/` (ảnh + YOLO label)
- **Training metrics** → hiển thị trên UI (số mẫu, độ sẵn sàng)

Dữ liệu được dùng để fine-tune lại model tăng độ chính xác theo từng loại bản vẽ.

---

## Trạng thái dự án

**Đang phát triển tích cực.**

---

## Licence

Dự án nội bộ — chưa có licence công khai.

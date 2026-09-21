import os
import sys

# Thiết lập UTF-8 Mode tuyệt đối cho Windows
os.environ["PYTHONIOENCODING"] = "utf-8"
os.environ["PYTHONUTF8"] = "1"
os.environ["GLOG_minloglevel"] = "3"
os.environ["FLAGS_pir_apply_shape_optimization_pass"] = "0"
os.environ["PADDLE_PDX_LOG_LEVEL"] = "ERROR"

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import argparse
import json
import time
import cv2

# Đảm bảo đường dẫn tới thư mục chứa AutoScanText để import local_ai_service
AUTOSCAN_DIR = r"C:\Users\IRS03-415\Desktop\AutoScanText"
if AUTOSCAN_DIR not in sys.path:
    sys.path.insert(0, AUTOSCAN_DIR)

try:
    from local_ai_service import LocalAIService
except Exception as e:
    print(f"ERROR: Khong the import LocalAIService tu {AUTOSCAN_DIR}: {e}", file=sys.stderr)
    sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Auto-Scan Bridge: YOLOv11 + PP-OCR Hybrid")
    parser.add_argument("--image", required=True, help="Duong dan file anh trang can scan")
    parser.add_argument("--out", required=True, help="Duong dan file JSON luu ket qua")
    parser.add_argument("--model", default="v6", choices=["v6", "v4"], help="Mo hinh PP-OCR (v6 goc hoac v4 cad)")
    args = parser.parse_args()

    image_path = os.path.abspath(args.image)
    out_path = os.path.abspath(args.out)

    if not os.path.exists(image_path):
        print(f"ERROR: Khong tim thay file anh: {image_path}", file=sys.stderr)
        sys.exit(2)

    t_start = time.perf_counter()
    img_bgr = cv2.imread(image_path)
    if img_bgr is None or img_bgr.size == 0:
        print(f"ERROR: cv2 khong the doc file anh: {image_path}", file=sys.stderr)
        sys.exit(3)

    # Khoi tao AI Service
    service = LocalAIService.get_instance(model_name=args.model)
    if args.model != service.model_name:
        service.set_ocr_model(args.model)

    # Thuc thi scan toan bo ban ve
    scan_res = service.scan_image(img_bgr)
    dims = scan_res.get("dimensions", [])

    results = []
    for d in dims:
        box = d.get("box", {})
        x = int(box.get("x", 0))
        y = int(box.get("y", 0))
        w = int(box.get("w", 0))
        h = int(box.get("h", 0))

        nom_val = d.get("nominal_str") or d.get("nominal") or d.get("raw_text") or ""
        raw_text = d.get("raw_text") or nom_val
        u_tol = d.get("upper_tol", "")
        l_tol = d.get("lower_tol", "")

        results.append({
            "x": x,
            "y": y,
            "w": w,
            "h": h,
            "nominal": str(nom_val).strip(),
            "raw_text": str(raw_text).strip(),
            "tol_plus": str(u_tol).strip() if u_tol is not None else "",
            "tol_minus": str(l_tol).strip() if l_tol is not None else "",
            "confidence": float(d.get("confidence", 0.0))
        })

    # Ghi ket qua JSON
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

    total_time = (time.perf_counter() - t_start) * 1000
    print(f"AUTO_SCAN_SUCCESS: {len(results)} items in {round(total_time, 1)} ms")
    sys.exit(0)

if __name__ == "__main__":
    main()

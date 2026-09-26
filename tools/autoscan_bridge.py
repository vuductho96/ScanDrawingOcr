import os
import sys
import warnings

# Tắt toàn bộ cảnh báo ccache / onnxruntime / paddle ra stderr
warnings.filterwarnings("ignore")

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
import re
import cv2

# Đảm bảo đường dẫn tới thư mục chứa AutoScanText để import local_ai_service
AUTOSCAN_DIR = r"C:\Users\IRS03-415\Desktop\AutoScanText"
if AUTOSCAN_DIR not in sys.path:
    sys.path.insert(0, AUTOSCAN_DIR)

try:
    from tolerance_parser import ToleranceParser
except Exception as e:
    print(f"ERROR: Khong the import tolerance_parser tu {AUTOSCAN_DIR}: {e}", file=sys.stderr)
    sys.exit(1)

LocalAIService = None
GoogleAiWebService = None

def load_local_ai_service():
    global LocalAIService
    if LocalAIService is None:
        from local_ai_service import LocalAIService as _LocalAIService
        LocalAIService = _LocalAIService
    return LocalAIService

def load_google_ai_web_service():
    global GoogleAiWebService
    if GoogleAiWebService is None:
        from google_ai_web_service import GoogleAiWebService as _GoogleAiWebService
        GoogleAiWebService = _GoogleAiWebService
    return GoogleAiWebService

def is_valid_nominal(nom_val):
    if hasattr(ToleranceParser, "is_valid_cad_nominal"):
        try:
            return ToleranceParser.is_valid_cad_nominal(nom_val)
        except Exception:
            pass
    if not nom_val:
        return False
    s = str(nom_val).strip()
    return bool(re.search(r'\d', s))

def sort_boxes_spatial(boxes, row_tol=None):
    """
    Sắp xếp các ô kích thước theo thứ tự đọc bản vẽ chuẩn kỹ thuật:
    Từ Trên xuống Dưới (Top to Bottom), Từ Trái sang Phải (Left to Right).
    Các ô cùng một hàng ngang (chênh lệch y <= row_tol) sẽ được gom vào 1 dải (band)
    và sắp xếp từ trái qua phải theo x để đánh số thứ tự bong bóng chuẩn xác.
    """
    if not boxes or len(boxes) <= 1:
        return boxes

    def get_box_coord(b):
        if "box" in b:
            bc = b["box"]
            if isinstance(bc, dict):
                return bc.get("x", 0), bc.get("y", 0), bc.get("w", 0), bc.get("h", 0)
            elif isinstance(bc, (list, tuple)) and len(bc) >= 4:
                return bc[0], bc[1], bc[2], bc[3]
        return b.get("x", 0), b.get("y", 0), b.get("w", 0), b.get("h", 0)

    avg_h = sum(get_box_coord(b)[3] for b in boxes) / len(boxes)
    if row_tol is None:
        row_tol = max(35.0, avg_h * 1.5)

    sorted_by_y = sorted(boxes, key=lambda b: (get_box_coord(b)[1], get_box_coord(b)[0]))
    bands = []
    current_band = []
    current_band_y = None

    for b in sorted_by_y:
        _, by, _, _ = get_box_coord(b)
        if current_band_y is None:
            current_band = [b]
            current_band_y = by
        elif abs(by - current_band_y) <= row_tol:
            current_band.append(b)
            current_band_y = sum(get_box_coord(item)[1] for item in current_band) / len(current_band)
        else:
            current_band.sort(key=lambda item: get_box_coord(item)[0])
            bands.append(current_band)
            current_band = [b]
            current_band_y = by

    if current_band:
        current_band.sort(key=lambda item: get_box_coord(item)[0])
        bands.append(current_band)

    final = []
    for band in bands:
        final.extend(band)
    return final

def main():
    parser = argparse.ArgumentParser(description="Auto-Scan Bridge: YOLOv11 + PP-OCR Hybrid")
    parser.add_argument("--image", required=True, help="Duong dan file anh trang can scan")
    parser.add_argument("--out", required=True, help="Duong dan file JSON luu ket qua")
    parser.add_argument("--model", default="v6", choices=["v6", "v4", "hybrid", "boxes_only", "google_ai_web"], help="Mo hinh OCR (v6 goc mac dinh, v4 cad, hybrid, boxes_only, hoac google_ai_web qua Playwright)")
    parser.add_argument("--yolo-model", default=None, help="Duong dan file YOLO ONNX dung cho boxes_only/google_ai_web")
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

    # Che do Fast YOLO (chi can YOLO, khong can nap mo hinh PP-OCR ton thoi gian)
    if args.model in ["boxes_only", "google_ai_web"]:
        from test_trained_yolo_onnx import YOLOCADDetector
        yolo_path = args.yolo_model or os.path.join(AUTOSCAN_DIR, "AutoScan_YOLO_Trained_Model", "best.onnx")
        yolo_path = os.path.abspath(yolo_path)
        if not os.path.exists(yolo_path):
            print(f"ERROR: Khong tim thay YOLO ONNX model: {yolo_path}", file=sys.stderr)
            sys.exit(4)
        print("[*] YOLOv11 dang quet tim cac o kich thuoc...", flush=True)
        detector = YOLOCADDetector(onnx_path=yolo_path, imgsz=1024, conf_thres=0.28, iou_thres=0.45)
        raw_boxes, infer_time = detector.detect(img_bgr)
        candidates = []
        for b in raw_boxes:
            box_coords = b.get("box", [0, 0, 0, 0])
            if isinstance(box_coords, (list, tuple)) and len(box_coords) == 4:
                bx, by, bw, bh = box_coords
                box_dict = {"x": int(bx), "y": int(by), "w": int(bw), "h": int(bh)}
            elif isinstance(box_coords, dict):
                box_dict = {
                    "x": int(box_coords.get("x", 0)),
                    "y": int(box_coords.get("y", 0)),
                    "w": int(box_coords.get("w", 0)),
                    "h": int(box_coords.get("h", 0))
                }
            else:
                continue

            candidates.append({
                "box": box_dict,
                "detector_conf": float(b.get("confidence", 0.0))
            })
        print(f"[*] YOLOv11 da phat hien {len(candidates)} o kich thuoc CAD!", flush=True)

        # Sắp xếp các ô kích thước theo thứ tự đọc bản vẽ chuẩn: Từ Trên xuống Dưới, Từ Trái qua Phải
        candidates = sort_boxes_spatial(candidates)
        print(f"[*] Da sap xep {len(candidates)} o theo thu tu doc ban ve (Tren->Duoi, Trai->Phai)!", flush=True)

        if args.model == "boxes_only":
            boxes = []
            for c in candidates:
                b = c.get("box", {})
                boxes.append({
                    "x": int(b.get("x", 0)),
                    "y": int(b.get("y", 0)),
                    "w": int(b.get("w", 0)),
                    "h": int(b.get("h", 0)),
                    "nominal": "",
                    "raw_text": "",
                    "tol_plus": "",
                    "tol_minus": "",
                    "confidence": float(c.get("detector_conf", 0.0))
                })
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump(boxes, f, ensure_ascii=False, indent=2)
            total_time = (time.perf_counter() - t_start) * 1000
            print(f"AUTO_SCAN_SUCCESS: {len(boxes)} boxes in {round(total_time, 1)} ms", flush=True)
            sys.exit(0)

        if args.model == "google_ai_web":
            GoogleAiWebService = load_google_ai_web_service()
            web_service = GoogleAiWebService.get_instance()
            ai_results = web_service.process_crops(img_bgr, candidates, headless=False)

            valid_results = []
            for r in ai_results:
                nom_val = r.get("nominal", "")
                if nom_val and is_valid_nominal(nom_val):
                    valid_results.append(r)

            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump(valid_results, f, ensure_ascii=False, indent=2)
            total_time = (time.perf_counter() - t_start) * 1000
            print(f"AUTO_SCAN_SUCCESS: {len(valid_results)} items in {round(total_time, 1)} ms", flush=True)
            sys.exit(0)

    # Che do Scan bang PP-OCR offline (v4 fine-tuned, v6 goc, hoac hybrid)
    LocalAIService = load_local_ai_service()
    service = LocalAIService.get_instance(model_name=args.model)
    if args.model in ["v4", "v6", "hybrid"]:
        service.set_ocr_model(args.model)

    scan_res = service.scan_image(img_bgr)
    dims = scan_res.get("dimensions", [])

    results = []
    for d in dims:
        box = d.get("box", {})
        x = int(box.get("x", 0))
        y = int(box.get("y", 0))
        w = int(box.get("w", 0))
        h = int(box.get("h", 0))

        nom_val = d.get("nominal_str") or d.get("nominal") or ""
        nom_val = re.sub(r'^\s*[\(\[]\s*([^\(\)\[\]]+?)\s*[\)\]]\s*$', r'\1', str(nom_val)).strip()

        # Không cho lọt chữ vào làm nominal: nếu không có nominal hoặc nominal không hợp lệ -> bỏ qua
        if not nom_val or not is_valid_nominal(nom_val):
            continue

        raw_text = d.get("raw_text") or nom_val
        tol_type = d.get("tol_type", "local")
        is_global = (tol_type == "global")
        # Neu la dung sai global (tren ban ve khong ghi dung sai), de trong tol_plus/tol_minus
        # de PowerShell tu dong ap dung bang Default Tolerance nguoi dung thiet lap tren GUI
        u_tol = "" if is_global else (d.get("upper_tol", "") or "")
        l_tol = "" if is_global else (d.get("lower_tol", "") or "")

        results.append({
            "x": x,
            "y": y,
            "w": w,
            "h": h,
            "nominal": str(nom_val).strip(),
            "raw_text": str(raw_text).strip(),
            "tol_plus": str(u_tol).strip() if u_tol is not None else "",
            "tol_minus": str(l_tol).strip() if l_tol is not None else "",
            "confidence": float(d.get("confidence", 0.0)),
            "tol_type": tol_type
        })

    # Sắp xếp kết quả theo thứ tự đọc bản vẽ chuẩn: Từ Trên xuống Dưới, Từ Trái qua Phải
    results = sort_boxes_spatial(results)

    # Ghi ket qua JSON
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

    total_time = (time.perf_counter() - t_start) * 1000
    print(f"AUTO_SCAN_SUCCESS: {len(results)} items in {round(total_time, 1)} ms")
    sys.exit(0)

if __name__ == "__main__":
    main()

# Worked example: run a raw Ultralytics YOLO model (bbox detect OR segm)
# against real test images, at very low confidence, to see what it ACTUALLY
# produces before wiring it into a workflow behind a UltralyticsDetectorProvider
# node. Run via run-python.sh, e.g.:
#
#   run-python.sh <image> inference_test_yolo.py \
#     ./models:/models:ro \
#     ./test-images:/images:ro
#
# Why bother: a workflow's default confidence threshold (often 0.5) silently
# rejects everything below it, so "detector finds nothing" and "detector
# finds it at 0.3" look identical from inside ComfyUI unless you go looking.
# Running at conf=0.01 here shows you the REAL score distribution, so you set
# a threshold based on evidence instead of guessing 0.15 and hoping.
#
# This also tells you unambiguously whether a model is `detect` (bbox-only)
# or `segment` (has a mask head, so it can feed a SEGM_DETECTOR slot too) --
# `model.task` -- rather than guessing from filename/folder conventions,
# which are just naming, not a guarantee (a repo can put a plain detect
# checkpoint in a folder named "segm/" and vice versa).

from ultralytics import YOLO

MODELS = [
    "/models/example_detector.pt",
    # add more to compare candidates side by side
]
IMAGES = [
    "/images/img1.png",
    "/images/img2.png",
]

for model_path in MODELS:
    print(f"\n===== MODEL: {model_path} =====")
    model = YOLO(model_path)
    print("task:", model.task, "names:", model.names)  # task tells you detect vs segment
    results = model.predict(IMAGES, conf=0.01, iou=0.5, verbose=False)
    for img_path, r in zip(IMAGES, results):
        print(f"\n-- {img_path} --  orig shape {r.orig_shape}")
        if r.boxes is None or len(r.boxes) == 0:
            print("   NO detections at all (conf>=0.01) -- genuinely no signal, not a threshold problem")
            continue
        boxes = r.boxes
        for i in range(len(boxes)):
            cls_id = int(boxes.cls[i].item())
            conf = float(boxes.conf[i].item())
            xyxy = boxes.xyxy[i].tolist()
            cls_name = model.names.get(cls_id, cls_id)
            print(f"   class={cls_name!r} conf={conf:.4f} box(px)={['%.0f' % v for v in xyxy]}")

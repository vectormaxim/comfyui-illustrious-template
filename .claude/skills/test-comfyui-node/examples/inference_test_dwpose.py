# Worked example: run comfyui_controlnet_aux's DWPose detector directly
# against real test images, and dump every keypoint with its confidence and
# COORDINATE SPACE -- before trusting a downstream node's assumption about
# whether POSE_KEYPOINT values are normalized [0,1] or absolute pixels.
#
# That assumption is genuinely ambiguous and build-dependent: the library's
# own util.is_normalized() has to guess it heuristically too (see
# custom_controlnet_aux/dwpose/util.py). Getting it wrong doesn't error --
# it silently places computed regions thousands of pixels off-canvas. Run
# this once against your actual build before writing any code that consumes
# POSE_KEYPOINT.
#
# Run via run-python.sh:
#   run-python.sh <image> inference_test_dwpose.py ./test-images:/images:ro
#
# No models/ mount needed -- DWPose downloads its own bbox+pose ONNX models
# from HuggingFace (yzd-v/DWPose) on first use inside the container.

import sys
sys.path.insert(0, "/ComfyUI/custom_nodes/comfyui_controlnet_aux/src")
import numpy as np
from PIL import Image
from custom_controlnet_aux.dwpose import DwposeDetector

model = DwposeDetector.from_pretrained(
    "yzd-v/DWPose", "yzd-v/DWPose",
    # det_filename=None skips the person-bbox detection stage entirely and
    # runs pose estimation on the whole image -- worth trying if the DWPose
    # Estimator NODE's default (its "bbox_detector" widget defaults to
    # "yolox_l.onnx", a COCO-real-photo-trained person detector; this
    # from_pretrained() call's own default is already None, so passing it
    # explicitly here is just documenting the choice, not overriding a
    # library default) finds zero people on stylized/anime art, which it
    # often does on close-up or unusual-pose renders. Confirmed in this
    # project by running WITH yolox_l.onnx as a control: 0 people detected
    # on 5 of 6 real test renders; whole-image mode handled all 6.
    det_filename=None,
    pose_filename="dw-ll_ucoco_384.onnx",
)
# Gotcha if you adapt this to A/B two different det_filename/pose_filename
# configs in one script: DwposeDetector.from_pretrained() stashes its result
# in a module-level cache and reuses it whenever the filenames match the
# last call -- calling from_pretrained() again with the SAME arguments does
# NOT reload, but calling it with DIFFERENT arguments does, so a same-process
# comparison is safe as long as each config gets its own from_pretrained()
# call (as here) rather than assuming a fresh instance per call.

# Standard 18-point OpenPose/COCO body order emitted in pose_keypoints_2d.
NAMES_18 = ["Nose", "Neck", "RShoulder", "RElbow", "RWrist", "LShoulder", "LElbow", "LWrist",
            "RHip", "RKnee", "RAnkle", "LHip", "LKnee", "LAnkle", "REye", "LEye", "REar", "LEar"]

IMAGES = ["/images/img1.png", "/images/img2.png"]

for img_path in IMAGES:
    print(f"\n== {img_path} ==")
    img = np.array(Image.open(img_path).convert("RGB"))
    _, openpose_dict = model(img, include_hand=False, include_face=False, include_body=True,
                              image_and_json=True, output_type="np")
    people = openpose_dict.get("people", [])
    print(f"  people detected: {len(people)}  canvas: {openpose_dict.get('canvas_width')}x{openpose_dict.get('canvas_height')}")
    if not people:
        continue
    kp = people[0]["pose_keypoints_2d"]
    xs, ys = [], []
    for idx, name in enumerate(NAMES_18):
        o = idx * 3
        x, y, c = kp[o], kp[o + 1], kp[o + 2]
        if c > 0:
            xs.append(x)
            ys.append(y)
        print(f"  {name:10s} idx={idx:2d}  x={x:8.2f} y={y:8.2f} conf={c:.3f}")
    if xs:
        normalized = all(abs(v) <= 1.0 for v in xs + ys)
        print(f"  => coordinates look {'NORMALIZED [0,1]' if normalized else 'ABSOLUTE PIXELS'} "
              f"(x range {min(xs):.2f}..{max(xs):.2f})")

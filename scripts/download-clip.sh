#!/bin/bash
# Downloads Apple's MobileCLIP-S2 (Core ML, about 200 MB) and CLIP's tokenizer
# files into ./Models, where scripts/build-app.sh picks them up. The app runs
# them on this Mac; it never downloads anything itself.
# Model weights: Apple Sample Code License, see
# https://github.com/apple/ml-mobileclip/blob/main/LICENSE_weights_data
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Models

HF="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
for m in mobileclip_s2_image mobileclip_s2_text; do
  for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    mkdir -p "Models/$m.mlpackage/$(dirname "$f")"
    curl -fL --progress-bar "$HF/$m.mlpackage/$f" -o "Models/$m.mlpackage/$f"
  done
done

GH="https://raw.githubusercontent.com/apple/ml-mobileclip/main/ios_app/MobileCLIPExplore/Resources"
for f in clip-vocab.json clip-merges.txt; do
  curl -fL --progress-bar "$GH/$f" -o "Models/$f"
done
echo "MobileCLIP is in Models/. Run scripts/build-app.sh to bundle it."

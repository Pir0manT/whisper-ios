#!/bin/bash

# Download ggml-medium.bin model from HuggingFace
# Usage: ./download-model.sh [model_name]
# Default: medium

MODEL_NAME="${1:-medium}"
MODEL_FILE="ggml-${MODEL_NAME}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_FILE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "${SCRIPT_DIR}/${MODEL_FILE}" ]; then
    echo "Model ${MODEL_FILE} already exists"
    exit 0
fi

echo "Downloading ${MODEL_FILE} from HuggingFace..."
curl -L -o "${SCRIPT_DIR}/${MODEL_FILE}" "${MODEL_URL}"

if [ $? -eq 0 ]; then
    echo "Downloaded ${MODEL_FILE} successfully"
    ls -lh "${SCRIPT_DIR}/${MODEL_FILE}"
else
    echo "Failed to download ${MODEL_FILE}"
    exit 1
fi

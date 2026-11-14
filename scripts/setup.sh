#!/usr/bin/env bash
# One-time setup (needs internet ONCE). After this, Notes runs fully offline.
# Downloads:
#   - PrismML's llama.cpp fork (llama-server, Metal build) — required for Ternary Bonsai 2
#   - Ternary Bonsai 2 GGUF model (default 4B, ~1.15 GB; set BONSAI_MODEL=2B or 9B)
# Whisper + SpeakerKit (Argmax) models are fetched by the app's "Download models" button.
set -euo pipefail

BONSAI_MODEL="${BONSAI_MODEL:-4B}"
LLAMA_TAG="${LLAMA_TAG:-prism-b12128-d7b2896}"
SUPPORT="$HOME/Library/Application Support/Notes"
BIN="$SUPPORT/bin"
LLM="$SUPPORT/models/llm"
mkdir -p "$BIN" "$LLM"

if [ ! -x "$BIN/llama-server" ]; then
  echo "→ Downloading PrismML llama.cpp (${LLAMA_TAG}, macOS arm64 Metal)…"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar \
    "https://github.com/PrismML-Eng/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64.tar.gz" \
    -o "$tmp/llama.tar.gz"
  tar -xzf "$tmp/llama.tar.gz" -C "$tmp"
  srv="$(find "$tmp" -name llama-server -type f | head -1)"
  cp -R "$(dirname "$srv")"/. "$BIN"/
  xattr -dr com.apple.quarantine "$BIN" 2>/dev/null || true
  rm -rf "$tmp"
fi
echo "✓ llama-server: $BIN/llama-server"

FILE="Ternary-Bonsai-2-${BONSAI_MODEL}-PQ2_0.gguf"
if [ ! -f "$LLM/$FILE" ]; then
  echo "→ Downloading ${FILE}…"
  curl -fL --progress-bar -o "$LLM/$FILE.part" \
    "https://huggingface.co/prism-ml/Ternary-Bonsai-2-${BONSAI_MODEL}-gguf/resolve/main/$FILE"
  mv "$LLM/$FILE.part" "$LLM/$FILE"
fi
echo "✓ Bonsai model: $LLM/$FILE"
echo
echo "Done. Next: ./scripts/build_app.sh && open build/Notes.app"

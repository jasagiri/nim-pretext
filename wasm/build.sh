#!/bin/bash
# nim-pretext WASM build script
# Compiles Nim → C → clang → WASM using wasm32-wasi target
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$SCRIPT_DIR/dist"

mkdir -p "$DIST_DIR"

echo "Building nim-pretext WASM module..."

# Check for required tools
for cmd in nim clang wasm-ld; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: $cmd not found in PATH"
    exit 1
  fi
done

# Find wasi-sysroot
WASI_SYSROOT=""
for path in \
  "/opt/homebrew/share/wasi-sysroot" \
  "/usr/share/wasi-sysroot" \
  "/usr/local/share/wasi-sysroot" \
  "$HOME/.wasi-sdk/share/wasi-sysroot"; do
  if [ -d "$path" ]; then
    WASI_SYSROOT="$path"
    break
  fi
done

if [ -z "$WASI_SYSROOT" ]; then
  echo "Error: wasi-sysroot not found. Install with: brew install wasi-libc"
  exit 1
fi

echo "Using wasi-sysroot: $WASI_SYSROOT"

# Step 1: Compile Nim to C
echo "Step 1: Nim -> C..."
nim c \
    --compileOnly \
    --os:any \
    --cpu:wasm32 \
    --cc:clang \
    --mm:arc \
    --exceptions:quirky \
    --threads:off \
    -d:release \
    -d:danger \
    -d:noSignalHandler \
    -d:useMalloc \
    --opt:speed \
    --panics:on \
    --noMain:on \
    --app:lib \
    --path:"$PROJECT_DIR/src" \
    --path:"$SCRIPT_DIR" \
    --nimcache:"$SCRIPT_DIR/nimcache" \
    "$PROJECT_DIR/src/nim_pretext/wasm_exports.nim" 2>&1

# Step 2: Compile C to WASM using clang directly
echo "Step 2: C -> WASM..."
C_FILES=$(find "$SCRIPT_DIR/nimcache" -name '*.c' 2>/dev/null)
if [ -z "$C_FILES" ]; then
  echo "Error: No C files generated in nimcache"
  exit 1
fi

OBJ_FILES=""
for cfile in $C_FILES; do
  objfile="${cfile%.c}.o"
  NIM_LIB_DIR=$(nim dump --dump.format:json 2>/dev/null | grep -o '"libpath":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "")
  if [ -z "$NIM_LIB_DIR" ]; then
    NIM_LIB_DIR="$(dirname "$(which nim)")/../lib"
  fi
  clang \
    --target=wasm32-wasi \
    --sysroot="$WASI_SYSROOT" \
    -O3 \
    -flto \
    -c \
    -I"$SCRIPT_DIR/nimcache" \
    -I"$NIM_LIB_DIR" \
    "$cfile" \
    -o "$objfile" 2>&1
  OBJ_FILES="$OBJ_FILES $objfile"
done

# Step 3: Link into WASM module
echo "Step 3: Link -> WASM..."
wasm-ld \
  --no-entry \
  --export-all \
  --lto-O3 \
  --allow-undefined \
  --initial-memory=1048576 \
  -L"$WASI_SYSROOT/lib/wasm32-wasi" \
  -lc \
  $OBJ_FILES \
  -o "$DIST_DIR/nim_pretext.wasm"

# Report size
WASM_SIZE=$(wc -c < "$DIST_DIR/nim_pretext.wasm" | tr -d ' ')
echo "Built: $DIST_DIR/nim_pretext.wasm ($WASM_SIZE bytes)"

# Optimize with wasm-opt if available
if command -v wasm-opt &> /dev/null; then
  wasm-opt -O3 "$DIST_DIR/nim_pretext.wasm" -o "$DIST_DIR/nim_pretext.opt.wasm"
  OPT_SIZE=$(wc -c < "$DIST_DIR/nim_pretext.opt.wasm" | tr -d ' ')
  mv "$DIST_DIR/nim_pretext.opt.wasm" "$DIST_DIR/nim_pretext.wasm"
  echo "Optimized: $OPT_SIZE bytes (wasm-opt -O3)"
fi

# ---------------------------------------------------------------------------
# nilvm build (optional — requires nilvm in ecosystem)
# ---------------------------------------------------------------------------

NLVM="$PROJECT_DIR/../nilvm/nlvm/nlvm"
if [ -x "$NLVM" ]; then
  echo ""
  echo "Building nilvm variant..."

  # nlvm_system stub (required by nilvm's patched stdlib)
  # panicoverride.nim also needed (standalone OS requires it)
  STUB_DIR=$(mktemp -d)
  echo "# stub" > "$STUB_DIR/nlvm_system.nim"
  cp "$SCRIPT_DIR/panicoverride.nim" "$STUB_DIR/"
  # nilvm also needs panicoverride next to the source file
  cp "$SCRIPT_DIR/panicoverride.nim" "$PROJECT_DIR/src/nim_pretext/panicoverride.nim"

  rm -rf "$SCRIPT_DIR/nimcache_nlvm"

  $NLVM c \
      --cpu:wasm32 \
      --os:standalone \
      --mm:none \
      --passl:-Wl,--no-entry \
      --passl:-Wl,--export-all \
      --passl:-Wl,--allow-undefined \
      --passc:-mattr=+bulk-memory \
      -d:release \
      -d:danger \
      -d:nilvm \
      --opt:speed \
      --path:"$PROJECT_DIR/src" \
      --path:"$STUB_DIR" \
      --path:"$SCRIPT_DIR" \
      --nimcache:"$SCRIPT_DIR/nimcache_nlvm" \
      --out:"$DIST_DIR/nim_pretext_nlvm.wasm" \
      "$PROJECT_DIR/src/nim_pretext/wasm_exports.nim" 2>&1

  rm -rf "$STUB_DIR"

  if [ -f "$DIST_DIR/nim_pretext_nlvm.wasm" ]; then
    NLVM_SIZE=$(wc -c < "$DIST_DIR/nim_pretext_nlvm.wasm" | tr -d ' ')
    echo "Built: $DIST_DIR/nim_pretext_nlvm.wasm ($NLVM_SIZE bytes)"
  else
    echo "nilvm build failed (non-fatal)"
  fi
else
  echo ""
  echo "Skipping nilvm build (nlvm not found at $NLVM)"
fi

echo ""
echo "Done."

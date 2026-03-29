# Package
version       = "0.1.0"
author        = "GodsGolemInc"
description   = "Nim port of pretext text layout engine, compiled to WASM"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

task test, "Run tests":
  exec "nim c -r tests/test_line_break.nim"

task buildWasm, "Build WASM module":
  exec "bash wasm/build.sh"

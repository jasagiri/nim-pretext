## Panic and OS override for bare WASM builds.
## Provides minimal stubs that Nim's runtime needs.

proc rawoutput(s: string) =
  discard

proc panic(s: string) {.noreturn.} =
  rawoutput(s)
  while true: discard

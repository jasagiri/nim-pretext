## nim-pretext: Nim port of pretext text layout engine
##
## Two-phase text layout without DOM reflow:
## - prepare() in JS: segment text, measure via canvas (browser APIs)
## - layout() in Nim/WASM: pure arithmetic line breaking on cached widths

import nim_pretext/types
import nim_pretext/line_break

export types, line_break

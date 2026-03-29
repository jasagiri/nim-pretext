/**
 * JS ↔ WASM bridge for nilvm-built nim-pretext.
 * Minimal imports: only env.fmod needed.
 * Chunks are passed as flat int32 arrays (3 ints per chunk).
 */

import { type TransferredPrepared } from "./bridge.ts";

const BREAK_KIND_MAP: Record<string, number> = {
  text: 0, space: 1, "preserved-space": 2, tab: 3,
  glue: 4, "zero-width-break": 5, "soft-hyphen": 6, "hard-break": 7,
};

type NlvmExports = {
  memory: WebAssembly.Memory;
  pt_layout_count_lines: (...args: number[]) => number;
};

export class NimPretextNlvm {
  private wasm: NlvmExports;
  private bumpPtr: number;

  private constructor(wasm: NlvmExports) {
    this.wasm = wasm;
    // nilvm module with --mm:none has no allocator.
    // We manually bump-allocate into its memory, starting at a safe offset.
    this.bumpPtr = 65536; // Start at 64KB (well past any static data)
  }

  static async load(wasmPath: string): Promise<NimPretextNlvm> {
    const response = await fetch(wasmPath);
    const wasmBytes = await response.arrayBuffer();

    const imports = {
      env: {
        fmod: (a: number, b: number) => a % b,
      },
    };

    const module = await WebAssembly.instantiate(wasmBytes, imports);
    const exports = module.instance.exports as unknown as NlvmExports;
    return new NimPretextNlvm(exports);
  }

  private allocAligned(bytes: number): number {
    const ptr = this.bumpPtr;
    this.bumpPtr += bytes;
    this.bumpPtr = (this.bumpPtr + 7) & ~7; // align to 8
    // Grow memory if needed
    const pages = this.wasm.memory.buffer.byteLength / 65536;
    const neededPages = Math.ceil(this.bumpPtr / 65536);
    if (neededPages > pages) {
      this.wasm.memory.grow(neededPages - pages);
    }
    return ptr;
  }

  private writeFloat64Array(data: number[]): number {
    const ptr = this.allocAligned(data.length * 8);
    new Float64Array(this.wasm.memory.buffer, ptr, data.length).set(data);
    return ptr;
  }

  private writeInt32Array(data: number[]): number {
    const ptr = this.allocAligned(data.length * 4);
    new Int32Array(this.wasm.memory.buffer, ptr, data.length).set(data);
    return ptr;
  }

  private writeUint8Array(data: number[]): number {
    const ptr = this.allocAligned(data.length);
    new Uint8Array(this.wasm.memory.buffer, ptr, data.length).set(data);
    return ptr;
  }

  transferPrepared(prepared: any): TransferredPrepared {
    const widths: number[] = prepared.widths;
    const lineEndFitAdvances: number[] = prepared.lineEndFitAdvances;
    const lineEndPaintAdvances: number[] = prepared.lineEndPaintAdvances;
    const kinds: string[] = prepared.kinds;
    const breakableWidths: (number[] | null)[] = prepared.breakableWidths;
    const breakablePrefixWidths: (number[] | null)[] = prepared.breakablePrefixWidths;
    const chunks: { startSegmentIndex: number; endSegmentIndex: number; consumedEndSegmentIndex: number }[] = prepared.chunks;
    const n = widths.length;

    const widthsPtr = this.writeFloat64Array(widths);
    const fitPtr = this.writeFloat64Array(lineEndFitAdvances);
    const paintPtr = this.writeFloat64Array(lineEndPaintAdvances);
    const kindsU8 = kinds.map(k => BREAK_KIND_MAP[k] ?? 0);
    const kindsPtr = this.writeUint8Array(kindsU8);

    const offsets: number[] = [];
    const lengths: number[] = [];
    const flatData: number[] = [];
    const flatPrefixData: number[] = [];
    let hasPrefixData = false;

    for (let i = 0; i < n; i++) {
      const bw = breakableWidths[i];
      if (bw === null || bw === undefined) {
        offsets.push(-1);
        lengths.push(0);
      } else {
        offsets.push(flatData.length);
        lengths.push(bw.length);
        for (const w of bw) flatData.push(w);
        const bpw = breakablePrefixWidths?.[i];
        if (bpw) { hasPrefixData = true; for (const w of bpw) flatPrefixData.push(w); }
        else { for (let j = 0; j < bw.length; j++) flatPrefixData.push(0); }
      }
    }

    const offsetsPtr = this.writeInt32Array(offsets);
    const dataPtr = this.writeFloat64Array(flatData);
    const lengthsPtr = this.writeInt32Array(lengths);
    let prefixDataPtr = 0;
    if (hasPrefixData) prefixDataPtr = this.writeFloat64Array(flatPrefixData);

    const chunkData: number[] = [];
    for (const c of chunks) chunkData.push(c.startSegmentIndex, c.endSegmentIndex, c.consumedEndSegmentIndex);
    const chunksPtr = this.writeInt32Array(chunkData);

    return {
      segmentCount: n,
      widthsPtr, lineEndFitAdvancesPtr: fitPtr, lineEndPaintAdvancesPtr: paintPtr,
      kindsPtr, simplefast: prepared.simpleLineWalkFastPath ? 1 : 0,
      discretionaryHyphenWidth: prepared.discretionaryHyphenWidth ?? 0,
      tabStopAdvance: prepared.tabStopAdvance ?? 0,
      breakableOffsetsPtr: offsetsPtr, breakableDataPtr: dataPtr,
      breakableLengthsPtr: lengthsPtr, breakablePrefixDataPtr: prefixDataPtr,
      chunkCount: chunks.length, chunksPtr, ptrs: [],
    };
  }

  layoutCountLines(
    t: TransferredPrepared,
    maxWidth: number,
    lineFitEpsilon = 1e-3,
    preferPrefixWidths = 0,
    preferEarlySoftHyphen = 0,
  ): number {
    return this.wasm.pt_layout_count_lines(
      t.segmentCount, t.widthsPtr, t.lineEndFitAdvancesPtr, t.lineEndPaintAdvancesPtr,
      t.kindsPtr, t.simplefast, t.discretionaryHyphenWidth, t.tabStopAdvance,
      t.breakableOffsetsPtr, t.breakableDataPtr, t.breakableLengthsPtr, t.breakablePrefixDataPtr,
      t.chunkCount, t.chunksPtr, maxWidth,
      lineFitEpsilon, preferPrefixWidths, preferEarlySoftHyphen,
    );
  }
}

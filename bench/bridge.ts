/**
 * JS ↔ WASM bridge for nim-pretext.
 *
 * Transfers PreparedText internal arrays into WASM linear memory,
 * then calls the Nim layout function.
 */

// SegmentBreakKind enum values matching Nim's types.nim
const BREAK_KIND_MAP: Record<string, number> = {
  text: 0,
  space: 1,
  "preserved-space": 2,
  tab: 3,
  glue: 4,
  "zero-width-break": 5,
  "soft-hyphen": 6,
  "hard-break": 7,
};

export type WasmExports = {
  memory: WebAssembly.Memory;
  pt_init: () => void;
  pt_alloc: (size: number) => number;
  pt_free: (ptr: number) => void;
  pt_layout_count_lines: (
    segmentCount: number,
    widthsPtr: number,
    lineEndFitAdvancesPtr: number,
    lineEndPaintAdvancesPtr: number,
    kindsPtr: number,
    simplefast: number,
    discretionaryHyphenWidth: number,
    tabStopAdvance: number,
    breakableOffsetsPtr: number,
    breakableDataPtr: number,
    breakableLengthsPtr: number,
    breakablePrefixDataPtr: number,
    chunkCount: number,
    chunksPtr: number,
    maxWidth: number,
    lineFitEpsilon: number,
    preferPrefixWidths: number,
    preferEarlySoftHyphen: number,
  ) => number;
  pt_layout_count_lines_batch: (
    segmentCount: number,
    widthsPtr: number,
    lineEndFitAdvancesPtr: number,
    lineEndPaintAdvancesPtr: number,
    kindsPtr: number,
    simplefast: number,
    discretionaryHyphenWidth: number,
    tabStopAdvance: number,
    breakableOffsetsPtr: number,
    breakableDataPtr: number,
    breakableLengthsPtr: number,
    breakablePrefixDataPtr: number,
    chunkCount: number,
    chunksPtr: number,
    maxWidthsPtr: number,
    maxWidthCount: number,
    resultsPtr: number,
    lineFitEpsilon: number,
    preferPrefixWidths: number,
    preferEarlySoftHyphen: number,
  ) => number;
};

export type TransferredPrepared = {
  segmentCount: number;
  widthsPtr: number;
  lineEndFitAdvancesPtr: number;
  lineEndPaintAdvancesPtr: number;
  kindsPtr: number;
  simplefast: number;
  discretionaryHyphenWidth: number;
  tabStopAdvance: number;
  breakableOffsetsPtr: number;
  breakableDataPtr: number;
  breakableLengthsPtr: number;
  breakablePrefixDataPtr: number;
  chunkCount: number;
  chunksPtr: number;
  ptrs: number[]; // all allocated pointers for cleanup
};

export class NimPretextWasm {
  private wasm: WasmExports;

  private constructor(wasm: WasmExports) {
    this.wasm = wasm;
  }

  static async load(wasmPath: string): Promise<NimPretextWasm> {
    const response = await fetch(wasmPath);
    const wasmBytes = await response.arrayBuffer();

    // Stub all WASI imports - our WASM module doesn't actually use filesystem/IO
    const noop = () => 0;
    const wasiStub: Record<string, Function> = {};
    const wasiNames = [
      "args_get", "args_sizes_get", "environ_get", "environ_sizes_get",
      "clock_res_get", "clock_time_get",
      "fd_advise", "fd_allocate", "fd_close", "fd_datasync",
      "fd_fdstat_get", "fd_fdstat_set_flags", "fd_fdstat_set_rights",
      "fd_filestat_get", "fd_filestat_set_size", "fd_filestat_set_times",
      "fd_pread", "fd_prestat_get", "fd_prestat_dir_name", "fd_pwrite",
      "fd_read", "fd_readdir", "fd_renumber", "fd_seek", "fd_sync",
      "fd_tell", "fd_write",
      "path_create_directory", "path_filestat_get", "path_filestat_set_times",
      "path_link", "path_open", "path_readlink", "path_remove_directory",
      "path_rename", "path_symlink", "path_unlink_file",
      "poll_oneoff", "proc_exit", "sched_yield", "random_get",
      "sock_accept", "sock_recv", "sock_send", "sock_shutdown",
    ];
    for (const name of wasiNames) wasiStub[name] = noop;
    wasiStub["proc_exit"] = (_code: number) => { throw new Error(`WASI proc_exit(${_code})`); };
    const wasiImports = { wasi_snapshot_preview1: wasiStub };

    const module = await WebAssembly.instantiate(wasmBytes, wasiImports);
    const exports = module.instance.exports as unknown as WasmExports;
    exports.pt_init();
    return new NimPretextWasm(exports);
  }

  private writeFloat64Array(data: number[]): number {
    const bytes = data.length * 8;
    const ptr = this.wasm.pt_alloc(bytes);
    const view = new Float64Array(
      this.wasm.memory.buffer,
      ptr,
      data.length,
    );
    view.set(data);
    return ptr;
  }

  private writeInt32Array(data: number[]): number {
    const bytes = data.length * 4;
    const ptr = this.wasm.pt_alloc(bytes);
    const view = new Int32Array(this.wasm.memory.buffer, ptr, data.length);
    view.set(data);
    return ptr;
  }

  private writeUint8Array(data: number[]): number {
    const bytes = data.length;
    const ptr = this.wasm.pt_alloc(bytes);
    const view = new Uint8Array(this.wasm.memory.buffer, ptr, data.length);
    view.set(data);
    return ptr;
  }

  /**
   * Transfer a PreparedText's internal data into WASM memory.
   * The PreparedText must be cast to access its internal parallel arrays.
   */
  transferPrepared(prepared: any): TransferredPrepared {
    const ptrs: number[] = [];

    const widths: number[] = prepared.widths;
    const lineEndFitAdvances: number[] = prepared.lineEndFitAdvances;
    const lineEndPaintAdvances: number[] = prepared.lineEndPaintAdvances;
    const kinds: string[] = prepared.kinds;
    const breakableWidths: (number[] | null)[] = prepared.breakableWidths;
    const breakablePrefixWidths: (number[] | null)[] =
      prepared.breakablePrefixWidths;
    const chunks: {
      startSegmentIndex: number;
      endSegmentIndex: number;
      consumedEndSegmentIndex: number;
    }[] = prepared.chunks;

    const n = widths.length;

    // Widths
    const widthsPtr = this.writeFloat64Array(widths);
    ptrs.push(widthsPtr);

    const fitPtr = this.writeFloat64Array(lineEndFitAdvances);
    ptrs.push(fitPtr);

    const paintPtr = this.writeFloat64Array(lineEndPaintAdvances);
    ptrs.push(paintPtr);

    // Kinds as uint8
    const kindsU8 = kinds.map((k) => BREAK_KIND_MAP[k] ?? 0);
    const kindsPtr = this.writeUint8Array(kindsU8);
    ptrs.push(kindsPtr);

    // Flatten breakable grapheme widths
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
        if (bpw !== null && bpw !== undefined) {
          hasPrefixData = true;
          for (const w of bpw) flatPrefixData.push(w);
        } else {
          for (let j = 0; j < bw.length; j++) flatPrefixData.push(0);
        }
      }
    }

    const offsetsPtr = this.writeInt32Array(offsets);
    ptrs.push(offsetsPtr);

    const dataPtr = this.writeFloat64Array(flatData);
    ptrs.push(dataPtr);

    const lengthsPtr = this.writeInt32Array(lengths);
    ptrs.push(lengthsPtr);

    let prefixDataPtr = 0;
    if (hasPrefixData) {
      prefixDataPtr = this.writeFloat64Array(flatPrefixData);
      ptrs.push(prefixDataPtr);
    }

    // Chunks: pack as 3 int32s each
    const chunkData: number[] = [];
    for (const c of chunks) {
      chunkData.push(
        c.startSegmentIndex,
        c.endSegmentIndex,
        c.consumedEndSegmentIndex,
      );
    }
    const chunksPtr = this.writeInt32Array(chunkData);
    ptrs.push(chunksPtr);

    return {
      segmentCount: n,
      widthsPtr,
      lineEndFitAdvancesPtr: fitPtr,
      lineEndPaintAdvancesPtr: paintPtr,
      kindsPtr,
      simplefast: prepared.simpleLineWalkFastPath ? 1 : 0,
      discretionaryHyphenWidth: prepared.discretionaryHyphenWidth ?? 0,
      tabStopAdvance: prepared.tabStopAdvance ?? 0,
      breakableOffsetsPtr: offsetsPtr,
      breakableDataPtr: dataPtr,
      breakableLengthsPtr: lengthsPtr,
      breakablePrefixDataPtr: prefixDataPtr,
      chunkCount: chunks.length,
      chunksPtr,
      ptrs,
    };
  }

  /**
   * Count lines using WASM layout engine.
   */
  layoutCountLines(
    t: TransferredPrepared,
    maxWidth: number,
    lineFitEpsilon = 1e-3,
    preferPrefixWidths = 0,
    preferEarlySoftHyphen = 0,
  ): number {
    return this.wasm.pt_layout_count_lines(
      t.segmentCount,
      t.widthsPtr,
      t.lineEndFitAdvancesPtr,
      t.lineEndPaintAdvancesPtr,
      t.kindsPtr,
      t.simplefast,
      t.discretionaryHyphenWidth,
      t.tabStopAdvance,
      t.breakableOffsetsPtr,
      t.breakableDataPtr,
      t.breakableLengthsPtr,
      t.breakablePrefixDataPtr,
      t.chunkCount,
      t.chunksPtr,
      maxWidth,
      lineFitEpsilon,
      preferPrefixWidths,
      preferEarlySoftHyphen,
    );
  }

  /**
   * Free all WASM memory for a transferred prepared text.
   */
  freePrepared(t: TransferredPrepared): void {
    for (const ptr of t.ptrs) {
      this.wasm.pt_free(ptr);
    }
  }
}

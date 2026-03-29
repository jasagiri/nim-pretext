/**
 * Benchmark harness: original pretext JS vs Nim-WASM layout.
 * Multiple scenarios from simple to stress.
 */

import {
  prepare,
  prepareWithSegments,
  layout,
  type PreparedText,
  type PreparedTextWithSegments,
} from "@chenglou/pretext";
import { NimPretextWasm, type TransferredPrepared } from "./bridge.ts";
import { NimPretextNlvm } from "./bridge_nlvm.ts";

// --- Benchmark utilities ---

function median(arr: number[]): number {
  const sorted = arr.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 !== 0
    ? sorted[mid]!
    : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

function percentile(arr: number[], p: number): number {
  const sorted = arr.slice().sort((a, b) => a - b);
  const idx = Math.ceil(sorted.length * (p / 100)) - 1;
  return sorted[Math.max(0, idx)]!;
}

// --- Scenario definitions ---

type Scenario = {
  name: string;
  corpus: string[];
  widths: number[];
  font: string;
  lineHeight: number;
  warmup: number;
  iterations: number;
};

const FONT = "16px Inter, Helvetica, Arial, sans-serif";

// Repeat a string to reach approximate character count
function repeat(s: string, targetChars: number): string {
  let result = s;
  while (result.length < targetChars) result += " " + s;
  return result.slice(0, targetChars);
}

// Generate Japanese prose (~5000 chars, many segments due to per-char CJK breaking)
const CJK_PROSE = repeat(
  "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。" +
  "何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。" +
  "吾輩はここで始めて人間というものを見た。しかもあとで聞くとそれは書生という" +
  "人間中で一番獰悪な種族であったそうだ。この書生というのは時々我々を捕えて煮て食うという話である。" +
  "しかしその当時は何という考もなかったから別段恐しいとも思わなかった。",
  5000,
);

// Arabic long-form (~3000 chars, bidi complexity)
const ARABIC_PROSE = repeat(
  "في قرية من قرى لامانشا التي لا أريد أن أتذكر اسمها عاش منذ زمن ليس ببعيد أحد هؤلاء النبلاء الذين يحتفظون برمح في حامل الرماح ودرع قديم وحصان هزيل وكلب صيد للمطاردة. " +
  "كان طعامه يتكون من لحم البقر أكثر من لحم الضأن وسلطة في معظم الليالي وبقايا الطعام أيام السبت والعدس أيام الجمعة وحمامة أو نحو ذلك زيادة أيام الأحد.",
  3000,
);

// Mixed CJK + Latin + emoji (high segment diversity)
const MIXED_COMPLEX = repeat(
  "React 18のSuspense 🎉 は「宣言的なローディング状態」を提供します。" +
  "TypeScript 5.0 introduced decorators 🏷️ and const type parameters。" +
  "Nim 2.0のARC/ORC 🔄 メモリ管理は決定論的でリアルタイムシステムに適しています。" +
  "WebAssembly 🌐 enables near-native performance in browsers ブラウザで実行可能。" +
  "Unicode 15.1 added 627 new emoji 🫨 and 4 new scripts スクリプト追加。",
  4000,
);

// Very long Latin with soft-hyphen candidates (overflow-wrap stress)
const LONG_WORDS = repeat(
  "Pneumonoultramicroscopicsilicovolcanoconiosis antidisestablishmentarianism " +
  "supercalifragilisticexpialidocious hippopotomonstrosesquippedaliophobia " +
  "floccinaucinihilipilification honorificabilitudinitatibus " +
  "thyroparathyroidectomized dichlorodiphenyltrichloroethane " +
  "electroencephalographically psychoneuroendocrinological ",
  3000,
);

// Dense numeric/URL content (merging pass heavy)
const DENSE_DATA = repeat(
  "2024-03-29T14:30:00Z https://api.example.com/v2/users?page=1&limit=100&sort=created_at " +
  "IP: 192.168.1.100:8080 Phone: +1-800-555-0123 ext. 4567 " +
  "SHA-256: a3f2b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6 " +
  "Price: $1,234,567.89 (¥142,857,142) Ratio: 3.14159:2.71828 " +
  "Version: 2.0.0-beta.3+build.12345 RFC-2822 compliant ",
  3000,
);

function buildScenarios(): Scenario[] {
  return [
    {
      name: "Standard (500 mixed texts, 8 widths)",
      corpus: (() => {
        const templates = [
          "The quick brown fox jumps over the lazy dog.",
          "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.",
          "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
          "Hello世界！This is a mixed テスト with CJK and Latin text 混合。",
          "Hello 👋 World 🌍! This has emoji 🎉🎊 and text mixed together 💻✨",
        ];
        return Array.from({ length: 500 }, (_, i) => templates[i % templates.length]!);
      })(),
      widths: [100, 200, 300, 400, 500, 600, 800, 1000],
      font: FONT, lineHeight: 24, warmup: 100, iterations: 1000,
    },
    {
      name: "CJK editorial (8 x 5000-char Japanese, narrow widths)",
      corpus: Array.from({ length: 8 }, () => CJK_PROSE),
      widths: [120, 180, 240, 300, 360],
      font: FONT, lineHeight: 28, warmup: 50, iterations: 500,
    },
    {
      name: "Arabic long-form (8 texts, bidi-heavy)",
      corpus: Array.from({ length: 8 }, () => ARABIC_PROSE),
      widths: [150, 240, 300, 360, 480],
      font: FONT, lineHeight: 28, warmup: 50, iterations: 500,
    },
    {
      name: "Mixed multilingual (16 texts, CJK+Latin+emoji)",
      corpus: Array.from({ length: 16 }, () => MIXED_COMPLEX),
      widths: [200, 300, 400, 600],
      font: FONT, lineHeight: 24, warmup: 50, iterations: 500,
    },
    {
      name: "Long words overflow-wrap (16 texts, very narrow)",
      corpus: Array.from({ length: 16 }, () => LONG_WORDS),
      widths: [80, 120, 160, 200, 300],
      font: FONT, lineHeight: 20, warmup: 50, iterations: 500,
    },
    {
      name: "Dense data/URLs (16 texts, numeric merging)",
      corpus: Array.from({ length: 16 }, () => DENSE_DATA),
      widths: [200, 300, 400, 600],
      font: FONT, lineHeight: 20, warmup: 50, iterations: 500,
    },
    {
      name: "Resize sweep (1 large CJK text, 20 widths)",
      corpus: [CJK_PROSE],
      widths: Array.from({ length: 20 }, (_, i) => 100 + i * 50),
      font: FONT, lineHeight: 24, warmup: 100, iterations: 2000,
    },
  ];
}

// --- Run a single scenario ---

async function runScenario(
  scenario: Scenario,
  wasm: NimPretextWasm,
  nlvm: NimPretextNlvm,
  log: (msg: string) => void,
) {
  const { name, corpus, widths, font, lineHeight, warmup, iterations } = scenario;

  log(`\n--- ${name} ---`);

  // Prepare
  const prepared = corpus.map((text) => prepareWithSegments(text, font));
  const totalSegs = prepared.reduce((sum, p) => sum + (p as any).widths.length, 0);
  log(`  Texts: ${corpus.length}, Segments: ${totalSegs}, Widths: ${widths.length}`);

  // Transfer
  const clangT = prepared.map((p) => wasm.transferPrepared(p as any));
  const nlvmT = prepared.map((p) => nlvm.transferPrepared(p as any));

  // Validate
  let ok = true;
  for (let ti = 0; ti < prepared.length; ti++) {
    for (const w of widths) {
      const js = layout(prepared[ti]! as unknown as PreparedText, w, lineHeight).lineCount;
      const cl = wasm.layoutCountLines(clangT[ti]!, w);
      const nl = nlvm.layoutCountLines(nlvmT[ti]!, w);
      if (js !== cl || js !== nl) {
        log(`  MISMATCH text[${ti}] @${w}px: JS=${js} clang=${cl} nilvm=${nl}`);
        ok = false;
      }
    }
  }
  if (!ok) { log("  SKIPPING (correctness failed)"); return null; }

  const callsPerIter = corpus.length * widths.length;

  // Warmup
  for (let iter = 0; iter < warmup; iter++) {
    for (const p of prepared) for (const w of widths) layout(p as unknown as PreparedText, w, lineHeight);
    for (const t of clangT) for (const w of widths) wasm.layoutCountLines(t, w);
    for (const t of nlvmT) for (const w of widths) nlvm.layoutCountLines(t, w);
  }

  // Measure
  const jsTimes: number[] = [];
  for (let iter = 0; iter < iterations; iter++) {
    const start = performance.now();
    for (const p of prepared) for (const w of widths) layout(p as unknown as PreparedText, w, lineHeight);
    jsTimes.push(performance.now() - start);
  }

  const clangTimes: number[] = [];
  for (let iter = 0; iter < iterations; iter++) {
    const start = performance.now();
    for (const t of clangT) for (const w of widths) wasm.layoutCountLines(t, w);
    clangTimes.push(performance.now() - start);
  }

  const nlvmTimes: number[] = [];
  for (let iter = 0; iter < iterations; iter++) {
    const start = performance.now();
    for (const t of nlvmT) for (const w of widths) nlvm.layoutCountLines(t, w);
    nlvmTimes.push(performance.now() - start);
  }

  // Cleanup
  for (const t of clangT) wasm.freePrepared(t);

  const jsM = median(jsTimes);
  const clM = median(clangTimes);
  const nlM = median(nlvmTimes);

  log(`  Calls/iter: ${callsPerIter} | Warmup: ${warmup} | Measured: ${iterations}`);
  log(`  JS:     ${jsM.toFixed(3)}ms  (${(jsM / callsPerIter * 1000).toFixed(3)} us/call)`);
  log(`  clang:  ${clM.toFixed(3)}ms  (${(clM / callsPerIter * 1000).toFixed(3)} us/call)  ${(jsM / clM).toFixed(1)}x`);
  log(`  nilvm:  ${nlM.toFixed(3)}ms  (${(nlM / callsPerIter * 1000).toFixed(3)} us/call)  ${(jsM / nlM).toFixed(1)}x`);

  return { name, callsPerIter, jsM, clM, nlM };
}

// --- Main ---

async function runBenchmark() {
  const log = (msg: string) => {
    const el = document.getElementById("output");
    if (el) el.textContent += msg + "\n";
    console.log(msg);
  };

  log("=== nim-pretext Benchmark: JS vs WASM ===");
  log("Loading WASM modules...");
  const wasm = await NimPretextWasm.load("./nim_pretext.wasm");
  const nlvm = await NimPretextNlvm.load("./nim_pretext_nlvm.wasm");
  log("Loaded.\n");

  const scenarios = buildScenarios();
  const results: { name: string; callsPerIter: number; jsM: number; clM: number; nlM: number }[] = [];

  for (const scenario of scenarios) {
    const r = await runScenario(scenario, wasm, nlvm, log);
    if (r) results.push(r);
  }

  // Summary table
  log("\n=== Summary ===\n");
  log("| Scenario | Segs | JS (us/call) | clang | nilvm |");
  log("|---|---|---|---|---|");
  for (const r of results) {
    const jsUs = (r.jsM / r.callsPerIter * 1000).toFixed(3);
    const clX = (r.jsM / r.clM).toFixed(1);
    const nlX = (r.jsM / r.nlM).toFixed(1);
    log(`| ${r.name.split("(")[0]!.trim()} | ${r.callsPerIter} | ${jsUs} | ${clX}x | ${nlX}x |`);
  }

  log("\nDone.");
}

runBenchmark();

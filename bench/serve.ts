/**
 * Dev server for the benchmark page.
 * Serves static files and handles TypeScript transpilation.
 */

const BENCH_DIR = import.meta.dir;
const WASM_DIR = BENCH_DIR + "/../wasm/dist";

Bun.serve({
  port: 3456,
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname;

    if (path === "/" || path === "/index.html") {
      return new Response(Bun.file(BENCH_DIR + "/index.html"), {
        headers: { "Content-Type": "text/html" },
      });
    }

    // WASM files
    if (path.endsWith(".wasm")) {
      const wasmFile = Bun.file(WASM_DIR + path);
      if (await wasmFile.exists()) {
        return new Response(wasmFile, {
          headers: { "Content-Type": "application/wasm" },
        });
      }
    }

    // TypeScript files: build on the fly
    if (path.endsWith(".js")) {
      const tsPath = path.replace(/\.js$/, ".ts");
      const tsFile = BENCH_DIR + tsPath;

      if (await Bun.file(tsFile).exists()) {
        const build = await Bun.build({
          entrypoints: [tsFile],
          target: "browser",
          format: "esm",
        });

        if (build.success && build.outputs.length > 0) {
          const text = await build.outputs[0]!.text();
          return new Response(text, {
            headers: { "Content-Type": "application/javascript" },
          });
        }
      }

      // Try serving .js directly
      const jsFile = BENCH_DIR + path;
      if (await Bun.file(jsFile).exists()) {
        return new Response(Bun.file(jsFile), {
          headers: { "Content-Type": "application/javascript" },
        });
      }
    }

    // Static files
    const file = Bun.file(BENCH_DIR + path);
    if (await file.exists()) {
      return new Response(file);
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log("Benchmark server running at http://localhost:3456");

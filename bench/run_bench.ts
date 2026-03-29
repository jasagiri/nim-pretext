/**
 * Headless benchmark runner using Playwright.
 * Launches a browser, navigates to the benchmark page,
 * and captures the output.
 */

import { chromium } from "playwright";

async function main() {
  console.log("Launching headless Chrome...");

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  // Capture console output
  page.on("console", (msg) => {
    console.log(msg.text());
  });

  page.on("pageerror", (err) => {
    console.error("Page error:", err.message);
  });

  console.log("Navigating to benchmark page...");
  await page.goto("http://localhost:3456/", { waitUntil: "networkidle" });

  // Wait for benchmark to complete (look for "Done." in output)
  console.log("Waiting for benchmark to complete...");
  await page.waitForFunction(
    () => {
      const el = document.getElementById("output");
      return el?.textContent?.includes("Done.") ?? false;
    },
    { timeout: 1200000 }, // 20 minute timeout (multi-scenario)
  );

  // Get final output
  const output = await page.$eval("#output", (el) => el.textContent);
  console.log("\n" + "=".repeat(60));
  console.log(output);
  console.log("=".repeat(60));

  await browser.close();
}

main().catch(console.error);

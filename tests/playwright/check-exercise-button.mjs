// Drives a real browser against the example frontend and presses the given
// exercise button (data-exercise="<name>"), the same way a student would in
// the UI, instead of hitting the backend API directly.
//
// Usage: node check-exercise-button.mjs <app-url> <exercise-name>

import { chromium } from "playwright";

async function main() {
  const [url, exercise] = process.argv.slice(2);
  if (!url || !exercise) {
    throw new Error("usage: node check-exercise-button.mjs <app-url> <exercise-name>");
  }

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto(url, { waitUntil: "domcontentloaded" });

    const button = page.locator(`[data-exercise="${exercise}"]`);
    await button.waitFor({ state: "visible", timeout: 30000 });

    // The button only makes a single request per click -- it doesn't retry
    // on its own. If the backend dependency (e.g. Postgres) isn't ready yet
    // at the moment of the click, it just reports "Not yet working" and
    // stays clickable forever. A real student would click it again, so keep
    // clicking until it reports success (data-ex-success="<exercise>") or
    // we run out of time.
    const success = page.locator(`[data-ex-success="${exercise}"]`);
    const deadline = Date.now() + 60000;
    let reported = false;
    while (Date.now() < deadline) {
      await button.click();
      try {
        await success.waitFor({ timeout: 3000 });
        reported = true;
        break;
      } catch {
        // Not ready yet -- click again.
      }
    }
    if (!reported) {
      throw new Error(`button never reported success within 60s of retrying`);
    }

    // The status message for this exercise sits in the sibling span right
    // after the button (the page has one such span per exercise).
    const message = (
      await button.locator('xpath=following-sibling::span[@class="exercise-status"]').first().textContent()
    )?.trim();

    console.log(`PASS: pressing the "${exercise}" button reported success (message: "${message}")`);
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(`FAIL: ${error.message}`);
  process.exit(1);
});

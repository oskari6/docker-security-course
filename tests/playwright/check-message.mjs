// Drives the "messages" section of the frontend (the postgres exercise's
// input field + "Send message!" / "Get all messages!" buttons), instead of
// calling POST/GET /api/messages directly.
//
// Usage:
//   node check-message.mjs <app-url> send "<message body>"   -- types the
//     message, presses "Send message!", then presses "Get all messages!"
//     and waits for it to show up in the list.
//   node check-message.mjs <app-url> check "<message body>"  -- presses
//     "Get all messages!" and waits for the message to show up, without
//     sending it first (used to check that a previously sent message is
//     still there, e.g. after restarting the stack).
//   node check-message.mjs <app-url> absent "<message body>" -- presses
//     "Get all messages!" and confirms the message does NOT show up (used
//     to check that data is actually gone, e.g. after wiping the bind
//     mount's host directory and restarting). The caller is responsible
//     for confirming the backend is actually connected before calling this
//     (e.g. via check-exercise-button.mjs), so an empty result here means
//     "the data is gone", not "the backend hasn't answered yet".

import { chromium } from "playwright";

async function main() {
  const [url, mode, body] = process.argv.slice(2);
  if (!url || !["send", "check", "absent"].includes(mode) || !body) {
    throw new Error('usage: node check-message.mjs <app-url> send|check|absent "<message body>"');
  }

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto(url, { waitUntil: "domcontentloaded" });

    if (mode === "send") {
      const input = page.locator("#message");
      await input.waitFor({ state: "visible", timeout: 30000 });
      await input.fill(body);
      await page.getByRole("button", { name: "Send message!" }).click();
    }

    const getAllButton = page.getByRole("button", { name: "Get all messages!" });
    const target = page.getByText(body, { exact: true });

    if (mode === "absent") {
      await getAllButton.click();
      await page.waitForTimeout(2000);
      const count = await target.count();
      if (count > 0) {
        throw new Error(`message "${body}" is still listed, but it should be gone`);
      }
      console.log(`PASS: message "${body}" is not listed (as expected)`);
      return;
    }

    // "Get all messages!" only makes a single request per click -- if the
    // backend isn't connected to Postgres yet (e.g. right after a restart,
    // while it's still retrying the connection), one click just yields an
    // empty/stale list. A real student would click it again, so keep
    // clicking until the message shows up or we run out of time.
    const deadline = Date.now() + 60000;
    let found = false;
    while (Date.now() < deadline) {
      await getAllButton.click();
      try {
        await target.waitFor({ timeout: 3000 });
        found = true;
        break;
      } catch {
        // Not there yet -- click again.
      }
    }
    if (!found) {
      throw new Error(`message never appeared within 60s of retrying "Get all messages!"`);
    }

    console.log(`PASS: message "${body}" is listed in the frontend's message list`);
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(`FAIL: ${error.message}`);
  process.exit(1);
});

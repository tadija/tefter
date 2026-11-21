import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const cwd = fileURLToPath(new URL("../..", import.meta.url));
const home = await mkdtemp(join(tmpdir(), "tefter-browser-"));
const probe = net.createServer();
probe.listen(0, "127.0.0.1");
await once(probe, "listening");
const port = probe.address().port;
await new Promise((resolve) => probe.close(resolve));
const env = { ...process.env, TEFTER_HOME: home, TEFTER_PORT: String(port) };
const url = "http://127.0.0.1:" + port;
const email = "reader@example.test";
const password = "local browser password";
let server, browser;
try {
  const bootstrap = spawnSync(".build/debug/tefter", ["bootstrap", email], {
    cwd,
    env,
    input: password + "\n",
  });
  assert.equal(bootstrap.status, 0, bootstrap.stderr.toString());
  server = spawn(".build/debug/tefter", [], { cwd, env, stdio: "ignore" });
  for (let attempt = 0; attempt < 100; attempt++) {
    if (
      await fetch(url + "/api/v1/ready").then(
        (r) => r.ok,
        () => false,
      )
    )
      break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  browser = await chromium.launch({
    channel: "chrome",
    headless: true,
    executablePath: process.env.TEFTER_TEST_CHROME || undefined,
  });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(url);
  await page.getByLabel("Email", { exact: true }).first().fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.getByLabel("File path", { exact: true }).fill("notes.md");
  await page
    .getByLabel("Markdown", { exact: true })
    .fill("# Meeting notes\n\nA durable decision.");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page.getByRole("heading", { name: "Meeting notes" }).waitFor();
  await page
    .getByLabel("New comment", { exact: true })
    .fill("Document approval");
  await page.getByRole("button", { name: "Save comment" }).click();
  await page.getByText("Document approval", { exact: true }).waitFor();
  await page
    .getByRole("button", { name: "Search", exact: true })
    .first()
    .click();
  await page.getByLabel("Search content and comments").fill("approval");
  await page
    .getByRole("button", { name: "Search", exact: true })
    .last()
    .click();
  await page.getByText(/notes · notes.md/).waitFor();
  await page.reload();
  await page.getByRole("button", { name: "notes.md", exact: true }).click();
  await page.getByText("Document approval", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await page.getByRole("button", { name: "Sign in", exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log(
    "Passed browser sign-in, document editing, comments, search, page reload and logout.",
  );
} finally {
  await browser?.close();
  if (server && server.exitCode === null) {
    const exit = once(server, "exit");
    server.kill("SIGTERM");
    await exit;
  }
  await rm(home, { recursive: true, force: true });
}

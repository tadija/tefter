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
const binary = process.env.TEFTER_TEST_BINARY || ".build/debug/tefter";
let server, browser;
try {
  const bootstrap = spawnSync(binary, ["bootstrap", email], {
    cwd,
    env,
    input: password + "\n",
  });
  assert.equal(bootstrap.status, 0, bootstrap.stderr.toString());
  server = spawn(binary, [], { cwd, env, stdio: "ignore" });
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
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(url);
  await page.getByLabel("Email", { exact: true }).first().fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.getByLabel("File path", { exact: true }).fill("notes.md");
  await page
    .getByLabel("Markdown", { exact: true })
    .fill(
      "# Meeting notes\n\nA durable decision.\n\n<form><input name=embedded-control></form>",
    );
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page.getByRole("heading", { name: "Meeting notes" }).waitFor();
  assert.equal(await page.locator("article input").count(), 0);
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
  // Stage 2: two browser clients, sanitized live messages and promotion.
  const peer = await page.context().newPage();
  peer.on("pageerror", (error) => errors.push(error.message));
  await peer.goto(url);
  for (const client of [page, peer]) {
    await client.getByRole("button", { name: "Comms", exact: true }).click();
    await client
      .getByText("Live", { exact: true })
      .waitFor({ timeout: 8000 })
      .catch(async (e) => {
        console.error(await client.locator("body").innerText());
        throw e;
      });
  }
  await page
    .getByLabel("Message", { exact: true })
    .fill("**Live decision** <img src=x onerror=alert(1)>");
  await page.getByRole("button", { name: "Send message", exact: true }).click();
  for (const client of [page, peer]) {
    await client
      .locator("article strong")
      .filter({ hasText: "Live decision" })
      .waitFor();
    assert.equal(await client.locator("article img").count(), 0);
  }
  await page.getByLabel("New channel", { exact: true }).fill("planning");
  await page
    .getByRole("button", { name: "Create channel", exact: true })
    .click();
  await page.waitForFunction(
    () =>
      document.querySelector("#comms-channel")?.selectedOptions[0]
        ?.textContent === "#planning",
  );
  await page.getByText("Live", { exact: true }).waitFor();
  await page
    .getByLabel("Channel", { exact: true })
    .selectOption({ label: "#general" });
  await page
    .locator("article strong")
    .filter({ hasText: "Live decision" })
    .waitFor();
  await page
    .getByRole("button", { name: "Promote to document", exact: true })
    .click();
  await page.getByLabel("File path", { exact: true }).fill("promoted.md");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page
    .locator("section article strong")
    .filter({ hasText: "Live decision" })
    .waitFor();
  await peer.close();

  // Share a personal document into an organization space without copying it.
  const prepared = await page.evaluate(async () => {
    const { csrf } = await (await fetch("/api/v1/session")).json();
    const call = async (path, data) => {
      const response = await fetch("/api/v1/" + path, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
        body: JSON.stringify(data),
      });
      if (!response.ok) throw Error(await response.text());
      return response.json();
    };
    const source = (await (await fetch("/api/v1/spaces")).json()).spaces[0].id;
    const org = await call("organizations", { name: "Collaboration" });
    const target = await call(`organizations/${org.id}/spaces`, {
      name: "Team",
    });
    const grant = await call(`spaces/${source}/shares`, {
      path: "notes.md",
      target: target.id,
      allowExport: false,
    });
    return { source, target: target.id, grant: grant.id };
  });
  await page.reload();
  await page.getByLabel("Space", { exact: true }).selectOption(prepared.target);
  await page.getByRole("button", { name: "Sharing", exact: true }).click();
  await page.getByLabel("Grant ID", { exact: true }).fill(prepared.grant);
  await page
    .getByRole("button", { name: "Add shared reference", exact: true })
    .click();
  await page.getByRole("button", { name: "notes", exact: true }).click();
  await page
    .getByRole("article", { name: "Shared preview" })
    .getByRole("heading", { name: "Meeting notes" })
    .waitFor();
  await page.getByText("Document approval", { exact: true }).waitFor();
  await page.evaluate(async ({ source, grant }) => {
    const { csrf } = await (await fetch("/api/v1/session")).json();
    const res = await fetch(`/api/v1/spaces/${source}/shares/${grant}`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf },
    });
    if (!res.ok) throw Error("Revoke failed");
  }, prepared);
  await page.getByText("Shared content unavailable", { exact: true }).waitFor();
  await page
    .getByRole("article", { name: "Shared preview" })
    .waitFor({ state: "detached" });
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await page.getByRole("button", { name: "Sign in", exact: true }).waitFor();
  assert.deepEqual(errors, []);
  console.log(
    "Passed browser workspace, two-client Comms, sanitization, promotion, sharing, revocation and logout.",
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

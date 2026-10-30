// AFFiNE smoke test, platform smoke-test contract v0.1
// (hackathon-platform-team: platform/schemas/app-catalog/README.md#smoke-test-vertrag).
//
// Checks the central user action end to end: sign in, find (first run: create) a fixed test
// document with an attachment, write to the document and read everything back over HTTP.
// Diagnostics go to stderr; the last stdout line is the JSON result. Exit code 0 only on success.
//
// Environment:
//   TARGET_URL            https://affine.<baseDomain> (set by the platform)
//   SMOKE_USER_EMAIL      smoke user's email (catalog smokeTest.env)
//   SMOKE_USER_PASSWORD   smoke user's password (catalog smokeTest.secrets, generated secret)
//   ATTEMPTS              attempts for the initial /info check, default 5
//   RETRY_DELAY_SECONDS   delay between those attempts, default 6
//   TIMEOUT_SECONDS       timeout per request, default 20
//   INSECURE_TLS          "true" skips certificate checks (staging HTTP/self-signed fallback only)

import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { io } from "socket.io-client";
import * as Y from "yjs";

// Fixed fixture: created once, found again by every later run (acceptance scenario 9).
export const FIXTURE_DOC_ID = "mmk-smoke-persistence";
export const FIXTURE_TITLE = "MMK Smoke-Test: Persistenz";
export const FIXTURE_MARKER = "mmk-smoke-persistence-v1";
export const WORKSPACE_NAME = "MMK Smoke";
export const ATTACHMENT_NAME = "mmk-smoke-attachment.txt";
export const ATTACHMENT_BYTES = Buffer.from("MMK DIGITAL AFFiNE smoke attachment v1\n", "utf8");
// AFFiNE rejects passwords longer than 32 characters; platform-generated secrets are longer.
export const MAX_PASSWORD_LENGTH = 32;

const env = process.env;
const timeoutMs = Number(env.TIMEOUT_SECONDS ?? 20) * 1000;
if (env.INSECURE_TLS === "true") env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const log = (msg) => console.error(`[smoke] ${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

class CheckError extends Error {}

/** Minimal HTTP client with a cookie jar for AFFiNE's session cookies. */
class Client {
  constructor(base) {
    this.base = base;
    this.cookies = new Map();
  }

  get cookieHeader() {
    return [...this.cookies].map(([k, v]) => `${k}=${v}`).join("; ");
  }

  async request(path, init = {}) {
    const res = await fetch(this.base + path, {
      ...init,
      headers: { "user-agent": "mmk-affine-smoke/0.1", cookie: this.cookieHeader, ...init.headers },
      redirect: "manual",
      signal: AbortSignal.timeout(timeoutMs),
    });
    for (const line of res.headers.getSetCookie()) {
      const [pair] = line.split(";");
      const i = pair.indexOf("=");
      this.cookies.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
    return res;
  }

  async json(path, body) {
    const res = await this.request(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    return { status: res.status, body: await res.json().catch(() => ({})) };
  }

  async graphql(query, variables = {}) {
    const { status, body } = await this.json("/graphql", { query, variables });
    if (status !== 200 || body.errors?.length) {
      throw new CheckError(`GraphQL ${status}: ${body.errors?.map((e) => e.message).join("; ") ?? "keine Daten"}`);
    }
    return body.data;
  }

  /** GraphQL multipart upload (graphql-multipart-request-spec). */
  async upload(query, variables, fileVar, bytes, filename, type) {
    const form = new FormData();
    form.set("operations", JSON.stringify({ query, variables: { ...variables, [fileVar]: null } }));
    form.set("map", JSON.stringify({ 0: [`variables.${fileVar}`] }));
    form.set("0", new Blob([bytes], { type }), filename);
    const res = await this.request("/graphql", {
      method: "POST",
      headers: { "x-apollo-operation-name": "smokeUpload" },
      body: form,
    });
    const body = await res.json().catch(() => ({}));
    if (res.status !== 200 || body.errors?.length) {
      throw new CheckError(`Upload ${res.status}: ${body.errors?.map((e) => e.message).join("; ") ?? "keine Daten"}`);
    }
    return body.data;
  }

  /** Doc as stored by the server (merged Yjs update), or null if it does not exist. */
  async loadDoc(workspaceId, docId) {
    const res = await this.request(`/api/workspaces/${workspaceId}/docs/${docId}`);
    if (res.status === 404) return null;
    if (res.status !== 200) throw new CheckError(`Dokument ${docId}: HTTP ${res.status}`);
    const doc = new Y.Doc();
    Y.applyUpdate(doc, new Uint8Array(await res.arrayBuffer()));
    return doc;
  }
}

/** Socket.IO session in one workspace; AFFiNE only accepts doc writes over this channel. */
async function openSpace(client, workspaceId, version) {
  const socket = io(client.base, {
    transports: ["websocket"],
    extraHeaders: { cookie: client.cookieHeader },
    reconnection: false,
    timeout: timeoutMs,
  });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("connect_error", (e) => reject(new CheckError(`WebSocket: ${e.message}`)));
  });
  const call = async (event, payload) => {
    const res = await socket.timeout(timeoutMs).emitWithAck(event, payload);
    if (res?.error) throw new CheckError(`${event}: ${res.error.message ?? JSON.stringify(res.error)}`);
    return res?.data;
  };
  await call("space:join", { spaceType: "workspace", spaceId: workspaceId, clientVersion: version });
  return {
    push: (docId, update) =>
      call("space:push-doc-update", {
        spaceType: "workspace",
        spaceId: workspaceId,
        docId,
        update: Buffer.from(update).toString("base64"),
      }),
    close: () => socket.close(),
  };
}

/** BlockSuite page with title, paragraph (marker) and an attachment block, readable in the AFFiNE UI. */
export function buildFixtureDoc(attachmentKey, createdAt) {
  const doc = new Y.Doc();
  const blocks = doc.getMap("blocks");
  const block = (id, flavour, version, props, children = []) => {
    const map = new Y.Map();
    blocks.set(id, map);
    map.set("sys:id", id);
    map.set("sys:flavour", flavour);
    map.set("sys:version", version);
    const kids = new Y.Array();
    kids.push(children);
    map.set("sys:children", kids);
    for (const [k, v] of Object.entries(props)) map.set(`prop:${k}`, v);
  };
  doc.transact(() => {
    block("page", "affine:page", 2, { title: new Y.Text(FIXTURE_TITLE) }, ["note"]);
    block(
      "note",
      "affine:note",
      1,
      { xywh: "[0,0,800,95]", background: "--affine-note-background-white", index: "a0", hidden: false, displayMode: "both" },
      ["marker", "attachment"],
    );
    block("marker", "affine:paragraph", 1, { type: "text", text: new Y.Text(FIXTURE_MARKER) });
    block("attachment", "affine:attachment", 1, {
      name: ATTACHMENT_NAME,
      size: ATTACHMENT_BYTES.length,
      type: "text/plain",
      sourceId: attachmentKey,
      embed: false,
    });
    const smoke = doc.getMap("smoke");
    smoke.set("createdAt", createdAt);
    smoke.set("attachmentKey", attachmentKey);
    smoke.set("attachmentSha256", sha256(ATTACHMENT_BYTES));
  });
  return doc;
}

/** Workspace root doc listing the fixture page, so people can open it in the UI. */
function buildRootMeta(createdAt) {
  const doc = new Y.Doc();
  const meta = doc.getMap("meta");
  doc.transact(() => {
    meta.set("name", WORKSPACE_NAME);
    const pages = new Y.Array();
    meta.set("pages", pages);
    const page = new Y.Map();
    page.set("id", FIXTURE_DOC_ID);
    page.set("title", FIXTURE_TITLE);
    page.set("createDate", Date.parse(createdAt));
    page.set("tags", new Y.Array());
    pages.push([page]);
  });
  return doc;
}

export function fixtureFacts(doc) {
  const blocks = doc.getMap("blocks");
  const marker = blocks.get("marker")?.get("prop:text")?.toString();
  const smoke = doc.getMap("smoke");
  return {
    hasMarker: marker === FIXTURE_MARKER,
    createdAt: smoke.get("createdAt"),
    attachmentKey: smoke.get("attachmentKey") ?? blocks.get("attachment")?.get("prop:sourceId"),
    lastRunAt: smoke.get("lastRunAt"),
  };
}

async function waitForInfo(client) {
  const attempts = Math.max(1, Number(env.ATTEMPTS ?? 5));
  let last = "";
  for (let i = 1; i <= attempts; i++) {
    try {
      const res = await client.request("/info");
      if (res.status === 200) return await res.json();
      last = `HTTP ${res.status}`;
    } catch (e) {
      last = e.cause?.code ?? e.message;
    }
    log(`/info Versuch ${i}/${attempts}: ${last}`);
    if (i < attempts) await sleep(Number(env.RETRY_DELAY_SECONDS ?? 6) * 1000);
  }
  throw new CheckError(`/info nicht erreichbar: ${last}`);
}

async function signIn(client, email, password) {
  const res = await client.json("/api/auth/sign-in", { email, password });
  if (res.status === 200) return { userId: res.body.id, detail: "angemeldet" };
  if (res.body?.name !== "WRONG_SIGN_IN_CREDENTIALS") {
    throw new CheckError(`Anmeldung: HTTP ${res.status} ${res.body?.name ?? ""}`.trim());
  }
  // Fresh instance: the smoke user becomes the first administrator (documented in the runbook).
  const { serverConfig } = await client.graphql("{ serverConfig { initialized } }");
  if (serverConfig.initialized) {
    throw new CheckError("Anmeldung abgelehnt: Smoke-Nutzer fehlt oder Passwort weicht ab (Runbook: Smoke-Nutzer)");
  }
  const setup = await client.json("/api/setup/create-admin-user", { email, password });
  if (setup.status < 200 || setup.status > 299) throw new CheckError(`Ersteinrichtung: HTTP ${setup.status} ${setup.body?.name ?? ""}`.trim());
  return { userId: setup.body.id, detail: "Smoke-Nutzer als erster Administrator angelegt" };
}

/** Finds the workspace that holds the fixture; creates both only when the user has no workspace yet. */
async function ensureFixture(client, version, startedAt) {
  const { workspaces } = await client.graphql("{ workspaces { id } }");
  for (const { id } of workspaces) {
    const doc = await client.loadDoc(id, FIXTURE_DOC_ID);
    if (doc) return { workspaceId: id, doc, created: false };
  }
  if (workspaces.length > 0) {
    // The user exists but the fixture is gone: data loss, never paper over it by recreating.
    throw new CheckError(`Testdokument ${FIXTURE_DOC_ID} in ${workspaces.length} Arbeitsbereich(en) nicht gefunden`);
  }

  log("erster Lauf: lege Arbeitsbereich, Anhang und Testdokument an");
  const { createWorkspace } = await client.graphql("mutation { createWorkspace { id } }");
  const workspaceId = createWorkspace.id;
  // The server stores the blob under the upload's filename; AFFiNE clients use the content hash.
  const { setBlob } = await client.upload(
    "mutation smokeUpload($workspaceId: String!, $blob: Upload!) { setBlob(workspaceId: $workspaceId, blob: $blob) }",
    { workspaceId },
    "blob",
    ATTACHMENT_BYTES,
    createHash("sha256").update(ATTACHMENT_BYTES).digest("base64url"),
    "text/plain",
  );
  const space = await openSpace(client, workspaceId, version);
  try {
    await space.push(workspaceId, Y.encodeStateAsUpdate(buildRootMeta(startedAt)));
    await space.push(FIXTURE_DOC_ID, Y.encodeStateAsUpdate(buildFixtureDoc(setBlob, startedAt)));
  } finally {
    space.close();
  }
  const doc = await client.loadDoc(workspaceId, FIXTURE_DOC_ID);
  if (!doc) throw new CheckError("Testdokument nach dem Anlegen nicht lesbar");
  return { workspaceId, doc, created: true };
}

/** Writes this run's timestamp into the fixture and reads it back over HTTP. */
async function writeAndReadBack(client, version, workspaceId, doc, startedAt) {
  const before = Y.encodeStateVector(doc);
  doc.getMap("smoke").set("lastRunAt", startedAt);
  const space = await openSpace(client, workspaceId, version);
  try {
    await space.push(FIXTURE_DOC_ID, Y.encodeStateAsUpdate(doc, before));
  } finally {
    space.close();
  }
  const reloaded = await client.loadDoc(workspaceId, FIXTURE_DOC_ID);
  const seen = reloaded && fixtureFacts(reloaded).lastRunAt;
  if (seen !== startedAt) throw new CheckError(`Schreibprobe nicht zurückgelesen (gelesen: ${seen ?? "nichts"})`);
}

async function main() {
  const startedAt = now();
  const evidence = [];
  const pass = (check, detail, ref) => evidence.push({ check, success: true, detail, ...(ref ? { ref } : {}) });
  let current = "config";
  try {
    const target = (env.TARGET_URL ?? "").replace(/\/+$/, "");
    const email = env.SMOKE_USER_EMAIL ?? "";
    const password = (env.SMOKE_USER_PASSWORD ?? "").slice(0, MAX_PASSWORD_LENGTH);
    if (!target || !email || password.length < 8) {
      throw new CheckError("TARGET_URL, SMOKE_USER_EMAIL oder SMOKE_USER_PASSWORD (mind. 8 Zeichen) fehlt");
    }
    const client = new Client(target);

    current = "availability";
    const info = await waitForInfo(client);
    const version = info.compatibility;
    pass(current, `AFFiNE ${version}`, `${target}/info`);

    current = "login";
    const login = await signIn(client, email, password);
    pass(current, login.detail, `user/${login.userId}`);

    current = "document";
    const fixture = await ensureFixture(client, version, startedAt);
    const facts = fixtureFacts(fixture.doc);
    if (!facts.hasMarker) throw new CheckError("Testdokument ohne erwarteten Inhalt");
    pass(
      current,
      fixture.created ? `angelegt ${facts.createdAt}` : `wiedergefunden, angelegt ${facts.createdAt}`,
      `workspace/${fixture.workspaceId}/doc/${FIXTURE_DOC_ID}`,
    );

    current = "document-write";
    await writeAndReadBack(client, version, fixture.workspaceId, fixture.doc, startedAt);
    pass(current, "Schreibprobe gespeichert und zurückgelesen", `workspace/${fixture.workspaceId}/doc/${FIXTURE_DOC_ID}`);

    current = "attachment";
    if (!facts.attachmentKey) throw new CheckError("Testdokument ohne Anhangsverweis");
    const res = await client.request(`/api/workspaces/${fixture.workspaceId}/blobs/${facts.attachmentKey}`);
    if (res.status !== 200) throw new CheckError(`Anhang ${facts.attachmentKey}: HTTP ${res.status}`);
    const bytes = Buffer.from(await res.arrayBuffer());
    if (sha256(bytes) !== sha256(ATTACHMENT_BYTES)) throw new CheckError("Anhang gelesen, Inhalt weicht ab");
    pass(
      current,
      `${ATTACHMENT_NAME} (${bytes.length} Bytes) ${fixture.created ? "angelegt" : "wiedergefunden"}`,
      `workspace/${fixture.workspaceId}/blob/${facts.attachmentKey}`,
    );
  } catch (e) {
    const detail = e instanceof CheckError ? e.message : `${e.name}: ${e.message}`;
    log(`${current} fehlgeschlagen: ${detail}`);
    evidence.push({ check: current, success: false, detail });
  }
  const success = evidence.length > 0 && evidence.every((e) => e.success);
  console.log(JSON.stringify({ success, startedAt, finishedAt: now(), evidence }));
  return success ? 0 : 1;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  process.exitCode = await main();
  // socket.io may keep handles open briefly; the result is already written
  setTimeout(() => process.exit(process.exitCode), 100).unref();
}

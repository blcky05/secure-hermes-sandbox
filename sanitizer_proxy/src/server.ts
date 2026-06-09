import { serve } from "@hono/node-server";
import { Hono } from "hono";

type JsonObject = Record<string, unknown>;

const pasteguardUrl = stripTrailingSlash(
  process.env.PASTEGUARD_URL ?? "http://pasteguard:3000",
);
const firecrawlUrl = stripTrailingSlash(process.env.FIRECRAWL_URL ?? "http://firecrawl:3002");
const firecrawlApiKey = (process.env.FIRECRAWL_API_KEY ?? "").trim();
const requestTimeoutMs = Number(process.env.REQUEST_TIMEOUT_SECONDS ?? "30") * 1000;
const port = Number(process.env.PORT ?? "5000");
const logLevel = (process.env.LOG_LEVEL ?? "INFO").toUpperCase();

const hopByHopHeaders = new Set([
  "host",
  "connection",
  "keep-alive",
  "transfer-encoding",
  "te",
  "trailer",
  "upgrade",
  "proxy-authorization",
  "proxy-authenticate",
  "content-length",
  "authorization",
]);

const scrubbedRoutes: Record<string, string[]> = {
  search: ["query"],
  scrape: ["url", "prompt"],
  extract: ["urls", "prompt"],
  crawl: ["url", "prompt"],
};

const app = new Hono();

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

function info(message: string, ...args: unknown[]): void {
  if (!["ERROR", "WARN", "WARNING"].includes(logLevel)) {
    console.log(message, ...args);
  }
}

function warn(message: string, ...args: unknown[]): void {
  if (logLevel !== "ERROR") {
    console.warn(message, ...args);
  }
}

function asJson(value: unknown): string {
  return JSON.stringify(value);
}

async function fetchJson(url: string, init: RequestInit): Promise<unknown> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), requestTimeoutMs);
  try {
    const response = await fetch(url, { ...init, signal: controller.signal });
    if (!response.ok) {
      throw new Error(`${response.status} ${response.statusText}`);
    }
    return response.json();
  } finally {
    clearTimeout(timeout);
  }
}

async function maskText(text: string): Promise<{ masked: string; entities: { type: string }[] }> {
  const data = await fetchJson(`${pasteguardUrl}/api/mask`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text, detect: ["pii", "secrets"] }),
  });

  if (!isJsonObject(data) || typeof data.masked !== "string") {
    throw new Error(`Unexpected mask response shape: ${JSON.stringify(data)}`);
  }
  return {
    masked: data.masked as string,
    entities: Array.isArray(data.entities) ? (data.entities as { type: string }[]) : [],
  };
}

async function scrubString(original: string, endpoint: string, field: string): Promise<string> {
  const { masked, entities } = await maskText(original);

  if (entities.length === 0) {
    info("scan endpoint=%s field=%s len=%d findings=none", endpoint, field, original.length);
    return original;
  }

  warn(
    "PII REDACTED before Firecrawl. endpoint=%s field=%s findings=%s | original=%o | scrubbed=%o",
    endpoint,
    field,
    asJson(entities.map((e) => e.type)),
    original,
    masked,
  );
  return masked;
}

async function scrubField(body: JsonObject, field: string, endpoint: string): Promise<void> {
  const value = body[field];
  if (typeof value === "string" && value.trim()) {
    body[field] = await scrubString(value, endpoint, field);
  } else if (Array.isArray(value)) {
    body[field] = await Promise.all(
      value.map((item, index) =>
        typeof item === "string" && item.trim()
          ? scrubString(item, endpoint, `${field}[${index}]`)
          : item,
      ),
    );
  }
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function upstreamHeaders(request: Request): Headers {
  const headers = new Headers();
  for (const [key, value] of request.headers.entries()) {
    if (!hopByHopHeaders.has(key.toLowerCase())) {
      headers.set(key, value);
    }
  }
  headers.set("Content-Type", request.headers.get("Content-Type") ?? "application/json");
  if (firecrawlApiKey) {
    headers.set("Authorization", `Bearer ${firecrawlApiKey}`);
  }
  return headers;
}

async function forward(request: Request, path: string, body?: unknown): Promise<Response> {
  const sourceUrl = new URL(request.url);
  const upstreamUrl = `${firecrawlUrl}${path}${sourceUrl.search}`;
  const method = request.method;

  const init: RequestInit = {
    method,
    headers: upstreamHeaders(request),
    signal: AbortSignal.timeout(requestTimeoutMs),
  };

  if (!["GET", "DELETE", "HEAD"].includes(method)) {
    init.body = JSON.stringify(body ?? (await readOptionalJson(request)));
  }

  try {
    const upstream = await fetch(upstreamUrl, init);
    return new Response(method === "HEAD" ? null : upstream.body, {
      status: upstream.status,
      headers: {
        "Content-Type": upstream.headers.get("Content-Type") ?? "application/json",
      },
    });
  } catch (error) {
    if (isAbortError(error)) {
      console.error("Firecrawl timed out on %s %s after %ss", method, path, requestTimeoutMs / 1000);
      return Response.json({ error: "firecrawl_timeout" }, { status: 504 });
    }
    console.error("Firecrawl request failed on %s %s: %s", method, path, String(error));
    return Response.json({ error: "firecrawl_unavailable", detail: String(error) }, { status: 502 });
  }
}

async function readOptionalJson(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    return undefined;
  }
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && (error.name === "AbortError" || error.name === "TimeoutError");
}

async function withScrubbedBody(request: Request, fields: string[], endpoint: string): Promise<Response> {
  if (!request.headers.get("Content-Type")?.includes("application/json")) {
    return Response.json({ error: "Content-Type must be application/json" }, { status: 400 });
  }

  const body = await readOptionalJson(request);
  if (!isJsonObject(body)) {
    return Response.json({ error: "request body must be a JSON object" }, { status: 400 });
  }

  const present = fields.filter((field) => Object.hasOwn(body, field));
  info(
    "intake endpoint=%s fields_to_scan=%s present=%s body_keys=%s",
    endpoint,
    asJson(fields),
    asJson(present),
    asJson(Object.keys(body).sort()),
  );

  try {
    for (const field of fields) {
      await scrubField(body, field, endpoint);
    }
  } catch (error) {
    console.error("Sanitizer failed while scrubbing %s: %s", endpoint, String(error));
    return Response.json({ error: "sanitizer_unavailable", detail: String(error) }, { status: 503 });
  }

  return forward(request, `/${endpoint}`, body);
}

app.get("/health", (c) => c.json({ status: "ok" }));

for (const version of ["v1", "v2"] as const) {
  for (const [endpoint, fields] of Object.entries(scrubbedRoutes)) {
    app.post(`/${version}/${endpoint}`, (c) =>
      withScrubbedBody(c.req.raw, fields, `${version}/${endpoint}`),
    );
  }
}

app.all("/v1/*", (c) => forward(c.req.raw, new URL(c.req.url).pathname));
app.all("/v2/*", (c) => forward(c.req.raw, new URL(c.req.url).pathname));

serve({ fetch: app.fetch, port }, (serverInfo) => {
  console.log(`sanitizer-proxy listening on :${serverInfo.port}`);
});

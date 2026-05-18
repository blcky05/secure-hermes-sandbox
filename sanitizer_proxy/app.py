"""Firecrawl-shaped reverse proxy that scrubs text fields via Presidio
before forwarding to a self-hosted Firecrawl instance."""

from __future__ import annotations

import logging
import os
import sys
from typing import Any

import requests
from flask import Flask, jsonify, request

PRESIDIO_ANALYZER_URL = os.environ.get(
    "PRESIDIO_ANALYZER_URL", "http://presidio-analyzer:3000"
).rstrip("/")
PRESIDIO_ANONYMIZER_URL = os.environ.get(
    "PRESIDIO_ANONYMIZER_URL", "http://presidio-anonymizer:3000"
).rstrip("/")
FIRECRAWL_URL = os.environ.get("FIRECRAWL_URL", "http://firecrawl:3002").rstrip("/")
FIRECRAWL_API_KEY = os.environ.get("FIRECRAWL_API_KEY", "").strip()
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT_SECONDS", "30"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s sanitizer-proxy %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("sanitizer-proxy")

API_KEY_RECOGNIZER: dict[str, Any] = {
    "name": "API Key Recognizer",
    "supported_language": "en",
    "supported_entity": "API_KEY",
    "patterns": [
        {
            "name": "sk-prefixed secret",
            "regex": r"sk-[a-zA-Z0-9]{20,}",
            "score": 0.9,
        },
        {
            "name": "anthropic-style secret",
            "regex": r"sk-ant-[a-zA-Z0-9\-_]{20,}",
            "score": 0.95,
        },
    ],
    "context": ["api", "key", "secret", "token", "bearer"],
}

ANALYZER_ENTITIES = [
    "CREDIT_CARD",
    "EMAIL_ADDRESS",
    "PHONE_NUMBER",
    "US_SSN",
    "IBAN_CODE",
    "IP_ADDRESS",
    "PERSON",
    "LOCATION",
    "API_KEY",
]

ANONYMIZER_OPERATORS: dict[str, dict[str, Any]] = {
    "DEFAULT": {"type": "replace", "new_value": "<REDACTED>"},
    "API_KEY": {"type": "replace", "new_value": "<API_KEY>"},
    "CREDIT_CARD": {"type": "replace", "new_value": "<CREDIT_CARD>"},
    "EMAIL_ADDRESS": {"type": "replace", "new_value": "<EMAIL>"},
    "PHONE_NUMBER": {"type": "replace", "new_value": "<PHONE>"},
    "US_SSN": {"type": "replace", "new_value": "<SSN>"},
    "IBAN_CODE": {"type": "replace", "new_value": "<IBAN>"},
    "IP_ADDRESS": {"type": "replace", "new_value": "<IP>"},
    "PERSON": {"type": "replace", "new_value": "<PERSON>"},
    "LOCATION": {"type": "replace", "new_value": "<LOCATION>"},
}

# Drop Authorization (sandbox sends the `proxy-managed` sentinel) plus
# the usual hop-by-hop set; the upstream gets our host-side key instead.
HOP_BY_HOP_HEADERS = {
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
}

app = Flask(__name__)


def analyze(text: str) -> list[dict[str, Any]]:
    payload = {
        "text": text,
        "language": "en",
        "entities": ANALYZER_ENTITIES,
        "ad_hoc_recognizers": [API_KEY_RECOGNIZER],
    }
    resp = requests.post(
        f"{PRESIDIO_ANALYZER_URL}/analyze",
        json=payload,
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()
    if not isinstance(data, list):
        raise ValueError(f"Unexpected analyzer response shape: {data!r}")
    return data


def anonymize(text: str, analyzer_results: list[dict[str, Any]]) -> str:
    if not analyzer_results:
        return text
    payload = {
        "text": text,
        "analyzer_results": analyzer_results,
        "anonymizers": ANONYMIZER_OPERATORS,
    }
    resp = requests.post(
        f"{PRESIDIO_ANONYMIZER_URL}/anonymize",
        json=payload,
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()
    redacted = data.get("text")
    if not isinstance(redacted, str):
        raise ValueError(f"Unexpected anonymizer response: {data!r}")
    return redacted


def _scrub_str(original: str, *, endpoint: str, field: str) -> str:
    analyzer_results = analyze(original)
    findings = [
        {"entity_type": r.get("entity_type"), "score": r.get("score")}
        for r in analyzer_results
    ]
    if not findings:
        log.info(
            "scan endpoint=%s field=%s len=%d findings=none",
            endpoint,
            field,
            len(original),
        )
        return original
    redacted = anonymize(original, analyzer_results)
    log.warning(
        "PII REDACTED before Firecrawl. endpoint=%s field=%s findings=%s "
        "| original=%r | scrubbed=%r",
        endpoint,
        field,
        findings,
        original,
        redacted,
    )
    return redacted


def scrub_field(body: dict[str, Any], field: str, *, where: str) -> None:
    value = body.get(field)
    if isinstance(value, str):
        if value.strip():
            body[field] = _scrub_str(value, endpoint=where, field=field)
    elif isinstance(value, list):
        new_list: list[Any] = []
        for i, item in enumerate(value):
            if isinstance(item, str) and item.strip():
                new_list.append(_scrub_str(item, endpoint=where, field=f"{field}[{i}]"))
            else:
                new_list.append(item)
        body[field] = new_list
    elif value is None:
        log.debug("skip endpoint=%s field=%s reason=absent", where, field)
    else:
        log.debug(
            "skip endpoint=%s field=%s reason=unsupported_type type=%s",
            where,
            field,
            type(value).__name__,
        )


def upstream_headers() -> dict[str, str]:
    out: dict[str, str] = {}
    for k, v in request.headers.items():
        if k.lower() in HOP_BY_HOP_HEADERS:
            continue
        out[k] = v
    out["Content-Type"] = request.headers.get("Content-Type", "application/json")
    if FIRECRAWL_API_KEY:
        out["Authorization"] = f"Bearer {FIRECRAWL_API_KEY}"
    return out


def forward(method: str, path: str, *, body: Any = None) -> Any:
    url = f"{FIRECRAWL_URL}{path}"
    try:
        if body is None and request.method in {"GET", "DELETE", "HEAD"}:
            upstream = requests.request(
                method,
                url,
                headers=upstream_headers(),
                params=request.args,
                timeout=REQUEST_TIMEOUT,
            )
        else:
            upstream = requests.request(
                method,
                url,
                headers=upstream_headers(),
                params=request.args,
                json=body if body is not None else request.get_json(silent=True),
                timeout=REQUEST_TIMEOUT,
            )
    except requests.Timeout:
        log.error("Firecrawl timed out on %s %s after %ss", method, path, REQUEST_TIMEOUT)
        return jsonify({"error": "firecrawl_timeout"}), 504
    except requests.RequestException as exc:
        log.error("Firecrawl request failed on %s %s: %s", method, path, exc)
        return jsonify({"error": "firecrawl_unavailable", "detail": str(exc)}), 502

    content_type = upstream.headers.get("Content-Type", "application/json")
    return upstream.content, upstream.status_code, {"Content-Type": content_type}


def with_scrubbed_body(scrub_fields: list[str], *, where: str) -> Any:
    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400
    body = request.get_json(silent=True) or {}
    if not isinstance(body, dict):
        return jsonify({"error": "request body must be a JSON object"}), 400

    present = [f for f in scrub_fields if f in body]
    log.info(
        "intake endpoint=%s fields_to_scan=%s present=%s body_keys=%s",
        where,
        scrub_fields,
        present,
        sorted(body.keys()),
    )

    try:
        for field in scrub_fields:
            scrub_field(body, field, where=where)
    except requests.RequestException as exc:
        log.error("Presidio unreachable while scrubbing %s: %s", where, exc)
        return jsonify({"error": "sanitizer_unavailable", "detail": str(exc)}), 503
    except (ValueError, KeyError) as exc:
        log.error("Presidio returned unexpected payload while scrubbing %s: %s", where, exc)
        return jsonify({"error": "sanitizer_response_invalid"}), 502

    return forward("POST", f"/{where.lstrip('/')}", body=body)


@app.get("/health")
def health() -> Any:
    return jsonify({"status": "ok"}), 200


# Firecrawl exposes the same shape under /v1 and /v2; current Hermes / SDK
# clients default to v2. Both are scrubbed the same way.
SCRUBBED_ROUTES: dict[str, list[str]] = {
    "search": ["query"],
    "scrape": ["url", "prompt"],
    "extract": ["urls", "prompt"],
    "crawl": ["url", "prompt"],
}


def _register_scrubbed(version: str, endpoint: str, fields: list[str]) -> None:
    path = f"/{version}/{endpoint}"

    def handler(_fields: list[str] = fields, _where: str = f"{version}/{endpoint}") -> Any:
        return with_scrubbed_body(_fields, where=_where)

    app.add_url_rule(path, endpoint=f"{version}_{endpoint}", view_func=handler, methods=["POST"])


for _version in ("v1", "v2"):
    for _endpoint, _fields in SCRUBBED_ROUTES.items():
        _register_scrubbed(_version, _endpoint, _fields)


@app.route("/v1/<path:subpath>", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
def v1_passthrough(subpath: str) -> Any:
    return forward(request.method, f"/v1/{subpath}")


@app.route("/v2/<path:subpath>", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
def v2_passthrough(subpath: str) -> Any:
    return forward(request.method, f"/v2/{subpath}")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

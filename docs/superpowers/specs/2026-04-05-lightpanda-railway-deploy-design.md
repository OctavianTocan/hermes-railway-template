# Lightpanda Browser on Railway -- Design Spec

## Goal

Deploy Lightpanda headless browser as a separate Railway service so that
Hermes (on Railway) and OpenClaw (local PC) can use it for browser
automation without paying for a cloud browser service.

## Architecture

```
Railway Project
├── Hermes Service (existing)
│   └── connects via ws://lightpanda.railway.internal:9222 (CDP)
└── Lightpanda Service (new)
    └── lightpanda serve --host 0.0.0.0 --port 9222
        └── CDP WebSocket on port 9222

External
└── OpenClaw (local PC)
    └── connects via wss://<railway-domain> (CDP over HTTPS)
```

**Protocol:** Chrome DevTools Protocol (CDP) over WebSocket. Lightpanda's
local binary only supports CDP (`lightpanda serve`). MCP is cloud-only
and not available in the self-hosted binary.

**Internal access:** Hermes connects via Railway's private networking
(`lightpanda.railway.internal:9222`). No public exposure needed for this
path.

**External access:** Railway generates a public HTTPS domain that proxies
WebSocket connections. OpenClaw connects here using Playwright's
`connectOverCDP()`.

## Dockerfile

Based on `lightpanda/browser:nightly` (debian:stable-slim + lightpanda
binary + tini). The default image already runs
`lightpanda serve --host 0.0.0.0 --port 9222` -- so we may use it as-is
or extend it minimally.

```dockerfile
FROM lightpanda/browser:nightly

# Default CMD already runs lightpanda serve on 0.0.0.0:9222
# Override only if we need custom flags (timeout, proxy, etc.)
```

If we need to customize (e.g., longer timeout, HTTP proxy for outbound
requests), we override CMD:

```dockerfile
FROM lightpanda/browser:nightly
CMD ["/bin/lightpanda", "serve", \
     "--host", "0.0.0.0", \
     "--port", "9222", \
     "--timeout", "120", \
     "--log-level", "info"]
```

## Railway Configuration

```toml
[build]
builder = "dockerfile"

[deploy]
restartPolicyType = "on_failure"
```

No persistent volume needed -- Lightpanda is stateless.

### Environment Variables

None required by Lightpanda itself. Optional:

| Variable | Purpose | Default |
|----------|---------|---------|
| `PORT` | Railway uses this to route traffic | 9222 |

### Networking

- **Internal:** Railway private networking exposes the service at
  `lightpanda.railway.internal:9222`
- **Public:** Generate a Railway domain for OpenClaw access. Railway
  automatically proxies WebSocket over HTTPS.

## Client Connection

### Hermes (Railway internal)

Hermes connects via Playwright/Puppeteer using CDP:

```python
from playwright.async_api import async_playwright

async with async_playwright() as p:
    browser = await p.chromium.connect_over_cdp(
        "ws://lightpanda.railway.internal:9222"
    )
    page = await browser.new_page()
    await page.goto("https://example.com")
    content = await page.content()
```

### OpenClaw (local PC)

OpenClaw connects via the public Railway domain:

```python
browser = await p.chromium.connect_over_cdp(
    "wss://lightpanda-production-xxxx.up.railway.app"
)
```

## Security Considerations

- CDP has no built-in authentication. Anyone with the public URL can
  connect and control the browser.
- **Mitigation options:**
  1. Railway's built-in request filtering (IP allowlist if available)
  2. Keep the public domain URL secret (security through obscurity --
     not ideal but acceptable for personal use)
  3. If stronger auth is needed later: add a WebSocket proxy (e.g.,
     nginx or a small Go/Node proxy) that validates a bearer token
     before forwarding to Lightpanda's CDP port
- For now, option 2 is sufficient for personal use. The URL is
  unguessable (random Railway subdomain).

## Resource Requirements

- **Memory:** ~70-120MB per browser instance (vs 650-1100MB for Chrome)
- **CPU:** Low -- no rendering engine
- **Disk:** Minimal -- single binary, no Chromium install
- **Recommended Railway plan:** Hobby tier should be sufficient

## Limitations

- **No screenshots:** Lightpanda has no rendering engine. If screenshot
  support is needed, fall back to browser-use with Chrome.
- **Beta status:** Some complex SPAs may hit missing Web API
  implementations. Test with target sites before relying on it.
- **No local MCP:** MCP tools (goto, click, fill, markdown, etc.) are
  only available via Lightpanda's cloud service, not the self-hosted
  binary. Self-hosted uses CDP only.
- **Single concurrent session by default:** `--cdp_max_connections` flag
  may allow multi-client, but needs testing.

## Files to Create/Modify

1. `Dockerfile` -- extend or use `lightpanda/browser:nightly` as-is
2. `railway.toml` -- Railway deployment config
3. `README.md` -- usage documentation

This is a new Railway service in the existing project, so it should be
deployed as a separate service (not modifying the existing Hermes
Dockerfile/config).

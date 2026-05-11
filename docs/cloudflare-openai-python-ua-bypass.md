# Cloudflare bypass for `OpenAI/Python` user agents

## Why this exists

`proxy.feixingqi.shop` was verified to behave differently at the edge:

- minimal headers reach origin and return `200`
- requests with `User-Agent: OpenAI/Python ...` are blocked with `403 Your request was blocked.`
- direct origin requests and local Caddy requests with the same headers return `200`

That means the narrowest correct fix is at the Cloudflare edge, not in Caddy and not in CLIProxyAPI.

## What the helper script does

`scripts/cloudflare-allow-openai-python-ua.sh` creates, updates, or deletes a zone-level custom rule in the `http_request_firewall_custom` phase.

The default matcher is:

- host equals `proxy.feixingqi.shop`
- path starts with `/v1`
- user agent starts with `OpenAI/Python`

The default action is `skip`, with these targets:

- current custom-rules ruleset (`ruleset: current`)
- downstream phases:
  - `http_request_firewall_managed`
  - `http_ratelimit`
  - `http_request_sbfm`
- legacy products:
  - `uaBlock`
  - `bic`
  - `securityLevel`
  - `waf`
  - `rateLimit`

This keeps the exception as narrow as possible while covering the most likely Cloudflare-side blockers for the observed behavior.

## Prerequisites

You need one of the following:

- `CLOUDFLARE_ZONE_ID`
- `CLOUDFLARE_ZONE_NAME`

And also:

- `CLOUDFLARE_API_TOKEN`

The API token must be able to manage zone rulesets.

## Dry run

Preview the exact API call without changing Cloudflare:

```bash
./scripts/cloudflare-allow-openai-python-ua.sh \
  --api-token "$CLOUDFLARE_API_TOKEN" \
  --zone-name feixingqi.shop \
  --dry-run
```

## Apply the bypass rule

Using a zone name:

```bash
./scripts/cloudflare-allow-openai-python-ua.sh \
  --api-token "$CLOUDFLARE_API_TOKEN" \
  --zone-name feixingqi.shop
```

Using a zone ID:

```bash
./scripts/cloudflare-allow-openai-python-ua.sh \
  --api-token "$CLOUDFLARE_API_TOKEN" \
  --zone-id <zone-id>
```

The script is idempotent:

- if the rule does not exist, it creates it
- if the rule already exists, it updates it in place
- it uses a stable rule ref by default: `allow_openai_python_sdk_proxy_v1`

## Roll back

Delete the rule created by the helper:

```bash
./scripts/cloudflare-allow-openai-python-ua.sh \
  --api-token "$CLOUDFLARE_API_TOKEN" \
  --zone-name feixingqi.shop \
  --delete
```

## Verification

After applying the rule, repeat the public edge check.

Minimal headers should still return `200`:

```bash
curl -i https://proxy.feixingqi.shop/v1/chat/completions \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  --data '{"model":"gpt-5.4","messages":[{"role":"user","content":"hi"}]}'
```

The SDK-style request should also reach origin instead of returning the edge `403`:

```bash
curl -i https://proxy.feixingqi.shop/v1/chat/completions \
  -H "Authorization: Bearer <KEY>" \
  -H "Content-Type: application/json" \
  -H "User-Agent: OpenAI/Python 1.x" \
  -H "X-Stainless-Lang: python" \
  -H "X-Stainless-Package-Version: 1.0.0" \
  -H "X-Stainless-OS: Linux" \
  -H "X-Stainless-Arch: x64" \
  -H "X-Stainless-Runtime: CPython" \
  -H "X-Stainless-Runtime-Version: 3.12.3" \
  -H "x-stainless-retry-count: 0" \
  -H "x-stainless-read-timeout: 600" \
  --data '{"model":"gpt-5.4","messages":[{"role":"user","content":"hi"}]}'
```

Expected outcome after the fix:

- no Cloudflare `403 Your request was blocked.` body
- origin-specific headers appear again, such as `Via: 1.1 Caddy`
- the request is visible in origin-side access logs

## Customization

The helper supports these overrides:

- `--host`
- `--path-prefix`
- `--ua-prefix`
- `--description`
- `--rule-ref`
- `--skip-products`
- `--skip-phases`
- `--skip-current-ruleset`
- `--no-skip-current-ruleset`
- `--enable-logging`
- `--disable-logging`

If you already know the exact Cloudflare product causing the block, reduce the skip targets accordingly.

---
summary: "LiteLLM provider setup and usage data shape."
read_when:
  - Configuring LiteLLM usage tracking
  - Troubleshooting LiteLLM API-key usage in CodexBar
---

# LiteLLM

LiteLLM uses a target virtual key plus the proxy base URL. Some LiteLLM deployments allow that same key to read
`/key/info` and `/user/info`; others require a separate management or master key for those management endpoints.

Configure it in Settings -> Providers -> LiteLLM, or in `~/.codexbar/config.json`:

```json
{
  "id": "litellm",
  "enabled": true,
  "apiKey": "<LITELLM_API_KEY>",
  "secretKey": "<OPTIONAL_LITELLM_MANAGEMENT_KEY>",
  "enterpriseHost": "https://litellm.example.com"
}
```

Leave `secretKey` unset when your LiteLLM virtual key can authorize the management endpoints itself. Set `secretKey`
only when your proxy requires an admin or master key for management API reads.

Equivalent environment variables:

```bash
export LITELLM_API_KEY=sk-...
export LITELLM_MANAGEMENT_KEY=sk-... # optional
export LITELLM_BASE_URL=https://litellm.example.com
```

`LITELLM_BASE_URL` may include `/v1`; CodexBar strips that suffix before calling LiteLLM management endpoints.

## Data Source

The provider calls:

1. `GET /key/info?key=<apiKey>` to discover the `user_id`.
2. `GET /user/info?user_id=<user_id>` to read personal spend, budget, keys, and teams.

Both requests use `Authorization: Bearer <secretKey>` when `secretKey` or `LITELLM_MANAGEMENT_KEY` is configured.
Otherwise they use `Authorization: Bearer <apiKey>`.

The primary menu bar value uses `user_info.spend / user_info.max_budget`. If team budget data is present, the first
team matching the current key is shown as the secondary budget window.

## Security

Treat LiteLLM keys as secrets. If you configure a management key, it can be more privileged than an LLM invocation key.
CodexBar stores configured keys only in provider config or token-account storage and sends them only to the configured
LiteLLM base URL.

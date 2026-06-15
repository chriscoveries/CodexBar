---
summary: "LiteLLM provider setup and usage data shape."
read_when:
  - Configuring LiteLLM usage tracking
  - Troubleshooting LiteLLM API-key usage in CodexBar
---

# LiteLLM

LiteLLM uses a personal virtual key plus the proxy base URL.

Configure it in Settings -> Providers -> LiteLLM, or in `~/.codexbar/config.json`:

```json
{
  "id": "litellm",
  "enabled": true,
  "apiKey": "<LITELLM_API_KEY>",
  "enterpriseHost": "https://litellm.example.com"
}
```

Equivalent environment variables:

```bash
export LITELLM_API_KEY=sk-...
export LITELLM_BASE_URL=https://litellm.example.com
```

`LITELLM_BASE_URL` may include `/v1`; CodexBar strips that suffix before calling LiteLLM management endpoints.

## Data Source

The provider calls:

1. `GET /key/info?key=<key>` with `Authorization: Bearer <key>` to discover the `user_id`.
2. `GET /user/info?user_id=<user_id>` with the same bearer token to read personal spend, budget, keys, and teams.

The primary menu bar value uses `user_info.spend / user_info.max_budget`. If team budget data is present, the first
team matching the current key is shown as the secondary budget window.

## Security

Treat the LiteLLM API key like an LLM invocation key. It is stored only in CodexBar provider config or token-account
storage and is sent only to the configured LiteLLM base URL.

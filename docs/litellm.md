---
summary: "LiteLLM provider setup and usage data shape."
read_when:
  - Configuring LiteLLM usage tracking
  - Troubleshooting LiteLLM API-key usage in CodexBar
---

# LiteLLM

LiteLLM uses a virtual key plus the proxy base URL. The key reads its own identity and budget data through LiteLLM's
authenticated information endpoints.

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

1. `GET /key/info` to discover the authenticated key's `user_id` and `team_id`.
2. `GET /user/info?user_id=<user_id>` to read personal spend, budget, and teams.

Both requests use `Authorization: Bearer <apiKey>`. CodexBar does not request or store a LiteLLM master key.

The primary menu bar value uses `user_info.spend / user_info.max_budget`. If the authenticated key has a team and that
team is present in `/user/info`, its budget is shown as the secondary window.

## Security

Treat LiteLLM keys as secrets. CodexBar stores configured keys only in provider config or token-account storage and
sends them only to the configured LiteLLM base URL.

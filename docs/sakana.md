---
summary: "Sakana AI provider: manual Cookie header, billing page parser, 5-hour and weekly quota windows."
read_when:
  - Adding or modifying the Sakana AI provider
  - Debugging Sakana AI cookie import or quota parsing
  - Adjusting Sakana AI menu labels or reset window display
---

# Sakana AI

[Sakana AI](https://sakana.ai) is a research lab focusing on foundation models and nature-inspired AI. CodexBar reads
the billing page to surface 5-hour and weekly quota windows for subscribers.

## Setup

1. Sign in at [console.sakana.ai](https://console.sakana.ai).
2. Open your browser's developer tools, navigate to the **Network** tab, and reload the billing page
   (`console.sakana.ai/billing`).
3. Copy the full `Cookie:` request header value from any billing-page request.
4. In CodexBar, paste the header in **Preferences → Providers → Sakana AI → Cookie header**.
   The value is stored in `~/.codexbar/config.json` with restrictive file permissions (`0600`).

Alternatively, set the environment variable `SAKANA_COOKIE` to the raw cookie header value.

## Data source

- **Auth method**: manual `Cookie:` header; no automatic browser cookie import.
- **Target page**: `https://console.sakana.ai/billing` (HTML scrape; no JSON API).
- **Source label**: `web`.

## Usage details

- The primary row shows the **5-hour quota** (session limit); resets after five hours from first use.
- The secondary row shows the **weekly quota**; resets on the weekly boundary shown on the billing page.
- `usedPercent` for each window is parsed directly from the billing page progress bar.
- Reset dates are parsed from the billing page using the device's local time zone (`TimeZone.current`).
  The fetcher detects `"MMMM d, yyyy 'at' h:mm a"` format strings.
- Plan name and price label (e.g. `Standard $20/mo`) are surfaced as the `loginMethod` identity field
  and shown below the usage percent in the menu.
- Token cost tracking (`supportsTokenCost: false`): not supported; cost summary is unavailable.
- Credits row (`supportsCredits: false`): not shown.
- Widget support: not currently available for Sakana AI.

## CLI usage

```
codexbar usage --provider sakana
codexbar usage --provider sakana-ai   # alias
```

Set the cookie via the environment variable or Preferences UI:

- **Environment variable**: `SAKANA_COOKIE=<cookie-header-value> codexbar usage --provider sakana`
- **Preferences UI**: Preferences → Providers → Sakana AI → Cookie header

There is no `codexbar config set` command for `cookieHeader`; use one of the paths above.

## Errors

| Error | Meaning |
|-------|---------|
| `missingCookie` | No `Cookie:` header is configured and `SAKANA_COOKIE` is unset. |
| `loginRequired` | The billing page returned a login redirect (cookie expired or invalid). |
| `apiError(Int)` | The billing page returned a non-2xx HTTP status. |
| `parseFailed(String)` | The billing HTML was reachable but the quota pattern was not found. |

## Related files

- `Sources/CodexBarCore/Providers/Sakana/`
  - `SakanaProviderDescriptor.swift` — provider metadata, fetch plan, CLI config
  - `SakanaSettingsReader.swift` — `SAKANA_COOKIE` env key, cookie normalizer
  - `SakanaUsageFetcher.swift` — billing-page HTML fetch and quota parser
- `Sources/CodexBar/Providers/Sakana/`
  - `SakanaProviderImplementation.swift` — settings UI, availability check
  - `SakanaSettingsStore.swift` — `sakanaCookieHeader` settings binding
- `Tests/CodexBarTests/SakanaUsageFetcherTests.swift` — parser regression tests
- Dashboard: `https://console.sakana.ai/billing`

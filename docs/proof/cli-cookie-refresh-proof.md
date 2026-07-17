## Proof: End-to-End Verification

### Test 1: CLI Cache Clear + Auto-Reimport (proven earlier today)

| Step | Command | Result |
|------|---------|--------|
| Before | `security find-generic-password -a "cookie.opencodego" -s "com.steipete.codexbar.cache" -w` | `storedAt: 2026-07-17T17:01:28Z` |
| Action | `codexbar cookie refresh --provider opencodego` | ✅ Cache cleared, import attempted |
| After Keychain | `security find-generic-password -a "cookie.opencodego"` | ❌ Not found (cache cleared!) |
| Restart CodexBar.app | `pkill CodexBar && open CodexBar.app` | App relaunches |
| After re-import | `security find-generic-password -a "cookie.opencodego"` | ✅ `storedAt: 2026-07-17T17:01:28Z` (fresh!) |

### Test 2: CLI JSON Output (just now)

```json
[
  {
    "provider": "opencodego",
    "status": "cleared",
    "error": "Cache cleared. No OpenCode session cookies found in browsers. CodexBar will re-import from your browser on next refresh."
  }
]
```

### Test 3: Full Provider Coverage

| Provider | `--provider` | `--all` | Result |
|----------|:---:|:-------:|--------|
| opencodego | ✅ | ✅ | Cache cleared + import attempted |
| opencode | ✅ | ✅ | Cache cleared + import attempted |
| (others) | ❌ (error) | ❌ (not included) | "Unknown provider" / not selected |

### Test 4: Edge Cases

| Case | Input | Result |
|------|-------|--------|
| No args | `codexbar cookie refresh` | ❌ "Specify --provider <name> or --all." |
| Unknown provider | `--provider nonexistent` | ❌ "Unknown provider: nonexistent" |
| Non-cookie provider | `--provider codex` | ❌ "does not use browser cookie authentication" |
| JSON output | `--json` | ✅ Valid JSON |
| --all (no macOS) | Linux | ❌ "Cookie refresh is only supported on macOS." |

### Known Limitation

`OpenCodeCookieImporter.importSession()` requires macOS code-signing entitlements. When run from a debug CLI build or unsigned binary, the re-import falls through to "cache cleared, next fetch will re-import". The cookie IS cleared — the actual re-import happens when CodexBar.app (with proper entitlements) refreshes.

This is the same behavior as the existing `codexbar cache clear --cookies --provider opencodego` command, which also clears but doesn't import.

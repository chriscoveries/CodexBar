---
summary: "Decision proposal for provider identity in macOS notifications."
read_when:
  - Reviewing or implementing provider-specific notification visuals
  - Changing the shared macOS notification delivery path
---

# Provider Identity in Notifications — Decision Proposal

**Status:** proposed; maintainer sign-off required
**Date:** 2026-07-01
**Issue:** #1828
**Related:** #1299, PR #1818

## Decision requested

Should CodexBar keep provider identity in the notification title, or add each provider mark as a media attachment even though macOS continues to show the CodexBar app icon as the notification's sender?

## Recommendation

Keep the current provider-first titles and do not add an attachment by default. The public macOS User Notifications API does not expose a per-notification sender-icon override. A provider image can only be supplementary media, so it cannot deliver the requested icon replacement and may enlarge or otherwise change the system-controlled notification layout.

Keep #1828 open only if a supplementary attachment is an acceptable interpretation. If the requested outcome specifically requires replacing the CodexBar sender icon, evidence-close it as unsupported by the public API. Do not model quota alerts as communication notifications merely to obtain avatar-like presentation.

## Current behavior already carries provider identity

Every current provider-related notification puts the localized provider display name in its title:

| Path | English title shape |
| --- | --- |
| Session depleted | `<Provider> session depleted` |
| Session restored | `<Provider> session restored` |
| Quota warning | `<Provider> <window> quota low` |
| Login success | `<Provider> login successful` |
| Permission prompt | `<Provider> is waiting for permission` |

This is semantic identity, localized with the rest of the notification, and remains available when images fail to load or are hidden. It satisfies clarity, but not the issue's separate request for glanceable visual branding.

## Platform boundary

Apple's [`UNMutableNotificationContent`](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent) surface includes title, subtitle, body, attachments, badge, sound, grouping, and delivery metadata. It has no notification-icon property.

Apple describes [`attachments`](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/attachments) as visual or audio content displayed alongside the main content. Attachments must exist locally before scheduling. [`UNNotificationAttachment`](https://developer.apple.com/documentation/usernotifications/unnotificationattachment) also documents that invalid or unsupported local media prevents the request from being scheduled.

`UNNotificationActionIcon` customizes an action button, not the notification sender. Apple's [notification design guidance](https://developer.apple.com/design/human-interface-guidelines/notifications) reserves prominent avatar presentation for direct communication such as calls and messages; provider quota and login status are noncommunication notifications.

## Options

| Option | Result | Cost / risk | Disposition |
| --- | --- | --- | --- |
| Keep provider-first title | CodexBar sender icon plus explicit provider name | No new runtime or failure path; not pictorial | Recommended |
| Add provider media attachment | CodexBar sender icon plus a system-placed provider image | Does not replace sender icon; layout varies; rasterization, local-file lifecycle, contrast, and fallback work | Prototype only after approval |
| Add an action icon | Provider image appears on an action button | Requires an otherwise-unneeded action and does not identify the notification itself | Reject |
| Pretend alerts are direct communication | Potential avatar-like system presentation | Semantically false; incorrect system integration | Reject |

The conceptual comparison is in [provider-notification-identity-options.svg](../../screenshots/provider-notification-identity-options.svg). It intentionally does not claim exact system placement for attachment media.

## Attachment implementation seam after approval

If the supplementary-media interpretation is approved:

1. Keep provider name in the title as the authoritative identity.
2. Resolve the icon through `ProviderDescriptorRegistry`; do not add provider-specific switches.
3. Rasterize the bundled template SVG to a notification-safe PNG on a neutral backing. The current shared UI image is a 16-point template image, not a ready notification attachment.
4. Store generated files in an app-owned cache with bounded cleanup. Do not include account, workspace, plan, usage, or other private values in filenames or attachment metadata.
5. If resolution, rendering, file creation, or attachment construction fails, post the text-only notification. Visual identity must never suppress a quota or permission alert.
6. Keep `AppNotifications` generic: accept an optional prepared attachment rather than coupling the delivery layer to provider descriptors.

## Required tests after approval

- All registered providers resolve through the shared descriptor/icon path.
- Attachment construction produces supported local media without account-derived filenames or metadata.
- Missing, corrupt, or unwritable media falls back to the existing text-only request.
- Existing title/body, localization, badge, and sound behavior stays unchanged.
- #1299/PR #1818 predictive warnings, if approved, use the same centralized identity policy.
- Headless tests never access `UNUserNotificationCenter`.

## Tahoe proof gate after approval

Use a packaged build and synthetic provider label only. Capture both the transient banner and Notification Center on the supported Tahoe baseline, in light and dark appearances. The proof must show:

- the CodexBar sender icon remains present;
- whether and where the provider attachment appears in compact and expanded states;
- readable provider identity without the attachment;
- no account, workspace, plan, quota amount, or other private data;
- text-only delivery still succeeds when attachment creation is intentionally failed.

Do not land an attachment implementation based only on source tests or the conceptual mock.

## Overlap

Issue #1299 and PR #1818 propose additional predictive pace notifications through the same delivery path. PR #1818 is documentation-only and does not edit runtime notification or icon files, so there is no current code conflict. The identity decision should nevertheless apply centrally before that proposal is implemented; otherwise each notification family could acquire different visual behavior and fallback semantics.

No other active PR changes `AppNotifications.swift`, `SessionQuotaNotifications.swift`, `ProviderBrandIcon.swift`, or provider icon resources as of this proposal.

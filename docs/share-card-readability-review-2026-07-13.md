# Share card readability review

Date: 2026-07-13

## Decision

The share card should be judged at its likely feed size, not only at its 1200 x 630 export size. At a 600 x 315 render, the previous 9-16 pt badges, mappings, labels, and row text became roughly 4.5-8 px. The result preserved the data but lost the flex: the token total survived while the subscriptions and models were difficult to identify.

The revised card uses a feed-first hierarchy:

1. tracked tokens and estimated 30-day spend;
2. a separately labeled OpenRouter month-to-date figure;
3. five individually named subscription rows, preserving the current full stack;
4. three top model rows, each reinforced with its provider name;
5. a ten-bucket activity strip used as supporting texture rather than a detailed chart.

## Primary standards and product references

- [Apple Human Interface Guidelines: Typography](https://developer.apple.com/design/human-interface-guidelines/typography) recommends readable sizes and weights, clear hierarchy, and testing text in its real viewing context.
- [WCAG 2.2: Contrast Minimum](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) requires at least 4.5:1 contrast for normal text and 3:1 for large text, including images of text. WCAG does not impose a general minimum font size, so the card's type floor is a product readability decision rather than a claimed WCAG requirement.
- [Apple: Sufficient Contrast evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-accessibility-evaluation-criteria/) reinforces checking foreground/background contrast in the actual interface.
- [Apple: Differentiate Without Color Alone evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria/) supports using labels and ranks in addition to provider colors.
- [OpenRouter Rankings](https://openrouter.ai/rankings) is the closest product reference: the experience is data-first, uses direct labels and ranked rows, and lets spacing and hierarchy carry more weight than decoration.

All links were checked on 2026-07-13.

## Exa and Parallel comparison

Exa and Parallel were queried with comparable objectives: social-card typography at half-size, contrast and color semantics, and OpenRouter-like ranking density.

- Both surfaced Apple typography guidance and WCAG contrast as the durable standards.
- Both supported a strong hierarchy, neutral readable text, and redundant provider identification instead of color-only meaning.
- Exa's first pass included third-party OpenRouter design commentary. Parallel surfaced the official OpenRouter rankings page more directly. The implementation therefore relies on the official product and standards pages, not third-party aesthetic summaries.
- There was no material disagreement in the primary-source set.

## Frontier-model panel

The same constrained design brief was sent through OpenRouter. Raw responses are retained locally under `~/reports/codexbar-share-card-readability-2026-07-13/raw/` and are not part of the repository.

| Model | Result used | Material guidance |
| --- | --- | --- |
| `anthropic/claude-sonnet-5` | Yes | Called the old result a dashboard screenshot; enlarge the hero, remove tiny badges, use neutral text, simplify the chart, and separate OpenRouter MTD. |
| `x-ai/grok-4.5` | Yes | Set an 18 pt native floor for essential text, use three top models, make rank plus name carry meaning, and flatten tinted rows. |
| `z-ai/glm-5.2` | Yes | Recommended a roughly 22 pt floor for important rows, one metric per line, three models, and a single low-detail activity shape. |
| `qwen/qwen3.7-max` | Yes | Identified the same dashboard-versus-share-card problem and recommended removing plan badges, mapping microcopy, and nested surfaces. |
| `moonshotai/kimi-k2.7-code` | Partial | The direct latest-code call spent its completion budget without a visible answer. A retry through `~moonshotai/kimi-latest` resolved to `moonshotai/kimi-k2.6` and recommended a 24 pt floor, top-three lists, explicit OpenRouter labels, and one sparkline. |
| `minimax/minimax-m3` | No verdict | One response exhausted its budget without visible content; the concise retry timed out. It is recorded as an attempted reviewer and excluded from consensus. |

### Consensus

- Design for the 600 x 315 feed render.
- Keep the token total and spend as the glance-level hook.
- Remove 9 pt plan pills and 11 pt model-mapping copy.
- Keep OpenRouter month-to-date spend explicitly separate from the trailing-period estimate.
- Use provider color as a locator only; names, ranks, and metrics must work without it.
- Replace 30 narrow daily bars with a small, bucketed activity strip.
- Use fewer model rows and more breathing room.

### Deliberate disagreement

Most models recommended limiting both lists to three. That conflicts with the product requirement to show the user's whole current subscription stack in one image. The implementation keeps five fully named subscription rows, raises their names to 20 pt and details to 18 pt, and limits only the model ranking to three. This is the smallest compromise that preserves both readability and the core flex.

## Implementation rules

- Export remains 1200 x 630.
- Essential labels start at 18 pt native; subscription names use 20 pt and model names use 20 pt. Decorative provenance may be 14 pt because it is not required to understand the card.
- Primary text stays warm off-white. Secondary text is a higher-contrast warm gray than the previous card.
- Provider colors appear as compact leading bars and activity segments. Provider names and numeric ranks remain visible, so no meaning depends on hue.
- Subscription plan names are plain text, not tiny colored pills.
- OpenRouter MTD is its own labeled metric and is not included in the estimated 30-day total.
- Rows use a nearly neutral surface and subtle outline instead of provider-tinted cards.
- Activity is aggregated into at most ten buckets with no axes, grid, or legend.

## Verification target

The production proof should demonstrate the card at the app's scaled preview size and confirm that:

- all five current subscriptions are named;
- the three top models and their provider names are readable;
- OpenRouter MTD is visibly separate from the 30-day estimate;
- provider colors reinforce labels rather than replace them;
- Copy Image and Copy Stats work without adding permissions or network upload behavior.

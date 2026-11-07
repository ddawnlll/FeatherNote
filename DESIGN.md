# DESIGN.md - FeatherNote

## Context (from discovery)

- Artifact type: SaaS application, specifically a single-owner writing and reading tool with an editorial content surface
- Positioning: utilitarian, private, text-first
- Audience: one technical owner who keeps personal notes on their own machine | Primary action: open a note and read or write it
- Adjectives: quiet, exact, editorial, tactile, private
- Visual word translations:
  - quiet -> flat paper surfaces, no ambient glow, no decoration without a job
  - exact -> ruled index rows, tabular dates, consistent 1px rules
  - editorial -> serif reading text, margin metadata, a real measure
  - tactile -> ink-on-paper contrast, vermilion registration marks, visible focus
  - private -> no remote assets, no scripts, no analytics, no stock imagery
- Aesthetic essence: ink, paper, margin
- Single-minded proposition: this notebook feels owned, not rented
- References: admire the ruled index of a printed ledger and the margin notes of an annotated book; avoid the cream-and-glow AI landing-page look and cyberpunk neon
- Mode: both (4 light, 8 dark themes) | Density: balanced
- Constraints: zero JavaScript, no external fonts or images, single embedded CSS file, WCAG AA, Zig server-rendered HTML

## Aesthetic

- Direction: editorial ledger
- Defining trait: ruled index rows with dates in the margin, and metadata set in a narrow rail beside the reading column
- Signature move: a margin-dated ledger index with a vermilion registration mark

## Typography

- Display: Iowan Old Style / Palatino / Book Antiqua / Georgia | source: local system faces | license: OS-provided
- Body: Charter / Bitstream Charter / Sitka Text / Cambria | source: local system faces | license: OS-provided
- UI: Avenir Next / Avenir / Futura / Century Gothic / Gill Sans | source: local system faces | license: OS-provided
- Mono: SF Mono / Cascadia Mono / IBM Plex Mono / Menlo | source: local system faces | license: OS-provided
- Scale: ratio 1.25 (Major Third), base 16px

| step | size | line-height | use |
|------|------|-------------|-----|
| display | 31px (1.953rem) | 1.05 | page titles |
| h2 | 25px (1.5625rem) | 1.15 | section and auth headings |
| h3 | 20px (1.25rem) | 1.2 | subsections |
| body | 16px | 1.7 | prose, interface body |
| small | 14px | 1.5 | metadata, helper text |
| micro | 12px | 1.4 | labels, dates, flags |

- Weights: 400 body, 500 note titles, 600 headings and controls, 700 uppercase labels
- Measure: 68ch | Tracking: display -0.01em, uppercase labels +0.12em, never tighter than -0.02em

## Color

- Strategy: cool paper and near-black ink with one vermilion accent. No indigo or violet band, no gradient text, no cream-by-reflex default. Accent is one metallic or earthen sharp note per theme, distributed roughly 60 neutral / 30 surface / 10 accent.
- Distribution: 60 neutral (bg/surface), 30 ink (fg/muted/line), 10 accent and semantic states
- Palette for the default Paper theme (role -> OKLCH | hex):
  - bg: oklch(0.948 0.011 123.5) | #ECEFE7
  - surface: oklch(0.979 0.008 121.6) | #F7F9F3
  - surface-2: oklch(0.921 0.014 128.6) | #E2E7DD
  - fg: oklch(0.234 0.008 153.3) | #1B1F1C
  - muted: oklch(0.506 0.019 148.2) | #5E685F
  - line: oklch(0.851 0.017 137.0) | #C9D1C6
  - accent: oklch(0.520 0.164 29.6) | #B4372A
  - on-accent: oklch(0.977 0.011 84.6) | #FBF7EF
  - error: oklch(0.468 0.153 28.8) | #9E2B22
- Dark themes (Ink, Midnight, Graphite, Forest, Fjord, Wine, Ember, Signal) use near-black tinted backgrounds around L 0.19 to 0.22, off-white text, borders lighter than the surface, and desaturated accent siblings. Full values live in `web/style.css` under `[data-theme]`.

## Spacing, radius, shadow

- Spacing base: 4px, scale 4, 8, 12, 16, 24, 32, 48, 64, 96
- Radius: two values only, 6px for surfaces and controls, 999px reserved for tags and pills (unused in the current UI)
- Shadow approach: defined edge only. No diffuse elevation shadows anywhere. Focus is a 3px ring with no blur. Selected theme cards use an inset ring.

## Layout and composition

- Grid: editorial two-column sheet, 13rem metadata rail plus a fluid reading column, collapsing to one column under 860px
- Gutters and margins: page content max 70rem, prose max 68ch, section gaps 48 to 96px
- Spacing rhythm: tight within rows and label/value pairs (4 to 8px), generous between sections (48px), larger around the sheet (96px)
- Signature layout move: ledger index rows with a fixed date column and a right-aligned pin flag, then a rail-plus-column article sheet
- Density: balanced | Scanning: F-pattern on the index, left-aligned reading column
- Responsive: mobile-first stacking at 700px, rail moves above content and becomes flat metadata

## Components and states

- Button hierarchy: one filled primary per view, secondary outlined, tertiary text. Hover changes border and text color; active scales to 0.98 under motion preference; focus uses a 3px ring; disabled state is not used yet.
- Inputs: visible uppercase labels, 6px radius, 1px border, accent border plus ring on focus. Errors keep the submitted draft and render above the form.
- Tables: the ledger index uses left-aligned titles, right-aligned flags, tabular monospaced dates, and 1px separators.
- Overlays: none. No modals, popovers, or focus traps.
- Empty / loading / error: empty state is a ruled italic line; errors are bordered surface blocks in the danger color; no loading state because every page is server-rendered.
- Focus ring: 3px `color-mix` accent ring via box-shadow, plus 2px outline on `:focus-visible` for high contrast.

## Motion

- Duration scale: instant 100ms, fast 150ms, normal 220ms
- Easing: `--ease-out: cubic-bezier(0.23, 1, 0.32, 1)`, `--ease-in: cubic-bezier(0.4, 0, 1, 1)`
- What animates: transform and opacity only
- Page transitions: CSS cross-document View Transitions (`@view-transition { navigation: auto; }`), 140ms out and 220ms in, with the header excluded so it stays put
- Micro-interaction: buttons scale to 0.98 on press, 100ms
- Removed: entrance fades on every section, hover lifts, shadow transitions, theme-switch color transitions
- Reduced motion: page transition animation set to none, all transitions disabled

## Iconography

- Set: one custom feather mark, inline SVG | grid: 32px viewBox | stroke: 1.6 | caps/joins: round | radius match: yes
- No icon library, no emoji, no icon tiles above headings

## Imagery and illustration

- Mode: real product screens, plus one generated demo image for the attachment example
- Rules: flat color blocks, editorial crop, letterpress palette, thin rules, monospaced coordinates
- Avoid: stock people, gradient orbs, floating blobs, corporate Memphis, default Midjourney renders
- Text-over-image contrast: the demo image keeps off-white text on dark teal blocks

## Dark mode (if in scope)

- Base bg: L 0.186 to 0.216, tinted near-black | fg: L 0.92 to 0.94 off-white
- Elevation ramp: surface L +0.04, surface-2 L +0.08; no shadow elevation
- Accent (dark): lighter and less saturated than the light accent, still AA against surface
- Border: L 0.307 to 0.356, lighter than the panel it borders
- Theme switching: no color transition

## Accessibility

- Contrast: AA target in all 12 themes; ink and accent pairs chosen for at least 4.5:1 body contrast where text is small
- Focus: visible 2px outline plus ring, never removed
- Keyboard: all actions are links, buttons, or forms, fully operable
- Targets: controls at least 24px, most 32 to 38px
- Color independence: pinned state is the word "Pinned", not a dot; errors include text
- Reduced motion: honored with an explicit reduced-motion branch
- Measured contrast: every theme passes at least 4.5:1 for muted and accent text on its background. Rose muted was darkened to 4.86:1 during the audit.

## Tokens (source of truth)

```css
:root {
  --font-display: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Palatino, Georgia, serif;
  --font-body: Charter, "Bitstream Charter", "Sitka Text", Cambria, Georgia, serif;
  --font-ui: "Avenir Next", Avenir, Futura, "Century Gothic", "Gill Sans", sans-serif;
  --font-mono: "SF Mono", "Cascadia Mono", "IBM Plex Mono", Menlo, Consolas, monospace;
  --text-xs: 0.75rem; --text-sm: 0.875rem; --text-base: 1rem;
  --text-lg: 1.25rem; --text-xl: 1.5625rem; --text-2xl: 1.953rem;
  --space-1: 0.25rem; --space-2: 0.5rem; --space-3: 0.75rem; --space-4: 1rem;
  --space-6: 1.5rem; --space-8: 2rem; --space-12: 3rem; --space-16: 4rem; --space-24: 6rem;
  --radius: 6px; --radius-pill: 999px;
  --duration-instant: 100ms; --duration-fast: 150ms; --duration-normal: 220ms;
  --ease-out: cubic-bezier(0.23, 1, 0.32, 1);
  --ease-in: cubic-bezier(0.4, 0, 1, 1);
  --bg: oklch(0.948 0.011 123.5);
  --surface: oklch(0.979 0.008 121.6);
  --surface-2: oklch(0.921 0.014 128.6);
  --fg: oklch(0.234 0.008 153.3);
  --muted: oklch(0.506 0.019 148.2);
  --line: oklch(0.851 0.017 137.0);
  --accent: oklch(0.520 0.164 29.6);
  --on-accent: oklch(0.977 0.011 84.6);
  --danger: oklch(0.468 0.153 28.8);
}
```

- Adapter: plain CSS custom properties

## Cards and surfaces

- Cards and surfaces: defined 1px edge, 6px radius, 8 to 16px padding, flat background
- Nesting: no nested cards. The article sheet is flat; rails and prose share the page surface.
- No card grid is used for the notes index. Rows are ruled, not boxed.

## Slop audit

- Date: 2026-11-07 | Result: fixed 14 tells
- Tells caught and corrected:
  1. gradient text on the page title
  2. cream background used as the default
  3. decorative radial aurora glows
  4. glassmorphism header with backdrop blur
  5. diffuse shadows stacked on hairline borders
  6. uniform large radii and pill-shaped cards
  7. identical card grid as the only layout device
  8. eyebrow kicker above every heading
  9. oversized marketing headline inside an app page
  10. entrance fade-up on every section and list row
  11. hover lift plus shadow animation on every card
  12. purple accent and cyberpunk green/magenta themes
  13. gradient orb demo image
  14. system-ui as the primary typeface
- Craft-layer result: buttons ranked by importance with full hover, focus, active states; inputs keep drafts on error; ruled index uses tabular dates; dark themes use lightness elevation and no glow; motion limited to transform and opacity with a reduced-motion branch
- Accessibility gate: focused outline and ring on all interactive elements, labeled inputs, 24px-plus targets, pinned state has text, contrast reviewed per theme

## Changelog

- 2026-11-07: First design system. Replaced the earlier aurora-and-cards UI with the editorial ledger direction, added OKLCH tokens, local editorial type, ledger index, rail sheet layout, CSS View Transitions, and dark-theme tokens for 12 themes.

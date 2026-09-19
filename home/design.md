# Personal UI Design Guide

Use this guide when designing or changing any UI for this user. It is platform-neutral: translate the rules into native components for web, mobile, desktop, games, or tools. Preserve the hierarchy and intent, not framework APIs.

The desired result is calm, practical, dark-first, compact without being crowded, and clearly functional. It should feel like OwnApps: a flat Nord interface with monospace type, softly rounded surfaces, and one restrained blue accent.

## Non-negotiable character

- Use the Nord palette. Do not substitute generic black, white, or bright framework colors.
- Use Martian Mono where available. Otherwise use a clean readable monospace font for all UI text.
- Prefer flat layered surfaces over gradients, glass effects, heavy shadows, or decorative art.
- Create structure with spacing, surface color, and alignment—not many borders or boxes.
- Keep copy short, direct, and non-technical.
- Do not add controls merely to fill empty space. A quiet screen is good.

## Color system

### Canonical palette

| Token | Hex | Use |
|---|---:|---|
| nord0 | #2E3440 | dark background |
| nord1 | #3B4252 | dark surface/card |
| nord2 | #434C5E | nested or grouped surface |
| nord3 | #4C566A | quiet border, muted detail |
| nord4 | #D8DEE9 | dark-theme primary text |
| nord5 | #E5E9F0 | light surface |
| nord6 | #ECEFF4 | light background |
| nord7 | #8FBCBB | secondary accent, use sparingly |
| nord8 | #88C0D0 | light frost accent, use sparingly |
| nord9 | #81A1C1 | primary blue; interactive accent |
| nord10 | #5E81AC | darker blue container/detail |
| nord11 | #BF616A | error and destructive actions |
| nord12 | #D08770 | warning |
| nord13 | #EBCB8B | code keyword/highlight |
| nord14 | #A3BE8C | success/code string |
| nord15 | #B48EAD | code number/highlight |

Dark is preferred. If light mode exists, follow the system theme, but keep nord9 as the primary accent in both modes.

| Role | Dark | Light |
|---|---|---|
| page background | nord0 | nord6 |
| main surface | nord1 | nord5 |
| nested surface | nord2 | nord4 |
| primary text | nord4/nord6 | nord0/nord1 |
| primary interactive color | nord9 | nord9 |
| border/quiet icon | nord3 | nord3 |
| destructive/error | nord11 | nord11 |

Use blue for normal interaction and selection. Reserve red only for errors and destructive actions.

The app icon uses a nord9 glyph on a nord0 rounded-square background, matching the primary accent.

## Typography

- Martian Mono regular for body text; medium for titles, labels, and button text.
- Keep the native platform type scale unless a product already has one.
- Use medium-weight small titles rather than oversized headings. The UI should be information-dense but easy to scan.
- Body and supporting text are quieter than titles, never larger or bolder.
- Avoid all caps, except where a platform control forces it.
- Use plain labels: “Grant permission,” “Delete script,” “Pick an element.”

## Spacing, shape, and layout

Use a 4-point rhythm:

| Purpose | Spacing |
|---|---:|
| tight inline gap | 4–6 px/dp |
| related control gap | 8 px/dp |
| standard card padding | 12 px/dp |
| screen edge / major gap | 16 px/dp |
| gap between sections/cards | 12 px/dp |

- Default page side padding: 16 px/dp.
- Cards and input fields: 12 px/dp corner radius.
- Small media, thumbnails, and code editors: 8 px/dp corner radius.
- Use full-width controls inside cards when there is one clear action.
- Align repeated trailing controls to the same vertical edge.
- Prefer a single-column layout for settings and management screens. Use grids only when browsing visual items genuinely benefits from one.

## Surfaces and cards

Cards group related content; they are not decoration.

- Normal depth sequence: page background → card surface → nested/group surface.
- Use no elevation at rest. Small elevation is acceptable only as active feedback, such as while dragging.
- Avoid outlines on cards by default. Separation comes from surface contrast and the 12 px/dp gap.
- A standard information/settings card has 12 px/dp internal padding: title on top or left, supporting text beneath, status/action on the right or below.
- Keep warning cards calm: normal surface, short red message, then a clear action. Do not make the whole card red.

## Controls and action hierarchy

Do not make every action look equally important.

### Filled primary button

Use a filled nord9 blue button with dark text for one main next step:

- grant a required permission;
- save a form;
- complete a confirmation;
- open the required setup flow for the current feature.

Do not place several filled buttons together unless the user must choose between equally important outcomes. Use full width in a card when it is the card’s only action.

### Quiet outlined secondary button

Use a transparent button with a 1 px/dp nord3 border and nord9 text. No colored background. It is for useful but less urgent actions, such as an optional system setting or supporting tool.

- It may include one small leading icon when that makes the action clearer.
- Fade text and border when disabled; do not hide availability information.
- Current examples: Node Picker and Ignore battery optimization.

### Plain text action

Use text-only blue actions for low-emphasis choices, especially dismissal or cancellation.

- Typical example: Cancel in a confirmation dialog.
- Do not use text-only actions for a primary save, grant, or destructive confirmation.

### Destructive actions

- Delete/trash icons are nord11 red.
- A destructive confirmation button is filled nord11 red with light text.
- A text-only destructive button (e.g. "Delete" in an edit dialog) uses nord11 red text with no background.
- Keep its paired Cancel action text-only.
- Always confirm an irreversible delete. Use a short question and a one-sentence consequence.

### Warning actions

- A text-only warning button (e.g. "Reset to defaults") uses nord12 orange text with no background.
- Use this for actions that are disruptive but recoverable.

### Icon buttons

- Use icon-only controls for familiar compact actions: back, add, search clear, edit, delete, settings, pin, and navigation tools.
- Give every icon an accessible label or tooltip.
- Keep normal icons quiet. The delete icon is the deliberate red exception.
- Do not wrap an icon button in a decorative container unless the platform requires a touch target.

### Switches and toggles

- A switch represents a persistent on/off state, never a one-time command.
- ON always means enabled/allowed; OFF always means disabled/blocked.
- Place switches at the trailing edge of rows and align them across the list.
- A disabled switch should visibly explain an unavailable prerequisite nearby when that matters.

## Navigation, lists, and forms

### Top bar

- Keep it simple: screen title, back icon on subpages, and only essential actions on the right.
- Root screens may have a small set of icon actions. Do not add text actions to the bar unless a task such as Save is the clear primary action.
- A global switch may sit at the trailing edge when the whole screen has one enable/disable state.

### Lists

- Rows are compact, flat, and easy to scan: icon or thumbnail, title, quiet secondary text if needed, then trailing controls.
- Make a row tappable only if tapping anywhere has one obvious result. Do not make a row tappable when it contains several competing actions.
- Use small dividers only between meaningful groups. Prefer card spacing otherwise.
- Empty/loading states should be quiet and centered, without illustrations unless they teach a workflow.

### Inputs and editors

- Inputs are outlined, full width, 12 px/dp rounded, and labelled clearly.
- Search has a leading search icon and a clear icon only when there is text.
- Keep forms vertically stacked with 8–12 px/dp gaps.
- Code editors may use a tighter 8 px/dp radius, a subtle border, and Nord syntax colors. Do not use code styling for ordinary settings text.

### Dialogs and feedback

- Dialogs use the normal surface, a short title, one brief explanation, and minimal actions.
- Use native transitions and motion, but keep them fast and subtle. A short slide plus fade is preferred over dramatic animation.
- Do not use alerts or banners for expected states. Use them for errors, completed actions, or prerequisites that need attention.

## Copy rules

- Lead with the user outcome: “Turn on accessibility,” not “Accessibility service required.”
- Keep labels to a few words where possible.
- Explain a prerequisite once near the unavailable action; do not repeat it across the screen.
- Avoid developer names, implementation details, and internal vocabulary unless the user must act on them.
- Prefer “Copy,” “Save,” “Delete,” “Open settings,” and “Grant permission” over verbose variants.

## Avoid

- Bright gradients, glassmorphism, neon effects, stock illustrations, or ornamental backgrounds.
- Rounded pills everywhere. Use 12 px/dp rounded rectangles, not exaggerated capsules.
- Heavy shadows, large floating action buttons, or oversized hero headings unless the product is marketing-focused.
- Multiple accent colors competing for attention.
- Dense borders around every element.
- Long explanatory text when a short label plus optional secondary line will do.
- Making every clickable item look like a primary button.

## Implementation checklist for an AI

Before finishing a UI task, check that:

1. Nord colors and monospace typography are consistent.
2. The page has a clear primary action, if it needs one, and no unnecessary primary buttons.
3. Secondary actions are transparent buttons with quiet nord3 outlines and blue text; cancel/dismiss actions are text-only.
4. Delete and other irreversible actions are red and confirmed.
5. Cards use flat surfaces, 12 px/dp corners, and consistent 12/16 px/dp spacing.
6. Repeated rows align their trailing controls.
7. User-facing copy is short, direct, and free of implementation jargon.
8. The result is accessible: adequate contrast, labelled icons, usable touch/click targets, visible disabled state, and keyboard/focus support where the platform provides it.
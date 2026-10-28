# Starlight style guide

The design rules for everything Starlight shows: the notch, its cards, and the windows. The tokens
named here (`ink`, `fill-quiet`, `answer-width`, `radius-flare`…) are defined in
[tokens.json](tokens.json) and [tokens.css](tokens.css); the live style guide, with every component
and animated icon, is the "Starlight Big Answers" design system artifact. In code, the shape and motion
live in `Sources/NotchShape.swift` and the `Motion` enum (`Sources/NotchModel.swift`).

Starlight shows answers the way a car's dashboard shows speed: one big, plain line you can read at a glance, then nothing until it's needed again. Everything is black and white. Color appears for exactly two things, success and failure, and always comes with a shape.

## The idea: big answers

- **Say the answer, not the question.** A card never repeats what was asked. "What's the capital of Azerbaijan?" shows **Baku.**, not "The capital of Azerbaijan is Baku."
- **Facts go big.** A short fact is set in `headline` (22px semibold, `ink`), one or two lines, with at most two lines of `detail` under it in `ink-secondary`: **1,000 USD is about 850 CHF.** / At today's rate of 0.85.
- **Sentences stay small.** An answer that's a sentence or three uses `answer` (13px). Code, steps and anything longer move to the long card (`long-answer-width`), which scrolls inside the notch.
- **Actions are confirmations.** When Starlight does something, the card says what happened in `outcome` (15px semibold) beside a check or a cross: **Saved to memory**, **Cancelled**. When it opened, saved or moved something, the thing itself is the headline: its own icon (`item-icon`), the verb small in `verb` over it (Opened, Saved and opened, Added to Reminders), the name big.
- **One thing at a time.** One card, one answer. A card that needs a decision (approve a change) has one main button in `fill-strong` and one quiet one.

## Writing

- Plain, short sentences in the second person: "Hover me any time." "Starlight only asks for what a feature needs." Never "Please", never "Oops".
- Sentence case everywhere, buttons included: Copy transcript, Move to Trash, Start using Starlight.
- Real numbers, formatted: 1,000 not 1000; $12 a seat; 212 GB free of 494 GB; 3:43.13. Currencies as their codes or symbols, the way people say them.
- Step titles in windows end with a period: "A few permissions." "Try it." Card text ends with one too.
- Status words are one or two words with an ellipsis only while working: Thinking…, Calculating…, Listening. Done states have no ellipsis.
- Friendly at the edges: the end of a meeting reads "13 minutes with Dana" / "You did most of the talking", not statistics.
- No emoji, ever. Keys are spelled as words: Control + Space, Option + Space.

## Color

- `notch` (pure black) is the only background inside the notch and in every window. `ink` (white) is the only text color for answers.
- Hierarchy comes from white at fixed strengths, not from grey hues: `ink` (primary), `ink-code` (code), `ink-secondary` (the small line around a big one), `ink-tertiary` (paths, hints), `ink-faint` (placeholders only).
- Surfaces inside black are white at low strength: `fill-quiet` at rest, `fill-hover` under the pointer, `fill-strong` for the one main action, with `on-fill-strong` text. Dividers and window edges are `hairline`.
- `success` and `danger` are the only hues, and only as the check and cross circles (and the word Overdue). They always carry their shape, so they read without color.
- `desktop-top` and `desktop-bottom` exist only to show the notch in context, in previews and product shots.

## Type

- System faces only: SF Pro through `--font-sans`, SF Pro Rounded for the clock through `--font-rounded`, SF Mono for real commands through `--font-mono`. No web fonts.
- The scale inside the notch: `headline` 22, `outcome` 15, `answer` 13, `detail` and `verb` 12.5, `status` 12, `label` 11.5. Windows add `page-title` 44, `done-title` 30, `section-title` 22, `body` 15.
- Weights: 600 for anything big, 500 for verbs, 400 for running text. Figures are tabular where they change (the clock, timers, percentages).

## Layout

- Words never come closer than `space-28` to the notch's curved sides. The notch grows to fit its text; it never truncates a headline.
- An answer card is `answer-width` (460) wide; code and long answers are `long-answer-width` (580) and scroll inside, up to 420 tall, fading at the top.
- A picture beside a named place or person is `picture` (64) square with `radius-row` corners, on the right.
- Pills sit `space-6` apart; a glyph sits `space-8` from its words.

## The window

- **Organised by what you do.** The sidebar lists Dictation, Meetings, Tasks and Memory (each feature's history and its settings, as two tabs on one page), then General, Answers, Shortcuts, Privacy, Account and About. No two items share a name. Search at the top finds any setting by name, opens its page and lights the group it's in.
- **Show, don't tell.** A choice that changes what you see is a row of picture tiles, not a dropdown: the real notch at your text size, the same sentence in each dictation style, the notch asking, listening or staying out of a call, an answer at each length. Shortcuts are drawn as keycaps. The chosen tile has a white ring; nothing else has one.
- **Simple first.** Each page shows the few settings people change; the rest wait under "More settings" at the bottom.
- `notch` black behind everything, the sidebar included: it sits flush with the window's left edge with no panel, border or divider, and the selection is the only shape in it. Settings sit in `surface-row` cards with a `hairline` edge, one card style on every page.
- Liquid Glass (macOS 26 and later) only on the buttons. Content never sits on glass.
- Switches are black and white, never the accent color: on is white with a black knob.
- Long lists (dictations, meetings) load a page at a time as you scroll.
- The content column is centred, up to 720 wide. Every page opens at its top; pages switch without a cross-fade.
- Notes under a card use `ink-secondary` at 12pt, never fainter.

## Shape

- The notch hangs from the top edge: square at the top, `radius-flare` concave curves where it meets the screen, rounded bottom corners that go from `radius-notch-closed` (10) at rest to `radius-notch-open` (36) once it has grown 110pt taller, eased between the two by its size.
- Buttons and toggles are capsules (`radius-pill`). Rows and wells use `radius-row`, settings groups `radius-card`, tiles `radius-tile`, the transcript window `radius-window`.
- The notch casts `notch-shadow` only while hovered, open or showing something; floating windows cast `window-shadow`. Nothing else has a shadow.

## Motion

Every change of shape runs on a spring, never a duration curve:

| When | Spring (response, damping) |
|---|---|
| Pointer arrives (hover) | 0.36 s, 0.5: a lively swell with a little bounce, 18 × 7pt bigger |
| Opening | 0.46 s, 0.66: a small overshoot, so it pops out |
| Closing, pointer leaving | 0.38 s, 0.96: settles without bouncing |
| Press | 0.42 s, 0.6: gives back a little over half the hover growth |

Content comes in 0.08 s after the shape starts to grow, sharpening out of a 22pt blur from 80% size, anchored to the top of the notch (0.32 s, no bounce), and leaves in 0.18 s. An item's icon pops in from 55% with a slight turn. A check circle scales in. With Reduce Motion on, everything fades instead.

## Iconography

- 42 line glyphs drawn for Starlight, white on black, about 1.85pt strokes at 24pt on a 24-unit grid (see the Icons card). Every one has a hover motion; voice, agent, globe and spring keep moving while active; check, alert and cross draw themselves on. Their frames are in the Icons assets.
- Apps and files are shown with their own Finder icons, never redrawn.
- Example photos are credited where they're used (the Baku montage is CC BY-SA 3.0, by Interfase on Wikimedia Commons).
- The mark is the voice glyph's five bars (5, 10.5, 15, 10.5, 5 units tall, 4 apart): `Resources/AppIcon.png` is white bars on a black tile, `Resources/AppIcon-white.png` the inverse for light grounds.

## Don't

- Don't add a color to make something stand out; make it bigger or whiter.
- Don't put a border on the notch or a card inside it.
- Don't show the user's own question back to them.
- Don't use grey text below `ink-tertiary` for anything that must be read.
- Don't stack two cards; replace the first.

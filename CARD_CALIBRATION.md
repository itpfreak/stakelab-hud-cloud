# StakeLab HUD Cloud — Card Calibration Contract

This file documents the runtime card-grounding contract. It is not a model-training file by itself; the Swift watcher enforces these rules by cropping the permitted regions before inference.

## Hero identity

- Hero username: `J4clubs`
- `J4clubs`, `J4`, and `4c` in the username are never hole cards.

## Permitted regions

- Hero hand: only the two face-up card rectangles immediately above the visible `J4clubs` username.
- Board: only the face-up community-card row in the center of the green table.
- Ignore every other number, letter, suit-like symbol, stack, timer, blind, pot, button, avatar, and browser element.

## Four-color deck

- Red: hearts (`h`)
- Blue: diamonds (`d`)
- Green: clubs (`c`)
- Black/dark: spades (`s`)

## Confidence behavior

- A rank and suit must be visibly confirmed in the permitted region.
- Unknown rank or suit must be represented as `?`; never default an unknown suit to spades.
- The strategy model must not replace grounded OCR/color results with a guess.

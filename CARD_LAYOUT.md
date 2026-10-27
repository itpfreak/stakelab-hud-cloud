# StakeLab Cloud Coach v2 — Fixed Floorp Layout Contract

David uses Floorp consistently and does not resize the table window during a session. The watcher therefore uses a locked geometry version after the `J4clubs` anchor is found.

## Perception rules

- Locate `J4clubs` only as a seat anchor; never parse username characters as cards.
- Hero cards are two physical slots immediately above the anchor: left slot and right slot.
- Board cards are a left-to-right row in the center-table crop.
- Every candidate must be assigned to a physical slot before it can become card evidence.
- OCR tokens outside a slot are rejected; the first N tokens are never authoritative.
- Unknown rank or suit is `?`, not a guessed suit.
- A geometry change, anchor movement, window switch, or inconsistent table bounds invalidates the locked geometry and suspends card-dependent advice until reacquired.

## Current implementation status

The v2 branch uses slot assignment for hero cards and spatial de-duplication for board observations. The next calibration pass should render these boxes over a captured screenshot and record exact normalized coordinates for this Floorp/table theme. Keep the A3-versus-AK incident as a permanent regression case.

# Issue #14 review

## Prior issue

The first implementation set every reset-window `guidanceDeadline` to the reset timestamp. That answered how long the cycle lasts, not how long the recommended action lasts. It also blended the current distance from the chart's pacing guide with projected remaining usage, so the recommendation could describe a different relationship than the chart.

For example, in a uniform 24-hour cycle, at hour 10 the guide has 58.33% remaining. If recorded remaining usage is 25%, zero usage catches the guide at hour 18, when the guide reaches 25%. “Conserve until midnight” was six hours too long.

## Revised semantics

Use the same active-time coordinate as `resetWindowPaceGuide`. If `A` is the cycle's total weighted active seconds and `a(t)` is weighted active seconds elapsed, the guide is:

`G(t) = 100 * (1 - a(t) / A)`

The pacing score and recommendation now describe the current chart relationship directly:

`score = currentRemaining - G(now)`

For conserve, usage is explicitly zero, so recorded remaining usage `U` stays constant. The active duration to alignment is:

`delta = (G(now) - U) / (100 / A)`

For push, “push” means continuing at the supported observed burn rate `r`. When `r` is faster than the guide burn rate, the active duration is:

`delta = (U - G(now)) / (r - 100 / A)`

The engine converts that active duration back to a wall-clock date using the same learned hourly/weekday weights as the chart and never carries a deadline past the reset boundary.

Numerical checks include:

- Conserve: `U = 25%`, `G(now) = 58.33%`, uniform guide burn `4.1667%/hour` gives 8 active hours, and both trajectories equal 25% at hour 18.
- Push: `U = 60%`, `G(now) = 50%`, observed burn `6%/hour`, and guide burn `4%/hour` gives 5 active hours; both trajectories equal 30% then.
- Smart active hours: four active hours starting at 8:00 PM map to midnight rather than four arbitrary elapsed model hours.

## Undefined and low-confidence behavior

- No assessment is produced when the current reset cycle has no defensible cycle start, matching the chart's need for a defined guide.
- A push deadline is omitted when the observed burn estimate has confidence below 0.35, is not faster than the guide, or cannot intersect before reset. The menu keeps the recommendation label without claiming an “until” time.
- A conserve deadline remains defined without a burn estimate because its stated assumption is zero usage; it depends only on the displayed pacing guide.
- Existing notification confidence gating, limit-reached behavior, and imminent-reset wording remain unchanged.

## Deadline display

Pacing guidance compares the deadline with `now` using the supplied local `Calendar`, including
its time zone. A same-calendar-day deadline stays concise (for example, `Conserve hard until
5:45 PM`). A deadline on tomorrow or any later calendar day includes the locale's medium date and
short time (for example, `Conserve hard until Jul 7, 2026 at 5:45 PM`). Including the year avoids
ambiguity across long reset windows, while system date/time styles respect the user's locale and
12/24-hour preference. Calendar-day comparison, rather than a 24-hour interval, keeps this rule
correct across daylight-saving transitions.

The macOS menu is the only current consumer of the pacing deadline message. Pacing notifications
show projected-empty and reset timestamps with dates rather than the guidance deadline. The CLI and
mobile presentation do not currently expose pacing deadline text, so they require no display change.

## Overflow display

The menu's status line remains compact and leading-aligned on one line. Text that fits does not move.
When the full status is wider than its row, hovering pauses for 0.4 seconds and then eases the text
left exactly far enough to expose its trailing edge. It stops there rather than looping. Moving the
pointer away eases it back to the leading edge in 0.3 seconds. Reduce Motion removes the animation.
The unabridged status is also exposed as the accessibility label and as the macOS help tooltip.

Manual check: select pace coloring, open the menu for an ahead/behind reset-window metric, and
compare the local “until” timestamp with the point where the corresponding usage trajectory meets
the pacing guide. Narrow or lengthen the status enough to truncate it, then hover the status line:
the first 0.4 seconds should remain still, the trailing text should move in once and stop, and moving
the pointer away should restore the leading text. A status that fits should remain still. Pause over
either status to confirm the tooltip contains the full text, and inspect the line with VoiceOver to
confirm it announces that same unabridged text. Undefined push intersections should show only the
action label. Limit reached and imminent-reset wording should remain concise.

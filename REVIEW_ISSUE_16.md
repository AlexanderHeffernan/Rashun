# Issue #16 review

Adds an **Hour** history range covering the current calendar hour, not a rolling 60-minute window. The chart uses ten-minute axis ticks at this scale.

Hour tick labels show compact times (`8:00`, `8:10`, …) instead of repeating the full date at every tick. The date is shown once, centered beneath the hour axis. Other chart ranges retain their existing label formats.

Manual check: open Usage History, choose Hour, and verify the bounds run from `:00` through the next hour with readable ten-minute labels and a single date below them.

Validation: `ChartTimeRangeTests`, `UsageChartViewTests`, and a release app build.

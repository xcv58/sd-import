# SD Import 1.10

- Simplified the Import preview with a clearer Preset mode and a Custom mode for manual media and organization overrides.
- Replaced the confusing excluded-files warning with direct empty-state guidance and recovery buttons when the selected media type is not on the card.
- Cached import preview rows, totals, destinations, and space checks so progress updates no longer rebuild the full preview during imports.
- Kept the active import preview separate from History details, preventing History navigation from changing the planned import.
- Reduced import-time UI churn by showing progress without the full preview and by publishing progress updates less aggressively.
- Fixed source volume capacity display when macOS reports zero important-usage capacity but normal free space is available.

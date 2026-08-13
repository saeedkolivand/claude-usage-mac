# One widget kind per face style

Face styles were only discoverable through Edit Widget's Style dropdown, so the
gallery advertised a single widget and five looks went unseen. Each style is now
its own widget kind (`…widget.terminal`, `…widget.lcd`, …) so the gallery lists
and previews all six. Widget kinds are permanent — WidgetKit offers no
migration, which is how the original kind got frozen at 0.3 — so these six
strings can never be renamed or consolidated back into one; a future cleanup
that merges them would kill every placed widget. All kinds deliberately share
the one `UsageConfigIntent` (the Style parameter stays as an override) so there
is exactly one migration-fragile intent type to protect, not six.

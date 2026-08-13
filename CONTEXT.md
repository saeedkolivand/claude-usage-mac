# Claude Usage

A macOS menu bar app and widget set that shows Claude account limits and local
token spend. This glossary pins the terms the UI and code must agree on.

## Language

**Account-scoped**:
Numbers Anthropic reports for the whole account — the session, weekly,
per-model, and extra-usage percentages with their reset times. Identical on
every device signed in to the account.
_Avoid_: global, remote, API stats

**Machine-scoped**:
Numbers computed from this Mac's own transcripts — tokens, cost, history,
projects. Other devices on the same account are invisible here; the UI labels
these blocks "THIS MAC".
_Avoid_: local stats, device stats, per-device usage

**Profile**:
One Claude config directory (and its credentials) discovered on this Mac. One
account may own several profiles; identity across profiles is email plus
organization.
_Avoid_: account (that's the thing a profile signs in to)

**Face**:
Which widget family size is being drawn — small, medium, or large.
_Avoid_: size, family (in view code)

**Face style**:
The visual skin a widget wears — Default, Terminal, Speedometer, LCD, Glass,
Heatmap — independent of its face.
_Avoid_: theme, skin, look

**Widget kind**:
The permanent identity string of a gallery entry. Frozen the moment a user
places a widget of that kind; renaming one kills every placed widget.
_Avoid_: widget id, widget type

# Interface Style

Screenlogger uses native macOS behavior.
Clear text and predictable navigation have priority over decoration.

## Principles

- Use standard AppKit and SwiftUI controls when they support the required behavior.
- Show the current state and next safe action clearly.
- Put optional technical details in disclosure controls.
- Keep recovery information visible.
- Use one visual style for each role in Library, Timeline, Setup, and Settings.
- Prefer spacing and alignment to nested cards.
- Do not use only color, motion, or an icon to explain a state.

The visual direction is a native visual library, shared by Search, Sessions,
Timeline, Settings, and Setup. Captured content takes precedence over chrome.
Use SF system typography for this data-heavy utility rather than editorial
display type. Respect the selected accent; ordinary labels and secondary
actions remain neutral. Do not force Timeline into a different appearance.

`SLDesign` owns the shared title, section, body, and metadata fonts. Prefer its
4, 8, 16, 24, 32, and 48-point spacing tokens. Use 8-point image corners and
12-point panel corners only where grouping serves a purpose. Native controls
retain their platform sizing and accessibility behavior.

The requested SwiftUI design review covers philosophy, visual hierarchy, craft,
functionality, and originality. Review rendered light and dark screens, not
source code alone. A numerical score is a design judgment, not automated proof;
record concrete defects and verify their fixes before calling a surface ready.

Timeline uses an adaptive image stage, a flat transport row, and directly
labeled activity bands. The playhead and selected activity carry the accent;
display controls stay outside the captured image. Settings uses left-aligned
headings, neutral navigation icons, and flat grouped forms. Setup uses one next
instruction, with privacy details disclosed on demand and explicit consent
preserved. Sessions keeps its native list selection and an image-led detail
pane; Search offers recent queries and sessions instead of a decorative hero.

Only when Meaning is selected and has incomplete coverage, show one compact indexed/waiting line
next to the query area with a native filled Index Now button, not a text link. Keep partial results
usable, distinguish active indexing from waiting, and remove the line when the
backlog and failures are clear. Do not repeat this status around the results.
Both matching modes show recent searches when the query is blank and no filters
are active. A Meaning description prompt must not hide that starting point.

Result headings use recorded page/window titles, with an application fallback;
OCR is evidence, not an invented title. Show app/site/time context once and
include an excerpt only when it explains the match beyond that identity.
Sorting belongs to the results toolbar. Group filtering by When, Where, and
Content, and keep selected application/site choices visible when lists collapse.

Sessions lead with chronological sampled screenshots. App and website totals
sit beside them at wide sizes and below them at narrow sizes. Keep recorded
time methodology behind a disclosure. Row and detail Rename actions share one
explicit-target editor; invoking row Rename selects that row.

## Layout

- Use pane margins and section spacing from `SLDesign`.
- Align row titles, descriptions, state labels, and controls.
- Let important text wrap.
- Do not truncate permission, privacy, or error text.
- Test window sizes of 820 x 540, 1,060 x 700, and 1,440 x 900.
- Make the layout adapt before you add horizontal scrolling.

## Typography and color

- Use system text styles and materials.
- Use shared Screenlogger color definitions.
- Use the selected accent as the color for controls and selection.
- Keep native AppKit color behavior where the system controls it.
- Use red only for destructive actions or failures.
- Show warning and success colors with text and an SF Symbol.
- Keep supporting text at secondary contrast or higher.

## Navigation

- Keep Library, Timeline, and Settings as stable destinations.
- Make Back restore the exact previous Library state.
- Preserve search, filters, selection, preview state, and position when users return from Timeline.
- Show useful session details after one click in Sessions.
- Open the exact pane and control from Settings search.
- Move keyboard focus to that control.
- Make every primary action available with the keyboard and VoiceOver.

## Controls and states

- Use one primary action for each decision.
- Give icon-only controls accessibility labels and help text.
- Show visible labels when space permits.
- Keep useful content visible during loading when possible.
- Distinguish first use, no results, active filters, and unavailable data.
- State the effect of an error.
- Give a recovery action that the user can perform.
- Explain why a disabled control is unavailable.
- Keep Words/Meaning matching inside the search control, not in a competing navigation row.
- Put search setup in that control's menu; do not repeat unavailable-state banners around results.
- Show the search field only in Search. Sessions is a separate browsing surface.
- State the scope of destructive actions before confirmation.

## Permissions

Setup has separate Screen Recording and Accessibility states.
Request permission only after an explicit user action.
Open the applicable System Settings pane for later actions.
Do not infer permission from an open Settings pane.
Do not use a content-capture API for repeated permission checks.

If a privacy list does not show the app, show a stationary app tile that users can drag.
Label its source and destination.
Also provide Show in Finder and Add-button instructions.
System Settings behavior differs between macOS releases.

## Assistant integrations

Each assistant row shows one identity, state, explanation, and primary action.
Use the assistant's logo only for identity.
Use SF Symbols for actions and state.
Show Connection verified only after Screenlogger checks its own command path.
Do not claim that Screenlogger tested the assistant itself.

## Motion

Use short motion only to explain a state or position change.
Respect Reduce Motion.
Do not use repeated decorative motion, animated gradients, or moving action targets.

## Copy

Write for the person using the app, not for the implementation.
Use natural, concise language and familiar macOS labels. Contractions are fine.

- Show the current state, not several overlapping descriptions of it.
- Give each state one clear next action.
- Keep setup, indexing details, and storage controls in Settings.
- Keep search controls compact. Do not turn the Library header into a status panel.
- Disabled features are setup states, not search failures.
- Explain privacy and destructive actions at the point where they matter.
- Preserve command syntax, machine identifiers, legal notices, and technical limits.

Test behavior and recovery, not exact display wording.

## Review checklist

- The first safe action is clear.
- State and recovery text match behavior.
- Keyboard and VoiceOver support the same actions as the pointer.
- Light mode, dark mode, Increased Contrast, Reduce Motion, and larger text remain usable.
- Shared code defines reusable spacing, color, text, and control styles.
- Screenshots show no clipped text, overlap, unused regions, or competing primary actions.
- Copy is clear in context. Remove text that repeats a control, state, or nearby explanation.

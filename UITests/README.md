# UI Tests

`ScreenlogAppUITests` checks Library, Timeline, Setup, Settings, assistant routing,
exclusions, keyboard navigation, and cross-window state restoration.

Tests start the real app with a new temporary data directory and separate preferences.
Debug-only fixtures create sample moments and specified permission or assistant states.
They do not read the user's Library, change TCC, or call ScreenCaptureKit.

Run the routed suite:

```sh
Scripts/test-ui.sh
```

The runner refuses to start while another Screenlogger process is active.

`VisualAuditUITests` captures app windows in repeatable light, dark, default-size,
and minimum-size states. Save exported screenshots and result bundles under `build`.
Do not commit them.

Prefer visible labels and roles to coordinates or hierarchy depth.
Add stable accessibility identifiers only when a lasting user-facing label cannot identify a control uniquely.

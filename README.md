# Fingerprint — Omarchy bar widget

Omarchy bar-widget to monitor and control the **FPC 9201 fingerprint reader**
on Redmi Book 16 / compatible laptops, driven by the [fingerprint-ocv
daemon](https://github.com/zimixin/fingerprint-ocv).

## Features

- Bar icon: colorized fingerprint glyph + enrolled count.
  - color: `urgent` = no print / driver down, `foreground` = ready.
- Popup panel:
  - **Actions** — Register / Verify / Delete-all / Refresh (V/E/D/R hotkeys).
  - **Driver** — start / restart the `fingerprint-ocv` user service from the panel.
  - **Registered list** — names of stored prints.
- Actions launch in a floating terminal with **live progress** (enroll shows
  `Этап X/10 [██░░…] нажатий N`, one carriage-return line).

## Screenshot

![Fingerprint widget](assets/preview.png)

## Requirements

- The **fingerprint-ocv** D-Bus daemon must be running (see
  [zimixin/fingerprint-ocv](https://github.com/zimixin/fingerprint-ocv)) and
  own the session bus name `net.reactivated.Fprint`.
- User is `/home/<user>`; the widget talks to the driver over the D-Bus
  session bus and to `systemd --user` for the service control.

## Install

```bash
omarchy plugin add https://github.com/zimixin/omarchy-fingerprint
```

Then add it to the bar: edit `~/.config/omarchy/shell.json` →
`bar.layout.right` → append `{"id":"zimixin.fingerprint"}`, then
`omarchy-restart-shell`.

## Files

- `Panel.qml` — bar button + popup (Quickshell, `qs.Ui` components).
- `bin/fp-status.sh` — status collector; writes
  `~/.local/state/omarchy/fingerprint/status.json` (keeps last-known on error).
- `bin/fp-action.py` — `status|enroll|verify|delete` over D-Bus; auto-picks a
  free print name on enroll, drives live progress output.

## Notes

- **No background polling.** The fingerprint-ocv daemon is not concurrency-safe
  on D-Bus (can abort on parallel calls). Status is refreshed only when the
  panel opens / the user clicks a refresh.
- `finger-present` is not shown as "touching now" — the driver's property
  latches `true` after the first touch of a scan.

## License

MIT — see `LICENSE`.
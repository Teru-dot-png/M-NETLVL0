# lib/log.lua — Tagged logging

Source: [../../onet/lib/log.lua](../../onet/lib/log.lua)

## Purpose

`log` is the one-line tagged logger that **every state transition, craft, and
build action** calls. It is deliberately tiny because it is the single dependency
every other module pulls in. Each tag has an assigned colour so the cockpit /
shell scan reads at a glance.

It is **byte-identical on turtle and overseer**.

## Place in the architecture

Every module requires this as `local log = require("log").log`. The tag taxonomy
(`BOOT`, `NAV`, `MINE`, `FUEL`, `DUMP`, `NET`, `PUSH`, `SCAN`, `BUILD`,
`GENESIS`, `ALERT`, `ROLE`, `OVERSEER`) is the convention used throughout the
codebase; tagged logging on every transition is a project-wide requirement.

---

## `M.log(tag, msg)`

**Signature:** `log(tag, msg) -> string`

Formats and prints a line `"[TAG] message"`. If running on a real CC computer
with a colour terminal (`term.isColor()` true), it looks the tag up in the
`TAG_COLOR` map, sets that text colour for the print, then restores the previous
colour. Outside a colour terminal (e.g. unit tests where `term` may be absent) it
falls back to a plain `print`.

- **Parameters:** `tag` (string; coerced, defaults to `"?"` if nil) — the log
  category; `msg` (any; coerced with `tostring`) — the message body.
- **Returns:** the formatted line string (also returned in the non-colour path),
  useful for callers that want to echo or store it.
- **Side effects:**
  - Terminal I/O: `print` to the active terminal.
  - Reads/writes terminal colour state via `term.getTextColor` /
    `term.setTextColor` (restored afterward) when a colour terminal is present.
- **Notes:** guards on `term`, `term.isColor`, and `colors` so it is safe to call
  in a non-CC environment.

### `TAG_COLOR` (module local)

The per-tag colour map. Unknown tags fall back to white.

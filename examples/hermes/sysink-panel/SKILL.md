---
name: sysink-panel
description: Show a short notice on the SysInk e-paper panel next to the Raspberry Pi, for things the user should see at a glance even when away from chat.
version: 1.0.0
author: SysInk
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Notifications, Raspberry Pi, E-Paper, Home]
---

# SysInk panel notices

The Raspberry Pi has a small 2.9" e-paper panel (296x128 px, black and white)
running SysInk, a system monitor. A notice replaces the monitor screen for a
while, 30 seconds by default, then the monitor comes back.

## When to use it

Use the panel for something the user should notice in the room, without
reading chat:

- a long task you were asked to watch has finished or failed
- a reminder the user asked for at a set time
- something that needs them at the machine now

Do not use it:

- **for anything private.** Anyone in the room can read the panel. No
  passwords, tokens, personal details or message contents.
- instead of answering in chat. The panel is an extra signal, not the reply.
- for a stream of updates. Each notice replaces the one before it, and a
  refresh takes about half a second, so send one when it matters, not one per
  step.

## How to send one

Run the helper with the `terminal` tool:

```bash
${HERMES_SKILL_DIR}/scripts/notify.sh "Backup finished"
${HERMES_SKILL_DIR}/scripts/notify.sh "Build failed: see chat" 300
${HERMES_SKILL_DIR}/scripts/notify.sh --clear
```

The second argument is how long to show it, in seconds, up to a day.
`--clear` takes the current notice down early.

The helper writes to the local pipe `/run/sys-ink/notify` when it can, and
otherwise publishes to the MQTT topic `sysink/notify`, with its own Python
publisher or `mosquitto_pub` where there is no Python. In a sandbox container
it finds the broker on the host by itself. Broker settings and credentials
come from `sysink.env` in the skill's directory, set up by the user; never
print or repeat them. Exit status 0 means the notice was handed over.

Always send through the helper, not by writing to the pipe or publishing
yourself: it is the one path that works both on the machine and inside a
sandbox, with the credentials it needs.

## Writing the text

- **Short.** Up to about 30 characters get the largest font, in two lines.
  Up to about 100 stay easy to read from across the room. About 250 is the
  most the panel holds, and anything longer is cut off with `...`.
- **Lead with the point:** "Backup failed: disk full", not "Hi! I wanted to
  let you know that...".
- **Diacritics are dropped.** The fonts are ASCII only, so "Pračka dokončila"
  shows as "Pracka dokoncila". It stays readable, so keep writing in the
  user's language. Emoji and other symbols show as `?`, so leave them out.
- **No line breaks.** The text is wrapped to fit. On the pipe a newline splits
  it into separate notices of which only the last is shown; the helper joins
  the lines for you.

## If it fails

- `nothing is reading /run/sys-ink/notify`: the SysInk service is not
  running. Tell the user; do not retry in a loop.
- `Permission denied` on the pipe: this user is not in the group named by
  `NOTIFY_GROUP` in `/etc/default/sys-ink`. Tell the user.
- MQTT publishes succeed but nothing shows: SysInk has MQTT off or uses
  another topic prefix. Tell the user.
- `broker refused: bad username or password` or `not authorized`: `sysink.env`
  is missing or wrong. Tell the user; do not go looking for credentials.

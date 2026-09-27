#!/bin/sh
# Show a notice on the SysInk e-paper panel.
#
#   notify.sh "text"            for the panel's default duration
#   notify.sh "text" SECONDS    for a duration of its own
#   notify.sh --clear           take the notice on show down
#
# Tries the local pipe first, which also proves the daemon is reading it, then
# MQTT, with the bundled Python publisher or, failing that, mosquitto_pub.
# Settings, all optional, from the environment or from sysink.env in the
# skill's directory:
#   SYSINK_FIFO           default /run/sys-ink/notify
#   SYSINK_MQTT_HOST      default localhost; inside a container, the host
#   SYSINK_MQTT_PORT      default 1883
#   SYSINK_MQTT_TOPIC     default sysink/notify
#   SYSINK_MQTT_USER, SYSINK_MQTT_PASSWORD
set -eu

settings="SYSINK_FIFO SYSINK_MQTT_HOST SYSINK_MQTT_PORT SYSINK_MQTT_TOPIC SYSINK_MQTT_USER SYSINK_MQTT_PASSWORD"
here=$(cd "$(dirname "$0")" && pwd)
if [ -f "$here/../sysink.env" ]; then
    # The environment wins over the file.
    for v in $settings; do eval "saved_$v=\${$v-__unset__}"; done
    # shellcheck disable=SC1091 # written by whoever installs the skill
    . "$here/../sysink.env"
    for v in $settings; do
        s=""; eval "s=\$saved_$v"
        if [ "$s" != __unset__ ]; then eval "$v=\$s"; fi
    done
fi

# In a container the broker on the host is behind the default gateway, not on
# localhost: agents' sandboxes are usually one.
if [ -z "${SYSINK_MQTT_HOST:-}" ] && [ -f /.dockerenv ]; then
    # The gateway column is hex, little-endian.
    gw=$(awk '$2 == "00000000" { print $3; exit }' /proc/net/route 2>/dev/null || true)
    if [ ${#gw} -eq 8 ]; then
        a=${gw#??????} b=${gw#????} c=${gw#??}
        SYSINK_MQTT_HOST="$((0x$a)).$((0x${b%??})).$((0x${c%????})).$((0x${gw%??????}))"
    fi
fi

fifo="${SYSINK_FIFO:-/run/sys-ink/notify}"
host="${SYSINK_MQTT_HOST:-localhost}"
port="${SYSINK_MQTT_PORT:-1883}"
topic="${SYSINK_MQTT_TOPIC:-sysink/notify}"

if [ $# -eq 0 ]; then
    echo "usage: notify.sh TEXT [SECONDS] | --clear" >&2
    exit 2
fi

if [ "$1" = "--clear" ]; then
    payload='{"text": ""}'
elif [ $# -ge 2 ]; then
    case "$2" in
        '' | *[!0-9]*) echo "notify.sh: SECONDS must be a whole number" >&2; exit 2 ;;
    esac
    # JSON-encoded properly, whatever quotes or backslashes the text holds.
    payload=$(python3 -c 'import json, sys; print(json.dumps({"text": sys.argv[1], "duration": int(sys.argv[2])}, ensure_ascii=False))' "$1" "$2")
else
    # One line is one notice on the pipe.
    payload=$(printf '%s' "$1" | tr '\r\n' '  ')
fi

# A pipe with no reader would block the write; the timeout turns that into an
# error, meaning the daemon is not running.
if [ -p "$fifo" ] && [ -w "$fifo" ]; then
    # shellcheck disable=SC2016 # expanded by the inner shell, on purpose
    if timeout 2 sh -c 'printf "%s\n" "$1" > "$2"' sh "$payload" "$fifo"; then
        exit 0
    fi
    echo "notify.sh: nothing is reading $fifo; trying MQTT" >&2
fi

# Never retained, either way: the panel ignores retained notices by design.
# The Python publisher first: it takes the password from the environment,
# where mosquitto_pub only takes it as an argument that every user on the
# machine can read from the process list.
if command -v python3 >/dev/null 2>&1; then
    export SYSINK_MQTT_USER="${SYSINK_MQTT_USER:-}" SYSINK_MQTT_PASSWORD="${SYSINK_MQTT_PASSWORD:-}"
    exec python3 "$here/mqtt_publish.py" "$host" "$port" "$topic" "$payload"
fi

if command -v mosquitto_pub >/dev/null 2>&1; then
    set -- -h "$host" -p "$port" -t "$topic" -m "$payload"
    if [ -n "${SYSINK_MQTT_USER:-}" ]; then set -- "$@" -u "$SYSINK_MQTT_USER"; fi
    if [ -n "${SYSINK_MQTT_PASSWORD:-}" ]; then set -- "$@" -P "$SYSINK_MQTT_PASSWORD"; fi
    exec mosquitto_pub "$@"
fi

echo "notify.sh: cannot reach the panel: not through $fifo, and neither mosquitto_pub nor python3 is here for MQTT" >&2
exit 1

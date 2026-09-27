#!/usr/bin/env python3
"""Publish one QoS 0 MQTT message, with nothing but the standard library.

For where mosquitto_pub is not installed, such as an agent's sandbox
container. Usage: mqtt_publish.py HOST PORT TOPIC PAYLOAD
Credentials come from SYSINK_MQTT_USER and SYSINK_MQTT_PASSWORD, so they stay
off the command line.
"""

import os
import socket
import struct
import sys


def field(data: bytes) -> bytes:
    return struct.pack("!H", len(data)) + data


def packet(first_byte: int, body: bytes) -> bytes:
    # Remaining length: seven bits a byte, least significant first.
    length, encoded = len(body), b""
    while True:
        digit, length = length % 128, length // 128
        encoded += bytes([digit | (0x80 if length else 0)])
        if not length:
            return bytes([first_byte]) + encoded + body


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    host, port, topic, payload = sys.argv[1:]
    user = os.environ.get("SYSINK_MQTT_USER") or None
    password = os.environ.get("SYSINK_MQTT_PASSWORD") or None

    flags = 0x02  # clean session
    if user:
        flags |= 0x80
    if password:
        flags |= 0x40
    connect = field(b"MQTT") + bytes([4, flags]) + struct.pack("!H", 30)
    connect += field(f"sysink-notify-{os.getpid()}".encode())
    if user:
        connect += field(user.encode())
    if password:
        connect += field(password.encode())

    try:
        with socket.create_connection((host, int(port)), timeout=5) as sock:
            sock.settimeout(5)
            sock.sendall(packet(0x10, connect))
            # recv may return part of the four bytes; keep reading until whole.
            connack = b""
            while len(connack) < 4:
                chunk = sock.recv(4 - len(connack))
                if not chunk:
                    break
                connack += chunk
            if len(connack) < 4 or connack[0] != 0x20:
                print("mqtt_publish: no CONNACK from the broker", file=sys.stderr)
                return 1
            if connack[3] != 0:
                reasons = {4: "bad username or password", 5: "not authorized"}
                print(f"mqtt_publish: broker refused: {reasons.get(connack[3], connack[3])}", file=sys.stderr)
                return 1
            # QoS 0, not retained: the panel ignores retained notices.
            sock.sendall(packet(0x30, field(topic.encode()) + payload.encode()))
            sock.sendall(b"\xe0\x00")  # DISCONNECT
    except OSError as err:
        print(f"mqtt_publish: {host}:{port}: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

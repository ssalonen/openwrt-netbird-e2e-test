#!/usr/bin/env python3
"""Wait for a real OpenWrt shell prompt, run a short command, retain output."""
import re
import socket
import sys
import time
from pathlib import Path

SOCKET = sys.argv[1]
LOG = Path(sys.argv[2])
COMMAND = b"mkdir -p /mnt/e2e; mount -t ext4 -o ro /dev/vdb /mnt/e2e && sh /mnt/e2e/guest-e2e.sh\n"
PROMPT = re.compile(rb"root@[^\r\n:]+:~# ")


def pump(sock, log, deadline, until, on_idle=None):
    recent = b""
    idle_ticks = 0
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(8192)
        except socket.timeout:
            idle_ticks += 1
            if on_idle is not None and idle_ticks >= 5:
                on_idle()
                idle_ticks = 0
            continue
        idle_ticks = 0
        if not chunk:
            raise RuntimeError("serial console closed")
        log.write(chunk)
        log.flush()
        recent = (recent + chunk)[-16384:]
        if until(recent):
            return recent
    raise TimeoutError("serial console timed out")


def main():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock, LOG.open("wb") as log:
        sock.settimeout(1)
        sock.connect(SOCKET)
        # First newline activates the root console if the guest is already ready.
        sock.sendall(b"\n")
        pump(sock, log, time.monotonic() + 120, lambda b: bool(PROMPT.search(b)),
             on_idle=lambda: sock.sendall(b"\n"))
        time.sleep(3)
        sock.sendall(COMMAND)
        recent = pump(sock, log, time.monotonic() + 240,
                      lambda b: b"RELAY-OVERLAY-PASS" in b)
        if b"RELAY-OVERLAY-PASS" not in recent:
            raise RuntimeError("guest command returned without relay success")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, TimeoutError) as error:
        print(f"serial-console: {error}", file=sys.stderr)
        sys.exit(1)

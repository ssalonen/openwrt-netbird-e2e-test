#!/usr/bin/env python3
"""Wait for a real OpenWrt shell prompt, run a short command, retain output."""
import re
import socket
import sys
import time
from pathlib import Path

SOCKET = sys.argv[1]
LOG = Path(sys.argv[2])
MOUNT = b"mkdir -p /mnt/e2e; mount -t 9p -o trans=virtio,ro netbirdcfg /mnt/e2e && echo E2E-MOUNT-OK\r\n"
COMMAND = b"sh /mnt/e2e/guest-e2e.sh\r\n"
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
        # Initial Enter may arrive during boot; retry after an idle prompt.
        sock.sendall(b"\r")
        pump(sock, log, time.monotonic() + 120, lambda b: bool(PROMPT.search(b)),
             on_idle=lambda: sock.sendall(b"\r"))
        time.sleep(3)
        sock.sendall(MOUNT)
        pump(sock, log, time.monotonic() + 60,
             lambda b: bool(re.search(rb"(?:\r?\n)E2E-MOUNT-OK\r?\n", b)))
        sock.sendall(COMMAND)
        recent = pump(sock, log, time.monotonic() + 420,
                      lambda b: b"RELAY-OVERLAY-PASS" in b)
        if b"RELAY-OVERLAY-PASS" not in recent:
            raise RuntimeError("guest command returned without relay success")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, TimeoutError) as error:
        print(f"serial-console: {error}", file=sys.stderr)
        sys.exit(1)

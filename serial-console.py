#!/usr/bin/env python3
"""Passively capture a disposable OpenWrt guest's serial E2E result."""
import socket
import sys
import time
from pathlib import Path

SOCKET = sys.argv[1]
LOG = Path(sys.argv[2])


def main():
    deadline = time.monotonic() + 480
    buffer = b""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock, LOG.open("wb") as log:
        sock.settimeout(1)
        sock.connect(SOCKET)
        while time.monotonic() < deadline:
            try:
                chunk = sock.recv(8192)
            except socket.timeout:
                continue
            if not chunk:
                raise RuntimeError("serial console closed")
            log.write(chunk)
            log.flush()
            buffer = (buffer + chunk)[-16384:]
            if b"RELAY-OVERLAY-PASS" in buffer:
                return
            if b"FAIL: " in buffer:
                raise RuntimeError("guest reported an E2E failure")
        raise TimeoutError("serial console timed out")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, TimeoutError) as error:
        print(f"serial-console: {error}", file=sys.stderr)
        sys.exit(1)

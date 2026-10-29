#!/usr/bin/env python3
"""Exercise the real Unix-serial driver against a simulated guest prompt."""
import socket
import subprocess
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent


def test_short_guest_command_waits_for_prompt():
    with tempfile.TemporaryDirectory() as temp:
        sock_path = Path(temp) / "serial.sock"
        log_path = Path(temp) / "serial.log"
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(sock_path))
            listener.listen(1)
            proc = subprocess.Popen(
                ["python3", str(HERE / "serial-console.py"), str(sock_path), str(log_path)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            with listener.accept()[0] as conn:
                conn.settimeout(10)
                conn.recv(1024)
                conn.sendall(b"booting...\r\nroot@(none):~# ")
                mount_command = conn.recv(4096)
                assert mount_command.startswith(b"mkdir -p /mnt/e2e;")
                assert mount_command.endswith(b"\r\n")
                assert b"setup-key" not in mount_command
                conn.sendall(b"\r\nE2E-MOUNT-OK\r\n")
                command = conn.recv(4096)
                assert command == b"sh /mnt/e2e/guest-e2e.sh\r\n"
                conn.sendall(b"\r\nConnection type: P2P\r\nP2P-OVERLAY-PASS\r\n")
                conn.sendall(b"Connection type: Relayed\r\nRELAY-OVERLAY-PASS\r\n")
            _, err = proc.communicate(timeout=10)
            assert proc.returncode == 0, err.decode()
            assert b"RELAY-OVERLAY-PASS" in log_path.read_bytes()


if __name__ == "__main__":
    test_short_guest_command_waits_for_prompt()
    print("PASS: short serial command and guest prompt")

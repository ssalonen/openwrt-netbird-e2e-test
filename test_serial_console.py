#!/usr/bin/env python3
"""Test passive serial capture; no setup keys or commands travel over it."""
import socket
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def test_guest_results_are_captured_without_writing_to_serial():
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
                conn.settimeout(1)
                try:
                    command = conn.recv(1024)
                except socket.timeout:
                    command = b""
                assert command == b"", "serial console must not transmit commands"
                conn.sendall(b"E2E-MOUNT-OK\r\nConnection type: P2P\r\nP2P-OVERLAY-PASS\r\n")
                conn.sendall(b"Connection type: Relayed\r\nRELAY-OVERLAY-PASS\r\n")
            _, err = proc.communicate(timeout=10)
            assert proc.returncode == 0, err.decode()
            assert b"RELAY-OVERLAY-PASS" in log_path.read_bytes()


if __name__ == "__main__":
    test_guest_results_are_captured_without_writing_to_serial()
    print("PASS: passive serial capture")

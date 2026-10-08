#!/usr/bin/env python3
"""Offline native updater TLS tests with temporary CA/server certificates.

KOREADER_DIR must contain luajit/setupkoenv.lua. Requires Python cryptography.
No network outside loopback, persistent credentials, or repository changes.
"""
import datetime
import os
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ROOT = pathlib.Path(__file__).resolve().parents[2]
KO = pathlib.Path(os.environ["KOREADER_DIR"])
NOW = datetime.datetime.now(datetime.timezone.utc)

def key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)

def name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])

def certificate(subject, public_key, issuer, issuer_key, san=None, ca=False, expired=False):
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer)
            .public_key(public_key).serial_number(x509.random_serial_number())
            .not_valid_before(NOW - datetime.timedelta(days=2))
            .not_valid_after(NOW + datetime.timedelta(days=-1 if expired else 1))
            .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if not ca:
        cert = cert.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    if san is not None:
        cert = cert.add_extension(x509.SubjectAlternativeName([x509.DNSName(san)]), critical=False)
    return cert.sign(issuer_key, hashes.SHA256())

with tempfile.TemporaryDirectory(prefix="koa_tls_") as temp:
    temp = pathlib.Path(temp)
    ca_key = key()
    ca = certificate(name("KOAssistant test CA"), ca_key.public_key(), name("KOAssistant test CA"), ca_key, ca=True)
    ca_path = temp / "ca.pem"
    ca_path.write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    cases = [
        ("trusted_exact", "api.github.com", "api.github.com", True, False, True, "http"),
        ("trusted_raw", "github.com", "github.com", True, False, True, "raw"),
        ("trusted_wildcard", "release-assets.githubusercontent.com", "*.githubusercontent.com", True, False, True, "http"),
        ("wrong_name", "api.github.com", "attacker.com", True, False, False, "http"),
        ("untrusted", "api.github.com", "api.github.com", False, False, False, "http"),
        ("expired", "api.github.com", "api.github.com", True, True, False, "http"),
        ("cn_only", "api.github.com", None, True, False, False, "http"),
        ("missing_ca", "api.github.com", "api.github.com", True, False, False, "http"),
        ("trusted_resolved", "github.com", "github.com", True, False, True, "resolved"),
    ]
    passed = 0
    skipped = 0
    for case, host, san, trusted, expired, expected, mode in cases:
        server_key = key()
        cert = certificate(name(host), server_key.public_key(), ca.subject if trusted else name(host),
                           ca_key if trusted else server_key, san=san, expired=expired)
        cert_path, key_path = temp / "server.pem", temp / "server.key"
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(server_key.private_bytes(serialization.Encoding.PEM,
                             serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert_path, key_path)
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", 443 if mode == "resolved" else 0))
        except PermissionError:
            listener.close()
            if mode != "resolved":
                raise
            print("SKIP trusted_resolved: binding privileged loopback port 443 is unavailable")
            skipped += 1
            continue
        listener.listen()
        listener.settimeout(5)
        port = listener.getsockname()[1]
        state = {"bytes": b""}
        def serve():
            try:
                raw, _ = listener.accept()
                raw.settimeout(5)
                with context.wrap_socket(raw, server_side=True) as conn:
                    while b"\r\n\r\n" not in state["bytes"]:
                        chunk = conn.recv(8192)
                        if not chunk:
                            break
                        state["bytes"] += chunk
                    if state["bytes"]:
                        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nverified")
            except (ssl.SSLError, OSError):
                pass  # Rejected peers must not get application bytes.
            finally:
                listener.close()
        thread = threading.Thread(target=serve)
        thread.start()
        result = subprocess.run([str(KO / "luajit"), str(ROOT / "tests/tools/updater_tls_e2e.lua"),
                    str(ROOT), str(ca_path if case != "missing_ca" else temp / "absent.pem"), host,
                    str(port), "success" if expected else "failure", mode], cwd=KO,
                    text=True, capture_output=True, timeout=10)
        thread.join(timeout=6)
        assert result.returncode == 0, f"{case}: {result.stdout}\n{result.stderr}"
        assert bool(state["bytes"]) == expected, f"{case}: unexpected application data {state['bytes']!r}"
        print(f"PASS {case}: {'verified request' if expected else 'rejected with zero HTTP bytes'}")
        passed += 1
    print(f"Native TLS: {passed} passed, {skipped} skipped")

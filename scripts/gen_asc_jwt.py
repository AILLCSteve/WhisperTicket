#!/usr/bin/env python3
"""Generate an App Store Connect API JWT (ES256).

Usage: python3 gen_asc_jwt.py <key_path> <key_id> <issuer_id>

Outputs a single-line JWT to stdout (no trailing newline).

Why Python instead of bash+openssl:
  - openssl dgst -sign produces DER-encoded ECDSA; JWT ES256 needs raw R||S
  - The cryptography library handles P-256/PKCS8 keys correctly on all platforms
  - Avoids base64/tr pipeline fragility on LibreSSL vs OpenSSL
  - Avoids trailing-whitespace bugs from secrets embedded in printf format strings
"""

import sys
import time
import json
import base64

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
except ImportError:
    sys.exit("ERROR: 'cryptography' package not installed. Run: pip3 install cryptography")


def b64url(data: bytes | dict) -> str:
    if isinstance(data, dict):
        data = json.dumps(data, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(f"Usage: {sys.argv[0]} <key_path> <key_id> <issuer_id>")

    key_path, key_id, issuer_id = sys.argv[1], sys.argv[2], sys.argv[3]

    # Strip any accidental whitespace from secrets
    key_id = key_id.strip()
    issuer_id = issuer_id.strip()

    with open(key_path, "rb") as f:
        private_key = serialization.load_pem_private_key(f.read(), password=None)

    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }

    signing_input = f"{b64url(header)}.{b64url(payload)}"

    # sign() returns DER-encoded ECDSA; decode_dss_signature extracts (r, s) integers
    sig_der = private_key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(sig_der)

    # JWT ES256 signature = 64-byte big-endian R || S (32 bytes each)
    sig_bytes = r.to_bytes(32, "big") + s.to_bytes(32, "big")

    print(f"{signing_input}.{b64url(sig_bytes)}", end="")


if __name__ == "__main__":
    main()

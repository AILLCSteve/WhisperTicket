#!/usr/bin/env python3
"""
One-time setup: creates an iOS Distribution certificate + App Store
provisioning profile for WhisperTicket via the App Store Connect API,
then sets GitHub secrets directly.

The private key and certificate are stored as separate PEM/DER secrets
so the P12 is assembled on the macOS CI runner using native LibreSSL —
avoiding PKCS12 cross-platform compatibility issues.

Requirements:
    pip install PyJWT cryptography requests

Usage:
    python scripts/setup-signing.py \
        --key-id      49ATJTTN9N \
        --issuer-id   350c80bb-1189-43d3-a908-acde233340b8 \
        --team-id     M37X5J35F8 \
        --bundle-id   com.whisperticket.app \
        --key-file    path/to/AuthKey_49ATJTTN9N.p8 \
        --repo        AILLCSteve/WhisperTicket
"""

import argparse, base64, subprocess, sys, time
import requests

try:
    import jwt
except ImportError:
    sys.exit("Missing dependency — run: pip install PyJWT cryptography requests")

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
except ImportError:
    sys.exit("Missing dependency — run: pip install PyJWT cryptography requests")


# ── CLI args ──────────────────────────────────────────────────────────────────

p = argparse.ArgumentParser()
p.add_argument("--key-id",    required=True)
p.add_argument("--issuer-id", required=True)
p.add_argument("--team-id",   required=True)
p.add_argument("--bundle-id", required=True)
p.add_argument("--key-file",  required=True, help=".p8 private key file path")
p.add_argument("--repo",      required=True, help="GitHub repo, e.g. AILLCSteve/WhisperTicket")
p.add_argument("--profile-name", default="WhisperTicket AppStore")
p.add_argument("--p12-password", default="whisperticket-dist-2024")
args = p.parse_args()

with open(args.key_file) as f:
    api_key_pem = f.read()


# ── App Store Connect JWT ─────────────────────────────────────────────────────

def asc_token():
    return jwt.encode(
        {"iss": args.issuer_id, "exp": int(time.time()) + 1100, "aud": "appstoreconnect-v1"},
        api_key_pem,
        algorithm="ES256",
        headers={"kid": args.key_id},
    )

def asc_get(path, **kwargs):
    r = requests.get(
        f"https://api.appstoreconnect.apple.com{path}",
        headers={"Authorization": f"Bearer {asc_token()}"},
        **kwargs,
    )
    r.raise_for_status()
    return r.json()

def asc_post(path, body):
    r = requests.post(
        f"https://api.appstoreconnect.apple.com{path}",
        headers={"Authorization": f"Bearer {asc_token()}", "Content-Type": "application/json"},
        json=body,
    )
    if not r.ok:
        print("API error:", r.status_code, r.text, file=sys.stderr)
        r.raise_for_status()
    return r.json()

def asc_delete(path):
    r = requests.delete(
        f"https://api.appstoreconnect.apple.com{path}",
        headers={"Authorization": f"Bearer {asc_token()}"},
    )
    if not r.ok and r.status_code != 404:
        print("API error:", r.status_code, r.text, file=sys.stderr)
        r.raise_for_status()


# ── Step 0: Revoke existing certs + delete existing profiles ─────────────────

print("\n[0/5] Revoking existing iOS Distribution certificates...")
existing = asc_get("/v1/certificates", params={"filter[certificateType]": "IOS_DISTRIBUTION"})
for cert in existing.get("data", []):
    cid = cert["id"]
    name = cert["attributes"].get("name", "")
    print(f"   Revoking cert {cid} ({name})...")
    asc_delete(f"/v1/certificates/{cid}")
    print(f"   Revoked.")

print("   Deleting existing App Store provisioning profiles...")
profiles_resp = asc_get("/v1/profiles", params={"filter[profileType]": "IOS_APP_STORE"})
for prof in profiles_resp.get("data", []):
    pid = prof["id"]
    pname = prof["attributes"].get("name", "")
    print(f"   Deleting profile {pid} ({pname})...")
    asc_delete(f"/v1/profiles/{pid}")
    print(f"   Deleted.")


# ── Step 1: Generate RSA-2048 key pair + CSR ──────────────────────────────────

print("\n[1/5] Generating RSA-2048 key pair and CSR...")
dist_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# Export private key as unencrypted PEM (stored as GitHub secret)
dist_key_pem = dist_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.TraditionalOpenSSL,
    encryption_algorithm=serialization.NoEncryption(),
).decode()

csr = (
    x509.CertificateSigningRequestBuilder()
    .subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "iOS Distribution"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, args.team_id),
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    ]))
    .sign(dist_key, hashes.SHA256())
)
csr_der = csr.public_bytes(serialization.Encoding.DER)
csr_b64 = base64.b64encode(csr_der).decode()


# ── Step 2: Create Distribution certificate ───────────────────────────────────

print("[2/5] Creating iOS Distribution certificate via App Store Connect API...")
cert_resp = asc_post("/v1/certificates", {
    "data": {
        "type": "certificates",
        "attributes": {
            "certificateType": "IOS_DISTRIBUTION",
            "csrContent": csr_b64,
        },
    }
})

cert_id = cert_resp["data"]["id"]
cert_b64 = cert_resp["data"]["attributes"]["certificateContent"]  # DER base64
cert_der = base64.b64decode(cert_b64)
cert_obj = x509.load_der_x509_certificate(cert_der)
print(f"   Certificate ID: {cert_id}")
print(f"   Subject: {cert_obj.subject.rfc4514_string()}")


# ── Step 3: Find bundle ID resource ──────────────────────────────────────────

print("[3/5] Looking up bundle ID resource...")
bundle_resp = asc_get(
    "/v1/bundleIds",
    params={"filter[identifier]": args.bundle_id, "filter[platform]": "IOS"},
)
bundles = bundle_resp.get("data", [])
if not bundles:
    sys.exit(f"Bundle ID '{args.bundle_id}' not found in App Store Connect.\n"
             "Register it at https://developer.apple.com/account/resources/identifiers/list")

bundle_resource_id = bundles[0]["id"]
print(f"   Bundle resource ID: {bundle_resource_id}")


# ── Step 4: Create App Store provisioning profile ────────────────────────────

print("[4/5] Creating App Store provisioning profile...")
profile_resp = asc_post("/v1/profiles", {
    "data": {
        "type": "profiles",
        "attributes": {
            "name": args.profile_name,
            "profileType": "IOS_APP_STORE",
        },
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
        },
    }
})

profile_b64 = profile_resp["data"]["attributes"]["profileContent"]
print(f"   Profile UUID: {profile_resp['data']['attributes'].get('uuid', 'n/a')}")
print(f"   Profile name: {profile_resp['data']['attributes']['name']}")


# ── Step 5: Set GitHub secrets ────────────────────────────────────────────────
# We store key+cert separately; CI generates the P12 on the macOS runner
# using native LibreSSL (openssl pkcs12 -export) to avoid cross-platform issues.

print("\n[5/5] Setting GitHub secrets...")

def gh_set_secret(name, value):
    # Pipe value via stdin to avoid Windows command-line length limits
    result = subprocess.run(
        ["gh", "secret", "set", name, "--repo", args.repo],
        input=value, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"   ERROR setting {name}: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"   Set {name} OK ({len(value)} chars)")

profile_uuid = profile_resp["data"]["attributes"].get("uuid", "")

gh_set_secret("DIST_PRIVATE_KEY_PEM",   dist_key_pem)
gh_set_secret("DIST_CERT_DER_B64",      cert_b64)        # base64-encoded DER
gh_set_secret("DIST_CERT_P12_PASSWORD", args.p12_password)
gh_set_secret("PROV_PROFILE_BASE64",    profile_b64)
gh_set_secret("PROV_PROFILE_UUID",      profile_uuid)

print("\n" + "=" * 60)
print("SUCCESS — 5 secrets set in GitHub repo.")
print(f"Profile UUID: {profile_uuid}")
print(f"Repo: https://github.com/{args.repo}/settings/secrets/actions")
print("=" * 60)
print("Push any change to main and GitHub Actions will")
print("build + upload to TestFlight automatically.")
print("=" * 60 + "\n")

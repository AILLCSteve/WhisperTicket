#!/usr/bin/env python3
"""
One-time setup: creates an iOS Distribution certificate + App Store
provisioning profile for WhisperTicket via the App Store Connect API,
then prints the GitHub secrets you need to add.

Requirements:
    pip install PyJWT cryptography requests

Usage:
    python scripts/setup-signing.py \
        --key-id      49ATJTTN9N \
        --issuer-id   350c80bb-1189-43d3-a908-acde233340b8 \
        --team-id     M37X5J35F8 \
        --bundle-id   com.whisperticket.app \
        --key-file    path/to/AuthKey_49ATJTTN9N.p8
"""

import argparse, base64, json, sys, time
import requests

try:
    import jwt
except ImportError:
    sys.exit("Missing dependency — run: pip install PyJWT cryptography requests")

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
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
p.add_argument("--cert-name", default="WhisperTicket Distribution")
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


# ── Step 1: Generate EC key pair + CSR ───────────────────────────────────────

print("\n[1/5] Generating RSA-2048 key pair and CSR...")
dist_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

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
cert_b64 = cert_resp["data"]["attributes"]["certificateContent"]
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


# ── Step 5: Build P12 and encode secrets ─────────────────────────────────────

print("[5/5] Building P12 bundle...")
p12_bytes = pkcs12.serialize_key_and_certificates(
    name=args.cert_name.encode(),
    key=dist_key,
    cert=cert_obj,
    cas=None,
    encryption_algorithm=serialization.BestAvailableEncryption(
        args.p12_password.encode()
    ),
)
p12_b64 = base64.b64encode(p12_bytes).decode()


# ── Output ────────────────────────────────────────────────────────────────────

print("\n" + "=" * 60)
print("SUCCESS — Add these 3 secrets to GitHub:")
print("https://github.com/AILLCSteve/WhisperTicket/settings/secrets/actions")
print("=" * 60)

print("\nSecret name:  DIST_CERT_P12")
print("Secret value:")
print(p12_b64)

print("\nSecret name:  DIST_CERT_P12_PASSWORD")
print("Secret value:")
print(args.p12_password)

print("\nSecret name:  PROV_PROFILE_BASE64")
print("Secret value:")
print(profile_b64)

print("\n" + "=" * 60)
print("After adding all 3 secrets, push any change to main and")
print("GitHub Actions will build + upload to TestFlight automatically.")
print("=" * 60 + "\n")

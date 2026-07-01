#!/usr/bin/env python3
"""Print an App Store Connect diagnostics report: beta groups + recent builds.

Usage: python3 scripts/asc_report.py <JWT> <APP_ID>

Read-only and non-fatal — always exits 0 so it can be used as a CI diagnostic
step without ever failing the build. Uses only the Python standard library.
"""
import json
import sys
import urllib.request
import urllib.error

BASE = "https://api.appstoreconnect.apple.com/v1"


def get(url: str, jwt: str):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {jwt}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        return e.code, body
    except Exception as e:  # noqa: BLE001 - diagnostics must never crash CI
        return 0, str(e)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: asc_report.py <JWT> <APP_ID>")
        return 0
    jwt, app_id = sys.argv[1], sys.argv[2]

    print("===== ASC DIAGNOSTICS =====")

    # ── Beta groups (all) — read isInternalGroup as an ATTRIBUTE. The endpoint
    #    rejects filter[isInternalGroup] with PARAMETER_ERROR.ILLEGAL, so we
    #    fetch all and inspect attributes client-side.
    status, data = get(
        f"{BASE}/apps/{app_id}/betaGroups"
        "?fields%5BbetaGroups%5D=name,isInternalGroup,hasAccessToAllBuilds&limit=200",
        jwt,
    )
    print(f"-- beta groups (HTTP {status}) --")
    if isinstance(data, dict) and data.get("data") is not None:
        groups = data["data"]
        if not groups:
            print("  (NO beta groups exist — create an Internal Testing group in "
                  "ASC and add yourself as a tester; nothing will distribute "
                  "until you do)")
        for g in groups:
            a = g.get("attributes", {})
            print(f"  - name={a.get('name')!r} internal={a.get('isInternalGroup')} "
                  f"autoAllBuilds={a.get('hasAccessToAllBuilds')} id={g.get('id')}")
    else:
        print(f"  {data}")

    # ── Recent builds + processing state ────────────────────────────────────
    status, data = get(
        f"{BASE}/builds?filter%5Bapp%5D={app_id}"
        "&sort=-uploadedDate&limit=8"
        "&fields%5Bbuilds%5D=version,processingState,uploadedDate,expired",
        jwt,
    )
    print(f"-- recent builds (HTTP {status}) --")
    if isinstance(data, dict) and data.get("data") is not None:
        builds = data["data"]
        if not builds:
            print("  (no builds visible yet — still processing, or none uploaded)")
        for b in builds:
            a = b.get("attributes", {})
            print(f"  - v{a.get('version')}: {a.get('processingState')} "
                  f"expired={a.get('expired')} uploaded={a.get('uploadedDate')}")
    else:
        print(f"  {data}")

    print("===========================")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Expire one TestFlight build, identified by exact version and build number.

Refuses to expire the newest build or anything that doesn't match exactly.
Expiring removes the build from testers and cannot be undone for that build.
Same environment as asc_status.py, plus EXPIRE_VERSION and EXPIRE_BUILD.
"""
import json
import os
import sys
import urllib.error
import urllib.request

from asc_status import API, get, token


def main() -> None:
    version, build_number = os.environ["EXPIRE_VERSION"].strip(), os.environ["EXPIRE_BUILD"].strip()
    auth = token()
    apps = get(f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}&fields[apps]=name", auth)["data"]
    if not apps:
        sys.exit("App not found.")
    app_id = apps[0]["id"]

    builds = get(f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=50&include=preReleaseVersion"
                 "&fields[builds]=version,expired,uploadedDate,preReleaseVersion", auth)
    versions = {i["id"]: i["attributes"]["version"] for i in builds.get("included", []) if i["type"] == "preReleaseVersions"}
    rows = []
    for b in builds["data"]:
        pre = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        rows.append((b["id"], versions.get(pre, "?"), b["attributes"]["version"], b["attributes"]["expired"]))
    if not rows:
        sys.exit("No builds found.")

    matches = [r for r in rows if r[1] == version and r[2] == build_number]
    if len(matches) != 1:
        sys.exit(f"Expected exactly one build {version} ({build_number}), found {len(matches)}. Nothing changed.")
    build_id, _, _, expired = matches[0]
    if build_id == rows[0][0]:
        sys.exit("Refusing to expire the newest build. Nothing changed.")
    if expired:
        print(f"{version} ({build_number}) is already expired. Nothing changed.")
        return

    body = json.dumps({"data": {"type": "builds", "id": build_id, "attributes": {"expired": True}}}).encode()
    request = urllib.request.Request(f"{API}/builds/{build_id}", data=body, method="PATCH",
                                     headers={"Authorization": f"Bearer {auth}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)["data"]["attributes"]
    except urllib.error.HTTPError as error:
        sys.exit(f"App Store Connect refused: HTTP {error.code} {error.read().decode(errors='replace')[:400]}")
    print(f"Expired {version} ({build_number}): expired={result.get('expired')}")


if __name__ == "__main__":
    main()

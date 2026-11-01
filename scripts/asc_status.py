"""Read-only TestFlight status from the App Store Connect API.

Prints the newest builds with their processing and beta states, the beta
groups, which builds each group has, and tester counts. Never prints tester
names or emails. Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (PEM text)
and BUNDLE_ID in the environment, plus `pip install pyjwt cryptography`.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def get(path: str, auth: str) -> dict:
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {auth}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:400]
        print(f"HTTP {error.code} for {path.split('?')[0]}: {body}")
        return {"data": []}


def main() -> None:
    auth = token()
    apps = get(f"/apps?filter[bundleId]={os.environ['BUNDLE_ID']}&fields[apps]=name,bundleId", auth)["data"]
    if not apps:
        sys.exit("No app with that bundle id is visible to this API key.")
    app = apps[0]
    print(f"App: {app['attributes']['name']} ({app['attributes']['bundleId']}), id {app['id']}\n")

    builds = get(f"/builds?filter[app]={app['id']}&sort=-uploadedDate&limit=6&include=preReleaseVersion,buildBetaDetail"
                 "&fields[builds]=version,uploadedDate,processingState,expired,usesNonExemptEncryption,preReleaseVersion,buildBetaDetail",
                 auth)
    included = {(i["type"], i["id"]): i["attributes"] for i in builds.get("included", [])}
    print("Newest builds:")
    for b in builds["data"]:
        a = b["attributes"]
        rel = b.get("relationships", {})
        version = included.get(("preReleaseVersions", (rel.get("preReleaseVersion", {}).get("data") or {}).get("id")), {}).get("version", "?")
        detail = included.get(("buildBetaDetails", (rel.get("buildBetaDetail", {}).get("data") or {}).get("id")), {})
        print(f"  {version} ({a['version']})  uploaded {a['uploadedDate'][:16]}  processing={a['processingState']}"
              f"  internal={detail.get('internalBuildState')}  external={detail.get('externalBuildState')}"
              f"  expired={a['expired']}  encryption={a.get('usesNonExemptEncryption')}")

    groups = get(f"/apps/{app['id']}/betaGroups?fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds", auth)["data"]
    print(f"\nBeta groups: {len(groups)}")
    for g in groups:
        a = g["attributes"]
        group_builds = get(f"/betaGroups/{g['id']}/builds?limit=10&fields[builds]=version", auth)["data"]
        testers = get(f"/betaGroups/{g['id']}/betaTesters?limit=50&fields[betaTesters]=inviteType,state", auth)["data"]
        states = {}
        for t in testers:
            state = t["attributes"].get("state") or "unknown"
            states[state] = states.get(state, 0) + 1
        print(f"  {a['name']}: internal={a['isInternalGroup']} all builds automatically={a.get('hasAccessToAllBuilds')}"
              f"  builds={[x['attributes']['version'] for x in group_builds]}  testers={len(testers)} {states}")
    if not groups:
        print("  None. Create an internal group in App Store Connect > TestFlight and add yourself.")


if __name__ == "__main__":
    main()

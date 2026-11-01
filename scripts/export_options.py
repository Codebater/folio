"""Validate the supplied profile; never generate or fabricate signing credentials."""
import datetime
import os
from pathlib import Path
import plistlib
import shutil

temp = Path(os.environ["RUNNER_TEMP"])
with (temp / "profile.plist").open("rb") as f:
    profile = plistlib.load(f)
team = os.environ["TEAM_ID"]
bundle = os.environ["BUNDLE_ID"]
assert profile["TeamIdentifier"][0] == team, "Profile team does not match APPLE_TEAM_ID"
assert profile["Entitlements"]["application-identifier"] == f"{team}.{bundle}", "Profile must match the explicit bundle identifier"
assert profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), "Expired profile"
assert not profile.get("ProvisionedDevices"), "Use an App Store Connect profile, not Ad Hoc/development"
assert not profile.get("ProvisionsAllDevices"), "Enterprise profiles cannot be used for TestFlight"
assert not profile["Entitlements"].get("get-task-allow", False), "Development profile is not valid for TestFlight"
uuid = profile["UUID"]
destination = Path.home() / "Library/MobileDevice/Provisioning Profiles"
destination.mkdir(parents=True, exist_ok=True)
shutil.copyfile(temp / "profile.mobileprovision", destination / f"{uuid}.mobileprovision")
with (temp / "ExportOptions.plist").open("wb") as f:
    plistlib.dump({"method": "app-store-connect", "signingStyle": "manual", "teamID": team,
                  "signingCertificate": "Apple Distribution", "provisioningProfiles": {bundle: uuid},
                  "manageAppVersionAndBuildNumber": False, "uploadSymbols": True}, f)
with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as f:
    f.write(f"PROFILE_UUID={uuid}\n")

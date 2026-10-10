#!/usr/bin/env python3
"""Check real Core Location movement in an installed, disposable QA simulator.

Run after installing a locally signed Debug app with App Group entitlements.
This replaces the simulator app's settings, so
SFN_ALLOW_SIMULATOR_STATE_RESET=1 is required. It does not use the app's
SFN_TEST_LOCATION injection or contact the production API.
"""

import json
import os
from pathlib import Path
import subprocess
import time


def simctl(*args, check=True, env=None):
	return subprocess.run(["xcrun", "simctl", *args], check=check, text=True,
		capture_output=True, env=env).stdout.strip()


def wait_for(path, predicate, description, timeout=75):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		try:
			value = json.loads(path.read_text())
			if predicate(value):
				return value
		except (OSError, ValueError):
			pass
		time.sleep(0.5)
	raise AssertionError(description)


def main():
	if os.environ.get("SFN_ALLOW_SIMULATOR_STATE_RESET") != "1":
		raise SystemExit("Set SFN_ALLOW_SIMULATOR_STATE_RESET=1 for a disposable QA simulator.")
	device = os.environ["SFN_SIMULATOR_ID"]
	bundle = "nyc.juliet.subwaysfornerds"
	root = Path(__file__).resolve().parent.parent
	output = root / "artifacts" / "bug-pass" / "system-location"
	output.mkdir(parents=True, exist_ok=True)
	simctl("terminate", device, bundle, check=False)
	data = Path(simctl("get_app_container", device, bundle, "data"))
	shared = Path(simctl("get_app_container", device, bundle, "group.nyc.juliet.subwaysfornerds"))
	assert shared.is_dir(), "Install a locally signed Debug app with App Group entitlements first"
	state = data / "Library" / "Application Support" / "SubwaysForNerds"
	state.mkdir(parents=True, exist_ok=True)
	settings = json.loads((root / "test" / "fixtures" / "settings.nerds").read_text())["settings"]
	settings["favorites"] = ["602", "611"]
	settings["theme"] = "subway"
	record = {"settings": settings, "lastStation": "602", "recent": []}
	(state / "settings.json").write_text(json.dumps(record))
	(state / "stations.json").write_bytes((root / "ios" / "TransitCore" / "Tests" / "TransitCoreTests" / "Fixtures" / "catalog.json").read_bytes())
	simctl("privacy", device, "grant", "location", bundle)
	simctl("location", device, "set", "40.755290,-73.987495")
	started = time.time()
	environment = {key: value for key, value in os.environ.items() if not key.startswith("SIMCTL_CHILD_SFN_")}
	environment.update({"SIMCTL_CHILD_SFN_RESET_STATE": "0", "SIMCTL_CHILD_SFN_DISABLE_LOCATION": "0",
		"SIMCTL_CHILD_SFN_API_BASE_URL": "http://127.0.0.1:1/subwaysForNerds/api/v1/"})
	simctl("launch", device, bundle, env=environment)
	shared_file = shared / "Widgets" / "state.json"
	initial = wait_for(shared_file, lambda value: coordinate_matches(value, 40.755290, started),
		"The foreground app never published the Times Square simulator location")
	wait_for(state / "settings.json", lambda value: value["lastStation"] == "611",
		"Cold launch did not select the closest saved favorite")
	print("PASS: actual Core Location selects Times Square on cold launch", flush=True)
	(output / "initial-state.json").write_text(json.dumps(initial, indent=2))
	simctl("io", device, "screenshot", str(output / "initial-times-square.png"))

	moved_at = time.time()
	simctl("location", device, "set", "40.735736,-73.990568")
	moved = wait_for(shared_file, lambda value: coordinate_matches(value, 40.735736, moved_at),
		"Movement was not published to widgets while the app stayed foreground")
	elapsed = time.time() - moved_at
	retained = json.loads((state / "settings.json").read_text())
	assert retained["lastStation"] == "611", "Movement unexpectedly navigated away from the open board"
	assert retained["settings"]["favorites"] == ["602", "611"], "Movement changed saved favorite membership"
	(output / "moved-state.json").write_text(json.dumps(moved, indent=2))
	(output / "result.json").write_text(json.dumps({"simulator": device, "passed": True,
		"movementPublishedSeconds": round(elapsed, 2), "retainedStation": "611",
		"favorites": ["602", "611"], "locationSource": "simctl/CoreLocation"}, indent=2))
	simctl("io", device, "screenshot", str(output / "moved-location-retained-board.png"))
	print(f"PASS: real movement reached widget shared state in {elapsed:.2f}s; board and favorites stayed intact", flush=True)
	print("WidgetKit background delivery timing is not measured by this check.", flush=True)


def coordinate_matches(value, latitude, since):
	coordinate = value.get("appLocation") or {}
	return abs(coordinate.get("latitude", 0) - latitude) < 0.00001 and coordinate.get("timestamp", 0) >= since - 1


if __name__ == "__main__":
	main()

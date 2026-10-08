"""Exercise the storage lifecycle without making OCI requests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "bin/hosted_app_storage_cli.sh"
OCID = "ocid1.generativeaihostedapplicationstorage.oc1.eu.example"
MOCK_OCI = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
action = args[6]
mode = os.environ.get("MOCK_MODE", "active")
if action == "create":
    if mode == "create_error":
        sys.exit(2)
    assert not Path(os.environ["STORAGE_OCID_FILE"]).exists()
    resources = [{"action-type": "CREATED",
                  "identifier": "invalid" if mode == "invalid_id" else os.environ["MOCK_OCID"]}]
    if mode == "missing_resource":
        resources = []
    print(json.dumps({"data": {
        "id": "ocid1.generativeaiworkrequest.oc1.eu.example",
        "status": "FAILED" if mode == "create_failed" else "SUCCEEDED",
        "resources": resources
    }}))
elif action == "get":
    if mode == "get_error":
        sys.exit(1)
    counter = Path(os.environ["MOCK_COUNTER"])
    count = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(count + 1))
    state = "FAILED" if mode == "failed" else "ACTIVE"
    if mode == "pending" and count == 0:
        state = "CREATING"
    print(json.dumps({"data": {
        "id": os.environ["MOCK_OCID"],
        "compartment-id": "compartment",
        "display-name": "wrong" if mode == "mismatch" else "demo-litellm-postgres",
        "storage-type": "POSTGRESQL", "lifecycle-state": state
    }}))
elif action == "delete":
    sys.exit(1 if mode == "delete_error" else 0)
else:
    sys.exit(2)
'''


class StorageLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="storage-cli-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.ocid_file = self.directory / "target/hosted_application_storage.ocid"
        self.log = self.directory / "calls.jsonl"
        mock = self.directory / "oci"
        mock.write_text(f"#!{sys.executable}\n" + MOCK_OCI)
        mock.chmod(0o755)
        sleep = self.directory / "sleep"
        sleep.write_text("#!/bin/sh\nexit 0\n")
        sleep.chmod(0o755)
        self.environment = dict(os.environ, **{
            "PATH": str(self.directory) + os.pathsep + os.environ["PATH"],
            "STORAGE_OCID_FILE": str(self.ocid_file),
            "STORAGE_REGION": "eu-frankfurt-1", "STORAGE_PROFILE": "TEST",
            "STORAGE_COMPARTMENT_ID": "compartment",
            "STORAGE_DISPLAY_NAME": "demo-litellm-postgres",
            "STORAGE_FREEFORM_TAGS": json.dumps({"owner": "O'Reilly $example"}),
            "MOCK_LOG": str(self.log), "MOCK_OCID": OCID,
            "MOCK_COUNTER": str(self.directory / "counter"),
        })

    def run_helper(self, action, mode="active", success=True):
        result = subprocess.run(
            ["bash", str(HELPER), action],
            env=dict(self.environment, MOCK_MODE=mode),
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_create_and_repeat(self):
        self.run_helper("create", "pending")
        self.assertEqual(self.ocid_file.read_text(), OCID + "\n")
        create = self.calls()[0]
        self.assertEqual(create[:6], ["--region", "eu-frankfurt-1", "--profile", "TEST",
                                     "generative-ai", "hosted-application-storage"])
        for flag, value in [("--compartment-id", "compartment"),
                            ("--display-name", "demo-litellm-postgres"),
                            ("--storage-type", "POSTGRESQL"),
                            ("--freeform-tags", self.environment["STORAGE_FREEFORM_TAGS"]),
                            ("--wait-for-state", "SUCCEEDED"),
                            ("--max-wait-seconds", "1200"),
                            ("--wait-interval-seconds", "10"),
                            ("--output", "json")]:
            self.assertEqual(create[create.index(flag) + 1], value)
        self.assertNotIn("--query", create)
        self.run_helper("create")
        self.assertEqual(sum(call[6] == "create" for call in self.calls()), 1)

    def test_readiness_failure_and_retry_preserve_id(self):
        self.run_helper("create", "failed", success=False)
        self.assertEqual(self.ocid_file.read_text().strip(), OCID)
        self.run_helper("create")
        self.assertEqual(sum(call[6] == "create" for call in self.calls()), 1)

    def test_get_error_preserves_id(self):
        self.run_helper("create", "get_error", success=False)
        self.assertEqual(self.ocid_file.read_text().strip(), OCID)

    def test_mismatched_recorded_resource_fails(self):
        self.run_helper("create")
        self.run_helper("create", "mismatch", success=False)
        self.assertTrue(self.ocid_file.exists())
        self.assertEqual(sum(call[6] == "create" for call in self.calls()), 1)

    def test_invalid_create_id_is_not_saved(self):
        self.run_helper("create", "invalid_id", success=False)
        self.assertFalse(self.ocid_file.exists())

    def test_create_failure_does_not_publish_ocid(self):
        for mode in ("create_error", "create_failed", "missing_resource"):
            with self.subTest(mode=mode):
                self.run_helper("create", mode, success=False)
                self.assertFalse(self.ocid_file.exists())

    def test_delete(self):
        self.run_helper("create")
        self.run_helper("delete")
        self.assertFalse(self.ocid_file.exists())
        self.assertEqual(self.calls()[-1][6:], ["delete", "--hosted-application-storage-id",
                         OCID, "--force", "--wait-for-state", "SUCCEEDED",
                         "--max-wait-seconds", "1200"])

    def test_delete_failure_preserves_id(self):
        self.run_helper("create")
        self.run_helper("delete", "delete_error", success=False)
        self.assertEqual(self.ocid_file.read_text().strip(), OCID)

    def test_delete_missing_or_invalid_id(self):
        self.run_helper("delete", success=False)
        self.ocid_file.parent.mkdir()
        self.ocid_file.write_text("invalid\n")
        self.run_helper("delete", success=False)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()

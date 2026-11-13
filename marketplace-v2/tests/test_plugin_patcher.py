import importlib.util
import json
import os
import pathlib
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("apply_patch", ROOT / "plugin" / "apply_patch.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "tests" / "fixtures" / "handles-upstream-shape.py").read_text()
        self.patched = module.patch(self.source)
        self.namespace = {}
        exec(compile(self.patched, "handles.py", "exec"), self.namespace)
        self.tmp = tempfile.TemporaryDirectory()
        self.rentals_file = pathlib.Path(self.tmp.name) / "rentals.json"
        self.now = int(time.time())
        self.rentals_file.write_text(json.dumps({
            "12": {
                "rentalId": "12",
                "machineName": "provider-01.example",
                "expiresAt": self.now + 600,
            },
            "13": {
                "rentalId": "13",
                "machineName": "provider-expired.example",
                "expiresAt": self.now - 10,
            },
        }), encoding="utf-8")
        self.previous_rentals_file = os.environ.get("MEGA_RENTALS_FILE")
        os.environ["MEGA_RENTALS_FILE"] = str(self.rentals_file)

    def tearDown(self):
        if self.previous_rentals_file is None:
            os.environ.pop("MEGA_RENTALS_FILE", None)
        else:
            os.environ["MEGA_RENTALS_FILE"] = self.previous_rentals_file
        self.tmp.cleanup()

    def test_patch_injects_guard_and_submit_pin(self):
        self.assertIn("_load_w3node_rental(pod)", self.patched)
        self.assertIn("rental=rental", self.patched)
        self.assertIn("_w3node_pin_submit_description(job, rental)", self.patched)
        self.assertIn('host="127.0.0.1", debug=False', self.patched)
        self.assertIn("Queue 1", self.patched)
        compile(self.patched, "handles.py", "exec")

    def test_patch_is_idempotent(self):
        self.assertEqual(module.patch(self.patched), self.patched)

    def test_valid_pod_annotation_resolves_rental(self):
        rental, error = self.namespace["_load_w3node_rental"]({
            "metadata": {"annotations": {"marketplace.w3node.io/rental-id": "12"}}
        })
        self.assertIsNone(error)
        self.assertEqual(rental["rentalId"], "12")
        self.assertEqual(rental["machineName"], "provider-01.example")

    def test_create_struct_pod_envelope_resolves_rental(self):
        rental, error = self.namespace["_load_w3node_rental"]({
            "pod": {"metadata": {"annotations": {"marketplace.w3node.io/rental-id": "12"}}}
        })
        self.assertIsNone(error)
        self.assertEqual(rental["machineName"], "provider-01.example")

    def test_missing_annotation_is_rejected(self):
        rental, error = self.namespace["_load_w3node_rental"]({"metadata": {"annotations": {}}})
        self.assertIsNone(rental)
        self.assertIn("rental ID", error)

    def test_malformed_annotation_is_rejected(self):
        rental, error = self.namespace["_load_w3node_rental"]({
            "metadata": {"annotations": {"marketplace.w3node.io/rental-id": "12; touch /tmp/pwned"}}
        })
        self.assertIsNone(rental)
        self.assertIn("invalid", error)

    def test_unknown_rental_is_rejected(self):
        rental, error = self.namespace["_load_w3node_rental"]({
            "metadata": {"annotations": {"marketplace.w3node.io/rental-id": "999"}}
        })
        self.assertIsNone(rental)
        self.assertIn("Unknown", error)

    def test_expired_rental_is_rejected(self):
        rental, error = self.namespace["_load_w3node_rental"]({
            "metadata": {"annotations": {"marketplace.w3node.io/rental-id": "13"}}
        })
        self.assertIsNone(rental)
        self.assertIn("expired", error)

    def test_invalid_machine_name_is_rejected(self):
        self.rentals_file.write_text(json.dumps({"14": {
            "rentalId": "14", "machineName": 'node"; touch /tmp/pwned; #',
            "expiresAt": self.now + 600,
        }}), encoding="utf-8")
        rental, error = self.namespace["_load_w3node_rental"]({
            "metadata": {"annotations": {"marketplace.w3node.io/rental-id": "14"}}
        })
        self.assertIsNone(rental)
        self.assertIn("invalid provider machine name", error)

    def test_submit_pinning_without_existing_requirements(self):
        rental = {"rentalId": "12", "machineName": "provider-01.example"}
        submit = "RequestCpus = 1\nRequestMemory = 512\nQueue 1\n"
        result = self.namespace["_w3node_pin_submit_description"](submit, rental)
        self.assertIn('+RentalId = "12"', result)
        self.assertIn('Requirements = (TARGET.Machine == "provider-01.example")', result)
        self.assertLess(result.index("Requirements"), result.index("Queue 1"))
        self.assertLess(result.index("RentalId"), result.index("Queue 1"))

    def test_submit_pinning_combines_existing_requirements(self):
        rental = {"rentalId": "12", "machineName": "provider-01.example"}
        submit = "RequestCpus = 1\nRequirements = (HasSingularity == true)\nQueue 1\n"
        result = self.namespace["_w3node_pin_submit_description"](submit, rental)
        self.assertIn(
            'Requirements = ((HasSingularity == true)) && (TARGET.Machine == "provider-01.example")',
            result,
        )
        self.assertEqual(result.count("Requirements ="), 1)
        self.assertLess(result.index("Requirements"), result.index("Queue 1"))

    def test_submit_pinning_fails_closed_without_queue(self):
        rental = {"rentalId": "12", "machineName": "provider-01.example"}
        with self.assertRaises(ValueError):
            self.namespace["_w3node_pin_submit_description"]("RequestCpus = 1\n", rental)

    def test_patcher_fails_closed_when_upstream_anchor_changes(self):
        changed = self.source.replace("    poststart_hooks=None,\n):", "    lifecycle_hooks=None,\n):")
        with self.assertRaises(RuntimeError):
            module.patch(changed)

class HostGuardTests(unittest.TestCase):
    def test_guard_checks_every_container(self):
        source = (ROOT / "tests" / "fixtures" / "handles-upstream-shape.py").read_text()
        patched = module.patch(source)
        self.assertIn('any("host" in str((c or {}).get("image", "")) for c in containers)', patched)
        self.assertNotIn('containers[0].get("image"', patched)


if __name__ == "__main__":
    unittest.main(verbosity=2)

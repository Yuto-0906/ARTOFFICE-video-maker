import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "macos_package", Path(__file__).with_name("package-macos.py")
)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class AppleTicketTests(unittest.TestCase):
    @patch.object(package.time, "sleep")
    @patch.object(package, "checked")
    def test_retries_a_lost_connection(self, checked, sleep):
        checked.side_effect = [RuntimeError("The network connection was lost."), "validated"]
        self.assertEqual(package.apple_ticket_check(["xcrun", "stapler", "validate", "app"]), "validated")
        self.assertEqual(checked.call_count, 2)
        sleep.assert_called_once_with(1)

    @patch.object(package.time, "sleep")
    @patch.object(package, "checked")
    def test_does_not_retry_an_invalid_signature(self, checked, sleep):
        checked.side_effect = RuntimeError("code signature is invalid")
        with self.assertRaisesRegex(RuntimeError, "signature is invalid"):
            package.apple_ticket_check(["xcrun", "stapler", "validate", "app"])
        checked.assert_called_once()
        sleep.assert_not_called()

    @patch.object(package.time, "sleep")
    @patch.object(package, "checked")
    def test_never_accepts_an_unverified_ticket(self, checked, sleep):
        checked.side_effect = RuntimeError("CloudKit: The validate action failed! Error 68.")
        with self.assertRaisesRegex(RuntimeError, "Error 68"):
            package.apple_ticket_check(["xcrun", "stapler", "validate", "app"])
        self.assertEqual(checked.call_count, 4)
        self.assertEqual(sleep.call_count, 3)


if __name__ == "__main__":
    unittest.main()

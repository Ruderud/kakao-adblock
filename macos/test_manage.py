import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("manage", Path(__file__).with_name("manage.py"))
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class HostsTests(unittest.TestCase):
    def test_preserves_unrelated_content(self):
        original = "# ordinary host file\n127.0.0.1 localhost\n192.0.2.1 example.invalid # test fixture\n"
        result = manage.managed_hosts(original)
        self.assertTrue(result.startswith(original))
        self.assertEqual(manage.managed_hosts(result, False), original)

    def test_idempotent(self):
        first = manage.managed_hosts("127.0.0.1 localhost\n")
        self.assertEqual(manage.managed_hosts(first), first)

    def test_ipv4_and_ipv6(self):
        state = manage.hosts_status(manage.managed_hosts(""))
        self.assertEqual(len(state), 5)
        self.assertTrue(all(value["ipv4"] and value["ipv6"] for value in state.values()))

    def test_comments_are_not_rules(self):
        state = manage.hosts_status("# 0.0.0.0 display.ad.daum.net\n")
        self.assertFalse(state["display.ad.daum.net"]["ipv4"])

    def test_aliases_and_case(self):
        state = manage.hosts_status("127.0.0.1 localhost DISPLAY.AD.DAUM.NET # blocked\n")
        self.assertTrue(state["display.ad.daum.net"]["ipv4"])

    def test_unmatched_marker_refused(self):
        with self.assertRaises(manage.MaintenanceError):
            manage.managed_hosts(manage.BEGIN + "\n")

    def test_duplicate_marker_refused(self):
        with self.assertRaises(manage.MaintenanceError):
            manage.managed_hosts((manage.BEGIN + "\n" + manage.END + "\n") * 2)

    def test_reversed_marker_refused(self):
        with self.assertRaises(manage.MaintenanceError):
            manage.managed_hosts(manage.END + "\n" + manage.BEGIN + "\n")

    def test_only_managed_block_removed(self):
        existing = "0.0.0.0 display.ad.daum.net # configured by another tool\n"
        self.assertEqual(manage.managed_hosts(manage.managed_hosts(existing), False), existing)

    def test_suffix_preserved(self):
        block = manage.managed_hosts("")
        suffix = "127.0.0.1 localhost\n"
        self.assertEqual(manage.managed_hosts(block + suffix, False), suffix)

    def test_existing_nonblocking_mapping_refused(self):
        with self.assertRaises(manage.MaintenanceError):
            manage.managed_hosts("192.0.2.1 display.ad.daum.net\n")


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "macos_tools", Path(__file__).with_name("build-macos-tools.py")
)
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class DeploymentTargetTests(unittest.TestCase):
    def test_does_not_confuse_linker_or_source_versions_with_the_os(self):
        commands = """
Load command 1
       cmd LC_BUILD_VERSION
   cmdsize 32
  platform 1
     minos 15.0
       sdk 26.0
     tools 1
      tool 3
   version 1167.5
Load command 2
       cmd LC_SOURCE_VERSION
   cmdsize 16
   version 0.0
"""
        self.assertEqual(tools.minimum_macos_versions(commands), [(15, 0, 0)])

    def test_legacy_minimum_version_command(self):
        self.assertEqual(
            tools.minimum_macos_versions("cmd LC_VERSION_MIN_MACOSX\nversion 15.0.1\nsdk 26.0\n"),
            [(15, 0, 1)],
        )

    def test_requires_an_actual_deployment_target(self):
        self.assertEqual(tools.minimum_macos_versions("cmd LC_SOURCE_VERSION\nversion 0.0\n"), [])


if __name__ == "__main__":
    unittest.main()

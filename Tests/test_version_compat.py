import copy
import unittest

from provenance import MANIFEST, compatible_production_runtime


class VersionCompatibilityTests(unittest.TestCase):
    def test_previous_release_productions_stay_renderable(self):
        for version in ('3.7.0', '3.8.0'):
            recorded = copy.deepcopy(MANIFEST); recorded['native_app_version'] = version
            self.assertTrue(compatible_production_runtime(recorded), version)

    def test_unknown_app_versions_and_pin_changes_are_still_rejected(self):
        recorded = copy.deepcopy(MANIFEST); recorded['native_app_version'] = '3.6.9'
        self.assertFalse(compatible_production_runtime(recorded))
        recorded = copy.deepcopy(MANIFEST); recorded['native_app_version'] = '3.7.0'; recorded['model_revision'] = 'other'
        self.assertFalse(compatible_production_runtime(recorded))


if __name__ == '__main__':
    unittest.main()

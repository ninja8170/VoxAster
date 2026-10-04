"""Publication scan regressions for historical identities and redacted findings."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release_audit', Path(__file__).resolve().parents[1] / 'tools/audit-release.py')
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)

class PublicationScanTests(unittest.TestCase):
    def test_public_identity_allowed_private_identity_redacted(self):
        public = b'123+contributor@users.noreply.github.com'
        private = b'person' + b'@' + b'example.invalid'
        self.assertEqual(audit.scan(public, 'commit'), [])
        findings = audit.scan(private, 'commit')
        self.assertTrue(findings)
        self.assertNotIn(private.decode(), '\n'.join(findings))

    def test_public_licensor_contact_allowed_without_general_email_exemption(self):
        self.assertEqual(audit.scan(b'LlamaUseReport' + b'@meta.com', 'licence'), [])
        self.assertTrue(audit.scan(b'private' + b'@meta.com', 'commit'))

    def test_binary_prefix_does_not_hide_credentials(self):
        token = b'ghp_' + b'Z' * 36
        findings = audit.scan(b'\0binary\0' + token, 'asset')
        self.assertTrue(any('GitHub token' in item for item in findings))
        self.assertNotIn(token.decode(), '\n'.join(findings))

    def test_old_commit_and_annotated_tag_scanned_after_safe_tip(self):
        with tempfile.TemporaryDirectory(prefix='voxaster-audit-test-') as temporary:
            root = Path(temporary)
            def git(*args):
                subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True)
            git('init', '-q')
            git('config', 'user.name', 'Test Contributor')
            private = 'person' + '@' + 'example.invalid'
            git('config', 'user.email', private)
            git('-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'Original')
            git('-c', 'tag.gpgsign=false', 'tag', '-a', 'legacy', '-m', 'Original tag')
            git('config', 'user.email', '123+contributor@users.noreply.github.com')
            git('-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'Safe tip')
            output = io.StringIO()
            with patch.object(audit, 'ROOT', root), contextlib.redirect_stdout(output):
                failed = audit.main()
            self.assertTrue(failed)
            self.assertIn('history commit', output.getvalue())
            self.assertIn('history tag', output.getvalue())
            self.assertNotIn(private, output.getvalue())

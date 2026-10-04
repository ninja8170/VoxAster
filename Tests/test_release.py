"""Public release boundary tests: no network, model loading or private data."""
import os
import tempfile
import unittest
from unittest.mock import patch

ROOT = tempfile.TemporaryDirectory(prefix="voxaster-release-tests-")
os.environ.setdefault("OMNIVOICE_DATA_ROOT", ROOT.name)
from fastapi.testclient import TestClient
import backend

class LocalAPITests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(backend.app, base_url="http://127.0.0.1:8011")

    def test_native_preview_remains_available(self):
        response = self.client.post('/preview-speech', data={'text': 'Hello.'})
        self.assertEqual(response.status_code, 200)

    def test_browser_form_posts_block_before_model_use(self):
        with patch.object(backend, 'generate_omni') as generate:
            for origin in ('https://attacker.example', 'null', 'http://127.0.0.1:8011'):
                response = self.client.post('/generate-design', data={'text':'Hello'}, headers={'Origin':origin})
                self.assertEqual(response.status_code, 403)
            generate.assert_not_called()

    def test_fetch_context_blocked_without_origin(self):
        for site in ('cross-site','same-site','same-origin'):
            response=self.client.post('/personal/train', headers={'Sec-Fetch-Site':site})
            self.assertEqual(response.status_code,403)

    def test_dns_rebinding_host_blocked(self):
        response=self.client.get('/health', headers={'Host':'rebind.example:8011'})
        self.assertEqual(response.status_code,400)

    def test_browser_cannot_read_productions(self):
        response=self.client.get('/performance', headers={'Origin':'https://attacker.example'})
        self.assertEqual(response.status_code,403)

    def test_public_interactive_docs_disabled(self):
        self.assertEqual(self.client.get('/docs').status_code,404)

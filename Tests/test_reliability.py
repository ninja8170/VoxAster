"""P0 failure injection: real temporary files, no model loading or synthesis."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import numpy as np
from safetensors.numpy import save_file
import soundfile as sf
TEST_RUNTIME = tempfile.TemporaryDirectory(prefix='omnivoice-p0-runtime-')
os.environ['OMNIVOICE_DATA_ROOT'] = TEST_RUNTIME.name
import backend
from fastapi.testclient import TestClient
from training_safety import OperationLock, atomic_json, publish_directory, reject_overlap, validate_model


class TrainingReliabilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='omnivoice-p0-training-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        personal = self.root / 'personal'
        names = dict(PERSONAL_ROOT=personal, PERSONAL_DATA=personal/'dataset',
            PERSONAL_AUDIO=personal/'dataset/audio', PERSONAL_TRAIN=personal/'dataset/train.jsonl',
            PERSONAL_DEV=personal/'dataset/dev.jsonl', PERSONAL_LOG=personal/'training.log',
            PERSONAL_OUT=personal/'exp', PERSONAL_MERGED=personal/'merged-model',
            TRAIN_VENV=personal/'venv', TRAINED_ENGINES_DIR=personal/'engines',
            TRAINED_ENGINES_REGISTRY=personal/'trained-engines.json')
        for name, value in names.items():
            p = patch.object(backend, name, value); p.start(); self.addCleanup(p.stop)
        for name in ['TRAIN_PROC', 'TRAIN_LOG_HANDLE', 'TRAIN_EXIT']:
            p = patch.object(backend, name, None); p.start(); self.addCleanup(p.stop)
        backend.PERSONAL_AUDIO.mkdir(parents=True)
        backend.TRAINED_ENGINES_DIR.mkdir()
        self.old = backend.PERSONAL_DATA/'old-audio.wav'
        self.old.write_bytes(b'old usable dataset')
        backend.PERSONAL_TRAIN.write_text('old training manifest')
        backend.PERSONAL_DEV.write_text('old dev manifest')
        self.before = self.snapshot(backend.PERSONAL_DATA)
        self.source = self.root/'recordings'; self.source.mkdir()
        for i in range(3):
            sf.write(self.source/f'{i}.wav', np.sin(np.arange(24000)*.05)*.2, 24000)
            (self.source/f'{i}.txt').write_text(f'Clip {i}.')
        checkpoint = backend.PERSONAL_OUT/'checkpoint-1'; checkpoint.mkdir(parents=True)
        (checkpoint/'adapter_config.json').write_text('{}')
        save_file({'adapter':np.zeros(1,dtype=np.float32)}, checkpoint/'adapter_model.safetensors')
        probe = patch("training_safety.read_process_table", return_value=Mock(returncode=0, stdout=""))
        probe.start(); self.addCleanup(probe.stop)
        self.client = TestClient(backend.app)
        self.reader = patch.object(backend, '_read_audio', side_effect=lambda path: sf.read(path, dtype='float32'))
        self.reader.start(); self.addCleanup(self.reader.stop)

    @staticmethod
    def snapshot(root):
        return {str(p.relative_to(root)):p.read_bytes() for p in root.rglob('*') if p.is_file()}

    def prepare(self, source=None):
        return self.client.post('/personal/prepare', json={'folder':str(source or self.source)})

    def preserved(self):
        self.assertEqual(self.snapshot(backend.PERSONAL_DATA), self.before)

    def fake_merge(self, checkpoint, stage):
        from tokenizers import Tokenizer
        from tokenizers.models import WordLevel
        (stage/'config.json').write_text('{}')
        (stage/'tokenizer_config.json').write_text('{}')
        Tokenizer(WordLevel({'[UNK]':0}, unk_token='[UNK]')).save(str(stage/'tokenizer.json'))
        (stage/'audio_tokenizer').mkdir()
        (stage/'audio_tokenizer/config.json').write_text('{}')
        (stage/'audio_tokenizer/preprocessor_config.json').write_text('{}')
        save_file({'weight':np.ones(2,dtype=np.float32)}, stage/'model.safetensors')
        save_file({'weight':np.ones(2,dtype=np.float32)}, stage/'audio_tokenizer/model.safetensors')
        validate_model(stage)

    def test_invalid_and_empty_source_preserve_dataset(self):
        for source in [self.root/'missing', self.root/'empty']:
            if source.name == 'empty': source.mkdir()
            self.assertEqual(self.prepare(source).status_code, 400); self.preserved()

    def test_source_destination_and_symlink_overlap(self):
        link = self.root/'alias'; link.symlink_to(backend.PERSONAL_DATA, target_is_directory=True)
        for source in [backend.PERSONAL_DATA, backend.PERSONAL_AUDIO, backend.PERSONAL_ROOT, link]:
            self.assertEqual(self.prepare(source).status_code, 400); self.preserved()

    def test_source_file_symlink_into_dataset_rejected(self):
        (self.source/'old.wav').symlink_to(self.old)
        self.assertEqual(self.prepare().status_code, 400); self.preserved()

    def test_prepare_read_failure_preserves_dataset(self):
        with patch.object(backend, '_read_audio', side_effect=OSError('read failure')):
            self.assertEqual(self.prepare().status_code, 400)
        self.preserved()

    def test_prepare_write_failure_preserves_dataset(self):
        with patch('soundfile.write', side_effect=OSError('disk full')):
            self.assertEqual(self.prepare().status_code, 400)
        self.preserved()

    def test_prepare_insufficient_accepted_clips_preserves_dataset(self):
        with patch.object(backend, '_quality', return_value=(False,'near_silence',1)):
            self.assertEqual(self.prepare().status_code, 400)
        self.preserved()

    def test_prepare_validation_failure_preserves_dataset(self):
        with patch.object(backend, 'validate_dataset', side_effect=ValueError('invalid staged manifest')):
            self.assertEqual(self.prepare().status_code, 400)
        self.preserved()

    def test_prepare_publish_failure_preserves_dataset(self):
        with patch.object(backend, 'publish_directory', side_effect=OSError('atomic swap refused')):
            self.assertEqual(self.prepare().status_code, 400)
        self.preserved()
        self.assertFalse(list(backend.PERSONAL_ROOT.glob('.dataset-staging-*')))

    def test_successful_atomic_dataset_replacement(self):
        result = self.prepare(); self.assertEqual(result.status_code,200,result.text)
        self.assertEqual(result.json()['accepted'],3)
        self.assertFalse(self.old.exists())
        for name in ('train.jsonl','dev.jsonl'):
            for line in (backend.PERSONAL_DATA/name).read_text().splitlines():
                row=json.loads(line)
                self.assertTrue(Path(row['audio_path']).is_file())
                self.assertNotIn('staging',row['audio_path'])

    def test_active_training_blocks_all_publication_routes(self):
        backend.TRAIN_PROC = Mock(); backend.TRAIN_PROC.poll.return_value = None
        for route,payload in [('/personal/prepare',{'folder':str(self.source)}),('/personal/merge',{}),('/personal/save-engine',{'name':'Voice'})]:
            r=self.client.post(route,json=payload)
            self.assertEqual(r.status_code,400); self.assertIn('active',r.json()['error'])
        self.preserved()

    def test_lock_blocks_other_backend_and_training_start(self):
        (backend.PERSONAL_ROOT/'run-lora.command').write_text('exit 0\n')
        with OperationLock(backend.PERSONAL_ROOT):
            self.assertEqual(self.prepare().status_code,400)
            self.assertEqual(self.client.post('/personal/train').status_code,500)
        self.preserved()

    def test_training_child_retains_lock_after_parent_descriptor_closes(self):
        ack = backend.PERSONAL_ROOT/'ack'
        script = backend.PERSONAL_ROOT/'run-lora.command'
        script.write_text(f'print ready > "{ack}"\n/bin/sleep 0.4\n')
        with OperationLock(backend.PERSONAL_ROOT) as lease:
            proc = backend._launch_training_script(script, lease.fd)
        try:
            deadline=time.monotonic()+2
            while not ack.exists() and time.monotonic()<deadline: time.sleep(.01)
            self.assertTrue(ack.exists())
            # Simulate restarted backend losing its in-memory Process handle.
            backend.TRAIN_PROC = None
            self.assertEqual(self.prepare().status_code,400)
            self.preserved()
            proc.wait(timeout=3)
            with OperationLock(backend.PERSONAL_ROOT): pass
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()
            backend.TRAIN_LOG_HANDLE.close()

    def test_merge_command_failure_preserves_model(self):
        backend.PERSONAL_MERGED.mkdir(); old=backend.PERSONAL_MERGED/'old'; old.write_bytes(b'good model')
        with patch.object(backend.subprocess,'run',return_value=Mock(returncode=1,stderr='merge failed',stdout='')):
            self.assertEqual(self.client.post('/personal/merge').status_code,400)
        self.assertEqual(old.read_bytes(),b'good model')

    def test_incomplete_merge_preserves_model(self):
        backend.PERSONAL_MERGED.mkdir(); old=backend.PERSONAL_MERGED/'old'; old.write_bytes(b'good model')
        with patch.object(backend.subprocess,'run',return_value=Mock(returncode=0)):
            self.assertEqual(self.client.post('/personal/merge').status_code,400)
        self.assertEqual(old.read_bytes(),b'good model')

    def test_merge_publish_failure_and_success(self):
        backend.PERSONAL_MERGED.mkdir(); old=backend.PERSONAL_MERGED/'old'; old.write_bytes(b'good model')
        with patch.object(backend,'merge_into',side_effect=self.fake_merge):
            with patch.object(backend,'publish_directory',side_effect=OSError('publish failed')):
                self.assertEqual(self.client.post('/personal/merge').status_code,400)
            self.assertEqual(old.read_bytes(),b'good model')
            r=self.client.post('/personal/merge'); self.assertEqual(r.status_code,200,r.text)
        validate_model(backend.PERSONAL_MERGED)

    def test_unsafe_merge_overlap_rejected(self):
        with patch.object(backend,'PERSONAL_MERGED',backend.PERSONAL_DATA):
            self.assertEqual(self.client.post('/personal/merge').status_code,400)
        self.preserved()

    def test_engine_names_cannot_collide_and_identity_stays_stable(self):
        with patch.object(backend,'merge_into',side_effect=self.fake_merge):
            a=self.client.post('/personal/save-engine',json={'name':'Voice / A'})
            b=self.client.post('/personal/save-engine',json={'name':'Voice : A'})
            self.assertEqual(a.status_code,200,a.text); self.assertEqual(b.status_code,200,b.text)
            self.assertNotEqual(a.json()['path'],b.json()['path'])
            initial=json.loads(backend.TRAINED_ENGINES_REGISTRY.read_text())
            again=self.client.post('/personal/save-engine',json={'name':'Voice / A'})
            final=json.loads(backend.TRAINED_ENGINES_REGISTRY.read_text())
            self.assertEqual(next(x['id'] for x in initial if x['name']=='Voice / A'),next(x['id'] for x in final if x['name']=='Voice / A'))
            self.assertTrue(Path(a.json()['path']).is_dir())
            self.assertNotEqual(a.json()['path'],again.json()['path'])

    def test_engine_registry_failure_preserves_old_engine_and_registry(self):
        with patch.object(backend,'merge_into',side_effect=self.fake_merge):
            first=self.client.post('/personal/save-engine',json={'name':'Voice'}).json()
            registry=backend.TRAINED_ENGINES_REGISTRY.read_bytes()
            old=self.snapshot(Path(first['path']))
            with patch.object(backend,'_save_trained_engines',side_effect=OSError('registry disk full')):
                self.assertEqual(self.client.post('/personal/save-engine',json={'name':'Voice'}).status_code,400)
            self.assertEqual(registry,backend.TRAINED_ENGINES_REGISTRY.read_bytes())
            self.assertEqual(old,self.snapshot(Path(first['path'])))

    def test_engine_merge_failure_preserves_registry_and_engine(self):
        with patch.object(backend,'merge_into',side_effect=self.fake_merge):
            first=self.client.post('/personal/save-engine',json={'name':'Voice'}).json()
        registry=backend.TRAINED_ENGINES_REGISTRY.read_bytes()
        with patch.object(backend,'merge_into',side_effect=RuntimeError('merge failed')):
            self.assertEqual(self.client.post('/personal/save-engine',json={'name':'Voice'}).status_code,400)
        self.assertEqual(registry,backend.TRAINED_ENGINES_REGISTRY.read_bytes()); validate_model(Path(first['path']))

    def test_legacy_registry_migrates_without_deleting_old_model(self):
        old=backend.TRAINED_ENGINES_DIR/'old-name';old.mkdir();self.fake_merge(None,old)
        atomic_json(backend.TRAINED_ENGINES_REGISTRY,[dict(name='Legacy',path=str(old))])
        with patch.object(backend,'merge_into',side_effect=self.fake_merge):
            r=self.client.post('/personal/save-engine',json={'name':'Legacy'});self.assertEqual(r.status_code,200,r.text)
        self.assertTrue(old.is_dir());self.assertIn('id',json.loads(backend.TRAINED_ENGINES_REGISTRY.read_text())[0])

    def test_corrupt_and_external_registry_entries_preserved(self):
        for text in ['not json',json.dumps([dict(name='Voice',path=str(self.root))])]:
            backend.TRAINED_ENGINES_REGISTRY.write_text(text)
            r=self.client.post('/personal/save-engine',json={'name':'Voice'})
            self.assertEqual(r.status_code,400);self.assertEqual(text,backend.TRAINED_ENGINES_REGISTRY.read_text())

    def test_atomic_json_failed_replacement_preserves_old(self):
        path=self.root/'registry.json';path.write_text('original')
        with patch('training_safety.os.replace',side_effect=OSError('rename denied')):
            with self.assertRaises(OSError): atomic_json(path,{'replacement':1})
        self.assertEqual(path.read_text(),'original')
        self.assertFalse(list(self.root.glob('.registry.json-*')))

    def test_directory_publication_rejects_symlink_and_non_siblings(self):
        stage=self.root/'stage';stage.mkdir()
        alias=self.root/'alias';alias.symlink_to(backend.PERSONAL_DATA,target_is_directory=True)
        with self.assertRaises(ValueError):publish_directory(stage,alias)
        with self.assertRaises(ValueError):publish_directory(stage,backend.PERSONAL_DATA)
        self.preserved()

    def test_legacy_training_detected_without_in_memory_handle(self):
        for command in [f'/bin/zsh {backend.PERSONAL_ROOT}/run-lora.command', f'{backend.TRAIN_VENV}/bin/accelerate launch -m omnivoice.cli.train --output_dir {backend.PERSONAL_OUT}']:
            with patch('training_safety.read_process_table', return_value=Mock(returncode=0, stdout=command)):
                r=self.prepare();self.assertEqual(r.status_code,400);self.assertIn('active',r.json()['error'])
        self.preserved()

    def test_process_inspection_unavailable_fails_closed(self):
        with patch('training_safety.read_process_table', side_effect=PermissionError('process table denied')):
            self.assertEqual(self.prepare().status_code,400)
        self.preserved()

    def test_missing_tokenizer_never_publishes_model(self):
        stage=self.root/'incomplete'; stage.mkdir(); self.fake_merge(None,stage)
        (stage/'audio_tokenizer/model.safetensors').unlink()
        with self.assertRaises(ValueError): validate_model(stage)

    def test_real_exchange_error_preserves_old_directory(self):
        import ctypes
        import errno
        stage=backend.PERSONAL_ROOT/'stage';stage.mkdir();(stage/'new').write_bytes(b'new')
        fake=Mock()
        def fail(*args):
            ctypes.set_errno(errno.EACCES)
            return -1
        fake.renamex_np.side_effect=fail
        fake.renameat2.side_effect=fail
        with patch('training_safety.ctypes.CDLL',return_value=fake):
            with self.assertRaises(OSError):publish_directory(stage,backend.PERSONAL_DATA)
        self.preserved();self.assertEqual((stage/'new').read_bytes(),b'new')

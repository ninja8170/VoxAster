import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import bootstrap as b


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)/'runtime'; self.root.mkdir()
        (self.root/'staging').mkdir()
        self.data = b'fixture-model'
        self.artifact = dict(name='fixture', version='1', filename='model.bin',
                             url='https://huggingface.co/approved/pinned',
                             sha256=hashlib.sha256(self.data).hexdigest(), size=len(self.data),
                             kind='model', destination='model/revision/model.bin',license='fixture')
        self.lock = dict(schema=1,architecture='arm64',runtime_id='fixture',app_version='3.7.0',pins={},
                         artifacts=[self.artifact],download_bytes=len(self.data))
        self.calls=0
        self.events=patch.object(b,'emit'); self.events.start();self.addCleanup(self.events.stop)

    def fetch(self,url,path,report):
        self.calls+=1;path.write_bytes(self.data);report(len(self.data))

    def stage(self):
        import uuid
        p=self.root/'staging'/uuid.uuid4().hex;p.mkdir();return p

    def install(self, downloader=None, validator=None):
        stage=self.stage()
        def files(s,downloads):
            p=s/self.artifact['destination'];p.parent.mkdir(parents=True);p.write_bytes(downloads['model.bin'].read_bytes())
        return b.install(self.root,stage,self.lock,'lock',Path(self.tmp.name),
                         downloader=downloader or self.fetch,installer=files,validator=validator or (lambda _:None))

    def test_fresh_install_requires_setup(self):
        with self.assertRaises(FileNotFoundError):b.active_installation(self.root)

    def test_successful_staging_and_receipt(self):
        p=self.install();self.assertEqual(b.active_installation(self.root),p)
        self.assertEqual(b.verify_installation(p,'lock',self.lock)['state'],'READY')
        self.assertFalse((self.root/'staging'/p.name).exists())

    def test_corrupted_download_never_promoted(self):
        def bad(url,p,r):p.write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError,'verification'):self.install(bad)
        self.assertFalse((self.root/'active.json').exists())

    def test_same_size_hash_failure(self):
        def bad(url,p,r):p.write_bytes(b'x'*len(self.data))
        with self.assertRaises(ValueError):self.install(bad)

    def test_interrupted_download_retry(self):
        def interrupted(url,p,r):p.write_bytes(b'half');raise InterruptedError()
        with self.assertRaises(InterruptedError):self.install(interrupted)
        self.assertFalse((self.root/'active.json').exists())
        self.install();self.assertEqual(self.calls,1)

    def test_validation_failure_does_not_activate(self):
        def fail(_):raise ValueError('import failure')
        with self.assertRaises(ValueError):self.install(validator=fail)
        self.assertFalse((self.root/'active.json').exists())

    def test_retry_reuses_verified_download(self):
        self.install();self.install();self.assertEqual(self.calls,1)

    def test_repair_keeps_previous_runtime_and_user_data(self):
        project=self.root.parent/'projects.json';project.write_text('keep')
        old=self.install();(old/self.artifact['destination']).write_bytes(b'bad')
        new=self.install()
        self.assertNotEqual(old,new);self.assertTrue(old.exists());self.assertEqual(project.read_text(),'keep')
        b.verify_installation(new,'lock',self.lock)

    def test_failed_repair_keeps_active_pointer(self):
        old=self.install()
        def fail(_):raise ValueError('failed')
        with self.assertRaises(ValueError):self.install(validator=fail)
        self.assertEqual(b.active_installation(self.root),old)

    def test_offline_before_setup(self):
        def offline(*_):raise RuntimeError('Internet access is required')
        with self.assertRaisesRegex(RuntimeError,'Internet'):self.install(offline)
        self.assertFalse((self.root/'active.json').exists())

    def test_offline_after_setup_does_not_download(self):
        p=self.install()
        with patch.object(b,'fetch',side_effect=AssertionError('network')):
            b.verify_installation(p,'lock',self.lock)

    def test_wrong_architecture(self):
        self.lock['architecture']='x86_64'
        with self.assertRaises(ValueError):self.install()

    def test_missing_model(self):
        p=self.install();(p/self.artifact['destination']).unlink()
        with self.assertRaises(ValueError):b.verify_installation(p,'lock',self.lock)

    def test_partial_model(self):
        p=self.install();(p/self.artifact['destination']).write_bytes(b'half')
        with self.assertRaises(ValueError):b.verify_installation(p,'lock',self.lock)

    def test_bundle_immutable(self):
        bundle=self.root.parent/'App.app';bundle.mkdir();file=bundle/'backend.py';file.write_text('sealed')
        before=b.inventory(bundle);self.install();self.assertEqual(b.inventory(bundle),before)

    def test_unknown_https_and_redirect_sources(self):
        for url in ['http://huggingface.co/a','https://evil.test/a','https://huggingface.co.evil.test/a',
                    'https://' + 'user:password' + '@' + 'huggingface.co/a','https://huggingface.co:444/a']:
            with self.assertRaises(ValueError):b.check_url(url)
        b.check_url('https://cas-bridge.xethub.hf.co/pinned')
        b.check_url('https://us.aws.cdn.hf.co/pinned')

    def test_path_escape_rejected(self):
        self.artifact['destination']='../project'
        with self.assertRaises(ValueError):self.install()

    def test_external_symlink_rejected(self):
        p=self.install();(p/'outside').symlink_to(self.root.parent)
        with self.assertRaises(ValueError):b.verify_installation(p,'lock',self.lock)

    def test_changed_lock_requires_new_runtime(self):
        p=self.install()
        with self.assertRaises(ValueError):b.verify_installation(p,'new-lock',self.lock)

    def test_uncommitted_stage_never_ready(self):
        stage=self.stage();(stage/'partial').write_text('incomplete')
        with self.assertRaises(FileNotFoundError):b.active_installation(self.root)

    def test_bundled_lock_preserves_pins_and_licences(self):
        resources=Path(b.__file__).parent
        lock=json.loads((resources/'bootstrap-lock.json').read_text())
        b.validate_lock(lock)
        self.assertEqual(lock['pins'],json.loads((resources/'runtime.json').read_text()))
        self.assertFalse(any('eustlb' in a['url'] for a in lock['artifacts']))
        self.assertEqual(len([a for a in lock['artifacts'] if a['kind']=='python']),1)
        self.assertEqual(len([a for a in lock['artifacts'] if a['kind']=='source']),1)

    def test_locked_wheel_dependency_closure(self):
        from packaging.requirements import Requirement
        from packaging.markers import default_environment
        from packaging.utils import canonicalize_name
        lock=json.loads((Path(b.__file__).parent/'bootstrap-lock.json').read_text())
        versions={canonicalize_name(a['name']):a['version'] for a in lock['artifacts'] if a['kind'] in ('wheel','source')}
        env=default_environment()
        env.update(python_version='3.12',python_full_version='3.12.15',sys_platform='darwin',platform_machine='arm64',platform_system='Darwin',extra='')
        for artifact in lock['artifacts']:
            for value in artifact.get('requires',[]):
                req=Requirement(value)
                if req.marker and not req.marker.evaluate(env):continue
                selected=versions.get(canonicalize_name(req.name))
                self.assertIsNotNone(selected, artifact['name']+' requires '+str(req))
                self.assertIn(selected,req.specifier,artifact['name']+' requires '+str(req))

    def test_installer_environment_cannot_use_personal_pip_cache(self):
        env=b.environment(self.root,self.root/'stage')
        self.assertEqual(env['PIP_NO_CACHE_DIR'],'1')
        self.assertTrue(env['PIP_CACHE_DIR'].startswith(str(self.root)))
        self.assertTrue(env['XDG_CACHE_HOME'].startswith(str(self.root)))
        self.assertNotIn('homebrew',env['PATH'])
        self.assertEqual(env['PYTHONDONTWRITEBYTECODE'],'1')

    def test_redirect_handler_rejects_unapproved_location(self):
        from urllib.request import Request
        with self.assertRaises(ValueError):
            b.Redirects().redirect_request(Request('https://github.com/start'), None, 302, '', {}, 'https://evil.test/payload')

    def test_download_directory_symlink_cannot_write_outside(self):
        outside=self.root.parent/'outside';outside.mkdir()
        (self.root/'downloads').symlink_to(outside)
        with self.assertRaises(ValueError):self.install()
        self.assertEqual(list(outside.iterdir()),[])

    def test_log_symlink_cannot_overwrite_user_file(self):
        outside=self.root.parent/'user-data';outside.write_text('keep')
        (self.root/'logs').mkdir();(self.root/'logs/setup.log').symlink_to(outside)
        with self.assertRaises(ValueError):b.prepare_storage(self.root)
        self.assertEqual(outside.read_text(),'keep')

    def test_partial_download_hardlink_rejected(self):
        import os
        outside=self.root.parent/'user-data';outside.write_text('keep')
        (self.root/'downloads').mkdir();os.link(outside,self.root/'downloads/model.bin.partial')
        with self.assertRaises(ValueError):self.install()
        self.assertEqual(outside.read_text(),'keep')

    def test_storage_anywhere_in_app_rejected_before_creation(self):
        root=self.root/'Fixture.app/Contents/Other/runtime'
        with self.assertRaises(ValueError):b.prepare_storage(root)
        self.assertFalse(root.exists())

    def test_environment_strips_startup_and_cache_overrides(self):
        injected={'PYTHONINSPECT':'1','PYTHONUSERBASE':'/unexpected','PYTHONPYCACHEPREFIX':'/unexpected',
                  '__PYVENV_LAUNCHER__':'/unexpected','TAR_OPTIONS':'--absolute-paths',
                  'HF_HUB_CACHE':'/unexpected','TRANSFORMERS_CACHE':'/unexpected','NUMBA_CACHE_DIR':'/unexpected'}
        with patch.dict(b.os.environ,injected):env=b.environment(self.root,self.root/'stage')
        for key in injected:
            self.assertNotEqual(env.get(key),injected[key],key)
        self.assertEqual(env['PYTHONDONTWRITEBYTECODE'],'1')

    def test_lock_rejects_dot_and_temporary_urls(self):
        for filename in ('.','..',''):
            lock=copy.deepcopy(self.lock);lock['artifacts'][0]['filename']=filename
            with self.assertRaises(ValueError):b.validate_lock(lock)
        lock=copy.deepcopy(self.lock);lock['artifacts'][0]['url']+='?expires=tomorrow'
        with self.assertRaises(ValueError):b.validate_lock(lock)

    def test_oversized_download_not_activated(self):
        def too_big(url,p,report):p.write_bytes(self.data+b'x');report(len(self.data)+1)
        with self.assertRaisesRegex(ValueError,'pinned size'):self.install(too_big)
        self.assertFalse((self.root/'active.json').exists())

    def test_all_locked_artifacts_match_target_and_catalogue(self):
        from collections import Counter
        from packaging.tags import cpython_tags, compatible_tags, mac_platforms
        from packaging.utils import parse_wheel_filename, canonicalize_name
        from urllib.parse import urlsplit
        lock=json.loads((Path(b.__file__).parent/'bootstrap-lock.json').read_text())
        self.assertEqual(Counter(a['kind'] for a in lock['artifacts']),dict(python=1,source=1,wheel=90,model=7,tokenizer=4))
        platforms=list(mac_platforms((14,0),'arm64'))
        tags=set(cpython_tags((3,12),platforms=platforms))|set(compatible_tags((3,12),'cp312',platforms))
        for a in lock['artifacts']:
            self.assertTrue(a['license_source']);self.assertGreater(a['unpacked_size'],0)
            url=urlsplit(a['url']);self.assertFalse(url.query or url.fragment)
            self.assertNotIn('latest',url.path.lower())
            if a['kind']=='wheel':
                name,version,_,wheel_tags=parse_wheel_filename(a['filename'])
                self.assertTrue(tags&wheel_tags,a['filename'])
                self.assertEqual(name,canonicalize_name(a['name']))
                self.assertEqual(str(version),a['version'])
            if a['kind'] in ('source','model','tokenizer'):
                self.assertIn(a.get('revision',a['version']),a['url'])
        self.assertEqual(sum(a['unpacked_size'] for a in lock['artifacts']),lock['unpacked_bytes'])

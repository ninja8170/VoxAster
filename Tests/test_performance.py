import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import numpy as np
import soundfile as sf
import torch
from omnivoice.models.omnivoice import VoiceClonePrompt
import test_generation as base
from generation import GenerationRequest
from performance_script import parse_script, compile_script, ScriptError, NATIVE_EVENTS
from performance_audio import prepare_audio, assemble, PEAK_CEILING, MASTER_HEADROOM
from performance import ProductionStore


def fixture():
    return np.concatenate([np.zeros(2400), np.full(1000, 0.25), np.zeros(4800)]).astype(np.float32)


class ParserTests(unittest.TestCase):
    def test_lossless_native_pronunciation_nodes(self):
        text = '你打ZHE2 [B EY1 S] ' + ' '.join(f'[{n}]' for n in NATIVE_EVENTS)
        nodes = parse_script(text)
        self.assertEqual(''.join(n.raw for n in nodes), text)
        self.assertEqual(sum(n.kind == 'native_event' for n in nodes), 13)
        self.assertEqual(sum(n.kind == 'phoneme' for n in nodes), 1)
        self.assertEqual(sum(n.kind == 'pinyin' for n in nodes), 1)
        for node in nodes:
            self.assertEqual(text[node.start:node.end], node.raw)

    def test_segmentation_gain_scope_and_native_preservation(self):
        script = 'Setup. [louder] bass [laughter] [pause 500ms] [quieter] [B EY1 S] ZHE2 [pause 1ms] Normal.'
        plan = compile_script(script, 'bass=[B EY1 S]\nS=oops\nlaughter=bad\nZHE=bad', 'substring')['segments']
        self.assertEqual([s['kind'] for s in plan], ['speech','speech','pause','speech','pause','speech'])
        self.assertEqual([s['gain_db'] for s in plan if s['kind']=='speech'], [0,3,-3,0])
        self.assertEqual(plan[1]['text'], '[B EY1 S] [laughter]')
        self.assertEqual(plan[3]['text'], '[B EY1 S] ZHE2')
        self.assertEqual(plan[2]['samples'],12000)

    def test_all_unknown_and_malformed_controls_block_precisely(self):
        for tag in ['deadpan','sarcastic','amused','angry','irritated','excited','sad','serious','whisper','shout',
                    'sniff','custom','Louder','quieter please','pause','pause 0ms','pause -1ms','pause 1.5ms',
                    'pause 10001ms','pause 01ms','pause 500 ms','PAUSE 500ms','B EY3 S']:
            with self.subTest(tag=tag), self.assertRaisesRegex(ScriptError, 'Line 2, column 3:'):
                compile_script('Hello\n  [' + tag + ']')
        for script in ['[[sigh]]','[sigh',']','<|text_start|>']:
            with self.assertRaises(ScriptError): compile_script(script)

    def test_app_directions_rejected_on_native_routes(self):
        for token in ['[pause 500ms]','[louder]','[quieter]']:
            with self.assertRaisesRegex(ValueError, 'Performance workspace'):
                GenerationRequest(text='Hi ' + token + ' there')

    def test_rule_protection_and_no_direction_injection(self):
        script = 'bass [pause 500ms] [louder] bass [B EY1 S]'
        result = compile_script(script,'bass=base\npause=bad\nlouder=bad\n[pause 500ms]=oops')['segments']
        self.assertEqual(result[1]['samples'],12000)
        self.assertEqual(result[2]['gain_db'],3)
        self.assertEqual(result[2]['text'],'base [B EY1 S]')
        for rules in ['bass=[pause 500ms]','bass=[louder]','bass=[deadpan]','bass=', 'invalid']:
            with self.assertRaises(ScriptError): compile_script(script,rules)

    def test_no_dangling_gain_and_resource_bounds(self):
        for script in ['[louder]','[louder] [quieter] Hi','[louder] [pause 20ms]', ' ']:
            with self.assertRaises(ScriptError): compile_script(script)
        with self.assertRaises(ScriptError): compile_script('[pause 10000ms]' * 13)
        with self.assertRaises(ScriptError): compile_script('Hello [pause 1ms]' * 129)
        with self.assertRaises(ScriptError): compile_script('x' * 100001)
        self.assertEqual(compile_script('[pause 1ms][pause 10000ms]')['segments'][1]['samples'],240000)


class AudioTests(unittest.TestCase):
    def test_exact_pause_24khz_and_edge_padding_removed(self):
        audio, stats = prepare_audio(fixture())
        self.assertEqual((stats['trimmed_start'],stats['trimmed_end']), (2400,4800))
        nodes = [dict(id='a',kind='speech'),dict(id='p',kind='pause',milliseconds=500),dict(id='b',kind='speech')]
        master,timeline = assemble(nodes,lambda _:audio)
        self.assertEqual(len(master),len(audio)*2+12000)
        gap = timeline[1]
        self.assertEqual(gap['end']-gap['start'],12000)
        self.assertTrue(np.all(master[gap['start']:gap['end']]==0))
        self.assertNotEqual(master[gap['start']-1],0)
        self.assertNotEqual(master[gap['end']],0)

    def test_gain_ratios_headroom_and_clipping_prevention(self):
        renders = {gain:prepare_audio(fixture(),gain)[0] for gain in (-3,0,3)}
        self.assertAlmostEqual(float(renders[3][500]/renders[0][500]),10**(3/20),places=6)
        self.assertAlmostEqual(float(renders[-3][500]/renders[0][500]),10**(-3/20),places=6)
        self.assertAlmostEqual(float(renders[0][500]),0.25*MASTER_HEADROOM,places=6)
        for amplitude in [1,2,100]:
            audio,_=prepare_audio(np.full(1000,amplitude),3)
            self.assertLessEqual(float(np.max(np.abs(audio))),PEAK_CEILING+1e-6)
        for value in [np.zeros(100),np.array([np.nan]),np.ones((2,100)),np.ones(10),np.array([])]:
            with self.assertRaises(ValueError): prepare_audio(value)

    def test_smooth_segment_boundaries_without_timing_overlap(self):
        positive,_=prepare_audio(np.ones(1000),3)
        negative,_=prepare_audio(-np.ones(1000),-3)
        nodes=[dict(kind='speech',id='a'),dict(kind='speech',id='b')]
        joined,timeline=assemble(nodes,lambda s:positive if s['id']=='a' else negative)
        self.assertEqual(len(joined),2000)
        self.assertEqual(timeline[1]['start'],1000)
        self.assertLess(float(abs(joined[1000]-joined[999])),0.02)
        self.assertTrue(np.all(np.diff(positive[:120])>0))
        self.assertTrue(np.all(np.diff(positive[-120:])<0))

    def test_leading_trailing_adjacent_pauses_and_determinism(self):
        nodes=[dict(id=str(i),kind='pause',milliseconds=ms) for i,ms in enumerate([1,500,10000])]
        one,timeline=assemble(nodes,lambda _:self.fail('Pause cannot synthesize'))
        two,again=assemble(nodes,lambda _:self.fail('Pause cannot synthesize'))
        self.assertEqual(len(one),10501*24)
        self.assertEqual(one.tobytes(),two.tobytes())
        self.assertEqual(timeline,again)


class ProductionTests(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store=ProductionStore(self.directory.name)
        self.model=Mock()
        self.model.create_voice_clone_prompt.return_value=VoiceClonePrompt(torch.zeros((8,10),dtype=torch.long),'True reference',0.1)
        self.generate=Mock(return_value=[fixture()])
        self.settings=dict(speed=1.2,steps=43,guidance=2.3,denoise=False,seed=100,
            t_shift=0.3,position_temperature=7,class_temperature=0.6,layer_penalty_factor=4,
            language='English',ref_text='True reference',pronunciations='bass=[B EY1 S]')
        self.job=self.store.create('bass [pause 500ms] [louder] Next.',self.settings,b'reference')

    def render_all(self):
        for segment in self.job['segments']:
            if segment['kind']=='speech': self.store.render(self.job['id'],segment['id'],self.model,self.generate)

    def test_pre_migration_production_keeps_retry_with_identical_audio_assets(self):
        job = self.store.read(self.job['id'])
        del job['runtime']['audio_tokenizer']
        self.store.save(job)
        result = self.store.render(job['id'], '0', self.model, self.generate)
        self.assertEqual(result['segments'][0]['state'], 'complete')
        self.assertEqual(result['segments'][0]['seed'], job['segments'][0]['seed'])
        from provenance import compatible_production_runtime, MANIFEST
        for key in ('model_revision', 'expected_package_commit', 'native_app_version'):
            changed = copy.deepcopy(job['runtime']); changed[key] = 'changed'
            self.assertFalse(compatible_production_runtime(changed))
        changed = copy.deepcopy(MANIFEST)
        changed['audio_tokenizer']['sha256']['model.safetensors'] = 'different'
        with patch('provenance.MANIFEST', changed):
            self.assertFalse(compatible_production_runtime(job['runtime']))

    def test_frozen_reference_settings_and_stable_seed(self):
        self.settings.update(seed=999,steps=8,ref_text='Changed')
        self.store.render(self.job['id'],'0',self.model,self.generate)
        self.store.render(self.job['id'],'2',self.model,self.generate)
        requests=[c.args[1] for c in self.generate.call_args_list]
        self.assertEqual([r.seed for r in requests],[100,101])
        for request in requests:
            self.assertEqual((request.speed,request.steps,request.guidance,request.denoise),(1.2,43,2.3,False))
            self.assertEqual((request.t_shift,request.position_temperature,request.class_temperature,request.layer_penalty_factor),(0.3,7,0.6,4))
            self.assertEqual(request.ref_text,'True reference')
            self.assertEqual(request.language,'en')
            self.assertEqual(request.pronunciations,'')
            self.assertNotIn('[pause',request.text)
            self.assertNotIn('[louder]',request.text)
        self.assertEqual(requests[0].text,'[B EY1 S]')
        self.assertEqual(Path(self.job['voice']['reference_path']).read_bytes(),b'reference')

    def test_blank_transcript_and_prompt_are_frozen_across_restart(self):
        job=self.store.create('A[pause 1ms]B',dict(ref_text='',seed=10),b'ref')
        self.model.create_voice_clone_prompt.return_value.ref_text='Resolved transcript.'
        self.store.render(job['id'],'0',self.model,self.generate)
        restarted=ProductionStore(self.directory.name)
        restarted.render(job['id'],'2',self.model,self.generate)
        restarted.render(job['id'],'2',self.model,self.generate)
        self.model.create_voice_clone_prompt.assert_called_once()
        self.assertIsNone(self.model.create_voice_clone_prompt.call_args.kwargs['ref_text'])
        for call in self.generate.call_args_list:
            self.assertEqual(call.kwargs['prompt'].ref_text,'Resolved transcript.')
            self.assertTrue(torch.equal(call.kwargs['prompt'].ref_audio_tokens,torch.zeros((8,10),dtype=torch.long)))
        saved=restarted.read(job['id'])
        self.assertEqual(saved['voice']['resolved_ref_text'],'Resolved transcript.')
        self.assertEqual(saved['segments'][0]['voice']['prompt_sha256'],saved['segments'][2]['voice']['prompt_sha256'])

    def test_bad_auto_transcript_and_changed_prompt_never_synthesize(self):
        self.model.create_voice_clone_prompt.return_value.ref_text='[unknown]'
        job=self.store.render(self.job['id'],'0',self.model,self.generate)
        self.assertEqual(job['segments'][0]['state'],'failed')
        self.generate.assert_not_called()
        self.model.create_voice_clone_prompt.return_value.ref_text='Valid transcript.'
        job=self.store.render(self.job['id'],'0',self.model,self.generate)
        Path(job['prompt']['path']).write_bytes(b'changed')
        self.generate.reset_mock()
        result=self.store.render(self.job['id'],'2',self.model,self.generate)
        self.assertEqual(result['segments'][2]['state'],'failed')
        self.assertIn('reference prompt',result['segments'][2]['last_error'])
        self.generate.assert_not_called()

    def test_zero_seed_resolves_once_and_survives_restart(self):
        job=self.store.create('A[pause 1ms]B',dict(seed=0),b'ref')
        self.assertGreater(job['base_seed'],0)
        restarted=ProductionStore(self.directory.name)
        saved=restarted.read(job['id'])
        self.assertEqual([s['seed'] for s in saved['segments'] if s['kind']=='speech'],[job['base_seed'],job['base_seed']+1])
        restarted.render(job['id'],'2',self.model,self.generate)
        restarted.render(job['id'],'2',self.model,self.generate)
        self.assertEqual(self.generate.call_args_list[-1].args[1].seed,self.generate.call_args_list[-2].args[1].seed)

    def test_retry_isolation_keeps_unrelated_files(self):
        self.render_all()
        before=self.store.rebuild(self.job['id'])
        first=copy.deepcopy(before['segments'][0])
        self.generate.reset_mock()
        after=self.store.render(self.job['id'],'2',self.model,self.generate)
        self.generate.assert_called_once()
        self.assertEqual(after['segments'][0],first)
        self.assertIsNone(after['master'])
        self.assertEqual(after['segments'][2]['seed'],101)
        self.assertNotEqual(after['segments'][2]['output'],before['segments'][2]['output'])

    def test_failed_retry_retains_previous_success_and_master(self):
        self.render_all()
        before=self.store.rebuild(self.job['id'])
        self.generate.side_effect=RuntimeError('Example inference failure')
        after=self.store.render(self.job['id'],'2',self.model,self.generate)
        self.assertEqual(after['master'],before['master'])
        self.assertEqual(after['segments'][2]['output'],before['segments'][2]['output'])
        self.assertEqual(after['segments'][2]['state'],'complete')
        self.assertIn('failure',after['segments'][2]['last_error'])

    def test_failed_initial_segment_does_not_lose_earlier_success(self):
        self.store.render(self.job['id'],'0',self.model,self.generate)
        self.generate.side_effect=RuntimeError('Example failure')
        after=self.store.render(self.job['id'],'2',self.model,self.generate)
        self.assertEqual(after['segments'][0]['state'],'complete')
        self.assertEqual(after['segments'][2]['state'],'failed')
        with self.assertRaises(ValueError): self.store.rebuild(self.job['id'])

    def test_master_rebuild_determinism_and_pause_survival(self):
        self.render_all()
        self.generate.reset_mock()
        first=self.store.rebuild(self.job['id'])
        original=Path(first['master']).read_bytes()
        second=ProductionStore(self.directory.name).rebuild(self.job['id'])
        self.assertEqual(Path(second['master']).read_bytes(),original)
        self.assertEqual(first['timeline'],second['timeline'])
        self.generate.assert_not_called()
        audio,rate=sf.read(second['master'],dtype='float32')
        self.assertEqual(rate,24000)
        pause=second['timeline'][1]
        self.assertEqual(pause['end']-pause['start'],12000)
        self.assertTrue(np.all(audio[pause['start']:pause['end']]==0))
        self.assertEqual(len(audio),14000)

    def test_tampered_reference_or_retained_audio_is_rejected(self):
        self.render_all()
        current=self.store.read(self.job['id'])
        Path(current['segments'][0]['output']).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'retained audio'): self.store.rebuild(self.job['id'])
        Path(current['voice']['reference_path']).write_bytes(b'changed')
        self.generate.reset_mock()
        with self.assertRaisesRegex(ValueError,'reference'): self.store.render(self.job['id'],'2',self.model,self.generate)
        self.generate.assert_not_called()

    def test_interrupted_production_is_recoverable_after_restart(self):
        job=self.store.read(self.job['id'])
        job['segments'][0]['state']='rendering'
        self.store.save(job)
        recovered=ProductionStore(self.directory.name).read(job['id'])
        self.assertEqual(recovered['segments'][0]['state'],'pending')
        self.assertIn('interrupted',recovered['segments'][0]['last_error'])
        self.assertEqual(recovered['segments'][0]['seed'],100)

    def test_engine_and_route_capability_isolation(self):
        for engine in ['F5-TTS','My Voice','Design']:
            with self.assertRaisesRegex(ValueError,'only OmniVoice'): self.store.create('Hi',{},b'ref',engine=engine)
        for extra in [dict(duration=5),dict(instruct='whisper'),dict(segments=['Hi']),dict(retry_index=0)]:
            with self.assertRaises(ValueError): self.store.create('Hi',extra,b'ref')
        for bad in ['../other','bad']:
            with self.assertRaises(ValueError): self.store.read(bad)


class PerformanceHTTPTests(unittest.TestCase):
    setUp=base.GenerationTests.setUp
    post=base.GenerationTests.post

    def test_prepare_render_retry_and_rebuild_through_real_routes(self):
        self.model.generate.return_value=[fixture()]
        self.model.create_voice_clone_prompt.return_value=VoiceClonePrompt(torch.zeros((8,10),dtype=torch.long),'Reference',0.1)
        settings=dict(self.data,pronunciations='bass=[B EY1 S]')
        response=self.post('/performance/prepare',dict(script='bass[pause 500ms][louder] Next.',settings=json.dumps(settings)))
        self.assertEqual(response.status_code,200,response.text)
        job=response.json()
        self.model.generate.assert_not_called()
        for segment_id in ['0','2']:
            result=self.client.post(f"/performance/{job['id']}/render/{segment_id}")
            self.assertEqual(result.status_code,200,result.text)
        self.assertEqual([c.args[0] for c in self.seed.call_args_list],[123,124])
        config=self.model.generate.call_args.kwargs['generation_config']
        self.assertEqual(config.num_step,43)
        self.assertFalse(config.denoise)
        self.assertEqual(self.model.generate.call_args.kwargs['language'],'en')
        count=self.model.generate.call_count
        result=self.client.post(f"/performance/{job['id']}/rebuild")
        self.assertEqual(result.status_code,200,result.text)
        self.assertEqual(self.model.generate.call_count,count)
        self.assertTrue(Path(result.json()['master']).exists())
        self.assertEqual(self.client.get(f"/performance/{job['id']}").status_code,200)

    def test_capabilities_and_reference_markup_are_explicit(self):
        capabilities=self.client.get('/performance/capabilities').json()
        self.assertEqual(capabilities['engines'],['OmniVoice Zero-Shot'])
        self.assertEqual(capabilities['sample_rate'],24000)
        self.assertFalse(capabilities['emotional_acting'])
        for text in ['[unknown]','[pause 500ms]','[louder]','[deadpan]']:
            result=self.post('/generate-clone',dict(self.data,ref_text=text))
            self.assertEqual(result.status_code,422,result.text)
        self.model.generate.assert_not_called()

    def test_editor_errors_and_native_route_rejection(self):
        for script in ['Hi [unknown]','Hi [pause 0ms]','[deadpan]']:
            result=self.client.post('/performance/preview',data=dict(text=script))
            self.assertFalse(result.json()['can_generate'])
            self.assertIn('Line 1, column',result.json()['issues'][0]['message'])
            result=self.post('/performance/prepare',dict(script=script,settings='{}'))
            self.assertEqual(result.status_code,422,result.text)
        for route in ['/generate-clone','/generate-design','/generate-long','/generate-variants','/engine-lab/compare']:
            result=self.post(route,dict(self.data,text='[louder] hello'))
            self.assertEqual(result.status_code,422,result.text)
        self.model.generate.assert_not_called()

    def test_preview_preserves_native_syntax_but_separates_app_nodes(self):
        result=self.client.post('/performance/preview',data=dict(text='bass [pause 500ms] [louder] [laughter] [B EY1 S]',pronunciations='bass=base'))
        self.assertTrue(result.json()['can_generate'],result.text)
        self.assertEqual([s['kind'] for s in result.json()['segments']],['speech','pause','speech'])
        self.assertNotIn('[pause',result.json()['text'])
        self.assertIn('12000 samples',result.json()['text'])
        self.assertIn('[laughter] [B EY1 S]',result.json()['text'])

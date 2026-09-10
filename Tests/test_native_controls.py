"""Native controls tested against the installed package, without loading weights."""
import json
from types import SimpleNamespace, MethodType
from unittest.mock import Mock, patch
import unittest

import test_generation as phase1
from generation import GenerationRequest, OMNI_CAPABILITIES
from speech_text import NATIVE_EVENTS, inspect_speech, apply_pronunciations
from omnivoice.models.omnivoice import OmniVoice, OmniVoiceGenerationConfig, _combine_text, _NONVERBAL_PATTERN


class NativeTextTests(unittest.TestCase):
    def test_all_13_events_exact_and_unchanged(self):
        expected = ('laughter sigh confirmation-en question-en question-ah question-oh question-ei question-yi '
                    'surprise-ah surprise-oh surprise-wa surprise-yo dissatisfaction-hnn').split()
        self.assertEqual(list(NATIVE_EVENTS), expected)
        for event in expected:
            with self.subTest(event=event):
                token = f'[{event}]'
                self.assertIsNotNone(_NONVERBAL_PATTERN.fullmatch(token))
                result = inspect_speech(token)
                self.assertTrue(result['can_generate'], result)
                self.assertEqual(result['text'], token)
                self.assertFalse(result['issues'])

    def test_case_and_padding_are_not_native_tokens(self):
        for event in NATIVE_EVENTS:
            for token in [f'[{event.upper()}]', f'[ {event}]', f'[{event} ]']:
                with self.subTest(token=token):
                    self.assertFalse(inspect_speech(token)['can_generate'])

    def test_unsupported_directions_block_without_deleting(self):
        for token in ('deadpan sarcastic angry amused irritated excited sad serious whisper shout '
                      'louder quieter pause laugh chuckle breath gasp sniff').split() + ['pause 500ms']:
            text = f'Setup [{token}] line.'
            with self.subTest(token=token):
                result = inspect_speech(text)
                self.assertFalse(result['can_generate'])
                self.assertEqual(result['text'], text)
                self.assertIn('not a native', result['issues'][0]['message'])

    def test_valid_cmu_and_pinyin_remain_intact(self):
        text = 'The [B EY1 S] and [K AE0 T] [AH2] 打ZHE2出售 NI3 HAO3.'
        result = inspect_speech(text, 'B=bee\nEY1=bad\nS=ess\nZHE=bad\nNI3=bad', 'substring')
        self.assertTrue(result['can_generate'], result)
        self.assertEqual(result['text'], _combine_text(text))

    def test_invalid_cmu_and_brackets(self):
        for text in ['[B EY3 S]', '[B EY S]', '[B WRONG S]', '[[laughter]]', '[sigh', 'sigh]']:
            with self.subTest(text=text):
                self.assertFalse(inspect_speech(text)['can_generate'])
        self.assertTrue(any('pinyin' in x['message'] for x in inspect_speech('ZHE0')['issues']))

    def test_markdown_and_ordinary_brackets_warn_without_rewriting(self):
        for text in ['**emphasis**', '*stage direction*', '# Heading', '[ordinary note]', '(whispering)']:
            with self.subTest(text=text):
                result = inspect_speech(text)
                self.assertTrue(result['can_generate'])
                self.assertTrue(result['issues'])
                self.assertEqual(result['text'], text)

    def test_default_whole_words_and_explicit_legacy_substrings(self):
        text = 'bass ambassador bassline bass. Bass'
        self.assertEqual(apply_pronunciations(text, 'bass=base'), 'base ambassador bassline base. Bass')
        self.assertEqual(apply_pronunciations(text, 'bass=base', 'substring'), 'base ambaseador baseline base. Bass')
        self.assertEqual(apply_pronunciations('red bass; red bassoon', 'red bass=fish'), 'fish; red bassoon')
        self.assertEqual(apply_pronunciations('打折出售', '折=ZHE2'), '打ZHE2出售')

    def test_rules_cannot_rewrite_native_or_newly_inserted_markup(self):
        for mode in ['words','substring']:
            text = 'bass [laughter] [B EY1 S] ZHE2'
            rules = 'bass=[B EY1 S]\nlaughter=oops\nS=ess\nZHE=bad\n[laughter]=oops'
            self.assertEqual(apply_pronunciations(text, rules, mode), '[B EY1 S] [laughter] [B EY1 S] ZHE2')

    def test_malformed_and_dangerous_rules_are_visible_errors(self):
        for rules in ['no equals', 'bass=', '=base', 'bass=[deadpan]', 'bass=[B EY3 S]', 'bass=<|text_start|>']:
            with self.subTest(rules=rules):
                self.assertFalse(inspect_speech('bass', rules)['can_generate'])
        self.assertTrue(any('repeated source' in i['message'] for i in inspect_speech('bass','bass=base\nbass=fish')['issues']))

    def test_preview_matches_native_whitespace_and_hides_internal_delimiters(self):
        text = '  bass\n\n  [laughter]   [B EY1 S]  打 ZHE2 出售  '
        result = inspect_speech(text, 'bass=base')
        self.assertEqual(result['text'], _combine_text(apply_pronunciations(text,'bass=base')))
        self.assertTrue(any('line breaks' in i['message'] for i in result['issues']))
        result = inspect_speech('<|text_start|>hello')
        self.assertFalse(result['can_generate'])
        self.assertEqual(result['text'], '')

    def test_native_duration_precedence_without_synthesis(self):
        # Exercise the actual installed model's preprocessing method, no weights/inference.
        model = SimpleNamespace(_estimate_target_tokens=Mock(return_value=100),
            audio_tokenizer=SimpleNamespace(config=SimpleNamespace(frame_rate=25)))
        model._ensure_list = MethodType(OmniVoice._ensure_list, model)
        fixed = OmniVoice._preprocess_all(model, 'Hello', speed=1.4, duration=2.0)
        self.assertEqual(model._estimate_target_tokens.call_args.kwargs['speed'], 1.0)
        self.assertEqual(fixed.target_lens, [50])
        model._estimate_target_tokens.reset_mock()
        automatic = OmniVoice._preprocess_all(model, 'Hello', speed=1.4)
        self.assertEqual(model._estimate_target_tokens.call_args.kwargs['speed'], 1.4)
        self.assertEqual(automatic.target_lens, [100])


class NativeRouteTests(unittest.TestCase):
    setUp = phase1.GenerationTests.setUp
    post = phase1.GenerationTests.post

    advanced = dict(duration='2.5', t_shift='0.3', position_temperature='7',
                    class_temperature='0.6', layer_penalty_factor='4')

    def assert_advanced(self, call, duration=2.5):
        kwargs = call.kwargs
        self.assertEqual(kwargs['duration'], duration)
        config = kwargs['generation_config']
        for key, value in self.advanced.items():
            if key != 'duration':
                self.assertEqual(getattr(config, key), float(value))

    def test_advanced_clone_design_and_variants_forward_to_native_config(self):
        for route in ['/generate-clone','/generate-design','/generate-variants']:
            with self.subTest(route=route):
                self.model.reset_mock()
                result = self.post(route, dict(self.data, **self.advanced))
                self.assertEqual(result.status_code, 200, result.text)
                for call in self.model.generate.call_args_list:
                    self.assert_advanced(call)
                    self.assertEqual(call.kwargs['speed'], 1.23)

    def test_advanced_engine_lab_native_both_engines(self):
        trained = Mock()
        trained.create_voice_clone_prompt.return_value = 'prompt'
        trained.generate.return_value = self.model.generate.return_value
        with patch.object(phase1.backend, '_trained_engine_map', return_value={'My Voice':phase1.ROOT.name}), patch.object(phase1.backend.OmniVoice,'from_pretrained',return_value=trained):
            result = self.post('/engine-lab/compare',dict(self.data, **self.advanced,
                engine_a='OmniVoice Zero-Shot',engine_b='My Voice'))
        self.assertEqual(result.status_code,200,result.text)
        self.assert_advanced(self.model.generate.call_args)
        self.assert_advanced(trained.generate.call_args)

    def test_long_and_retry_forward_decoding_controls_without_duration(self):
        advanced = {k:v for k,v in self.advanced.items() if k != 'duration'}
        for extra in [{}, {'retry_index':'1'}]:
            self.model.reset_mock()
            result = self.post('/generate-long', dict(self.data, **advanced, **extra, segments=json.dumps(['One','Two'])))
            self.assertEqual(result.status_code,200,result.text)
            for call in self.model.generate.call_args_list:
                self.assert_advanced(call,duration=None)

    def test_long_duration_is_explicitly_rejected(self):
        result = self.post('/generate-long', dict(self.data, duration='5'))
        self.assertEqual(result.status_code,422,result.text)
        self.model.generate.assert_not_called()
        self.assertNotIn('/generate-long', OMNI_CAPABILITIES['duration_routes'])

    def test_advanced_f5_values_rejected_before_either_engine_runs(self):
        for key,value in self.advanced.items():
            with self.subTest(key=key), patch.object(phase1.backend,'run_f5') as f5:
                result=self.post('/engine-lab/compare',dict(text='Plain',ref_text='Plain reference',
                    engine_a='OmniVoice Zero-Shot',engine_b='F5-TTS', **{key:value}))
                self.assertEqual(result.status_code,422,result.text)
                f5.assert_not_called()
                self.model.generate.assert_not_called()

    def test_range_validation_and_defaults_match_native(self):
        native=OmniVoiceGenerationConfig()
        request=GenerationRequest(text='Hello')
        config=request.omni_kwargs(OmniVoiceGenerationConfig)['generation_config']
        for key in ['t_shift','position_temperature','class_temperature','layer_penalty_factor']:
            self.assertEqual(getattr(config,key),getattr(native,key))
        for key,value in [('duration','0'),('duration','nan'),('duration','601'),('t_shift','0'),
                          ('position_temperature','-1'),('class_temperature','inf'),
                          ('layer_penalty_factor','21'),('pronunciation_mode','unknown')]:
            with self.subTest(key=key,value=value):
                result=self.post('/generate-clone',dict(self.data,**{key:value}))
                self.assertEqual(result.status_code,422,result.text)
                self.model.generate.assert_not_called()

    def test_preview_endpoint_uses_same_rules_as_generation(self):
        text='bass bassline [laughter] [B EY1 S]'
        for mode,expected in [('words','base bassline'),('substring','base baseline')]:
            data=dict(text=text,pronunciations='bass=base',pronunciation_mode=mode)
            preview=self.client.post('/preview-speech',data=data)
            self.assertEqual(preview.status_code,200,preview.text)
            self.assertTrue(preview.json()['text'].startswith(expected))
            result=self.post('/generate-clone',data)
            self.assertEqual(result.status_code,200,result.text)
            self.assertEqual(preview.json()['text'],_combine_text(self.model.generate.call_args.kwargs['text']))

    def test_invalid_later_production_segment_prevents_partial_generation(self):
        result=self.post('/generate-long',dict(self.data,segments=json.dumps(['Valid','[deadpan]'])) )
        self.assertEqual(result.status_code,422,result.text)
        self.model.generate.assert_not_called()
        self.model.create_voice_clone_prompt.assert_not_called()

    def test_safety_cannot_be_bypassed_via_api(self):
        for route in ['/generate-clone','/generate-design','/generate-variants','/generate-long','/engine-lab/compare']:
            with self.subTest(route=route):
                result=self.post(route,dict(self.data,text='[pause 500ms]',engine_a='OmniVoice Zero-Shot',engine_b='F5-TTS'))
                self.assertEqual(result.status_code,422,result.text)
                self.model.generate.assert_not_called()

"""Immutable production plans and retained audio. Only base OmniVoice cloning."""
import hashlib
import json
import re
import secrets
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

import soundfile as sf
from generation import GenerationRequest, OMNI_CAPABILITIES
from omnivoice.models.omnivoice import VoiceClonePrompt
from performance_script import compile_script, parse_script
from performance_audio import SAMPLE_RATE, prepare_audio, assemble
from provenance import MANIFEST, compatible_production_runtime

ENGINE = 'OmniVoice Zero-Shot'
PERFORMANCE_CAPABILITIES = dict(engines=[ENGINE], directions=['pause', 'louder', 'quieter'],
    sample_rate=24000, pause_min_ms=1, pause_max_ms=10000, gain_db=[-3,3],
    fixed_duration=False, emotional_acting=False, retained_segment_retry=True, reference_prompt_cache=True)
LOCK = threading.RLock()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ProductionStore:
    def __init__(self, root):
        self.root = Path(root)

    def folder(self, production_id):
        if not re.fullmatch(r'[0-9a-f]{32}', production_id):
            raise ValueError('Invalid production ID.')
        return self.root / production_id

    def read(self, production_id):
        job = json.loads((self.folder(production_id) / 'production.json').read_text())
        if job['schema'] != 1:
            raise ValueError('Unsupported production schema.')
        # The single-process backend performs synthesis synchronously. A persisted
        # rendering state encountered on a later read represents interrupted work.
        for segment in job['segments']:
            if segment['state'] == 'rendering':
                segment['state'] = 'complete' if segment.get('output') else 'pending'
                segment['last_error'] = 'Previous render was interrupted. Retry uses the frozen reference, settings and seed.'
        return job

    def save(self, job):
        folder = self.folder(job['id'])
        temporary = folder / 'production.pending.json'
        temporary.write_text(json.dumps(job, ensure_ascii=False, indent=2))
        temporary.replace(folder / 'production.json')

    def list(self):
        if not self.root.exists():
            return []
        jobs = []
        for path in self.root.glob('*/production.json'):
            try:
                job = self.read(path.parent.name)
                jobs.append(dict(id=job['id'], created_at=job['created_at'], script=job['script'][:100]))
            except (OSError, ValueError, KeyError):
                continue
        return sorted(jobs, key=lambda item:item['created_at'], reverse=True)

    def create(self, script, settings, reference, filename='reference.wav', engine=ENGINE):
        if engine != ENGINE:
            raise ValueError('Performance production supports only OmniVoice Zero-Shot reference cloning. F5, Design and trained-engine routing are not enabled.')
        if not reference:
            raise ValueError('A reference recording is required.')
        if settings.get('segments') is not None or settings.get('retry_index') is not None:
            raise ValueError('Performance segments are created only by the script parser.')
        plan = compile_script(script, settings.get('pronunciations',''), settings.get('pronunciation_mode','words'))
        speech_text = ' '.join(p['text'] for p in plan['segments'] if p['kind']=='speech') or 'Silence production'
        request = GenerationRequest(**dict(settings, text=speech_text, pronunciations=''))
        if request.instruct or request.duration is not None:
            raise ValueError('Performance cloning does not accept Design instructions or fixed generation duration.')
        speech_count = sum(p['kind']=='speech' for p in plan['segments'])
        base_seed = request.seed or secrets.randbelow(2**63 - 1024) + 1
        if base_seed + speech_count > 2**63 - 5:
            raise ValueError('Performance seed is too large for stable per-segment offsets.')
        production_id = uuid.uuid4().hex
        folder = self.folder(production_id)
        folder.mkdir(parents=True)
        suffix = Path(filename).suffix.lower()
        if suffix not in ('.wav','.mp3','.m4a','.flac','.aiff','.aif','.ogg'):
            suffix = '.wav'
        reference_path = folder / ('reference' + suffix)
        reference_path.write_bytes(reference)
        identity = dict(engine=engine, reference_path=str(reference_path), reference_sha256=digest(reference_path),
                        reference_name=Path(filename).name, ref_text=request.ref_text)
        speech_index = 0
        for index, segment in enumerate(plan['segments']):
            segment.update(id=str(index), state='ready' if segment['kind']=='pause' else 'pending')
            if segment['kind']=='speech':
                frozen = GenerationRequest(**dict(request.model_dump(), text=segment['text'], seed=base_seed+speech_index))
                segment.update(seed=frozen.seed, request=frozen.model_dump(), voice=identity.copy(),
                               capability=dict(OMNI_CAPABILITIES), output=None, output_sha256=None,
                               last_error=None, attempts=0)
                speech_index += 1
        job = dict(schema=1, id=production_id, created_at=datetime.now(timezone.utc).isoformat(),
            script=script, pronunciations=settings.get('pronunciations',''), pronunciation_mode=request.pronunciation_mode,
            voice=identity, runtime=MANIFEST.copy(), base_seed=base_seed, segments=plan['segments'],
            nodes=plan['nodes'], capabilities=PERFORMANCE_CAPABILITIES.copy(), revision=0, master=None, timeline=[])
        self.save(job)
        return job

    def reference_prompt(self, job, model):
        if cached := job.get('prompt'):
            if digest(cached['path']) != cached['sha256']:
                raise ValueError('The retained reference prompt has changed.')
            return VoiceClonePrompt.load(cached['path'])
        prompt = model.create_voice_clone_prompt(ref_audio=job['voice']['reference_path'],
            ref_text=job['voice']['ref_text'].strip() or None, preprocess_prompt=True)
        # Auto-transcribed reference markup is subject to the same strict boundary.
        parse_script(prompt.ref_text)
        path = self.folder(job['id']) / 'reference-prompt.pt'
        temporary = path.with_suffix('.pending.pt')
        prompt.save(str(temporary))
        temporary.replace(path)
        prompt_hash = digest(path)
        job['prompt'] = dict(path=str(path), sha256=prompt_hash, resolved_ref_text=prompt.ref_text)
        job['voice'].update(prompt_sha256=prompt_hash, resolved_ref_text=prompt.ref_text)
        for segment in job['segments']:
            if segment['kind']=='speech':
                segment['voice'].update(prompt_sha256=prompt_hash, resolved_ref_text=prompt.ref_text)
        self.save(job)
        return prompt

    def render(self, production_id, segment_id, model, generate):
        with LOCK:
            job = self.read(production_id)
            segment = next((s for s in job['segments'] if s['id']==segment_id), None)
            if segment is None or segment['kind']!='speech':
                raise ValueError('Select a speech segment to render or retry.')
            if model is None:
                raise ValueError('OmniVoice model is not ready.')
            if not compatible_production_runtime(job['runtime']) or segment['voice']['engine'] != ENGINE:
                raise ValueError('Production runtime or engine differs from the current verified runtime.')
            reference = job['voice']['reference_path']
            if digest(reference) != job['voice']['reference_sha256']:
                raise ValueError('The frozen reference recording has changed.')
            request = GenerationRequest(**segment['request'])
            segment['attempts'] += 1
            segment['last_error'] = None
            segment['state'] = 'rendering'
            self.save(job)
            try:
                prompt = self.reference_prompt(job, model)
                raw = generate(model, request, prompt=prompt)[0]
                processed, stats = prepare_audio(raw, segment['gain_db'])
                # New immutable take: a failed retry never overwrites the last success.
                path = self.folder(production_id) / (segment_id + '-' + uuid.uuid4().hex + '.wav')
                sf.write(path, processed, SAMPLE_RATE, subtype='FLOAT')
                segment.update(output=str(path), output_sha256=digest(path), audio=stats, state='complete')
                job.update(revision=job['revision']+1, master=None, timeline=[])
            except Exception as exc:
                segment.update(state='complete' if segment['output'] else 'failed', last_error=str(exc))
            self.save(job)
            return job

    def rebuild(self, production_id):
        with LOCK:
            job = self.read(production_id)
            def load(segment):
                if not segment.get('output'):
                    raise ValueError('Render all speech segments before rebuilding the master.')
                path = Path(segment['output'])
                if digest(path) != segment['output_sha256']:
                    raise ValueError('A retained audio segment changed. Retry it before rebuilding.')
                audio, rate = sf.read(path, dtype='float32')
                if rate != SAMPLE_RATE:
                    raise ValueError('Retained audio must be 24 kHz.')
                return audio
            joined, timeline = assemble(job['segments'], load)
            # No post-processing after this point: deliberate silence must survive.
            path = self.folder(production_id) / f"master-{job['revision']}.wav"
            temporary = path.with_suffix('.pending.wav')
            sf.write(temporary, joined, SAMPLE_RATE, subtype='FLOAT')
            temporary.replace(path)
            job.update(master=str(path), master_sha256=digest(path), timeline=timeline, master_samples=len(joined))
            self.save(job)
            return job

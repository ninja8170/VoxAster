"""Phase 1 request contract and engine adapters; no synthesis at import time."""
import json
import re
from typing import Optional
from fastapi import Form, HTTPException
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

OMNI_CAPABILITIES = {
    'controls': ['speed', 'steps', 'guidance', 'seed', 'denoise', 'language', 'pronunciations'],
    'native_markup': True, 'voice_design': True,
}
F5_CAPABILITIES = {'controls': ['speed'], 'native_markup': False, 'voice_design': False}


def apply_pronunciations(text, rules):
    # Protect native markup from substring replacements. Newly inserted markup is
    # protected from subsequent rules as well. This is not an acting-tag parser.
    protected = r'(\[[^\[\]]*\]|<\|[^<>]*\|>|[A-Z]+[1-5])'
    for line in rules.splitlines():
        if '=' not in line:
            continue
        original, replacement = (s.strip() for s in line.split('=', 1))
        if not original or not replacement:
            continue
        parts = re.split(protected, text)
        text = ''.join(p if i % 2 else p.replace(original, replacement)
                       for i, p in enumerate(parts))
    return text


class GenerationRequest(BaseModel):
    model_config = ConfigDict(extra='forbid', frozen=True)
    text: str
    ref_text: str = ''
    pronunciations: str = ''
    language: Optional[str] = None
    instruct: str = ''
    speed: float = Field(default=1.0, ge=0.5, le=1.5, allow_inf_nan=False)
    steps: int = Field(default=32, ge=8, le=64)
    guidance: float = Field(default=2.0, ge=0, le=4, allow_inf_nan=False)
    seed: int = Field(default=0, ge=0, le=2**63 - 5)
    denoise: bool = True
    count: int = Field(default=2, ge=2, le=4)
    segments: Optional[list[str]] = None
    retry_index: Optional[int] = Field(default=None, ge=0)

    @field_validator('text')
    @classmethod
    def spoken_text(cls, value):
        if not value.strip():
            raise ValueError('Speech text must not be empty.')
        return value.strip()

    @field_validator('segments')
    @classmethod
    def nonempty_segments(cls, value):
        if value is not None and (not value or any(not s.strip() for s in value)):
            raise ValueError('Production segments must not be empty.')
        return value

    @field_validator('language', mode='before')
    @classmethod
    def resolve_language(cls, value):
        if value is None or value in ('', 'Auto detect', 'Auto'):
            return None
        from omnivoice.models.omnivoice import _resolve_language
        resolved = _resolve_language(value)
        if resolved is None:
            raise ValueError('Unrecognized language selection.')
        return resolved

    @field_validator('instruct')
    @classmethod
    def validate_instruction(cls, value):
        if value.strip():
            from omnivoice.models.omnivoice import _resolve_instruct
            _resolve_instruct(value)
        return value

    def seed_for(self, index=0):
        return self.seed + index if self.seed else 0

    def omni_kwargs(self, config_type, text=None):
        return dict(text=apply_pronunciations(self.text if text is None else text,
                                             self.pronunciations),
                    language=self.language, speed=self.speed,
                    generation_config=config_type(num_step=self.steps,
                        guidance_scale=self.guidance, denoise=self.denoise,
                        preprocess_prompt=True, postprocess_output=True))

    def validate_engine(self, engine):
        if engine != 'F5-TTS':
            return
        # The F5 CLI interprets bracket strings as voice selectors. Never send
        # OmniVoice markup (including pronunciation rules) into that parser.
        if re.search(r'[\[\]]|<\||[A-Z]+[1-5]', self.text + ' ' + self.ref_text):
            raise ValueError('F5-TTS accepts plain text only; remove OmniVoice markup before comparing.')
        if self.pronunciations.strip() or self.instruct.strip() or self.language:
            raise ValueError('F5-TTS does not support OmniVoice pronunciation, language or Design controls.')

    def f5_arguments(self, ref_path, output):
        self.validate_engine('F5-TTS')
        return dict(ref_path=ref_path, ref_text=self.ref_text.strip(),
                    text=self.text, output_path=output, speed=self.speed)


def generation_form(text: str = Form(...), ref_text: str = Form(''),
                    pronunciations: str = Form(''), language: str = Form('Auto detect'),
                    instruct: str = Form(''), speed: float = Form(1.0),
                    steps: int = Form(32), guidance: float = Form(2.0),
                    seed: int = Form(0), denoise: bool = Form(True),
                    count: int = Form(2), segments: Optional[str] = Form(None),
                    retry_index: Optional[int] = Form(None)):
    try:
        return GenerationRequest(text=text, ref_text=ref_text, pronunciations=pronunciations,
            language=language, instruct=instruct, speed=speed, steps=steps,
            guidance=guidance, seed=seed, denoise=denoise, count=count,
            segments=json.loads(segments) if segments is not None else None,
            retry_index=retry_index)
    except (ValidationError, ValueError, TypeError) as exc:
        raise HTTPException(422, detail=str(exc)) from exc

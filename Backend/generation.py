"""Validated generation request contract and engine adapters; no synthesis at import time."""
import json
import re
from typing import Optional, Literal
from fastapi import Form, HTTPException
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

from speech_text import apply_pronunciations, inspect_speech, validate_speech

OMNI_CAPABILITIES = {
    'controls': ['speed', 'steps', 'guidance', 'seed', 'denoise', 'language', 'pronunciations', 'duration', 't_shift', 'position_temperature', 'class_temperature', 'layer_penalty_factor'],
    'native_markup': True, 'voice_design': True,
    'duration_routes': ['/generate-clone', '/generate-design', '/generate-variants', '/engine-lab/compare'],
}
F5_CAPABILITIES = {'controls': ['speed'], 'native_markup': False, 'voice_design': False}


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
    duration: Optional[float] = Field(default=None, gt=0, le=600, allow_inf_nan=False)
    t_shift: float = Field(default=0.1, ge=0.001, le=1, allow_inf_nan=False)
    position_temperature: float = Field(default=5, ge=0, le=20, allow_inf_nan=False)
    class_temperature: float = Field(default=0, ge=0, le=20, allow_inf_nan=False)
    layer_penalty_factor: float = Field(default=5, ge=0, le=20, allow_inf_nan=False)
    pronunciation_mode: Literal['words', 'substring'] = 'words'
    count: int = Field(default=2, ge=2, le=4)
    segments: Optional[list[str]] = None
    retry_index: Optional[int] = Field(default=None, ge=0)

    @field_validator('text')
    @classmethod
    def spoken_text(cls, value):
        if not value.strip():
            raise ValueError('Speech text must not be empty.')
        return value.strip()

    @field_validator('ref_text')
    @classmethod
    def validate_reference_markup(cls, value):
        from performance_script import parse_script
        parse_script(value)  # Validate only; never rewrite the reference transcript.
        return value

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

    @model_validator(mode='after')
    def valid_speech_inputs(self):
        for text in self.segments if self.segments is not None else [self.text]:
            validate_speech(text, self.pronunciations, self.pronunciation_mode)
        return self

    def seed_for(self, index=0):
        return self.seed + index if self.seed else 0

    def omni_kwargs(self, config_type, text=None):
        return dict(text=validate_speech(self.text if text is None else text,
                                             self.pronunciations, self.pronunciation_mode),
                    language=self.language, speed=self.speed, duration=self.duration,
                    generation_config=config_type(num_step=self.steps,
                        guidance_scale=self.guidance, denoise=self.denoise,
                        t_shift=self.t_shift, position_temperature=self.position_temperature,
                        class_temperature=self.class_temperature, layer_penalty_factor=self.layer_penalty_factor,
                        preprocess_prompt=True, postprocess_output=True))

    def validate_engine(self, engine):
        if engine != 'F5-TTS':
            return
        # The F5 CLI interprets bracket strings as voice selectors. Never send
        # OmniVoice markup (including pronunciation rules) into that parser.
        if re.search(r'[\[\]]|<\||[A-Z]+[1-5]', self.text + ' ' + self.ref_text):
            raise ValueError('F5-TTS accepts plain text only; remove OmniVoice markup before comparing.')
        if self.duration is not None or (self.t_shift, self.position_temperature, self.class_temperature, self.layer_penalty_factor) != (0.1, 5, 0, 5):
            raise ValueError('F5-TTS does not support OmniVoice advanced generation controls.')
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
                    duration: Optional[float] = Form(None), t_shift: float = Form(0.1),
                    position_temperature: float = Form(5), class_temperature: float = Form(0),
                    layer_penalty_factor: float = Form(5), pronunciation_mode: str = Form('words'),
                    count: int = Form(2), segments: Optional[str] = Form(None),
                    retry_index: Optional[int] = Form(None)):
    try:
        return GenerationRequest(text=text, ref_text=ref_text, pronunciations=pronunciations,
            language=language, instruct=instruct, speed=speed, steps=steps,
            duration=duration, t_shift=t_shift, position_temperature=position_temperature,
            class_temperature=class_temperature, layer_penalty_factor=layer_penalty_factor, pronunciation_mode=pronunciation_mode,
            guidance=guidance, seed=seed, denoise=denoise, count=count,
            segments=json.loads(segments) if segments is not None else None,
            retry_index=retry_index)
    except (ValidationError, ValueError, TypeError) as exc:
        raise HTTPException(422, detail=str(exc)) from exc

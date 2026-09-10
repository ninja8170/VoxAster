"""Lossless syntax nodes; application directions are never model input."""
from dataclasses import dataclass, asdict
import re

NATIVE_EVENTS = (
    'laughter', 'sigh', 'confirmation-en', 'question-en', 'question-ah',
    'question-oh', 'question-ei', 'question-yi', 'surprise-ah', 'surprise-oh',
    'surprise-wa', 'surprise-yo', 'dissatisfaction-hnn',
)
UNSUPPORTED = set('deadpan sarcastic angry amused irritated excited sad serious whisper shout louder quieter pause laugh chuckle breath gasp sniff conversational annoyed shouting chuckling throat_clear'.split())
VOWELS = set('AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW'.split())
CONSONANTS = set('B CH D DH F G HH JH K L M N NG P R S SH T TH V W Y Z ZH'.split())
PHONEMES = CONSONANTS | {v + stress for v in VOWELS for stress in '012'}
PROTECTED = re.compile(r'(\[[^\[\]]*\]|<\|[^<>]*\|>|[A-Z]+[1-5])')
BRACKETS = re.compile(r'\[([^\[\]]*)\]')


def cmu_valid(content):
    tokens = content.split()
    return bool(tokens) and all(t in PHONEMES for t in tokens)


@dataclass(frozen=True)
class Node:
    kind: str
    raw: str
    start: int
    end: int
    value: int = 0

class ScriptError(ValueError):
    def __init__(self, text, offset, message):
        self.offset = offset
        self.line = text.count('\n', 0, offset) + 1
        self.column = offset - text.rfind('\n', 0, offset)
        super().__init__(f"Line {self.line}, column {self.column}: {message}")


def parse_script(text, allow_performance=False):
    if len(text) > 100_000:
        raise ScriptError(text, 0, 'Script exceeds 100,000 characters.')
    nodes = []
    cursor = 0
    marker = re.compile(r'\[|\]|<\||\|>|[A-Z]+[1-5]')
    while cursor < len(text):
        match = marker.search(text, cursor)
        if match is None:
            nodes.append(Node('text', text[cursor:], cursor, len(text)))
            break
        start = match.start()
        if start > cursor:
            nodes.append(Node('text', text[cursor:start], cursor, start))
        raw = match.group()
        end = match.end()
        if raw in ('<|', '|>'):
            raise ScriptError(text, start, 'Internal model delimiters are not allowed.')
        if raw == ']':
            raise ScriptError(text, start, 'Unexpected closing bracket.')
        if raw == '[':
            close = text.find(']', end)
            if close < 0 or '[' in text[end:close]:
                raise ScriptError(text, start, 'Unclosed or nested bracket control.')
            end = close + 1
            raw = text[start:end]
            content = raw[1:-1]
            if content in NATIVE_EVENTS:
                kind, value = 'native_event', 0
            elif cmu_valid(content):
                kind, value = 'phoneme', 0
            elif content in ('louder', 'quieter'):
                kind, value = 'gain', 3 if content == 'louder' else -3
            elif pause := re.fullmatch(r'pause ([1-9][0-9]*)ms', content):
                if len(pause[1]) > 5 or not 1 <= int(pause[1]) <= 10_000:
                    raise ScriptError(text, start, 'Pause must be an integer from 1 to 10000 ms.')
                kind, value = 'pause', int(pause[1])
            else:
                raise ScriptError(text, start, f'Unknown or malformed control {raw}. Use exact native events, valid CMU, [pause Nms], [louder] or [quieter]; emotional acting tags are not supported.')
            if kind in ('gain', 'pause') and not allow_performance:
                raise ScriptError(text, start, f'{raw} is an app-level direction. Use the Performance workspace; it is not native OmniVoice syntax.')
        else:
            kind, value = 'pinyin', 0
        nodes.append(Node(kind, raw, start, end, value))
        cursor = end
    return nodes


def compile_script(text, rules='', mode='words'):
    # Import after the lexical module is initialized; pronunciation never sees
    # direction nodes. Replacements cannot create new structural directions.
    from speech_text import inspect_speech, rule_issues
    if mode not in ('words', 'substring'):
        raise ScriptError(text, 0, 'Unknown pronunciation match mode.')
    errors = [i['message'] for i in rule_issues(rules) if i['level']=='error']
    if errors:
        raise ScriptError(text, 0, 'Pronunciation rules: ' + '; '.join(errors))
    nodes = parse_script(text, allow_performance=True)
    pieces, pending = [], []
    gain = 0
    gain_node = None
    def flush():
        nonlocal pending, gain, gain_node
        raw = ''.join(n.raw for n in pending)
        if raw.strip():
            inspected = inspect_speech(raw, rules, mode)
            if not inspected['can_generate']:
                raise ScriptError(text, pending[0].start, 'Speech/replacement validation: ' + '; '.join(i['message'] for i in inspected['issues'] if i['level'] == 'error'))
            pieces.append(dict(kind='speech', source=raw, text=inspected['text'],
                gain_db=gain, start=pending[0].start, end=pending[-1].end, issues=inspected['issues']))
            gain = 0
            gain_node = None
        pending = []
    for node in nodes:
        if node.kind in ('gain','pause'):
            flush()
            if gain_node is not None:
                raise ScriptError(text, gain_node.start, 'A loudness direction needs speech before the next performance direction.')
            if node.kind == 'gain':
                gain, gain_node = node.value, node
            else:
                pieces.append(dict(kind='pause', milliseconds=node.value, samples=node.value * 24,
                    start=node.start, end=node.end))
        else:
            pending.append(node)
    flush()
    if gain_node is not None:
        raise ScriptError(text, gain_node.start, 'A loudness direction needs following speech.')
    if not pieces:
        raise ScriptError(text, 0, 'Enter speech or an explicit pause.')
    if len(pieces) > 256 or sum(p.get('milliseconds',0) for p in pieces) > 120_000:
        raise ScriptError(text, 0, 'Maximum 256 segments and 120 seconds of explicit pauses per production.')
    return dict(nodes=[asdict(n) for n in nodes], segments=pieces)

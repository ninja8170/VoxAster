"""Native speech syntax checks and preview; not a performance-direction parser."""
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


def syntax_issues(text):
    issues = []
    def add(level, message):
        issues.append({'level': level, 'message': message})
    if '<|' in text or '|>' in text:
        add('error', 'Internal model delimiters are not allowed in speech text.')
    remainder = BRACKETS.sub('', text)
    if '[' in remainder or ']' in remainder:
        add('error', 'Unbalanced or nested brackets. Check native event or CMU pronunciation markup.')
    for match in BRACKETS.finditer(text):
        content = match.group(1)
        if content in NATIVE_EVENTS or cmu_valid(content):
            continue
        lower = content.strip().lower()
        if lower in NATIVE_EVENTS:
            add('error', f'Native events require exact lowercase syntax: [{lower}].')
        elif re.split(r'[\s:]', lower, maxsplit=1)[0] in UNSUPPORTED:
            add('error', f'[{content}] is not a native OmniVoice acting control and may be spoken literally. Edit or remove it explicitly.')
        elif re.fullmatch(r'[A-Z0-9\s]+', content) and any(t in PHONEMES or re.fullmatch(r'[A-Z]+\d', t) for t in content.split()):
            add('error', f'Invalid CMU phonemes in [{content}]. Use uppercase CMU symbols, with vowel stress 0, 1 or 2.')
        else:
            add('warning', f'[{content}] is not a verified native event or valid CMU override; its contents may be spoken literally.')
    if re.search(r'\*\*[^*\n]+\*\*|(?<!\*)\*[^*\n]+\*(?!\*)', text):
        add('warning', 'Asterisks/Markdown do not control emphasis or acting. They reach the model and may be spoken literally.')
    if re.search(r'(?m)^\s{0,3}(?:#{1,6}\s|[-*]\s|```)|\[[^\]]+\]\([^)]*\)', text):
        add('warning', 'Markdown formatting is not interpreted as speech direction; no formatting is silently removed.')
    if re.search(r'\((?:whisper\w*|sarcastic\w*|deadpan|angry|pause\b)[^)]*\)', text, re.I):
        add('warning', 'Parenthetical stage directions remain speech text and may be spoken literally.')
    if re.search(r'[A-Z]+[06-9](?!\d)', BRACKETS.sub('', text)):
        add('warning', 'Possible malformed pinyin tone: native pinyin uses uppercase syllables with tone numbers 1–5.')
    if '\n' in text or '\r' in text:
        add('warning', 'OmniVoice removes line breaks; use spaces between sentences. Blank lines do not specify pauses.')
    return issues


def rule_issues(rules):
    issues = []
    seen = set()
    for index, line in enumerate(rules.splitlines(), 1):
        if not line.strip():
            continue
        if '=' not in line:
            issues.append({'level':'error','message':f'Rule {index}: use original=replacement.'})
            continue
        original, replacement = (s.strip() for s in line.split('=', 1))
        if not original or not replacement:
            issues.append({'level':'error','message':f'Rule {index}: both sides are required; empty rules do not delete text.'})
        if original in seen:
            issues.append({'level':'warning','message':f'Rule {index}: repeated source; rules run in order.'})
        seen.add(original)
        issues.extend(syntax_issues(replacement))
        if PROTECTED.fullmatch(original):
            issues.append({'level':'warning','message':f'Rule {index}: native markup is protected and cannot be replaced.'})
    return issues


def apply_pronunciations(text, rules, mode='words'):
    for line in rules.splitlines():
        if '=' not in line:
            continue
        original, replacement = (s.strip() for s in line.split('=', 1))
        if not original or not replacement:
            continue
        # Whole word/phrase matching by default; substring mode is explicit.
        boundary = r'A-Za-z0-9_'
        left = rf'(?<![{boundary}])' if original[0].isascii() and (original[0].isalnum() or original[0] == '_') else ''
        right = rf'(?![{boundary}])' if original[-1].isascii() and (original[-1].isalnum() or original[-1] == '_') else ''
        pattern = re.compile(left + re.escape(original) + right)
        parts = PROTECTED.split(text)
        text = ''.join(p if i % 2 else (p.replace(original, replacement) if mode == 'substring'
                        else pattern.sub(lambda _: replacement, p)) for i,p in enumerate(parts))
    return text


def inspect_speech(text, rules='', mode='words'):
    from omnivoice.models.omnivoice import _combine_text
    issues = rule_issues(rules) + syntax_issues(text)
    processed = apply_pronunciations(text, rules, mode)
    issues += syntax_issues(processed)
    unique = list({(x['level'],x['message']):x for x in issues}.values())
    # Preview is target text only, never the reference or model prompt envelope.
    preview = '' if '<|' in processed or '|>' in processed else _combine_text(processed)
    return {'text':preview, 'issues':unique,
            'can_generate':not any(x['level']=='error' for x in unique)}


def validate_speech(text, rules='', mode='words'):
    result = inspect_speech(text, rules, mode)
    errors = [x['message'] for x in result['issues'] if x['level']=='error']
    if errors:
        raise ValueError('\n'.join(errors))
    return apply_pronunciations(text, rules, mode)

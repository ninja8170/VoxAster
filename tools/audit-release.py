#!/usr/bin/env python3
"""Read-only publication checks. Prints locations, never matched secret values.

Heuristics cannot certify absence of secrets. Review findings and commit identity
metadata separately; never assume .gitignore removes historical content.
"""
import ast
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'GitHub token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})',
    'AWS key': rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'Google key': rb'AIza[A-Za-z0-9_-]{30,}',
    'Hugging Face token': rb'\bhf_[A-Za-z0-9]{25,}',
    'secret assignment': rb'(?i)(?:api[_-]?key|client[_-]?secret|password|access[_-]?token)\s*[:=]\s*[\x22\x27][A-Za-z0-9_+/=-]{16,}[\x22\x27]',
    'personal absolute path': rb'/' + rb'(?:Users|home)/[^\s/\x22\x27]+/',
    'credential URL': rb'https?://[^/\s:@]+:[^/\s@]+@',
    'private network URL': rb'https?://(?:10\.[\d.]+|192\.168\.[\d.]+|[^/\s]+\.(?:internal|local))[:/]',
}

# Published licensor contact in the unmodified Meta licence/AUP; not a contributor identity.
PUBLIC_LICENSOR_CONTACTS = {b'llamausereport' + b'@meta.com'}

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def scan(data, label):
    findings = []
    for name, pattern in PATTERNS.items():
        if re.search(pattern, data):
            findings.append(f'{name}: {label}')
    emails = re.findall(rb'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', data)
    if any(not email.lower().endswith(b'@users.noreply.github.com') and email.lower() not in PUBLIC_LICENSOR_CONTACTS for email in emails):
        findings.append(f'non-noreply email requires review: {label}')
    return findings


def main():
    findings = []
    paths = set(git('ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0')) - {''}
    files = 0
    for relative in sorted(paths):
        path = ROOT / relative
        if not path.is_file():
            continue  # deleted working-tree file
        files += 1
        data = path.read_bytes()
        findings.extend(scan(data, relative))
        if path.suffix == '.py':
            ast.parse(data, filename=relative)
        if path.suffix == '.command':
            subprocess.run(['zsh', '-n', str(path)], check=True)
        if path.suffix == '.md':
            for target in re.findall(r'\]\(([^)]+)\)', data.decode()):
                target = target.split('#', 1)[0]
                if not target or '://' in target or target.startswith('mailto:'):
                    continue
                if not (path.parent / target).exists():
                    findings.append(f'broken documentation link: {relative} -> {target}')
        if len(data) > 1_000_000:
            findings.append(f'large source file needs review: {relative}')
        if path.suffix.lower() in {'.wav', '.mp3', '.m4a', '.safetensors', '.pyc', '.p12', '.pem', '.key'}:
            findings.append(f'private/generated artifact: {relative}')
    blobs = 0
    metadata = 0
    for entry in git('rev-list', '--objects', '--all').decode().splitlines():
        oid, _, relative = entry.partition(' ')
        kind = git('cat-file', '-t', oid).strip()
        if kind in (b'blob', b'commit', b'tag'):
            blobs += kind == b'blob'
            metadata += kind != b'blob'
            findings.extend(scan(git('cat-file', '-p', oid), f'history {kind.decode()} {oid[:12]} {relative}'))
    identities = set(git('log', '--all', '--format=%ae%n%ce').decode().splitlines())
    print(f'Inspected {files} working-tree files and {blobs} reachable history blobs plus {metadata} commit/tag objects.')
    print(f'{len(identities)} Git email identity/identities require owner review; values omitted.')
    for finding in sorted(set(findings)):
        print('REVIEW:', finding)
    print('PASS: heuristic checks, Python parsing, shell syntax and documentation links' if not findings else 'FAIL: review findings above')
    return bool(findings)

if __name__ == '__main__':
    sys.exit(main())

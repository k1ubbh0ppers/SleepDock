#!/usr/bin/env python3
"""Check publishable source files without reading user profiles or running power actions."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {'.git', '.build', 'build', 'dist', 'node_modules', '__pycache__'}
PATTERNS = {
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'GitHub credential': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'AWS access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'API key': re.compile(r'\bsk-[A-Za-z0-9_-]{20,}\b'),
    'personal absolute path': re.compile(r'(?:/(?:Users|home)/[^\s/]+/|[A-Za-z]:\\+Users\\+[^\\\s]+\\+)'),
}
issues = []
checked = 0
for file in sorted(ROOT.rglob('*')):
    relative = file.relative_to(ROOT)
    if any(part in EXCLUDED for part in relative.parts) or not file.is_file():
        continue
    checked += 1
    if file.stat().st_size > 10 * 1024 * 1024:
        issues.append(f'{relative}: file larger than 10 MiB; attach binaries to Releases')
    if file == Path(__file__).resolve():
        continue  # Detection fixtures below are expressions, never credentials.
    try:
        source = file.read_text(encoding='utf-8')
    except UnicodeError:
        continue
    for label, pattern in PATTERNS.items():
        if pattern.search(source):
            issues.append(f'{relative}: {label}')
if issues:
    print('\n'.join(issues), file=sys.stderr)
    sys.exit(1)
print(f'PASS publish source check: {checked} files; no matched credentials, personal absolute paths, or large binaries')

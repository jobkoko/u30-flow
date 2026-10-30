"""Inspect tracked files for common credentials, personal paths and runtime artifacts.

This is a publication guard, not a guarantee that all possible secrets are detected.
It reports filenames and line numbers, never the matching secret value.
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RULES = {
    'private-key': re.compile(r'-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----'),
    'github-token': re.compile(r'\bgh[pousr]_[A-Za-z0-9_]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b'),
    'credential-url': re.compile(r'https?://[^\s\"\'<>]+[?&](?:token|secret|password|access_token)=[^\s\"\'<>]+', re.I),
    'embedded-vmess': re.compile(r'vmess://[A-Za-z0-9+/=]{24,}'),
    'authorized-public-key': re.compile(r'^ssh-(?:ed25519|rsa) [A-Za-z0-9+/=]{50,}', re.M),
    'personal-home-path': re.compile(r'/(?:Users|home)/[A-Za-z0-9][A-Za-z0-9._-]*(?:/|$)'),
}
FORBIDDEN = {'config.json', 'config.local.json', 'subscription.url', 'usage.json', 'last-snapshot.json', 'latest-state.json', 'known_hosts', 'monitor_ed25519', 'monitor_ed25519.pub'}


def main():
    raw = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT)
    files = [x.decode() for x in raw.split(b'\0') if x]
    if not files:
        raise SystemExit('No tracked files: stage the intended source files first.')
    errors = []
    for name in files:
        path = ROOT / name
        if path.is_symlink() or path.name in FORBIDDEN or path.suffix in {'.pcap', '.pcapng', '.pem', '.key', '.tsv', '.log'}:
            errors.append((name, 0, 'runtime-or-key-artifact'))
            continue
        try:
            text = path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            errors.append((name, 0, 'unexpected-binary'))
            continue
        for rule, pattern in RULES.items():
            for match in pattern.finditer(text):
                errors.append((name, text.count('\n', 0, match.start()) + 1, rule))
    if errors:
        for name, line, rule in errors:
            print(f'{name}:{line}: {rule}')
        return 1
    print(f'Publication guard passed: {len(files)} tracked text files.')
    return 0


if __name__ == '__main__':
    sys.exit(main())

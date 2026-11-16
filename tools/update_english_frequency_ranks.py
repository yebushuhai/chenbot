#!/usr/bin/env python3
"""Extract practice-item ranks from the pinned, separately downloaded list."""

import hashlib
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = '7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506'


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 tools/update_english_frequency_ranks.py /path/to/en_full.txt')
    source = Path(sys.argv[1])
    digest = hashlib.sha256()
    with source.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != SOURCE_SHA256:
        raise SystemExit('Unexpected source checksum; no output written')
    dart = (ROOT / 'lib/english_level.dart').read_text(encoding='utf-8')
    words = re.findall(r"EnglishQuestion\(\s*'([^']+)'", dart)
    if not words or len(words) != len(set(words)):
        raise SystemExit('No practice words or duplicate practice words found')
    wanted = set(words)
    ranks = {}
    with source.open(encoding='utf-8') as stream:
        for rank, line in enumerate(stream, 1):
            word = line.split(' ', 1)[0]
            if word in wanted:
                ranks[word] = rank
    missing = wanted - ranks.keys()
    if missing:
        raise SystemExit('No source rank for: ' + ', '.join(sorted(missing)))
    header = '''// SPDX-License-Identifier: CC-BY-SA-4.0
// Derived from FrequencyWords, English OpenSubtitles 2018 word-form frequencies.
// Source: https://github.com/hermitdave/FrequencyWords
// Data license: https://creativecommons.org/licenses/by-sa/4.0/
// Modified: extracted the one-based line ranks for Chenbot's hand-written items.
// Full provenance, pinned source and limitations: docs/english-frequency-data.md.

const Map<String, int> englishSubtitleRanks = {
'''
    rows = ''.join(f"  '{word}': {ranks[word]},\n" for word in sorted(words))
    (ROOT / 'lib/english_frequency_data.dart').write_text(header + rows + '};\n', encoding='utf-8')
    print(f'Extracted {len(ranks)} source word-form ranks.')


if __name__ == '__main__':
    main()

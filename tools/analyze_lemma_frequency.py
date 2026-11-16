#!/usr/bin/env python3
"""Experimental dictionary-filtered lemma frequencies; not vocabulary difficulty."""
import argparse
import bisect
import csv
import gzip
import hashlib
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = '7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506'
INFLECTIONS = ROOT / 'assets/vocabulary/english_inflections.csv.gz'


def run(source, words):
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        raise SystemExit('Unexpected FrequencyWords source checksum')
    groups = defaultdict(set)
    with gzip.open(INFLECTIONS, 'rt', encoding='utf8', newline='') as data:
        for row in csv.reader(data):
            if len(row) < 3 or row[1] not in ('noun', 'verb', 'adj'):
                continue
            lemma = row[0].strip().lower()
            forms = [lemma] + [form.strip().lower() for col in row[2:]
                               for form in col.split('/') if form.strip()]
            for form in forms:
                groups[form].add(lemma)
    totals = Counter()
    raw = {}
    excluded = 0
    with source.open(encoding='utf8') as data:
        for rank, line in enumerate(data, 1):
            form, count = line.rstrip('\n').rsplit(' ', 1)
            count = int(count)
            if form in words:
                raw[form] = (rank, count)
            candidates = groups.get(form, set())
            if form in candidates:
                lemma = form
            elif len(candidates) == 1:
                lemma = next(iter(candidates))
            else:
                excluded += 1
                continue
            totals[lemma] += count
    descending = sorted((-count for count in totals.values()))
    print(f'Eligible lemma strings: {len(totals)}; excluded word forms: {excluded}')
    print('word,original_word_form_line,original_form_count,lemma_rank_lower,lemma_rank_upper,lemma_total_count')
    for word in words:
        rank, raw_count = raw.get(word, ('', ''))
        count = totals.get(word)
        if count is None:
            print(f'{word},{rank},{raw_count},not-covered,not-covered,')
            continue
        lo = bisect.bisect_left(descending, -count) + 1
        hi = bisect.bisect_right(descending, -count)
        print(f'{word},{rank},{raw_count},{lo},{hi},{count}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('frequencywords_file', type=Path)
    parser.add_argument('words', nargs='+')
    args = parser.parse_args()
    run(args.frequencywords_file, [word.lower() for word in args.words])


if __name__ == '__main__':
    main()

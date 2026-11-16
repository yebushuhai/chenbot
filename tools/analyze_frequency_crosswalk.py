#!/usr/bin/env python3
"""Reproduce the word-form/lemma-candidate crosswalk; not a vocabulary test."""
import csv
import gzip
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets/vocabulary'
CHECKPOINTS = (1000, 3000, 5000, 10000, 20000, 30000, 50000, 100000, 200000)


def main():
    form_lemmas = defaultdict(set)
    with gzip.open(ASSETS / 'english_inflections.csv.gz', 'rt', encoding='utf8') as source:
        for row in csv.reader(source):
            if len(row) < 3 or row[1] not in ('noun', 'verb', 'adj'):
                continue
            lemma = row[0].strip().lower()
            for form in [lemma] + [part.strip().lower() for column in row[2:]
                                    for part in column.split('/') if part.strip()]:
                form_lemmas[form].add(lemma)
    candidates, covered, ambiguous = set(), 0, 0
    print('form_rank,candidate_units,recognized_forms,ambiguous_forms')
    with gzip.open(ASSETS / 'english_subtitles_top200k.txt.gz', 'rt', encoding='utf8') as source:
        for rank, line in enumerate(source, 1):
            form = line.strip().lower()
            choices = form_lemmas.get(form, set())
            covered += bool(choices)
            if form in choices:
                candidate = form
            elif len(choices) == 1:
                candidate = next(iter(choices))
            else:
                ambiguous += len(choices) > 1
                candidate = form  # Keep ambiguous/unrecognized forms as-is.
            candidates.add(candidate)
            if rank in CHECKPOINTS:
                print(f'{rank},{len(candidates)},{covered},{ambiguous}')


if __name__ == '__main__':
    main()

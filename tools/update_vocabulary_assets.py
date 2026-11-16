#!/usr/bin/env python3
"""Build the bundled frequency list and copy the pinned morphology source."""
import gzip
import hashlib
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
FREQ_HASH = '7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506'
INFL_HASH = '8c44bd5bec62488bef043f98b0cab022a431d6cb03954864ea70334530908ba7'


def check(path, digest):
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit(f'Unexpected source checksum: {path}')


def main():
    if len(sys.argv) != 3:
        raise SystemExit('Usage: update_vocabulary_assets.py en_full.txt infl_lu.csv.gz')
    source, inflections = map(Path, sys.argv[1:])
    check(source, FREQ_HASH)
    check(inflections, INFL_HASH)
    target = ROOT / 'assets/vocabulary'
    target.mkdir(parents=True, exist_ok=True)
    for limit in (200000, 500000):
        name = f'english_subtitles_top{limit // 1000}k.txt.gz'
        with source.open(encoding='utf8') as src, (target / name).open('wb') as dest:
            with gzip.GzipFile(filename='', fileobj=dest, mode='wb', mtime=0) as compressed:
                for index, line in enumerate(src):
                    if index >= limit:
                        break
                    compressed.write((line.rsplit(' ', 1)[0] + '\n').encode('utf8'))
    shutil.copyfile(inflections, target / 'english_inflections.csv.gz')
    print('Rebuilt pinned vocabulary assets.')


if __name__ == '__main__':
    main()

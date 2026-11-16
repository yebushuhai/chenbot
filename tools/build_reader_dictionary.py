#!/usr/bin/env python3
"""Create the offline ECDICT subset for the two bundled reading articles.

Usage: python3 tools/build_reader_dictionary.py /path/to/ecdict.csv
The upstream CSV is pinned and hash checked. See docs/reading-sources.md.
"""
import csv
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / 'assets' / 'reader'
SOURCE_SHA256 = 'd1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc'
WORD = re.compile(r"\b\d+(?:st|nd|rd|th)\b|[A-Za-z]+(?:['’][A-Za-z]+)*")
TITLES = ('Treaty of Nanking', 'In Event of Moon Disaster')

# Historical names and abbreviations in these particular documents need their
# historical sense rather than an unrelated general dictionary homograph.
HISTORICAL = {
    'aldrin': ('奥尔德林；此处指阿波罗 11 号航天员埃德温·巴兹·奥尔德林。', 'Edwin “Buzz” Aldrin, an Apollo 11 astronaut.'),
    'armstrong': ('阿姆斯特朗；此处指阿波罗 11 号航天员尼尔·阿姆斯特朗。', 'Neil Armstrong, an Apollo 11 astronaut.'),
    'canton': ('广州；此处使用广州的旧式英文名称 Canton。', 'A historical English name for Guangzhou.'),
    'disaster': ('灾难；造成严重损害或损失的事件。', 'A serious event that causes great damage or loss.'),
    'event': ('事件；发生的事情。', 'Something that happens; an occurrence.'),
    'chapoo': ('乍浦，浙江的一座港口；旧式英文地名。', 'The historical English name for Zhapu, a port in Zhejiang.'),
    'c': ('此处用于旧式缩写“&c.”，意思是“等等”。', 'Part of the historical abbreviation “&c.”, meaning et cetera.'),
    'chinhae': ('镇海，浙江宁波附近的地点；旧式英文地名。', 'The historical English name for Zhenhai near Ningbo.'),
    'chusan': ('舟山群岛；旧式英文地名。', 'The historical English name for the Zhoushan islands.'),
    'cohong': ('公行；清代广州获准经营对外贸易的商人组织。', 'A group of licensed Chinese merchants involved in foreign trade at Canton.'),
    'cornwallis': ('康华利士号；此处指签订条约的英国军舰。', 'The British ship on which the treaty was signed.'),
    'elepoo': ('伊里布；清朝全权大臣。', 'Yilibu, a Qing imperial commissioner.'),
    'foochowfoo': ('福州府；旧式英文地名。', 'A historical English name for Fuzhou.'),
    'keying': ('耆英；清朝全权大臣。', 'Qiying, a Qing imperial commissioner.'),
    'kong': ('“Hong Kong”的后一部分；此处指香港。', 'The second part of Hong Kong, a place name.'),
    'koolangsoo': ('鼓浪屿；厦门附近的岛屿，旧式英文名。', 'The historical English name for Gulangyu, an island near Xiamen.'),
    'kwang': ('“Taou-Kwang” 的后一部分；此处指道光帝。', 'The second part of Taou-Kwang, a historical spelling of Daoguang.'),
    "m's": ('Her Majesty’s 的缩写，即“女王陛下的”。', 'An abbreviation of Her Majesty’s.'),
    'majesty': ('陛下；对君主的尊称，也可表示庄严或威严。', 'A title used to address a sovereign; also dignity or grandeur.'),
    "majesty's": ('陛下的；Majesty 的所有格。', 'The possessive form of Majesty.'),
    'ningpo': ('宁波；旧式英文地名。', 'A historical English spelling of Ningbo.'),
    'neil': ('尼尔；此处是航天员尼尔·阿姆斯特朗的名字。', 'The given name of astronaut Neil Armstrong.'),
    'others': ('其他人；其余的人或事物。', 'Other people or things; the remaining ones.'),
    'pottinger': ('璞鼎查；此处指英国全权代表亨利·璞鼎查。', 'Henry Pottinger, the British plenipotentiary who signed the treaty.'),
    'r': ('此处为 Regina 的缩写，意为“女王”，用于维多利亚的签名。', 'An abbreviation of Regina, meaning queen, in Victoria’s signature.'),
    'taou': ('“Taou-Kwang” 的前一部分；此处指道光帝。', 'The first part of Taou-Kwang, a historical spelling of Daoguang.'),
    'subjects': ('臣民；此处指处于君主统治下的人民，是 subject 的复数。', 'People under the authority of a sovereign; plural of subject.'),
    'victoria': ('维多利亚；此处指英国女王维多利亚。', 'Victoria, Queen of the United Kingdom.'),
}

SUPPLEMENTAL_EXAMPLES = {
    'event': 'The event attracted international attention.',
    'disaster': 'The mission returned safely, avoiding disaster.',
    "m's": "Sir Henry Pottinger served as Her M's plenipotentiary.",
    'r': 'The document was signed “Victoria R.”',
}


def clean(value):
    return (value or '').replace('\\n', '\n').strip()


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != SOURCE_SHA256:
        raise SystemExit('Unexpected ECDICT source hash: ' + digest)

    words = set()
    for name in ('nanking', 'moon_disaster'):
        article = json.loads((READER / (name + '.json')).read_text(encoding='utf-8'))
        for paragraph in article['paragraphs']:
            words.update(m.group().lower().replace('’', "'") for m in WORD.finditer(paragraph))
    for title in TITLES:
        words.update(m.group().lower().replace('’', "'") for m in WORD.finditer(title))
    bases = {w[:-2] for w in words if w.endswith("'s")}
    wanted = words | bases
    entries = {}
    with source.open(encoding='utf-8', newline='') as f:
        for row in csv.DictReader(f):
            key = (row.get('word') or '').lower().replace('’', "'")
            if key not in wanted:
                continue
            zh, en = clean(row.get('translation')), clean(row.get('definition'))
            if not zh and not en:
                continue
            entry = {'zh': zh, 'en': en, 'phonetic': clean(row.get('phonetic'))}
            exchange = row.get('exchange') or ''
            base_match = re.search(r'(?:^|/)0:([^/]+)', exchange)
            if base_match:
                entry['base'] = base_match.group(1)
            # Prefer a record with Chinese meaning over a duplicate without it.
            if key not in entries or (not entries[key]['zh'] and zh):
                entries[key] = entry

    for word in words:
        if re.fullmatch(r'\d+(?:st|nd|rd|th)', word):
            number = re.match(r'\d+', word).group()
            entries[word] = {
                'zh': '第 ' + number + '（序数）。',
                'en': 'The ordinal form of ' + number + '.',
                'phonetic': '',
            }
        if word.endswith("'s") and word not in entries:
            base = word[:-2]
            if base in entries:
                original = entries[base]
                entries[word] = {
                    'zh': base + ' 的所有格：' + original['zh'],
                    'en': 'Possessive form of ' + base + '.',
                    'phonetic': '',
                    'base': base,
                }
    for word, (zh, en) in HISTORICAL.items():
        if word in words:
            entries[word] = {'zh': zh, 'en': en, 'phonetic': ''}
    for word, example in SUPPLEMENTAL_EXAMPLES.items():
        if word in entries:
            entries[word]['example'] = example
    missing = sorted(w for w in words if w not in entries or not entries[w]['zh'])
    if missing:
        raise SystemExit('Missing Chinese definitions: ' + ', '.join(missing))
    result = {word: entries[word] for word in sorted(words)}
    (READER / 'dictionary.json').write_text(
        json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n',
        encoding='utf-8',
    )
    print('Saved', len(result), 'article-specific word entries.')


if __name__ == '__main__':
    main()

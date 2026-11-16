# English word-frequency data

The rank metadata in `lib/english_frequency_data.dart` is adapted from the
English OpenSubtitles 2018 word-form frequency list published by hermitdave and
the FrequencyWords contributors, available under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/):

- Project and attribution: <https://github.com/hermitdave/FrequencyWords>
- Source file: <https://github.com/hermitdave/FrequencyWords/blob/072bbed282316a23651aa7068c7173aa7898cf80/content/2018/en/en_full.txt>
- Raw source SHA-256: `7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506`
- Modification: extract the one-based line rank for each of Chenbot's 214
  independently written practice items; retain the resulting mapping under
  CC BY-SA 4.0. The app provides attribution and license text under “我的 → 词频数据与开源许可”.

The original list ranks **word forms** in subtitles, not lemmas or word
families, and contains proper names, inflections and other noise. Tied counts
follow the source file's ordering. A word's subtitle rank neither measures a
learner's vocabulary size nor guarantees how difficult that word is for an
individual. The 12-question exercise uses rank as an uncalibrated input and can return only a broad provisional band range; it does not establish a numerical vocabulary size.

To regenerate the subset, download the pinned raw `en_full.txt` from the source
above and run `python3 tools/update_english_frequency_ranks.py path/to/en_full.txt`.
The script checks the source hash before writing any derived data. The full
20 MB file is not needed in the app or repository; compressed subsets of the first 200,000 and 500,000 forms are bundled for research and recognition respectively.


## Recognition preference and morphology data

`assets/vocabulary/english_subtitles_top500k.txt.gz` contains the first 500,000
English word forms from the same pinned FrequencyWords source, in source order,
with occurrence counts removed. It remains under CC BY-SA 4.0. English image
recognition requires a selected grade and an exact normalized surface-form match
in this local file. The model's unverified lemma is not allowed to make an absent
surface form pass the filter. The subtitle position divided by five is assigned
to the seven product bands; only the selected band and the next higher band are
returned. Shakespeare accepts only Shakespeare. The word's own band determines
its label color. Unknown or out-of-band results are never displayed. If no
non-trashed English noun passes the frequency check, the client makes at most
one additional request for level-appropriate nouns. This retry includes the
target subtitle rank range and the locally measured ranks of earlier
non-discarded candidates (null means absent), but the model does not have the
exact table. Every new candidate must still pass the same local filter. The
level retry and trash-triggered retries share an overall limit of three
requests per photo; each request may incur charges. A valid result is not
guaranteed.
Each image request asks for up to 32 grounded noun candidates, including visible
parts and accurate alternative names. The provider may return fewer. Candidates
are deduplicated for the same word and object position before local filtering;
distinct objects and distinct valid names are retained. Raising the output token
limit permits a longer response and may increase actual usage charges.
Previously saved English cards are filtered on display against the current
selection as well; their underlying local records are not deleted, and changing
back to a matching level makes them visible again. Japanese recognition is not
mapped to this English-only corpus.

The factor of five was chosen at the user's request after comparing 16 personal
subjective rank intervals with the same subtitle list: five matched 9/16 of the
merged-band intervals, four matched 7/16. These are hand-selected, subjective,
not a random sample or external benchmark; the difference does not validate a
universal factor, word difficulty, or a person's vocabulary size. The top
500,000 list includes noise, names, ties and forms; the tail is particularly
sparse. Strict filtering may return no word for a real image. The other
200,000-form asset is retained for the documented research crosswalk.

`assets/vocabulary/english_inflections.csv.gz` is the `infl_lu.csv.gz` lookup
from [LemmInflect](https://github.com/bjascob/LemmInflect), commit
`b7699808106a4ce843fc7f0e8e5d87fcb84cc636`, SHA-256
`8c44bd5bec62488bef043f98b0cab022a431d6cb03954864ea70334530908ba7`.
LemmInflect (Copyright 2019 Brad Jascob) is MIT licensed; the bundled license
is displayed under the app's open-source licenses. Its dictionary is derived
from the U.S. National Library of Medicine's SPECIALIST Lexicon. We use an
offline inflection lookup, not its neural model. Ambiguous forms are resolved
conservatively where possible; words outside the dictionary may be missed.
Japanese uses kana normalization, common adjective rules, and model-provided
forms; it does not have a comprehensive Japanese morphological dictionary.
Neither language can guarantee recognition of all spellings, senses, forms,
or homographs. Trash is reversible and does not delete underlying favorites.

To rebuild the assets from separately downloaded pinned inputs run:
`python3 tools/update_vocabulary_assets.py /path/to/en_full.txt /path/to/infl_lu.csv.gz`.
The script validates both source hashes. The MIT and CC BY-SA 4.0 texts are
bundled and displayed in the app's license page.

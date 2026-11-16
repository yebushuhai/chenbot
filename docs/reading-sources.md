# English reading sources

The reading tab bundles two English texts and their images for offline use.
Source URLs are also shown at the end of each article in the app.

- **Treaty of Nanking (1842):** English transcription of the British instrument,
  treaty text and all thirteen articles, signing and British ratification from
  [Wikisource](https://en.wikisource.org/wiki/Treaty_of_Nanking), identified
  there as public-domain government material. Article 10 contains a blank for
  the percentage in this transcription; the app retains the blank. The
  transcription's inline insertion of “due” in Article 5 is rendered as plain
  text. The artwork is a public-domain [1846 print after John Platt, engraved
  by John Burnet](https://commons.wikimedia.org/wiki/File:The_Signing_of_the_Treaty_of_Nanking.jpg).
- **In Event of Moon Disaster (1969):** all eight paragraphs of the proposed
  presidential statement, taken from the [U.S. National Archives copy of Bill
  Safire's memorandum](https://www.archives.gov/files/presidential-libraries/events/centennials/nixon/images/exhibit/rn100-6-1.pdf).
  This was a contingency speech and was not delivered. Two PDF extraction
  artifacts were corrected against the source transcription. The app presents
  the proposed statement itself; the memorandum's instructions before and
  after the statement are not part of the speech. The cover is Neil
  Armstrong's [NASA photograph AS11-40-5903](https://www.archives.gov/research/still-pictures/highlights/apollo-11-mission-image).
- **Word meanings:** `assets/reader/dictionary.json` is an article-specific
  subset of [ECDICT](https://github.com/skywind3000/ECDICT), commit
  `39cfb9672c0906b63569e0453c2e6abfb9ab182a`, whose `ecdict.csv` SHA-256 is
  `d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc`.
  The project's MIT license and copyright notice are bundled in
  `assets/reader/ECDICT_LICENSE.txt` and displayed in the app's license page.
  A small number of historical proper names, abbreviations, possessives and
  title terms are supplemented in `tools/build_reader_dictionary.py`. Rebuild the subset with
  `python3 tools/build_reader_dictionary.py /path/to/ecdict.csv`. Dictionary
  meanings are general references, not guaranteed context-sensitive analyses;
  the example shown is an original sentence. For a few title words and
  signature abbreviations without a complete sentence in the source, the app
  shows a clearly labeled, independently written supplemental sentence.

The source texts and images are bundled, and word lookup does not require a
network request or DeepSeek key. The underlying offline dictionary is a subset
for these two documents, not a comprehensive general-purpose dictionary.

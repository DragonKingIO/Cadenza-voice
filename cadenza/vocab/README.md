# Vocabulary packs

Lists of terms that speech recognition often gets wrong: product names, code names, jargon. Cadenza ships the packs in this
folder, and anyone can add to them with a pull request. Each pack is one JSON file.

```json
{
  "schema": 1,
  "id": "developer",
  "name": { "en": "Developer terms", "zh-Hans": "开发者词汇" },
  "description": { "en": "…", "zh-Hans": "…" },
  "license": "CC0-1.0",
  "default": true,
  "entries": [
    { "term": "GitHub", "aliases": ["git hub", "吉特哈勃"] },
    { "term": "Kubernetes" }
  ]
}
```

- `term` is the correct spelling. `aliases` (up to 12) are what recognizers actually write instead; add only spellings you
  have really seen.
- Without any alias, a term still fixes two things: an English term written apart or in the wrong case when the term has a
  capital inside or a digit (`git hub` and `github` become `GitHub`, `node js` becomes `Node.js`), and a Chinese term of three
  or more characters written with other characters that sound the same (same pinyin, tones ignored).
- A plain English word (`React`, `Swift`, `Go`) is not re-cased on its own, because that would capitalise the ordinary word.
  Give it an alias if recognizers really write it differently.
- Keep to what is accurate and useful to many people. No personal names, no private product names, no advertising, no
  offensive terms. One pack per field; put each term in the pack where people would look for it.
- `license` must be `CC0-1.0`, `CC-BY-4.0` or `MIT`. By contributing you confirm you may license the list that way.
- `default` says whether the pack is on until the person switches it off. Use `true` only for packs nearly everyone wants.

The app checks every pack when it starts and ignores one that is not valid; `--selftest` fails on an invalid pack. Rules:
`id` is lowercase letters, digits and hyphens; each term is 1–60 characters with no line break or backtick; no duplicate terms
in a pack; no alias equal to its term; at most 5000 entries.

People can also add their own terms in Settings → Vocabulary; those stay on their Mac.

"""Deterministic personal-dictionary correction.

Small cleanup models ignore vocabulary lists, and Parakeet can't be biased at
all, so after cleanup we fix near-miss spellings ourselves: a 1-3 word window
is replaced by a dictionary term when it *sounds* the same (metaphone key within
one edit, same first sound) and is spelled similarly. Conservative on purpose:
a missed fix is cheaper than a wrong word, so ordinary English words are left
alone unless they're the exact term.
"""

import re
from difflib import SequenceMatcher
from functools import cache
from pathlib import Path

import jellyfish

_WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9'\-]*")
_JOINABLE = re.compile(r"[A-Za-z0-9'\- ]+")
_DIGIT_WORDS = {"zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                "six": "6", "seven": "7", "eight": "8", "nine": "9"}


@cache
def _common_words() -> frozenset[str]:
    # Lowercase entries in the system word list are ordinary words; capitalized
    # ones are proper nouns, which we *do* want to be correctable.
    path = Path("/usr/share/dict/words")
    if not path.exists():
        return frozenset()
    return frozenset(w for w in path.read_text().split() if w.islower())


def _letters(s: str) -> str:
    return re.sub(r"[^a-z]", "", s.lower())


def _alnum(s: str) -> str:
    """Letters + digits, with spoken digits folded in: "S three" -> "s3"."""
    words = [_DIGIT_WORDS.get(w, w) for w in re.findall(r"[a-z0-9]+", s.lower())]
    return "".join(words)


def _key(letters: str) -> str:
    # metaphone writes "th" as "0"; treat it like "t" (Thomas ~ Tomasz)
    return jellyfish.metaphone(letters).replace("0", "T") if letters else ""


def _similarity(span: str, term: str, letters: str, key: str, term_letters: str, term_key: str) -> float:
    words = span.lower().split()
    common = _common_words()
    if any(ch.isdigit() for ch in term):
        # "S3", "M2", "GPT4": phonetics don't help with digits; require an exact
        # letters+digits match (spoken digits allowed).
        return 1.0 if _alnum(span) == _alnum(term) and span != term else 0.0
    if letters == term_letters:
        # Pure re-casing/re-spacing ("postgres" -> "Postgres", "use effect" -> "useEffect"),
        # except plain English words ("go" shouldn't become "Go" everywhere).
        if len(words) == 1 and words[0] in common and span.lower() == term.lower():
            return 0.0
        return 1.0
    if any(ch.isdigit() for ch in span):
        return 0.0
    if len(letters) < 3 or not key or key[0] != term_key[0]:
        return 0.0
    allowed = 1 if len(term_key) >= 3 else 0
    if jellyfish.levenshtein_distance(key, term_key) > allowed:
        return 0.0
    sim = SequenceMatcher(None, letters, term_letters).ratio()
    if len(words) == 1 and words[0].strip("'-") in common:
        return 0.0
    if all(w in common for w in words):
        # e.g. "super base" -> Supabase is fine, "use the effect" -> useEffect is not
        if abs(len(letters) - len(term_letters)) > 1 or sim < 0.8:
            return 0.0
    return sim if sim >= 0.6 else 0.0


def apply_vocab(text: str, vocab: list[str]) -> str:
    terms = [(t, _letters(t)) for t in (v.strip() for v in vocab) if _alnum(t)]
    if not terms or not text:
        return text
    terms = [(t, letters, _key(letters)) for t, letters in terms]
    tokens = list(_WORD.finditer(text))

    candidates = []  # (similarity, -n_words, first_token, n_words, term)
    for i in range(len(tokens)):
        for n in (1, 2, 3):
            if i + n > len(tokens):
                break
            span = text[tokens[i].start():tokens[i + n - 1].end()]
            if not _JOINABLE.fullmatch(span):
                break
            letters = _letters(span)
            key = _key(letters)
            for term, t_letters, t_key in terms:
                sim = _similarity(span, term, letters, key, t_letters, t_key)
                if sim:
                    candidates.append((sim, -n, i, n, term))

    # Best matches first; skip any that overlap an already-chosen span.
    taken: set[int] = set()
    chosen = []
    for sim, _, i, n, term in sorted(candidates, reverse=True):
        idx = set(range(i, i + n))
        if idx & taken:
            continue
        taken |= idx
        chosen.append((i, n, term))

    out, cursor = [], 0
    for i, n, term in sorted(chosen):
        start, end = tokens[i].start(), tokens[i + n - 1].end()
        out += [text[cursor:start], term]
        cursor = end
    out.append(text[cursor:])
    return "".join(out)

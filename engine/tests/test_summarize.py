import pytest

from mynah_engine.summarize import clean_title, fmt_time, format_transcript, normalize, parse_json, parse_time, split_sections


def test_format_transcript_merges_and_orders():
    segs = [
        {"track": "others", "start": 5.0, "text": "Can you send the deck?"},
        {"track": "you", "start": 1.0, "text": "Hi all."},
        {"track": "you", "start": 2.5, "text": "Thanks for joining."},
        {"track": "you", "start": 9.0, "text": "Sure, by Friday."},
        {"track": "others", "start": 3700.0, "text": "Bye."},
    ]
    assert format_transcript(segs) == (
        "[00:01] You: Hi all. Thanks for joining.\n"
        "[00:05] Others: Can you send the deck?\n"
        "[00:09] You: Sure, by Friday.\n"
        "[1:01:40] Others: Bye."
    )
    assert format_transcript(segs[:1], "Luke").startswith("[00:05] Others")
    assert "You (Luke):" in format_transcript(segs, "Luke")


def test_format_transcript_uses_speaker_names():
    segs = [
        {"track": "others", "start": 1.0, "speaker": "Bob", "text": "Hi."},
        {"track": "others", "start": 2.0, "speaker": "Bob", "text": "Ready?"},
        {"track": "others", "start": 3.0, "speaker": "Speaker 2", "text": "Yes."},
        {"track": "others", "start": 4.0, "text": "Unlabelled."},
    ]
    assert format_transcript(segs) == (
        "[00:01] Bob: Hi. Ready?\n"
        "[00:03] Speaker 2: Yes.\n"
        "[00:04] Others: Unlabelled."
    )


def test_time_round_trip():
    assert fmt_time(754) == "12:34"
    assert parse_time("12:34") == 754
    assert parse_time("1:01:40") == 3700
    assert parse_time("x") is None


def test_split_sections_respects_budget():
    text = "\n".join(f"line {i} " + "word " * 9 for i in range(100))
    count = lambda s: len(s.split())  # noqa: E731
    sections = split_sections(text, 100, count)
    assert len(sections) > 1
    assert all(sum(count(line) + 1 for line in s.splitlines()) <= 100 for s in sections)
    assert "\n".join(sections) == text


def test_parse_json_tolerates_fences_and_chatter():
    assert parse_json('Sure!\n```json\n{"tldr": "x"}\n```') == {"tldr": "x"}
    with pytest.raises(ValueError):
        parse_json("no json here")
    with pytest.raises(ValueError):
        parse_json('{"tldr": ')


def test_normalize_coerces_shapes():
    out = normalize({
        "tldr": ["Short call.", "About the deck."],
        "key_points": "deck",
        "decisions": None,
        "action_items": [
            {"text": "Send the deck", "owner": "You", "due": "2026-10-23", "time_s": "00:09"},
            {"text": "Review it", "owner": "Priya", "due": "next week", "time_s": 99999},
            {"text": "  ", "owner": "me"},
            "Book a room",
            {"text": "Follow up", "owner": "Others", "time_s": -5},
            {"text": "Stamp copied", "owner": "me", "time": "[01:05]"},
        ],
    }, duration_s=600)
    assert out["tldr"] == "Short call. About the deck."
    assert out["title"] is None
    assert out["key_points"] == ["deck"]
    assert out["decisions"] == [] and out["open_questions"] == []
    assert out["action_items"] == [
        {"text": "Send the deck", "owner": "me", "due": "2026-10-23", "time_s": 9.0},
        {"text": "Review it", "owner": "Priya", "due": None, "time_s": 600.0},
        {"text": "Book a room", "owner": "unassigned", "due": None, "time_s": None},
        {"text": "Follow up", "owner": "unassigned", "due": None, "time_s": 0.0},
        {"text": "Stamp copied", "owner": "me", "due": None, "time_s": 65.0},
    ]


def test_clean_title():
    assert clean_title('  "Title: Q3 budget review with finance."  ') == "Q3 budget review with finance"
    assert clean_title("“Hiring plan”") == "Hiring plan"
    assert clean_title("") is None and clean_title(None) is None and clean_title(["x"]) is None
    long = clean_title("word " * 40)
    assert len(long) <= 80 and not long.endswith(" ")

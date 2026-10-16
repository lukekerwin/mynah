from mynah_engine.vocab import apply_vocab

VOCAB = ["Supabase", "Postgres", "Kubernetes", "Priya", "Tomasz", "useEffect", "S3", "ESLint", "Go", "M2 Max"]


def fix(text: str) -> str:
    return apply_vocab(text, VOCAB)


def test_multiword_soundalikes():
    assert fix("we moved from super base to postgres on cooper netties") == "we moved from Supabase to Postgres on Kubernetes"


def test_names():
    assert fix("loop in Pria and Thomas") == "loop in Priya and Tomasz"


def test_respacing_and_casing():
    assert fix("refactor the use effect hook") == "refactor the useEffect hook"
    assert fix("update the es lint config") == "update the ESLint config"


def test_terms_with_digits():
    assert fix("the s3 upload") == "the S3 upload"
    assert fix("the S three upload") == "the S3 upload"
    assert fix("my m two max laptop") == "my M2 Max laptop"


def test_leaves_ordinary_words_alone():
    for text in ["let's go home", "I posted the post and it was a priority", "Use the effect of the post",
                 "after 30 seconds", "Tom asked about the base case"]:
        assert fix(text) == text


def test_empty_inputs():
    assert apply_vocab("", VOCAB) == ""
    assert apply_vocab("hello", []) == "hello"

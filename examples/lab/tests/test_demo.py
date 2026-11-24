from demo import shout, whisper


def test_shout():
    assert shout("hi") == "HI!"


def test_whisper():
    assert whisper("HI") == "hi…"

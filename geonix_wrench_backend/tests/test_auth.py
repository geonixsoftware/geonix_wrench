import pytest

from auth import InvalidHandleError, validate_handle


def test_valid_handle_passes():
    assert validate_handle("mike_the_mechanic1") == "mike_the_mechanic1"


def test_handle_is_lowercased():
    assert validate_handle("MikeMechanic") == "mikemechanic"


def test_handle_is_stripped():
    assert validate_handle("  mike  ") == "mike"


@pytest.mark.parametrize("raw", ["mike mechanic", "mike-mechanic", "mike!", "mike.mechanic", "mike@mechanic"])
def test_handle_rejects_spaces_and_symbols(raw):
    with pytest.raises(InvalidHandleError):
        validate_handle(raw)


def test_handle_too_short_rejected():
    with pytest.raises(InvalidHandleError):
        validate_handle("ab")


def test_handle_too_long_rejected():
    with pytest.raises(InvalidHandleError):
        validate_handle("a" * 31)


def test_handle_min_length_boundary_ok():
    assert validate_handle("abc") == "abc"


def test_handle_max_length_boundary_ok():
    assert validate_handle("a" * 30) == "a" * 30

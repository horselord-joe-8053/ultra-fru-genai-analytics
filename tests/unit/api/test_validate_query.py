"""Domain helpers: validate_query and is_qualitative."""


def test_validate_query_rejects_empty():
    import backend.api.app as app_module
    ok, err = app_module.validate_query("   ")
    assert ok is False
    assert "empty" in err.lower()


def test_validate_query_rejects_too_long():
    import backend.api.app as app_module

    ok, err = app_module.validate_query("x" * 1001)
    assert ok is False
    assert "long" in err.lower()


def test_is_qualitative_quantitative_keywords():
    import backend.api.app as app_module

    assert app_module.is_qualitative("How many LG fridges were sold?") is False


def test_is_qualitative_complaint_keywords():
    import backend.api.app as app_module

    assert app_module.is_qualitative("Why are customers complaining about delivery?") is True


def test_is_qualitative_defaults_to_qualitative():
    import backend.api.app as app_module

    assert app_module.is_qualitative("Tell me about fridge sales in Brazil") is True

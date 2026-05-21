"""JSON serialization helpers in app module."""

from datetime import date, datetime
from decimal import Decimal

def test_json_safe_decimal_and_dates():
    import backend.api.app as app_module
    out = app_module._json_safe(
        {"d": Decimal("1.5"), "when": datetime(2024, 1, 2, 3, 4, 5), "day": date(2024, 1, 2)}
    )
    assert out["d"] == 1.5
    assert "2024" in out["when"]
    assert out["day"] == "2024-01-02"

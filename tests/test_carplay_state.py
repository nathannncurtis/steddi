"""
Tests for CarPlay-related state logic: reroute suggestions as displayed in
CarPlay, the direction resolver's smart-default heuristic, and the distance
formatting algorithm ported from NavigationStateManager.swift.

Run: python3 -m pytest tests/test_carplay_state.py -v
"""

import pytest
from datetime import datetime, timedelta
from math import floor

from reroute_engine import evaluate, scaled_threshold, RerouteDecision, RerouteReason


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def mins(m: float) -> float:
    """Convert minutes to seconds for readability."""
    return m * 60.0


# ---------------------------------------------------------------------------
# Distance formatting — Python port of NavigationStateManager.formatDistance()
# ---------------------------------------------------------------------------

def format_distance(meters: float) -> str:
    """Port of NavigationStateManager.formatDistance from Swift.

    - < 160m: show feet (meters * 3.281, truncated to int)
    - < 10 miles: show 1-decimal miles
    - >= 10 miles: show whole-number miles
    """
    if meters < 160:
        return f"{int(meters * 3.281)} ft"
    miles = meters / 1609.34
    if miles < 10:
        return f"{miles:.1f} mi"
    return f"{int(miles)} mi"


# ---------------------------------------------------------------------------
# Direction resolver — Python port of CommuteDirectionResolver.smartDefault()
# ---------------------------------------------------------------------------

def smart_default(now: datetime):
    """Port of CommuteDirectionResolver.smartDefault from Swift.

    Returns 'originToDestination', 'destinationToOrigin', or None.
    Weekday (Mon-Fri): 5-11 → originToDestination, 12-21 → destinationToOrigin.
    Weekend or late night (22-4) → None (ambiguous).
    """
    weekday = now.isoweekday()  # Monday=1, Sunday=7
    hour = now.hour

    # Weekend: Saturday=6, Sunday=7
    if weekday in (6, 7):
        return None

    # Weekday
    if 5 <= hour < 12:
        return "originToDestination"
    elif 12 <= hour < 22:
        return "destinationToOrigin"

    return None  # late night


# ===========================================================================
# CarPlay Reroute Suggestion Tests
# ===========================================================================

class TestCarPlayRerouteSuggestions:
    """Verify reroute decisions carry correct savings info for CarPlay display."""

    def test_suggestion_has_correct_savings_minutes(self):
        """When a reroute triggers, savingsMinutes should match the time delta."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(20),
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        assert abs(result.savings_minutes - 10.0) < 0.01

    def test_suggestion_savings_percentage(self):
        """CarPlay alert shows percentage — verify it is computed correctly."""
        remaining = mins(40)
        fallback = mins(30)
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        expected_pct = (remaining - fallback) / remaining  # 0.25
        assert result.actual_percentage is not None
        assert abs(result.actual_percentage - expected_pct) < 0.001

    def test_no_suggestion_below_threshold(self):
        """When savings are too small, CarPlay should not show an alert."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(29),
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.BELOW_THRESHOLD

    def test_hard_floor_suggestion_metadata(self):
        """When reroute triggers via hard floor, the decision carries floor info."""
        result = evaluate(
            remaining_eta_seconds=mins(120),
            fallback_eta_seconds=mins(109),
            base_percentage=0.20,
            hard_minute_floor=10,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.HARD_FLOOR_MET
        assert result.savings_minutes_detail is not None
        assert result.savings_minutes_detail >= 10.0
        assert result.floor_minutes == 10.0

    def test_percentage_suggestion_includes_threshold(self):
        """Percentage-based suggestions should include actual and threshold values."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(15),
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET
        assert result.actual_percentage is not None
        assert result.threshold_percentage is not None
        assert result.actual_percentage > result.threshold_percentage

    def test_short_drive_high_threshold(self):
        """Short drives require larger percentage savings for CarPlay alert."""
        # 5 min remaining, 20% savings → threshold is ~30%, should NOT trigger
        remaining = mins(5)
        fallback = remaining * 0.80
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.should_reroute is False

    def test_long_drive_lower_threshold(self):
        """Long drives have a lower threshold — smaller percentage triggers alert."""
        # 90 min remaining, 12% savings → threshold ~10%, should trigger
        remaining = mins(90)
        fallback = remaining * 0.88
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.should_reroute is True

    def test_savings_seconds_is_exact(self):
        """Verify the raw savings_seconds value is exactly the input delta."""
        remaining = mins(60)
        fallback = mins(50)
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.savings_seconds == remaining - fallback


# ===========================================================================
# Direction Resolver — Smart Defaults Tests
# ===========================================================================

class TestDirectionResolverSmartDefaults:
    """Test the weekday/weekend time-based heuristic for direction resolution."""

    # -- Weekday morning → originToDestination --

    def test_weekday_early_morning(self):
        """Monday 6:00 AM → going to work (originToDestination)."""
        dt = datetime(2026, 3, 23, 6, 0)  # Monday
        assert smart_default(dt) == "originToDestination"

    def test_weekday_5am_boundary(self):
        """Weekday 5:00 AM is the earliest 'morning' → originToDestination."""
        dt = datetime(2026, 3, 24, 5, 0)  # Tuesday
        assert smart_default(dt) == "originToDestination"

    def test_weekday_1159am(self):
        """Weekday 11:59 AM still counts as morning → originToDestination."""
        dt = datetime(2026, 3, 25, 11, 59)  # Wednesday
        assert smart_default(dt) == "originToDestination"

    def test_weekday_8am(self):
        """Typical morning commute time."""
        dt = datetime(2026, 3, 26, 8, 0)  # Thursday
        assert smart_default(dt) == "originToDestination"

    # -- Weekday afternoon → destinationToOrigin --

    def test_weekday_noon(self):
        """Weekday 12:00 PM → going home (destinationToOrigin)."""
        dt = datetime(2026, 3, 23, 12, 0)  # Monday
        assert smart_default(dt) == "destinationToOrigin"

    def test_weekday_5pm(self):
        """Typical evening commute time."""
        dt = datetime(2026, 3, 24, 17, 0)  # Tuesday
        assert smart_default(dt) == "destinationToOrigin"

    def test_weekday_9pm(self):
        """Weekday 9:00 PM still counts as evening → destinationToOrigin."""
        dt = datetime(2026, 3, 25, 21, 0)  # Wednesday
        assert smart_default(dt) == "destinationToOrigin"

    def test_weekday_2159(self):
        """Weekday 21:59 is the last minute before late night → destinationToOrigin."""
        dt = datetime(2026, 3, 26, 21, 59)  # Thursday
        assert smart_default(dt) == "destinationToOrigin"

    # -- Weekend → ambiguous (None) --

    def test_saturday_morning(self):
        """Saturday morning → ambiguous."""
        dt = datetime(2026, 3, 21, 9, 0)  # Saturday
        assert smart_default(dt) is None

    def test_saturday_afternoon(self):
        """Saturday afternoon → ambiguous."""
        dt = datetime(2026, 3, 21, 15, 0)
        assert smart_default(dt) is None

    def test_sunday_morning(self):
        """Sunday morning → ambiguous."""
        dt = datetime(2026, 3, 22, 8, 0)  # Sunday
        assert smart_default(dt) is None

    def test_sunday_evening(self):
        """Sunday evening → ambiguous."""
        dt = datetime(2026, 3, 22, 20, 0)
        assert smart_default(dt) is None

    # -- Late night → ambiguous (None) --

    def test_weekday_10pm(self):
        """Weekday 10:00 PM → late night, ambiguous."""
        dt = datetime(2026, 3, 23, 22, 0)  # Monday
        assert smart_default(dt) is None

    def test_weekday_midnight(self):
        """Weekday midnight → ambiguous."""
        dt = datetime(2026, 3, 24, 0, 0)  # Tuesday
        assert smart_default(dt) is None

    def test_weekday_3am(self):
        """Weekday 3:00 AM → ambiguous."""
        dt = datetime(2026, 3, 25, 3, 0)  # Wednesday
        assert smart_default(dt) is None

    def test_weekday_459am(self):
        """Weekday 4:59 AM → just before morning cutoff, still ambiguous."""
        dt = datetime(2026, 3, 26, 4, 59)  # Thursday
        assert smart_default(dt) is None

    def test_weekday_11pm(self):
        """Weekday 11:00 PM → late night, ambiguous."""
        dt = datetime(2026, 3, 27, 23, 0)  # Friday
        assert smart_default(dt) is None


# ===========================================================================
# Distance Formatting Tests
# ===========================================================================

class TestFormatDistance:
    """Test the Python port of NavigationStateManager.formatDistance."""

    # -- Small distances (< 160m) → feet --

    def test_zero_meters(self):
        """0 meters → 0 ft."""
        assert format_distance(0) == "0 ft"

    def test_small_distance_in_feet(self):
        """50 meters → 164 ft (50 * 3.281 = 164.05, truncated)."""
        assert format_distance(50) == "164 ft"

    def test_100_meters(self):
        """100 meters → 328 ft."""
        assert format_distance(100) == "328 ft"

    def test_just_below_160m(self):
        """159 meters → feet."""
        result = format_distance(159)
        assert result.endswith("ft")
        assert result == "521 ft"

    def test_1_meter(self):
        """1 meter → 3 ft."""
        assert format_distance(1) == "3 ft"

    # -- Medium distances (160m to ~16km / 10mi) → X.X mi --

    def test_at_160m_switches_to_miles(self):
        """160 meters → should show miles."""
        result = format_distance(160)
        assert result.endswith("mi")

    def test_quarter_mile(self):
        """~0.25 miles (402m)."""
        result = format_distance(402.335)
        assert result == "0.2 mi"

    def test_half_mile(self):
        """~0.5 miles (804.67m)."""
        result = format_distance(804.67)
        assert result == "0.5 mi"

    def test_one_mile(self):
        """Exactly 1 mile (1609.34m)."""
        assert format_distance(1609.34) == "1.0 mi"

    def test_5_miles(self):
        """5 miles."""
        assert format_distance(5 * 1609.34) == "5.0 mi"

    def test_9_point_9_miles(self):
        """9.9 miles — just under the 10-mile threshold."""
        assert format_distance(9.9 * 1609.34) == "9.9 mi"

    # -- Large distances (>= 10mi) → X mi --

    def test_10_miles_whole_number(self):
        """10 miles switches to whole number."""
        assert format_distance(10 * 1609.34) == "10 mi"

    def test_25_miles(self):
        """25 miles."""
        assert format_distance(25 * 1609.34) == "25 mi"

    def test_100_miles(self):
        """100 miles."""
        assert format_distance(100 * 1609.34) == "100 mi"

    def test_999_miles(self):
        """Very large distance."""
        assert format_distance(999 * 1609.34) == "999 mi"

    # -- Boundary behavior --

    def test_159m_is_feet_160m_is_miles(self):
        """Verify the exact boundary between feet and miles."""
        assert format_distance(159).endswith("ft")
        assert format_distance(160).endswith("mi")

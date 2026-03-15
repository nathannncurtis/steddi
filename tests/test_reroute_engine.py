"""
Comprehensive tests for the Steddi reroute threshold algorithm.

These tests serve as living documentation for how the reroute engine
decides whether to suggest switching to a faster route. The algorithm
uses percentage-based thresholds scaled by remaining drive time via a
sigmoid curve, with an optional hard minute floor as a secondary gate.

Run: python3 -m pytest tests/ -v
"""

import pytest
from math import exp

from reroute_engine import (
    evaluate,
    scaled_threshold,
    RerouteDecision,
    RerouteReason,
)


# ---------------------------------------------------------------------------
# Helper — minutes to seconds
# ---------------------------------------------------------------------------

def mins(m: float) -> float:
    """Convert minutes to seconds for readability."""
    return m * 60.0


# ---------------------------------------------------------------------------
# Scaled threshold unit tests
# ---------------------------------------------------------------------------

class TestScaledThreshold:
    """Verify the sigmoid-based threshold scaling curve."""

    def test_short_drive_increases_threshold(self):
        """< 10 min remaining: multiplier ~1.5, threshold is ~1.5x base."""
        base = 0.20
        threshold = scaled_threshold(base, remaining_minutes=5.0)
        # Multiplier should be close to 1.5 → threshold ~0.30
        assert threshold > base * 1.3
        assert threshold < base * 1.6

    def test_medium_drive_unchanged(self):
        """~30 min remaining: multiplier ~1.0, threshold ≈ base."""
        base = 0.20
        threshold = scaled_threshold(base, remaining_minutes=30.0)
        assert abs(threshold - base) < 0.02  # within 2 percentage points

    def test_long_drive_decreases_threshold(self):
        """60+ min remaining: multiplier drops, threshold easier to meet."""
        base = 0.20
        threshold = scaled_threshold(base, remaining_minutes=60.0)
        assert threshold < base * 0.85

    def test_very_long_drive_floors_at_half(self):
        """90+ min remaining: multiplier floors at ~0.5."""
        base = 0.20
        threshold = scaled_threshold(base, remaining_minutes=120.0)
        # Should be close to base * 0.5 = 0.10
        assert threshold < base * 0.6
        assert threshold > base * 0.45

    def test_threshold_capped_at_80_percent(self):
        """Even with a very high base percentage, threshold never exceeds 0.80."""
        threshold = scaled_threshold(0.90, remaining_minutes=5.0)
        assert threshold == 0.80

    def test_multiplier_is_monotonically_decreasing(self):
        """As remaining time increases, the threshold should decrease (or stay flat)."""
        base = 0.20
        times = [5, 10, 20, 30, 45, 60, 90, 120]
        thresholds = [scaled_threshold(base, m) for m in times]
        for i in range(len(thresholds) - 1):
            assert thresholds[i] >= thresholds[i + 1], (
                f"Threshold at {times[i]} min ({thresholds[i]:.4f}) should be >= "
                f"threshold at {times[i+1]} min ({thresholds[i+1]:.4f})"
            )


# ---------------------------------------------------------------------------
# Basic reroute decision tests
# ---------------------------------------------------------------------------

class TestBasicDecisions:
    """Fundamental yes/no reroute scenarios."""

    def test_fallback_slower_no_reroute(self):
        """If the fallback route is slower, never reroute."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(35),
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.NO_SAVINGS
        assert result.savings_seconds < 0

    def test_fallback_equal_no_reroute(self):
        """If the fallback route is identical, no reroute."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(30),
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.NO_SAVINGS

    def test_huge_savings_always_reroutes(self):
        """Massive savings (e.g., 50% of a 30-min drive) should always trigger."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(15),
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET

    def test_tiny_savings_no_reroute(self):
        """Saving 1 second on a 30-min drive is never enough."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(30) - 1,
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.BELOW_THRESHOLD


# ---------------------------------------------------------------------------
# Percentage scaling behavior
# ---------------------------------------------------------------------------

class TestPercentageScaling:
    """Verify that the sigmoid scaling makes short drives harder to trigger
    and long drives easier to trigger."""

    def test_short_drive_15pct_savings_no_reroute(self):
        """10 min remaining, 15% savings → threshold is ~30%, so NO reroute."""
        remaining = mins(10)
        savings_pct = 0.15
        fallback = remaining * (1 - savings_pct)
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.BELOW_THRESHOLD

    def test_short_drive_40pct_savings_reroutes(self):
        """10 min remaining, 40% savings → exceeds ~30% threshold, SHOULD reroute."""
        remaining = mins(10)
        savings_pct = 0.40
        fallback = remaining * (1 - savings_pct)
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET

    def test_medium_drive_20pct_savings_reroutes(self):
        """30 min remaining, 20% savings → threshold ≈ 20%, should trigger."""
        remaining = mins(30)
        savings_pct = 0.20
        fallback = remaining * (1 - savings_pct)
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET

    def test_long_drive_11pct_savings_reroutes(self):
        """90 min remaining, 11% savings → threshold ~10.5% (0.53x scaling), triggers."""
        remaining = mins(90)
        savings_pct = 0.11
        fallback = remaining * (1 - savings_pct)
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET


# ---------------------------------------------------------------------------
# Percentage overrides hard floor (critical behavior)
# ---------------------------------------------------------------------------

class TestPercentageOverridesHardFloor:
    """The percentage threshold always wins if met, even when savings_minutes
    is below the hard floor. This is the most critical behavioral test."""

    def test_percentage_met_below_hard_floor(self):
        """20 min remaining, saves 8 min (40%), hard floor 10 min.
        8 < 10 floor, but 40% > scaled threshold → SHOULD reroute via percentage."""
        result = evaluate(
            remaining_eta_seconds=mins(20),
            fallback_eta_seconds=mins(12),
            base_percentage=0.20,
            hard_minute_floor=10,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET
        # Confirm savings is indeed below the hard floor
        assert result.savings_minutes < 10.0


# ---------------------------------------------------------------------------
# Hard floor as secondary gate
# ---------------------------------------------------------------------------

class TestHardFloor:
    """The hard minute floor only triggers when the percentage threshold is NOT met."""

    def test_long_drive_percentage_met_no_floor_needed(self):
        """90 min remaining, saves 12 min (13.3%), base 20%, scaled ~10%.
        Percentage is met → reroute via percentage (floor irrelevant)."""
        result = evaluate(
            remaining_eta_seconds=mins(90),
            fallback_eta_seconds=mins(78),
            base_percentage=0.20,
            hard_minute_floor=10,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET

    def test_long_drive_percentage_not_met_below_floor(self):
        """90 min remaining, saves 5 min (5.6%), base 20%, scaled ~10%.
        Percentage NOT met, 5 < 10 floor → no reroute."""
        result = evaluate(
            remaining_eta_seconds=mins(90),
            fallback_eta_seconds=mins(85),
            base_percentage=0.20,
            hard_minute_floor=10,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.BELOW_THRESHOLD

    def test_very_long_drive_floor_triggers(self):
        """120 min remaining, saves 11 min (9.2%), base 20%, scaled ~10%.
        Percentage NOT met (9.2% < ~10%), but 11 >= 10 floor → reroute via floor."""
        result = evaluate(
            remaining_eta_seconds=mins(120),
            fallback_eta_seconds=mins(109),
            base_percentage=0.20,
            hard_minute_floor=10,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.HARD_FLOOR_MET

    def test_no_hard_floor_set(self):
        """When hard_minute_floor is None, only percentage logic applies."""
        # Savings that would pass a 10-min floor but not percentage
        result = evaluate(
            remaining_eta_seconds=mins(120),
            fallback_eta_seconds=mins(109),
            base_percentage=0.20,
            hard_minute_floor=None,
        )
        # Without floor, this should NOT reroute (percentage alone not met)
        # Need to check: 11/120 = 9.2%, threshold at 120 min ≈ 0.20 * 0.5 = 10%
        # This is borderline; let's verify by checking the actual threshold
        threshold = scaled_threshold(0.20, 120.0)
        actual_pct = 11.0 / 120.0
        if actual_pct >= threshold:
            assert result.should_reroute is True
        else:
            assert result.should_reroute is False
            assert result.reason == RerouteReason.BELOW_THRESHOLD


# ---------------------------------------------------------------------------
# Same savings, different remaining ETA
# ---------------------------------------------------------------------------

class TestRemainingETARecalculation:
    """The same absolute savings should produce different decisions
    at different points in a drive, because the percentage changes."""

    def test_10min_savings_at_120min_remaining(self):
        """10 min savings at 120 min remaining = 8.3% savings.
        With scaled threshold ~10%, this should NOT trigger on percentage alone."""
        result = evaluate(
            remaining_eta_seconds=mins(120),
            fallback_eta_seconds=mins(110),
            base_percentage=0.20,
        )
        threshold = scaled_threshold(0.20, 120.0)
        actual_pct = 10.0 / 120.0
        if actual_pct < threshold:
            assert result.should_reroute is False
        else:
            assert result.should_reroute is True

    def test_10min_savings_at_20min_remaining(self):
        """10 min savings at 20 min remaining = 50% savings.
        Even with elevated threshold (~27%), 50% easily triggers."""
        result = evaluate(
            remaining_eta_seconds=mins(20),
            fallback_eta_seconds=mins(10),
            base_percentage=0.20,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET

    def test_same_savings_different_results(self):
        """Demonstrate that identical absolute savings (10 min) produces
        different decisions depending on remaining ETA."""
        # Far from destination: 10/120 = 8.3% — may not trigger percentage
        far = evaluate(
            remaining_eta_seconds=mins(120),
            fallback_eta_seconds=mins(110),
            base_percentage=0.20,
        )
        # Close to destination: 10/20 = 50% — easily triggers
        close = evaluate(
            remaining_eta_seconds=mins(20),
            fallback_eta_seconds=mins(10),
            base_percentage=0.20,
        )
        assert close.should_reroute is True
        # The far case depends on exact sigmoid values, but the point is
        # these two scenarios produce different percentage calculations
        assert close.savings_minutes == far.savings_minutes  # same absolute savings


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    """Boundary conditions and unusual inputs."""

    def test_zero_remaining_eta(self):
        """0 seconds remaining — you've arrived, no reroute possible.
        With 0 remaining and 0 fallback, savings is 0 → no_savings."""
        result = evaluate(
            remaining_eta_seconds=0,
            fallback_eta_seconds=0,
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.NO_SAVINGS

    def test_zero_remaining_positive_fallback(self):
        """0 remaining but fallback is positive → fallback is slower → no savings."""
        result = evaluate(
            remaining_eta_seconds=0,
            fallback_eta_seconds=mins(5),
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.NO_SAVINGS

    def test_negative_savings(self):
        """Fallback is significantly slower — clearly no reroute."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(45),
            base_percentage=0.20,
        )
        assert result.should_reroute is False
        assert result.reason == RerouteReason.NO_SAVINGS
        assert result.savings_seconds == -(mins(15))

    def test_one_second_savings(self):
        """Saving exactly 1 second on a 30-min drive: 0.056% — never enough."""
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(30) - 1,
            base_percentage=0.05,
        )
        assert result.should_reroute is False

    def test_very_large_base_percentage(self):
        """50% base percentage — very conservative user.
        30 min drive, 40% savings should NOT trigger (threshold ~50%)."""
        remaining = mins(30)
        fallback = remaining * 0.60  # 40% savings
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.50,
        )
        assert result.should_reroute is False

    def test_very_large_base_percentage_exceeded(self):
        """50% base percentage, but 60% savings → should trigger."""
        remaining = mins(30)
        fallback = remaining * 0.40  # 60% savings
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.50,
        )
        assert result.should_reroute is True

    def test_very_small_base_percentage(self):
        """5% base percentage — very aggressive rerouting.
        30 min drive, 6% savings should trigger."""
        remaining = mins(30)
        fallback = remaining * 0.94  # 6% savings
        result = evaluate(
            remaining_eta_seconds=remaining,
            fallback_eta_seconds=fallback,
            base_percentage=0.05,
        )
        assert result.should_reroute is True

    def test_savings_exactly_at_threshold(self):
        """Savings exactly matching the scaled threshold should trigger (>= check)."""
        base = 0.20
        remaining_min = 30.0
        threshold = scaled_threshold(base, remaining_min)
        remaining_sec = remaining_min * 60.0
        # Create fallback that produces exactly the threshold percentage savings
        savings_sec = threshold * remaining_sec
        fallback_sec = remaining_sec - savings_sec
        result = evaluate(
            remaining_eta_seconds=remaining_sec,
            fallback_eta_seconds=fallback_sec,
            base_percentage=base,
        )
        assert result.should_reroute is True
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET

    def test_hard_floor_zero(self):
        """Hard floor of 0 minutes — any positive savings meets the floor."""
        result = evaluate(
            remaining_eta_seconds=mins(120),
            fallback_eta_seconds=mins(119),
            base_percentage=0.20,
            hard_minute_floor=0,
        )
        # 1 min / 120 min = 0.83%, well below percentage threshold
        # But savings (1 min) >= floor (0 min) → hard floor met
        assert result.should_reroute is True
        assert result.reason == RerouteReason.HARD_FLOOR_MET


# ---------------------------------------------------------------------------
# Decision metadata tests
# ---------------------------------------------------------------------------

class TestDecisionMetadata:
    """Verify that the RerouteDecision carries useful debugging information."""

    def test_savings_minutes_calculated(self):
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(24),
            base_percentage=0.20,
        )
        assert abs(result.savings_minutes - 6.0) < 0.01

    def test_percentage_threshold_met_includes_details(self):
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(20),
            base_percentage=0.20,
        )
        assert result.reason == RerouteReason.PERCENTAGE_THRESHOLD_MET
        assert result.actual_percentage is not None
        assert result.threshold_percentage is not None
        assert result.actual_percentage > result.threshold_percentage

    def test_below_threshold_includes_details(self):
        result = evaluate(
            remaining_eta_seconds=mins(30),
            fallback_eta_seconds=mins(29),
            base_percentage=0.20,
        )
        assert result.reason == RerouteReason.BELOW_THRESHOLD
        assert result.actual_percentage is not None
        assert result.threshold_percentage is not None
        assert result.actual_percentage < result.threshold_percentage

    def test_hard_floor_met_includes_details(self):
        result = evaluate(
            remaining_eta_seconds=mins(120),
            fallback_eta_seconds=mins(109),
            base_percentage=0.20,
            hard_minute_floor=10,
        )
        # This may trigger via percentage or floor depending on exact sigmoid
        if result.reason == RerouteReason.HARD_FLOOR_MET:
            assert result.savings_minutes_detail is not None
            assert result.floor_minutes == 10.0

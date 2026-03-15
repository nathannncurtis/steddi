"""
Python port of Steddi's RerouteEngine (Swift → Python).

This is a faithful reimplementation of the reroute threshold algorithm
from Steddi/Services/RerouteEngine.swift, used for testing and validation.
"""

from __future__ import annotations
from dataclasses import dataclass
from enum import Enum, auto
from math import exp
from typing import Optional


class RerouteReason(Enum):
    NO_SAVINGS = auto()
    PERCENTAGE_THRESHOLD_MET = auto()
    HARD_FLOOR_MET = auto()
    BELOW_THRESHOLD = auto()


@dataclass(frozen=True)
class RerouteDecision:
    should_reroute: bool
    savings_seconds: float
    reason: RerouteReason
    # Optional detail fields (populated depending on reason)
    actual_percentage: Optional[float] = None
    threshold_percentage: Optional[float] = None
    savings_minutes_detail: Optional[float] = None
    floor_minutes: Optional[float] = None

    @property
    def savings_minutes(self) -> float:
        return self.savings_seconds / 60.0


def scaled_threshold(base_percentage: float, remaining_minutes: float) -> float:
    """Scale the base percentage threshold based on remaining drive time.

    Uses a sigmoid curve centered at 30 minutes:
    - Very short drives (< 10 min): multiplier ~1.5 (harder to trigger)
    - Medium drives (~30 min): multiplier ~1.0 (base unchanged)
    - Long drives (60+ min): multiplier ~0.7 (easier to trigger)
    - Very long drives (90+ min): multiplier floors at ~0.5
    """
    midpoint = 30.0
    steepness = 0.06

    sigmoid = 1.0 / (1.0 + exp(steepness * (remaining_minutes - midpoint)))
    multiplier = 0.5 + sigmoid  # Range: ~0.5 (long) to ~1.5 (short)

    return min(base_percentage * multiplier, 0.80)


def evaluate(
    remaining_eta_seconds: float,
    fallback_eta_seconds: float,
    base_percentage: float,
    hard_minute_floor: Optional[int] = None,
) -> RerouteDecision:
    """Determine whether a reroute should be suggested.

    Direct port of RerouteEngine.evaluate() from Swift.
    """
    savings_seconds = remaining_eta_seconds - fallback_eta_seconds

    # No savings or fallback is slower — never suggest
    if savings_seconds <= 0:
        return RerouteDecision(
            should_reroute=False,
            savings_seconds=savings_seconds,
            reason=RerouteReason.NO_SAVINGS,
        )

    remaining_minutes = remaining_eta_seconds / 60.0
    savings_minutes = savings_seconds / 60.0

    scaled_pct = scaled_threshold(base_percentage, remaining_minutes)

    # Guard against division by zero
    if remaining_eta_seconds == 0:
        actual_percentage = 0.0
    else:
        actual_percentage = savings_seconds / remaining_eta_seconds

    # Percentage threshold met — always suggest, regardless of hard floor
    if actual_percentage >= scaled_pct:
        return RerouteDecision(
            should_reroute=True,
            savings_seconds=savings_seconds,
            reason=RerouteReason.PERCENTAGE_THRESHOLD_MET,
            actual_percentage=actual_percentage,
            threshold_percentage=scaled_pct,
        )

    # Percentage not met — check hard minute floor as secondary gate
    if hard_minute_floor is not None and savings_minutes >= float(hard_minute_floor):
        return RerouteDecision(
            should_reroute=True,
            savings_seconds=savings_seconds,
            reason=RerouteReason.HARD_FLOOR_MET,
            savings_minutes_detail=savings_minutes,
            floor_minutes=float(hard_minute_floor),
        )

    return RerouteDecision(
        should_reroute=False,
        savings_seconds=savings_seconds,
        reason=RerouteReason.BELOW_THRESHOLD,
        actual_percentage=actual_percentage,
        threshold_percentage=scaled_pct,
    )

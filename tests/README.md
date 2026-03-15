# Reroute Engine Tests

Python test suite for Steddi's reroute threshold algorithm, ported from
`Steddi/Services/RerouteEngine.swift`.

## Files

| File | Purpose |
|------|---------|
| `reroute_engine.py` | Python port of the Swift `RerouteEngine` |
| `test_reroute_engine.py` | pytest test suite (35 tests) |
| `conftest.py` | Path configuration for pytest |

## Running

```bash
# From project root
python3 -m pytest tests/ -v
```

Requires Python 3.10+ and pytest (`pip3 install pytest`).

## What's Tested

### Scaled Threshold Curve
- Short drives (< 10 min): multiplier ~1.5x makes rerouting harder to trigger
- Medium drives (~30 min): multiplier ~1.0x, threshold equals base percentage
- Long drives (60+ min): multiplier drops, making rerouting easier
- Very long drives (90+ min): multiplier floors at ~0.5x
- 80% hard cap on threshold
- Monotonically decreasing threshold as drive time increases

### Basic Decisions
- Fallback slower or equal to current route: no reroute
- Large savings: always reroute
- Tiny savings: never reroute

### Percentage Scaling Behavior
- Short drive with moderate savings: blocked by elevated threshold
- Short drive with large savings: triggers despite elevated threshold
- Medium drive at base percentage: triggers normally
- Long drive with small percentage: triggers due to lowered threshold

### Percentage Overrides Hard Floor (Critical)
- When percentage threshold is met, reroute triggers even if absolute savings
  is below the hard minute floor. This is the most important behavioral invariant.

### Hard Floor as Secondary Gate
- Only evaluated when percentage threshold is NOT met
- Savings above floor: triggers reroute
- Savings below floor: no reroute
- No floor configured (None): only percentage logic applies

### Remaining ETA Recalculation
- Same absolute savings produces different decisions at different remaining ETAs
- Demonstrates percentage-based evaluation against current position, not trip start

### Edge Cases
- Zero remaining ETA
- Negative savings
- 1-second savings
- No hard floor (None)
- Very high base percentage (50%)
- Very low base percentage (5%)
- Savings exactly at threshold boundary
- Hard floor of 0 minutes

### Decision Metadata
- `savings_minutes` calculation
- Detail fields populated correctly for each reason type

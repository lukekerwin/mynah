import numpy as np

from mynah_engine.meeting import MAX_REGION_S, plan_regions, split_long

SR = 16_000


def test_merges_small_gaps_and_keeps_large_ones():
    regions, consumed = plan_regions([(1.0, 2.0), (2.3, 3.0), (5.0, 6.0)], 30.0, final=False)
    assert regions == [(1.0, 3.0), (5.0, 6.0)]
    assert consumed == 30.0


def test_holds_back_speech_touching_window_end():
    regions, consumed = plan_regions([(1.0, 2.0), (27.0, 29.9)], 30.0, final=False)
    assert regions == [(1.0, 2.0)]
    assert consumed == 27.0


def test_final_window_keeps_tail():
    regions, consumed = plan_regions([(1.0, 2.0), (27.0, 30.0)], 30.0, final=True)
    assert regions == [(1.0, 2.0), (27.0, 30.0)]
    assert consumed == 30.0


def test_tail_longer_than_max_region_is_released_in_part():
    regions, consumed = plan_regions([(10.0, 119.9)], 120.0, final=False)
    assert regions == [(10.0, 10.0 + MAX_REGION_S)]
    assert consumed == 10.0 + MAX_REGION_S


def test_empty_window():
    assert plan_regions([], 30.0, final=False) == ([], 30.0)


def test_drops_tiny_regions_and_clamps():
    regions, _ = plan_regions([(-0.5, 0.1), (5.0, 5.1), (8.0, 9.0)], 30.0, final=True)
    assert regions == [(8.0, 9.0)]


def test_merging_never_exceeds_max_region():
    speech = [(i * 10.0, i * 10.0 + 9.8) for i in range(5)]  # 0.2 s gaps, 50 s total
    regions, _ = plan_regions(speech, 60.0, final=True)
    assert all(e - s <= MAX_REGION_S for s, e in regions)
    assert len(regions) >= 2


def test_split_long_cuts_at_quiet_point():
    audio = np.full(int(70 * SR), 0.1, dtype=np.float32)
    audio[int(20 * SR):int(20.2 * SR)] = 0.0  # quiet spot inside the search range
    pieces = split_long([(0.0, 70.0)], audio)
    assert all(e - s <= MAX_REGION_S for s, e in pieces)
    assert abs(pieces[0][1] - 20.1) < 0.15
    assert pieces[-1][1] == 70.0

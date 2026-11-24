"""Pure helpers for player unavailability (DISCON) episodes inside scoring windows."""

from __future__ import annotations



from datetime import datetime, timezone

from typing import List, Optional, Sequence, Tuple



Episode = Tuple[datetime, int]





def normalize_utc(ts: datetime) -> datetime:

    if ts.tzinfo is None:

        return ts.replace(tzinfo=timezone.utc)

    return ts





def apply_discon_event(

    attention_visible: bool, ws_connected: bool, reason: str

) -> Tuple[bool, bool]:

    if reason == "connection":

        ws_connected = True

    elif reason == "disconnection":

        ws_connected = False

    elif reason in ("visible",):

        attention_visible = True

    elif reason in ("invisible", "blur"):

        attention_visible = False

    return attention_visible, ws_connected





def is_unavailable(attention_visible: bool, ws_connected: bool) -> bool:

    return (not attention_visible) or (not ws_connected)





def _state_at_instant(

    events: Sequence[dict], instant: datetime

) -> Tuple[bool, bool]:

    """Attention + WS state immediately before *instant* (default available)."""

    attention_visible = True

    ws_connected = True

    inst = normalize_utc(instant)

    for ev in sorted(events, key=lambda e: normalize_utc(e["timestamp"])):

        ts = normalize_utc(ev["timestamp"])

        if ts >= inst:

            break

        attention_visible, ws_connected = apply_discon_event(

            attention_visible, ws_connected, str(ev["reason"])

        )

    return attention_visible, ws_connected





def compute_discon_episodes_in_window(

    events: Sequence[dict],

    window_start: datetime,

    window_end: datetime,

    *,

    include_leading_gap: bool = True,

) -> List[Episode]:

    """

    Closed unavailability episodes clipped to [window_start, window_end].



    Q2: optional leading gap window_start → first_available when player is late.

    Never available for the whole window → no episodes.

    Open episode at window_end is omitted (0 seconds credited).

    """

    if window_end <= window_start:

        return []



    ws = normalize_utc(window_start)

    we = normalize_utc(window_end)

    sorted_events = sorted(

        events,

        key=lambda e: normalize_utc(e.get("timestamp") or datetime.min.replace(tzinfo=timezone.utc)),

    )



    had_events_before = any(

        normalize_utc(ev["timestamp"]) < ws

        for ev in sorted_events

        if ev.get("timestamp") is not None

    )

    attention_visible, ws_connected = _state_at_instant(sorted_events, ws)

    if include_leading_gap and not had_events_before:

        attention_visible = False

        ws_connected = False

    completed: List[Episode] = []

    in_episode = is_unavailable(attention_visible, ws_connected)

    episode_start: Optional[datetime] = ws if in_episode else None

    ever_available = not in_episode

    leading_done = not include_leading_gap or not in_episode



    for ev in sorted_events:

        ts = ev.get("timestamp")

        if ts is None:

            continue

        ts = normalize_utc(ts)

        if ts < ws:

            continue

        if ts > we:

            break



        was_available = not is_unavailable(attention_visible, ws_connected)

        attention_visible, ws_connected = apply_discon_event(

            attention_visible, ws_connected, str(ev["reason"])

        )

        now_available = not is_unavailable(attention_visible, ws_connected)



        if now_available:

            ever_available = True



        if (

            include_leading_gap

            and not leading_done

            and now_available

            and episode_start is not None

        ):

            dur = max(0, int((ts - episode_start).total_seconds()))

            if dur > 0:

                completed.append((episode_start, dur))

            in_episode = False

            episode_start = None

            leading_done = True

            continue



        if was_available and not now_available:

            in_episode = True

            episode_start = ts

        elif not was_available and now_available and in_episode and episode_start is not None:

            dur = max(0, int((ts - episode_start).total_seconds()))

            if dur > 0:

                completed.append((episode_start, dur))

            in_episode = False

            episode_start = None



    if not ever_available:

        return []



    # Open episode at window end → 0 (omit)

    return completed





def merge_episode_durations(episodes: List[Episode]) -> List[Episode]:

    """Sort by start time; keep (start, duration) pairs."""

    return sorted(episodes, key=lambda x: x[0])





def sum_episode_seconds(episodes: Sequence[Episode]) -> int:

    return sum(sec for _, sec in episodes)





def format_discon_label(episodes: Sequence[Episode]) -> str:

    if not episodes:

        return ""

    ordered = sorted(episodes, key=lambda x: x[0])

    return ", ".join(f"{sec}s" for _, sec in ordered)





def compute_discon_for_windows(

    events: Sequence[dict],

    windows: Sequence[Tuple[datetime, datetime]],

    *,

    include_leading_gap: bool = True,

) -> List[Episode]:

    all_eps: List[Episode] = []

    for w_start, w_end in windows:

        all_eps.extend(

            compute_discon_episodes_in_window(

                events,

                w_start,

                w_end,

                include_leading_gap=include_leading_gap,

            )

        )

    return merge_episode_durations(all_eps)





def graph_points_for_round(

    events: Sequence[dict],

    round_start: Optional[datetime],

    round_end: Optional[datetime],

    scoring_segments: Optional[Sequence[Tuple[datetime, datetime]]] = None,

) -> List[dict]:

    """

    Step graph: t_sec from round_start; y=+1 available, -1 unavailable (visibility or disconnect).

    When scoring_segments is set (classic mode), points outside union of segments are omitted

    except t=0 anchor when round_start is inside a segment.

    """

    if round_start is None:

        return []

    rs = normalize_utc(round_start)

    re = normalize_utc(round_end) if round_end is not None else None



    def in_scoring(t: datetime) -> bool:

        if not scoring_segments:

            return True

        tt = normalize_utc(t)

        for seg_s, seg_e in scoring_segments:

            if normalize_utc(seg_s) <= tt <= normalize_utc(seg_e):

                return True

        return False



    points: List[dict] = []

    attention_visible = True

    ws_connected = True



    def y_value() -> int:

        return -1 if is_unavailable(attention_visible, ws_connected) else 1



    def append_point(ts: datetime) -> None:

        if re is not None and ts > re:

            ts = re

        if not in_scoring(ts):

            return

        t_sec = max(0, int((ts - rs).total_seconds()))

        y = y_value()

        if points and points[-1]["t_sec"] == t_sec and points[-1]["y"] == y:

            return

        points.append({"t_sec": t_sec, "y": y})



    sorted_events = sorted(

        events,

        key=lambda e: normalize_utc(e.get("timestamp") or datetime.min.replace(tzinfo=timezone.utc)),

    )

    if sorted_events:

        first_ts = normalize_utc(sorted_events[0]["timestamp"])

        if in_scoring(first_ts):

            points.append({"t_sec": max(0, int((first_ts - rs).total_seconds())), "y": 0})



    for ev in sorted_events:

        ts = ev.get("timestamp")

        if ts is None:

            continue

        ts = normalize_utc(ts)

        if re is not None and ts > re:

            break

        attention_visible, ws_connected = apply_discon_event(

            attention_visible, ws_connected, str(ev["reason"])

        )

        append_point(ts)



    if not points and scoring_segments:

        for seg_s, _ in scoring_segments:

            if in_scoring(seg_s):

                points.append({"t_sec": max(0, int((normalize_utc(seg_s) - rs).total_seconds())), "y": 0})

                break

    return points


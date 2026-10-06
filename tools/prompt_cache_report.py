#!/usr/bin/env python3
"""Read request journals offline; no credentials or provider access."""
import collections
import glob
import json
import statistics
import sys


def report(paths):
    conversations = collections.defaultdict(list)
    tokens = collections.defaultdict(lambda: [0, 0])
    for path in paths:
        with open(path, encoding="utf-8") as source:
            for line in source:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                usage = row.get("tokens")
                # Tool receipts share the journal. Legacy rows have no record kind.
                if row.get("record_kind") not in (None, "model_request"):
                    continue
                if row.get("outcome") != "ok" or not isinstance(usage, dict):
                    continue
                uncached = int(usage.get("input", 0) or 0)
                cached = int(usage.get("cached_input", 0) or 0)
                stage = row.get("stage")
                tokens[stage][0] += uncached
                tokens[stage][1] += cached
                if stage != "develop":
                    continue
                # Legacy rows lack an explicit id; file + attempt/rung is the
                # best available grouping, but cannot identify checkpoints.
                key = row.get("conversation_id") or (
                    f"{path}:{row.get('attempt')}:{row.get('rung')}"
                )
                conversations[key].append((uncached + cached, cached, row.get("model")))
    measured = []
    for key, turns in sorted(conversations.items()):
        ratios = []
        for index, (_total, cached, model) in enumerate(turns):
            previous = turns[index - 1] if index else None
            if index >= 2 and previous and previous[0] and previous[2] == model:
                ratios.append(cached / previous[0])
        median = statistics.median(ratios) if ratios else None
        measured.append({"conversation_id": key, "samples": len(ratios),
                         "median_previous_input_reuse": median,
                         "meets_target": median >= 0.95 if median is not None else None})
    rates = {stage: cached / (uncached + cached) if uncached + cached else None
             for stage, (uncached, cached) in sorted(tokens.items())}
    return {"cache_hit_rate_by_stage": rates, "develop_conversations": measured}


if __name__ == "__main__":
    paths = sorted({path for pattern in sys.argv[1:] for path in glob.glob(pattern)})
    if not paths:
        raise SystemExit("Pass one or more requests.jsonl paths or quoted glob patterns")
    print(json.dumps(report(paths), indent=2))

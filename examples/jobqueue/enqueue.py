#!/usr/bin/env python3
"""Push one job onto the queue.

    python enqueue.py '{"task": "finetune", "epochs": 3}'
"""
import json
import os
import sys

import redis

QUEUE = os.environ.get("JOB_QUEUE", "homelab:jobs")
r = redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"))


def main() -> None:
    payload = sys.argv[1] if len(sys.argv) > 1 else '{"task": "noop"}'
    job = json.loads(payload)            # validate it's JSON before queueing
    r.rpush(QUEUE, json.dumps(job))
    print(f"[enqueue] queued {job!r} on {QUEUE}")


if __name__ == "__main__":
    main()

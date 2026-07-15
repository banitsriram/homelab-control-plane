#!/usr/bin/env python3
"""Minimal Brain/Brawn job worker.

The Brain (this always-on node) enqueues jobs to Redis; a worker pops them and
does the heavy lifting — locally now, on a burst GPU later. This is the skeleton
the dispatch pattern grows from, not a scheduler. Replace `run_job` with your
real handler (e.g. spin up a RunPod GPU, run the job, tear it down).

    pip install redis
    docker compose up -d redis
    python enqueue.py '{"task": "finetune", "epochs": 3}'
    python worker.py
"""
import json
import os
import sys
import time

import redis

QUEUE = os.environ.get("JOB_QUEUE", "homelab:jobs")
r = redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"))


def run_job(job: dict) -> None:
    # ponytail: placeholder handler. Swap for real GPU-burst dispatch —
    # provision RunPod/GCP, run the job, tear the instance down.
    print(f"[worker] running {job!r}")
    time.sleep(1)
    print(f"[worker] done: {job.get('task')}")


def main() -> None:
    print(f"[worker] waiting on {QUEUE} …")
    while True:
        _, raw = r.blpop(QUEUE)          # blocks until a job arrives
        try:
            job = json.loads(raw)
        except json.JSONDecodeError:
            print(f"[worker] skipping bad payload: {raw!r}", file=sys.stderr)
            continue
        run_job(job)


if __name__ == "__main__":
    main()

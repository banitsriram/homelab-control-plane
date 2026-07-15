# Job queue — the Brain/Brawn dispatch skeleton

The always-on node (**Brain**) is cheap and never has a GPU. Long ML jobs run on
on-demand cloud GPUs (**Brawn**) that spin up, work, and tear down. Redis is the
seam between them: the Brain pushes jobs, a worker pops them and dispatches.

```
enqueue.py ──rpush──▶  Redis list  ──blpop──▶  worker.py ──▶  run_job()
 (Brain / API)        (homelab:jobs)          (poller)        └─ your GPU burst
```

This is deliberately ~40 lines each — a starting point, not a task framework.
When you outgrow a plain list (retries, scheduling, dead-letters), reach for
[RQ](https://python-rq.org) or [Celery](https://docs.celeryq.dev); the enqueue
side barely changes.

## Try it

```bash
docker compose up -d redis            # from the repo root
pip install redis
python worker.py &                    # start the Brawn-side poller
python enqueue.py '{"task": "finetune", "epochs": 3}'
```

## Wiring it to real services

- **Kairos (or any app) as producer** — join its compose to the shared `homelab`
  network and point it at `redis://homelab-redis:6379`. From the host, use the
  loopback-published `redis://localhost:6379`.
- **`run_job` as the GPU burst** — replace the placeholder with: provision a
  RunPod/GCP GPU, submit the job, poll to completion, tear the instance down.
  The queue guarantees the Brain stays responsive while the Brawn does the work.

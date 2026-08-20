# Chaos scenarios — Phase 12 (and earlier)

Scripted failure injection. Each one has a matching runbook in `runbooks/`;
running the scenario is how the runbook gets exercised and corrected.

| Script                    | Injects                        | Runbook                     | Phase |
| ------------------------- | ------------------------------ | --------------------------- | ----- |
| `rds-failover.sh`         | forced Multi-AZ failover       | `rds-failover.md`           | 4     |
| `backup-restore.sh`       | PITR restore drill             | `restore-procedure.md`      | 5     |
| `connection-storm.py`     | connection exhaustion          | `connection-exhaustion.md`  | 6     |
| `long-running-query.sql`  | a query that will not finish   | `slow-query.md`             | 7     |
| `deadlock-test.sql`       | two transactions, opposite order | `deadlock.md`             | 7     |
| `replication-lag.sh`      | write burst against a replica  | `replication-lag.md`        | 8     |
| `secret-rotation.sh`      | credential rotation mid-traffic | `secret-rotation.md`       | 9     |

Every scenario records `T0..T5` timestamps so detection, failover and recovery
times are measured rather than estimated.

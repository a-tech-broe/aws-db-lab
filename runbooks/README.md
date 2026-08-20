# Runbooks

One per incident class. Format is fixed — see `docs/runbook-template.md`.

Phase 1 ships the four that its alarms can actually fire. The rest arrive with
the phase that creates the failure mode, because a runbook written before you
have ever caused the incident is fiction.

| Runbook                          | Alarm that fires it              | Phase |
| -------------------------------- | -------------------------------- | ----- |
| [rds-unavailable.md](rds-unavailable.md) | `rds-no-metrics`         | 1     |
| [high-cpu.md](high-cpu.md)       | `rds-cpu-high`, `rds-cpu-credits-low`, `rds-memory-low` | 1 |
| [high-storage.md](high-storage.md) | `rds-storage-low`              | 1     |
| [connection-exhaustion.md](connection-exhaustion.md) | `rds-connections-high` | 1 |
| rds-failover.md                  | `rds-no-metrics`                 | 4     |
| restore-procedure.md             | manual                           | 5     |
| backup-failure.md                | AWS Backup event                 | 5     |
| slow-query.md                    | `rds-read-latency-high`          | 7     |
| deadlock.md                      | `Deadlocks` metric               | 7     |
| replication-lag.md               | `rds-replica-lag-high`           | 8     |
| secret-rotation.md               | rotation failure event           | 9     |
| security-group-exposure.md       | Config rule / GuardDuty          | 9     |
| migration-failure.md             | DMS task event                   | 10    |
| regional-failure.md              | manual                           | 11    |

## Conventions

Every command block assumes:

```bash
export AWS_REGION=us-east-1
export DB_ID=$(terraform -chdir=terraform/environments/dev output -raw db_instance_id)
```

Command blocks use BSD `date` (`date -u -v-1H`), matching macOS. On Linux the
equivalent is `date -u -d '1 hour ago'`.

`psql` runs from inside the VPC — the maintenance host (`enable_bastion = true`)
or an ECS task. The database has no public endpoint, and `rds.force_ssl` means
every connection needs `sslmode=require`.

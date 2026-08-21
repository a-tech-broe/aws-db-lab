# Phase 1 architecture

## What exists after `terraform apply`

```
                            AWS account / us-east-1
┌───────────────────────────────────────────────────────────────────────────┐
│  VPC  10.20.0.0/16                                                        │
│                                                                           │
│  ┌── us-east-1a ──────┐  ┌── us-east-1b ──────┐  ┌── us-east-1c ──────┐   │
│  │                    │  │                    │  │                    │   │
│  │ public             │  │ public             │  │ public             │   │
│  │ 10.20.0.0/24       │  │ 10.20.1.0/24       │  │ 10.20.2.0/24       │   │
│  │  └─ NAT GW ──┐     │  │                    │  │                    │   │
│  │              │     │  │                    │  │                    │   │
│  ├──────────────┼─────┤  ├────────────────────┤  ├────────────────────┤   │
│  │              │     │  │                    │  │                    │   │
│  │ private-app  ▼     │  │ private-app        │  │ private-app        │   │
│  │ 10.20.16.0/20      │  │ 10.20.32.0/20      │  │ 10.20.48.0/20      │   │
│  │  (ECS, Phase 2)    │  │                    │  │                    │   │
│  │  [app SG]          │  │                    │  │                    │   │
│  ├────────┬───────────┤  ├─────────┬──────────┤  ├────────────────────┤   │
│  │        │ :5432     │  │         │ :5432    │  │                    │   │
│  │ private-db         │  │ private-db         │  │ private-db         │   │
│  │ 10.20.128.0/24     │  │ 10.20.129.0/24     │  │ 10.20.130.0/24     │   │
│  │        ▼           │  │         ▼          │  │                    │   │
│  │  ┌──────────────┐  │  │  ┌──────────────┐  │  │                    │   │
│  │  │ RDS PRIMARY  │◄─┼──┼─►│ RDS STANDBY  │  │  │  (spare AZ for     │   │
│  │  │ PostgreSQL16 │ sync │  │ (Multi-AZ)   │  │  │   failover room)  │   │
│  │  └──────────────┘  │  │  └──────────────┘  │  │                    │   │
│  │      [db SG]       │  │                    │  │                    │   │
│  └────────────────────┘  └────────────────────┘  └────────────────────┘   │
│                                                                           │
│   db subnets have NO route to IGW or NAT — the tier cannot reach out      │
└───────────────────────────────────────────────────────────────────────────┘
        │                    │                     │
        ▼                    ▼                     ▼
  KMS CMK              Secrets Manager        CloudWatch
  (rotation on)        awsdblab-dev/          ├─ 8 alarms ─► SNS topic
  encrypts:            rds/master             ├─ dashboard
   • RDS storage       user/password/         ├─ RDS logs (postgresql, upgrade)
   • PI data           host/port/dbname       ├─ VPC flow logs
   • secret            KMS-encrypted          └─ Enhanced Monitoring (30s)
   • SNS topic
   • log groups
```

## The three-tier split, and why the app tier is so much bigger

| Tier          | Size per AZ | Route to internet | Occupants                         |
| ------------- | ----------- | ----------------- | --------------------------------- |
| `public`      | `/24` (251) | IGW               | NAT gateway, ALB (Phase 2)        |
| `private-app` | `/20` (4091)| NAT only          | ECS Fargate tasks (Phase 2)       |
| `private-db`  | `/24` (251) | **none**          | RDS, RDS Proxy (Phase 6)          |

Fargate consumes one VPC IP per task. Phase 6 deliberately runs a connection
storm from many tasks at once, and a `/24` app subnet would exhaust its IPs
before the database ran out of connections — which would break the experiment
by failing in the wrong layer. The `/20` removes that confound.

The database tier has no default route at all. Everything RDS needs — backups
to S3, metric publication, Enhanced Monitoring — travels over the AWS internal
network, not through the VPC's routing table. A NAT route there would be pure
attack surface.

## The one ingress path

```
  app SG  ──egress :5432──►  db SG  ──ingress :5432 from app SG──►  RDS
```

The database security group references the *application security group*, not a
CIDR. This matters for two reasons:

1. It survives re-addressing. Change `vpc_cidr` and the rule is still correct.
2. It is unambiguous during an audit. "Who can reach the database?" has exactly
   one answer — whatever is attached to the app SG — instead of "anything that
   happens to land in 10.20.16.0/20."

Ingress rules are separate `aws_vpc_security_group_ingress_rule` resources
rather than inline blocks, so the Phase 9 security-incident exercise can add
and remove a deliberately-bad `0.0.0.0/0` rule without rewriting the group.

`scripts/validate.sh` asserts the CIDR-rule count on the db SG is exactly zero.

## Key decisions and their trade-offs

| Decision                        | Chosen              | Why                                                                                   | Cost of the alternative                       |
| ------------------------------- | ------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------- |
| AZ count                        | 3                   | Multi-AZ needs 2; the third gives failover somewhere to land twice and hosts a replica in Phase 8 | 2 AZs pin the replica onto the standby's AZ   |
| NAT gateways                    | 1 (`single_nat_gateway = true`) | ~$32/month instead of ~$96                                                | A NAT AZ failure isolates the whole app tier — flip the flag for production posture |
| Instance class                  | `db.t4g.medium`     | Graviton, 4 GiB, ~450 connections — enough for connection exhaustion to be reachable  | `db.m6g.large` is ~3x the cost for no extra lesson |
| Storage                         | `gp3`, 50 GiB, autoscale to 200 | Baseline IOPS without provisioning io1/io2                                | `gp2` ties IOPS to volume size and hides the Phase 7 signal |
| Engine version pin              | `"16"` (major only) | AWS picks the latest minor; `ignore_changes` stops plan churn after a maintenance-window bump | Pinning `16.14` means editing Terraform every quarter |
| Multi-AZ                        | on                  | Phase 4 is the failover lab; it is the whole point                                    | Single-AZ halves cost but deletes Phase 4     |
| Backup retention                | 7 days              | Defines the PITR window Phase 5 restores into                                          | 1 day is cheaper and makes Phase 5 unrunnable |
| Deletion protection             | on                  | Real posture; `scripts/destroy.sh` clears it deliberately                              | Off invites a one-keystroke data loss         |
| State backend                   | local               | Phase 1 is stood up and torn down repeatedly by one person                             | Remote state is required before CI/CD — the commented `backend "s3"` block is ready |

## Parameter group: tuned for the phases that come later

The instance is not on `default.postgres16`. Every parameter set is there
because a later phase needs it:

| Parameter                             | Value                | Serves                                    |
| ------------------------------------- | -------------------- | ----------------------------------------- |
| `shared_preload_libraries`            | `pg_stat_statements` | Phase 7 — query-level attribution         |
| `log_min_duration_statement`          | `1000` ms            | Phase 7 — slow queries reach CloudWatch   |
| `log_lock_waits`, `deadlock_timeout`  | on, `1000` ms        | Phase 7 — locks and deadlocks             |
| `log_connections`, `log_disconnections` | on                 | Phase 6 — connection churn is visible     |
| `rds.force_ssl`                       | `1`                  | Phase 9 — TLS is non-optional from day one |
| `statement_timeout`                   | `900000` ms          | Guards against a runaway lab query        |
| `idle_in_transaction_session_timeout` | `300000` ms          | Stops abandoned transactions pinning vacuum |
| `log_line_prefix`                     | `%m:%r:%u@%d:[%p]:%l:%e:%s:%v:%x:%c:%q%a:` | Makes the log group greppable during an incident. RDS allows only two values for this; this is the verbose one, adding ms precision, SQLSTATE, txid and `application_name` |

`shared_preload_libraries` and `rds.force_ssl` are `pending-reboot`; they take
effect on the first reboot after apply. `validate.sh` reports the parameter
group as `applying` rather than `in-sync` until then.

## Alarms

Thresholds are percentages of the instance's real capacity, not magic numbers,
so changing `db_instance_class` does not silently invalidate them.

| Alarm                     | Metric              | Trips at                    | Signal       |
| ------------------------- | ------------------- | --------------------------- | ------------ |
| `rds-no-metrics`          | `DatabaseConnections` | missing data for 3 minutes | availability |
| `rds-cpu-high`            | `CPUUtilization`    | > 80% for 3 min             | saturation   |
| `rds-cpu-credits-low`     | `CPUCreditBalance`  | < 30 for 10 min             | saturation   |
| `rds-memory-low`          | `FreeableMemory`    | < 10% of RAM for 5 min      | saturation   |
| `rds-storage-low`         | `FreeStorageSpace`  | < 20% of allocated for 10 min | saturation |
| `rds-connections-high`    | `DatabaseConnections` | > 80% of max_connections   | saturation   |
| `rds-read-latency-high`   | `ReadLatency`       | > 50 ms for 5 min           | latency      |
| `rds-write-latency-high`  | `WriteLatency`      | > 50 ms for 5 min           | latency      |

Two of these are worth explaining.

**`rds-no-metrics` alarms on absence.** CloudWatch has no "the database is up"
metric. When an instance reboots, fails over, or stops, it simply stops
publishing. Every other alarm here sets `treat_missing_data = "missing"`, which
holds the last state — exactly the wrong behaviour for an outage. This one sets
`treat_missing_data = "breaching"`, so silence *is* the alert. It is the alarm
Phase 4 watches to timestamp T1 (failure detected).

**`rds-cpu-credits-low` exists because the class is burstable.** On a `t4g`,
sustained load past the credit balance gets throttled to baseline. CPU sits at
a comfortable-looking 40% while throughput collapses. Without this alarm, the
CPU alarm never fires and the incident looks like a mystery. It is created only
when `db_instance_class` matches a burstable family.

## What Phase 1 deliberately does not build

| Not here            | Arrives in | Attaches to                                     |
| ------------------- | ---------- | ----------------------------------------------- |
| ALB, ECS Fargate    | Phase 2    | `public_subnet_ids`, `private_app_subnet_ids`, `app_security_group_id` |
| RDS Proxy           | Phase 6    | `private_db_subnet_ids`, `db_secret_arn`        |
| Read replica        | Phase 8    | `db_instance_arn`, `create_replica_lag_alarm`   |
| AWS Backup vault    | Phase 5    | `kms_key_arn`                                   |
| Secret rotation     | Phase 9    | `db_secret_arn` (the RDS-managed rotation Lambda reads this schema unmodified) |
| Cross-region DR     | Phase 11   | a second provider alias in `us-west-2`          |

Every one of those hangs off an output this phase already publishes. The
outputs in `terraform/environments/dev/outputs.tf` are the contract — adding to
them is safe, renaming them breaks `scripts/` and the later phases.

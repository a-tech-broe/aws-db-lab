# Connection exhaustion

**Severity:** SEV-1 · **Owner:** database on-call · **Last exercised:** not yet (Phase 6)

## 1. Symptoms

- `awsdblab-dev-rds-connections-high` in `ALARM` — above 80% of `max_connections`
  (360 of ~450 on `db.t4g.medium`).
- Application errors: `FATAL: sorry, too many clients already`, or
  `remaining connection slots are reserved for non-replication superuser connections`.
- New deployments fail health checks while existing tasks keep working.

## 2. Impact

Escalates sharply. At 80% it is a warning; at 100% *no new connection succeeds*,
including the ones you need to diagnose it. PostgreSQL reserves
`superuser_reserved_connections` (3 by default) so an admin can still get in —
that reserve is the only thing standing between you and a locked room.

## 3. Detection

`DatabaseConnections` is a 60-second metric with a 2-period alarm, so ~2 minutes
of warning. A genuine connection storm crosses 80% to 100% in seconds, so treat
this alarm as "already happening," not "about to happen."

## 4. Initial investigation

Open an admin session **first**, before diagnosing — if you hit 100% while
looking, you will not get one:

```bash
# From inside the VPC
psql "host=$(terraform -chdir=terraform/environments/dev output -raw db_instance_address) \
      dbname=appdb user=dbadmin sslmode=require application_name=oncall"
```

```bash
# 1. How close to the ceiling, and how fast did it get there?
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
  --start-time "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text

# 2. Did something just scale out? (Phase 2 onward)
aws ecs describe-services --cluster awsdblab-dev --services api \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Events:events[:3].message}'

# 3. log_connections is on, so the connection storm is in the log group
aws logs filter-log-events --log-group-name "/aws/rds/instance/${DB_ID}/postgresql" \
  --start-time "$(( ($(date +%s) - 900) * 1000 ))" \
  --filter-pattern '"connection authorized"' \
  --query 'length(events)' --output text
```

## 5. AWS commands

```bash
# What is max_connections actually set to? RDS derives it from instance memory
# unless the parameter group overrides it.
aws rds describe-db-parameters \
  --db-parameter-group-name "$(terraform -chdir=terraform/environments/dev output -raw db_parameter_group_name)" \
  --query "Parameters[?ParameterName=='max_connections'].[ParameterValue,Source]" --output text

# Emergency capacity: scale the application down, not the database up.
aws ecs update-service --cluster awsdblab-dev --service api --desired-count 1
```

## 6. PostgreSQL commands

```sql
-- The ceiling and the current draw, side by side
SELECT current_setting('max_connections')::int              AS max_connections,
       current_setting('superuser_reserved_connections')::int AS reserved,
       count(*)                                              AS in_use,
       count(*) FILTER (WHERE state = 'idle')                AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
       count(*) FILTER (WHERE state = 'active')              AS active
FROM pg_stat_activity;

-- Who is holding them? This names the culprit.
SELECT usename, application_name, client_addr, state, count(*)
FROM pg_stat_activity
GROUP BY 1, 2, 3, 4
ORDER BY count(*) DESC;

-- Idle-in-transaction is the worst category: holds a connection AND a snapshot,
-- which blocks vacuum and pins WAL.
SELECT pid, usename, application_name, client_addr,
       now() - state_change AS idle_for, left(query, 100) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY state_change
LIMIT 20;

-- Reclaim, most-abandoned first. Cancel before terminate.
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND state_change < now() - interval '10 minutes'
  AND pid <> pg_backend_pid();

-- Plain idle connections older than an hour: almost always a leaked pool
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < now() - interval '1 hour'
  AND pid <> pg_backend_pid();
```

## 7. Root-cause analysis

| Evidence                                                       | Cause                        | Go to |
| -------------------------------------------------------------- | ---------------------------- | ----- |
| Connections jump in a step, matching a task-count increase     | Scale-out × pool size        | §8 A  |
| Mostly `idle`, connection count never falls back               | Pool leak — connections not returned | §8 B |
| Many `idle in transaction`, ages growing                       | Application opens a transaction and does not close it | §8 B |
| Connections climb steadily over days                           | Slow leak                    | §8 B  |
| Count is normal but every connection is `active` and slow      | Not exhaustion — see `high-cpu.md` | — |
| One `client_addr` owns most connections                        | A single bad deploy or task  | §8 A  |

The arithmetic that causes this: **tasks × pool size must stay under
`max_connections`.** Four tasks with a pool of 100 is 400 connections against a
~450 ceiling — Phase 6 builds exactly that, on purpose.

## 8. Remediation

**A — reduce demand.** Fastest and safest. Scale the application in, or cap the
pool size and redeploy:

```bash
aws ecs update-service --cluster awsdblab-dev --service api --desired-count 2
```

**B — reclaim leaked connections.** Use the `pg_terminate_backend` queries in
§6. Terminate `idle in transaction` first — those cost the most beyond the
connection slot itself. Do not terminate `active` connections indiscriminately;
you will roll back real work.

**C — raise the ceiling.** A stopgap that trades connections for memory. Each
backend costs several MB, so this moves the failure from "too many clients" to
"out of memory." Requires a reboot:

```hcl
# in the rds module parameter group
parameter {
  name         = "max_connections"
  value        = "600"
  apply_method = "pending-reboot"
}
```

Also update `db_max_connections` in `terraform.tfvars` so the alarm rescales.

**D — put RDS Proxy in front (the durable fix, Phase 6).** The proxy holds a
small pool of real database connections and multiplexes many client connections
over it. Application scale-out stops translating one-to-one into database
connections, and the proxy holds client connections open across a failover
instead of dropping them.

```
  before:  4 tasks × 100 =  400 database connections
  after:   4 tasks × 100 → proxy → ~20 database connections
```

## 9. Validation

```bash
# Connection count back to baseline and stable
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
  --start-time "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Maximum Average --output table

aws cloudwatch describe-alarms --alarm-names awsdblab-dev-rds-connections-high \
  --query 'MetricAlarms[0].StateValue' --output text   # -> OK
```

```sql
-- Headroom restored, and no idle-in-transaction backlog
SELECT count(*) AS in_use,
       current_setting('max_connections')::int AS ceiling,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn
FROM pg_stat_activity;
```

A new connection must succeed from a cold client — that is the real test:

```bash
psql "host=... dbname=appdb user=dbadmin sslmode=require" -c 'SELECT 1;'
```

## 10. Rollback

Terminated connections cannot be restored; the application must reconnect, and
any in-flight transaction is rolled back by PostgreSQL. Scaling the service back
up is a single command. A `max_connections` increase reverts by restoring the
parameter and rebooting.

## 11. RTO / RPO impact

| Action                    | Downtime               | Data loss |
| ------------------------- | ---------------------- | --------- |
| Terminate idle connections | none                  | none      |
| Terminate idle-in-txn      | none                  | that transaction's uncommitted work |
| Scale the service in       | reduced capacity      | none      |
| Raise `max_connections`    | reboot, 2–5 min       | none      |
| Add RDS Proxy              | none (new endpoint)   | none      |

## 12. Preventive actions

- Keep `tasks × pool_size < 0.8 × max_connections` as a deployment invariant.
- `idle_in_transaction_session_timeout = 300000` is already set — it reaps the
  worst category automatically after 5 minutes.
- `log_connections` and `log_disconnections` are on, so churn is reconstructable
  from CloudWatch Logs after the fact.
- Set `application_name` in the application's connection string. Without it,
  `pg_stat_activity` cannot tell you which service is leaking.
- The connection alarm is a percentage of `db_max_connections` — update that
  variable whenever the instance class changes, or it will point at the wrong
  ceiling.
- RDS Proxy (Phase 6) is the structural fix; everything above is mitigation.

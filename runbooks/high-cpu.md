# High CPU / memory pressure

**Severity:** SEV-2 · **Owner:** database on-call · **Last exercised:** not yet (Phase 7)

## 1. Symptoms

- `awsdblab-dev-rds-cpu-high` in `ALARM` (> 80% for 3 minutes), **or**
- `awsdblab-dev-rds-cpu-credits-low` in `ALARM` while CPU looks *fine*, **or**
- `awsdblab-dev-rds-memory-low` in `ALARM` (`FreeableMemory` < 10% of RAM).
- Application latency rises across the board, including simple queries.

## 2. Impact

Degradation before outage. Every query slows, including health checks. If
credits are exhausted on a burstable class, throughput is capped at baseline
until they recover — a cliff, not a slope.

## 3. Detection

`CPUUtilization` is a 60-second average, so a 20-second spike may not trip a
3-period alarm. Performance Insights samples every second and is the better
first stop. `CPUCreditBalance` publishes every 5 minutes.

## 4. Initial investigation

```bash
# 1. Is this CPU, credits, or memory? Look at all three together.
for m in CPUUtilization CPUCreditBalance FreeableMemory; do
  echo "== $m"
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name "$m" \
    --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
    --start-time "$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Average --output text --query 'Datapoints[].[Timestamp,Average]' | sort
done

# 2. What is the database actually spending time on?
#    (top wait events over the last hour, from Performance Insights)
aws pi get-resource-metrics --service-type RDS \
  --identifier "$(terraform -chdir=terraform/environments/dev output -raw db_instance_resource_id)" \
  --metric-queries '[{"Metric":"db.load.avg","GroupBy":{"Group":"db.wait_event","Limit":7}}]' \
  --start-time "$(date -u -v-1H +%s)" --end-time "$(date -u +%s)" --period-in-seconds 300
```

## 5. AWS commands

```bash
# Top SQL by database load — the single most useful query here
aws pi describe-dimension-keys --service-type RDS \
  --identifier "$(terraform -chdir=terraform/environments/dev output -raw db_instance_resource_id)" \
  --metric db.load.avg --group-by '{"Group":"db.sql","Limit":10}' \
  --start-time "$(date -u -v-1H +%s)" --end-time "$(date -u +%s)" \
  --query 'Keys[].{Load:Total,SQL:Dimensions."db.sql.statement"}' --output table

# Slow statements RDS already logged for you (log_min_duration_statement = 1000ms)
aws logs filter-log-events --log-group-name "/aws/rds/instance/${DB_ID}/postgresql" \
  --start-time "$(( ($(date +%s) - 3600) * 1000 ))" \
  --filter-pattern '"duration:"' --max-items 40 \
  --query 'events[].message' --output text

# Autovacuum is a common invisible CPU consumer (log_autovacuum_min_duration = 0)
aws logs filter-log-events --log-group-name "/aws/rds/instance/${DB_ID}/postgresql" \
  --start-time "$(( ($(date +%s) - 3600) * 1000 ))" \
  --filter-pattern '"automatic vacuum"' --max-items 20 \
  --query 'events[].message' --output text
```

## 6. PostgreSQL commands

```sql
-- What is running right now, worst first
SELECT pid, usename, application_name, state,
       now() - query_start AS runtime,
       wait_event_type, wait_event, left(query, 120) AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;

-- Cumulative worst offenders (needs pg_stat_statements, preloaded by the
-- project parameter group)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT round(total_exec_time::numeric, 1) AS total_ms,
       calls,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       rows,
       left(query, 120) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 15;

-- Sequential scans on large tables: the classic missing index (Phase 7)
SELECT relname, seq_scan, seq_tup_read, idx_scan,
       seq_tup_read / NULLIF(seq_scan, 0) AS avg_rows_per_seq_scan,
       n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > 0 AND n_live_tup > 10000
ORDER BY seq_tup_read DESC
LIMIT 10;

-- Cache hit ratio: below ~0.99 means the working set exceeds shared_buffers,
-- which shows up as CPU *and* read IOPS
SELECT sum(heap_blks_hit) / NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0) AS cache_hit_ratio
FROM pg_statio_user_tables;

-- Bloat forcing autovacuum to work hard
SELECT relname, n_dead_tup, n_live_tup,
       round(100 * n_dead_tup::numeric / NULLIF(n_live_tup, 0), 1) AS dead_pct,
       last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;
```

## 7. Root-cause analysis

| Evidence                                                       | Cause                          | Go to |
| -------------------------------------------------------------- | ------------------------------ | ----- |
| One query dominates `pg_stat_statements` by `total_exec_time`  | Bad query or missing index     | §8 A  |
| High `seq_scan` + `seq_tup_read` on a large table              | Missing index                  | §8 A  |
| CPU normal, credits falling, throughput capped                 | Burstable class exhausted      | §8 C  |
| `cache_hit_ratio` < 0.99, `FreeableMemory` low, read IOPS high | Working set > RAM              | §8 C  |
| Many identical queries, `calls` enormous, `mean_exec_time` low | Application-side N+1           | §8 D  |
| `wait_event_type = Lock`                                       | Contention, not CPU            | `deadlock.md` (Phase 7) |
| `autovacuum` in `pg_stat_activity`, high `n_dead_tup`          | Vacuum debt                    | §8 B  |
| Connection count also at its ceiling                           | Connection storm               | `connection-exhaustion.md` |

## 8. Remediation

Least destructive first.

**A — kill the offending query, then fix it properly.**

```sql
-- Ask politely
SELECT pg_cancel_backend(<pid>);
-- Only if that does not return within ~10s
SELECT pg_terminate_backend(<pid>);
```

Then get the plan and add the index — this is the durable fix:

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM customers WHERE email = 'user@example.com';
-- Seq Scan on a large table => index it, without locking writes:
CREATE INDEX CONCURRENTLY idx_customers_email ON customers (email);
ANALYZE customers;
```

**B — clear vacuum debt.**

```sql
VACUUM (ANALYZE, VERBOSE) <table>;
-- For a table that keeps falling behind, make autovacuum more aggressive on it:
ALTER TABLE <table> SET (autovacuum_vacuum_scale_factor = 0.02);
```

**C — give it more capacity.** A resize restarts the instance (60–120s on
Multi-AZ, because it applies to the standby first, then fails over). Remember
to update the alarm-scaling variables, or every threshold silently becomes wrong:

```hcl
# terraform/environments/dev/terraform.tfvars
db_instance_class        = "db.m6g.large"   # non-burstable: no credit cliff
db_max_connections       = 900              # 8 GiB / 9531392
db_instance_memory_bytes = 8589934592       # 8 GiB
```

```bash
terraform -chdir=terraform/environments/dev apply
```

**D — fix the caller.** No database change helps an N+1. Batch the query in the
application. This is the only remediation on this list that is not a database
change, and it is frequently the correct one.

## 9. Validation

```bash
# CPU back under threshold, sustained for 15 minutes
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
  --start-time "$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Average Maximum --output table

# Alarms cleared
aws cloudwatch describe-alarms --alarm-name-prefix awsdblab-dev-rds \
  --state-value ALARM --query 'MetricAlarms[].AlarmName'
```

```sql
-- If an index was the fix, prove it changed the plan, not just the clock
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM customers WHERE email = 'user@example.com';
-- Expect: Index Scan using idx_customers_email

-- Reset the counters so the next incident starts from a clean baseline
SELECT pg_stat_statements_reset();
```

## 10. Rollback

```sql
DROP INDEX CONCURRENTLY idx_customers_email;   -- if the index hurt writes
```

An instance-class change reverts by setting the old values in `terraform.tfvars`
and applying — another 60–120s restart. Terminated queries cannot be rolled
back; the client must retry.

## 11. RTO / RPO impact

No data loss on any path here. Downtime is zero except for a resize
(60–120s on Multi-AZ). `CREATE INDEX CONCURRENTLY` does not block writes but
takes longer and fails if it deadlocks — check for an `INVALID` index and drop
it before retrying.

## 12. Preventive actions

- `pg_stat_statements` is preloaded, so attribution is always available. Do not
  remove it from `shared_preload_libraries`.
- `log_min_duration_statement = 1000` puts every slow query in CloudWatch Logs
  before anyone pages you.
- `statement_timeout = 900000` caps any single runaway at 15 minutes.
- Keep `rds-cpu-credits-low` enabled on any burstable class — it is the only
  alarm that catches throttling while CPU still reads as healthy.
- Re-check `db_max_connections` and `db_instance_memory_bytes` whenever
  `db_instance_class` changes.

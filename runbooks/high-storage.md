# Storage exhaustion

**Severity:** SEV-1 (a full volume stops writes entirely) · **Owner:** database on-call

## 1. Symptoms

- `awsdblab-dev-rds-storage-low` in `ALARM` — free space below 20% of allocated.
- Writes fail: `ERROR: could not extend file ... No space left on device`.
- Instance status becomes `storage-full`; it then looks like an outage, so
  `rds-no-metrics` may fire too.

## 2. Impact

Reads continue; **writes stop**. Autovacuum cannot reclaim space without
temporary space of its own, so a full volume tends to stay full. Recovery
requires adding storage, which takes minutes to hours.

## 3. Detection

`FreeStorageSpace` is a 60-second metric; the alarm uses a 300s period and 2
evaluation periods, so expect it ~10 minutes after crossing 20%. Storage
autoscaling (`max_allocated_storage = 200`) usually intervenes first — the
alarm firing anyway means autoscaling did not keep up or has hit its ceiling.

## 4. Initial investigation

```bash
# 1. How much is left, and how fast is it falling?
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
  --start-time "$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Minimum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Minimum]' --output text

# 2. Has autoscaling already reacted, and is it near its ceiling?
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].{Allocated:AllocatedStorage,Max:MaxAllocatedStorage,Status:DBInstanceStatus}'

# 3. Is it WAL rather than table data? This is the one people miss.
aws cloudwatch get-metric-statistics --namespace AWS/RDS \
  --metric-name TransactionLogsDiskUsage \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
  --start-time "$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Maximum --output table
```

## 5. AWS commands

```bash
# Raise the autoscaling ceiling — takes effect immediately, no restart
aws rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --max-allocated-storage 500 --apply-immediately

# Or add storage directly. Cannot be undone, and cannot be repeated
# within 6 hours of the previous scaling operation.
aws rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --allocated-storage 100 --apply-immediately

# Watch it complete
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Allocated:AllocatedStorage}'
```

## 6. PostgreSQL commands

```sql
-- Where did the space go? Largest relations, including indexes and TOAST.
SELECT relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid))       AS table_only,
       pg_size_pretty(pg_indexes_size(c.oid))        AS indexes
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 20;

-- Database totals
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY 2 DESC;

-- Dead tuples holding space that vacuum should have reclaimed
SELECT relname, n_dead_tup, n_live_tup, last_autovacuum, last_vacuum
FROM pg_stat_user_tables WHERE n_dead_tup > 0 ORDER BY n_dead_tup DESC LIMIT 20;

-- The three things that pin WAL and stop it being recycled.
-- Any one of these will fill a volume while table data stays flat.
SELECT pid, state, now() - xact_start AS xact_age, left(query, 80)
FROM pg_stat_activity
WHERE xact_start IS NOT NULL ORDER BY xact_start LIMIT 10;    -- long transactions

SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;                                     -- inactive slots

SELECT * FROM pg_prepared_xacts;                               -- orphaned 2PC

-- Unused indexes: free space with no query-plan cost
SELECT relname, indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE idx_scan = 0 ORDER BY pg_relation_size(indexrelid) DESC;
```

## 7. Root-cause analysis

| Evidence                                                        | Cause                        | Go to |
| --------------------------------------------------------------- | ---------------------------- | ----- |
| One table dominates and is growing as expected                   | Organic growth               | §8 A  |
| High `n_dead_tup`, `last_autovacuum` old or null                 | Vacuum is not keeping up     | §8 B  |
| `TransactionLogsDiskUsage` climbing, table sizes flat            | WAL is pinned                | §8 C  |
| An inactive replication slot with large `retained`               | Orphaned slot (Phase 8)      | §8 C  |
| A transaction open for hours                                     | Application leaked a transaction | §8 C |
| Large indexes with `idx_scan = 0`                                | Dead weight                  | §8 D  |
| `AllocatedStorage == MaxAllocatedStorage`                        | Autoscaling ceiling hit      | §8 A  |

## 8. Remediation

**A — add storage.** The immediate unblock. Raise the ceiling first (free, no
restart), then the allocation if still needed:

```bash
aws rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --max-allocated-storage 500 --apply-immediately
```

Storage can only grow. It cannot be shrunk without a dump/restore into a new
instance, so raise the *ceiling* generously and the *allocation* conservatively.

**B — reclaim dead tuples.** `VACUUM` returns space to the table for reuse but
not to the filesystem. Only `VACUUM FULL` returns it to the OS, and it takes an
`ACCESS EXCLUSIVE` lock — the table is unreadable and unwritable for its
duration, and it needs free space equal to the table size to work:

```sql
VACUUM (ANALYZE, VERBOSE) <table>;      -- safe, online
VACUUM FULL <table>;                     -- last resort, locks the table
```

Prefer `pg_repack` if downtime is unacceptable.

**C — release pinned WAL.** Fix the cause, not the symptom:

```sql
SELECT pg_terminate_backend(<pid>);                     -- the stale transaction
SELECT pg_drop_replication_slot('<slot_name>');         -- an inactive slot
ROLLBACK PREPARED '<gid>';                              -- an orphaned 2PC
```

Dropping an *active* slot breaks the replica that depends on it. Confirm
`active = false` first.

**D — drop unused indexes.**

```sql
DROP INDEX CONCURRENTLY <index_name>;
```

## 9. Validation

```bash
# Free space recovering, and above the 20% threshold (10 GiB of 50)
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
  --start-time "$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Minimum --output table

aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text   # -> available
```

```sql
-- Writes work again
CREATE TABLE _storage_check(id int); DROP TABLE _storage_check;
```

## 10. Rollback

There is no rollback for added storage — it is one-way. A dropped index can be
recreated (`CREATE INDEX CONCURRENTLY`); a dropped replication slot means the
downstream replica must be rebuilt from a fresh snapshot.

## 11. RTO / RPO impact

| Action                 | Downtime                | Data loss |
| ---------------------- | ----------------------- | --------- |
| Raise ceiling          | none                    | none      |
| Add storage            | none (online, minutes)  | none      |
| `VACUUM`               | none                    | none      |
| `VACUUM FULL`          | table locked, minutes–hours | none  |
| Drop index/slot        | none                    | none      |

The real risk is time-to-detection: once the volume is genuinely full, writes
have already been failing, and every one of those is lost work at the
application layer.

## 12. Preventive actions

- Storage autoscaling is on (`max_allocated_storage = 200`). Keep the ceiling
  at least 2x the allocation.
- The storage alarm is a percentage of allocated storage, so resizing the
  volume rescales it automatically.
- Monitor `TransactionLogsDiskUsage` on the dashboard, not just
  `FreeStorageSpace` — WAL growth is invisible in table sizes.
- `idle_in_transaction_session_timeout = 300000` kills abandoned transactions
  after 5 minutes, which is the most common WAL-pinning cause.
- Before Phase 8 adds a read replica, add an alert for inactive replication
  slots — an orphaned slot will fill the primary's volume silently.

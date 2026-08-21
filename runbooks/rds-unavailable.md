# RDS unavailable

**Severity:** SEV-1 · **Owner:** database on-call · **Last exercised:** not yet (Phase 4)

## 1. Symptoms

- CloudWatch alarm `awsdblab-dev-rds-no-metrics` in `ALARM`.
- Application returns 5xx; `/db-health` fails or times out (Phase 2 onward).
- `psql` hangs, or fails with `could not connect to server: Connection timed out`
  or `the database system is starting up`.

## 2. Impact

Total loss of reads and writes. Every dependent service is down. If this is a
Multi-AZ failover it is bounded — typically 60–120 seconds — and self-healing.
If it is not, it is unbounded until acted on.

## 3. Detection

`rds-no-metrics` alarms on the *absence* of `DatabaseConnections` data points:
3 evaluation periods of 60s with `treat_missing_data = "breaching"`. Expect the
alarm ~3–4 minutes after the instance stops publishing. That lag is the
detection component of MTTR, and Phase 4 measures it directly.

## 4. Initial investigation

Answer these three, in order, before touching anything:

```bash
# 1. What does RDS think the instance is doing?
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,AZ:AvailabilityZone,MultiAZ:MultiAZ,Pending:PendingModifiedValues}'

# 2. Has AWS logged an event in the last hour?
aws rds describe-events --source-identifier "$DB_ID" --source-type db-instance \
  --duration 60 --query 'Events[].{Time:Date,Message:Message}' --output table

# 3. Is this a failover already in progress?
aws rds describe-events --source-identifier "$DB_ID" --source-type db-instance \
  --duration 60 --event-categories failover --output table
```

If (3) returns a `Multi-AZ instance failover started` event: this is a
failover, it will complete on its own. Go to §9 and time it. Do not intervene.

## 5. AWS commands

```bash
# Instance status, one line
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text

# Which AZ is the primary in right now? (this flips on failover)
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].AvailabilityZone' --output text

# Does the endpoint still resolve, and to what?
dig +short "$(terraform -chdir=terraform/environments/dev output -raw db_instance_address)"

# Recent PostgreSQL log — the instance often explains itself here
aws logs tail "/aws/rds/instance/${DB_ID}/postgresql" --since 30m

# Storage full masquerades as unavailable (see runbooks/high-storage.md)
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_ID" \
  --start-time "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 --statistics Minimum --output table

# Rule out the network path before blaming the database
aws ec2 describe-security-groups \
  --group-ids "$(terraform -chdir=terraform/environments/dev output -raw db_security_group_id)" \
  --query 'SecurityGroups[0].IpPermissions'
```

## 6. PostgreSQL commands

Only once a connection is possible again:

```sql
-- Did it just come up? Compare against the outage window.
SELECT pg_postmaster_start_time(), now() - pg_postmaster_start_time() AS uptime;

-- Is this the writer or a promoted standby?
SELECT pg_is_in_recovery();          -- false = accepting writes

-- Anything stuck?
SELECT pid, state, wait_event_type, wait_event, now() - query_start AS runtime, left(query, 80)
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;

-- Confirm the last write survived
SELECT max(created_at) FROM customers;   -- Phase 2 onward
```

## 7. Root-cause analysis

| Evidence                                                       | Cause                     | Action        |
| -------------------------------------------------------------- | ------------------------- | ------------- |
| `describe-events` shows `Multi-AZ instance failover started`   | Planned or unplanned failover | §8 path A |
| Status `storage-full`, `FreeStorageSpace` at floor              | Storage exhausted         | `high-storage.md` |
| Status `available` but connections refused                      | Connection limit reached  | `connection-exhaustion.md` |
| Status `modifying` / `rebooting`, recent `apply_immediately`    | Self-inflicted — a Terraform apply | §8 path B |
| Status `available`, `dig` resolves, but the client times out    | Network path, not the DB  | §8 path C |
| Status `available`, alarm cleared before you looked             | Transient blip            | §9 only    |
| Status `failed` or `incompatible-parameters`                    | Bad parameter group       | §8 path D |

## 8. Remediation

**Path A — failover in progress.** Do nothing to the database. Confirm the app
reconnects; if it does not, the fault is in the client's connection pool, not in
RDS. Restart the application tasks:

```bash
aws ecs update-service --cluster awsdblab-dev --service api --force-new-deployment
```

**Path B — self-inflicted modification.** Wait. `apply_immediately = true` is
set in this environment, so a Terraform change to the instance applies at once
and can restart it. Watch it complete:

```bash
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
```

**Path C — network path.** The database SG must have exactly one ingress rule,
referencing the app SG. Verify nothing removed it:

```bash
./scripts/validate.sh --quick   # asserts the ingress rule and CIDR count
```

**Path D — bad parameters.** Revert to the last known-good parameter group and
reboot:

```bash
aws rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --db-parameter-group-name default.postgres16 --apply-immediately
aws rds reboot-db-instance --db-instance-identifier "$DB_ID"
```

**Last resort — force a failover onto the standby.** Only when the primary is
wedged and the standby is healthy. Costs 60–120s of downtime, zero data loss
(the standby is synchronous):

```bash
aws rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover
```

## 9. Validation

```bash
# 1. RDS reports available
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].DBInstanceStatus' --output text   # -> available

# 2. The alarm has actually cleared, not just gone quiet
aws cloudwatch describe-alarms --alarm-names awsdblab-dev-rds-no-metrics \
  --query 'MetricAlarms[0].{State:StateValue,Since:StateUpdatedTimestamp}'

# 3. A real query succeeds end to end
psql "host=$(terraform -chdir=terraform/environments/dev output -raw db_instance_address) \
      dbname=appdb user=dbadmin sslmode=require" -c 'SELECT 1;'

# 4. Full posture re-check
./scripts/validate.sh
```

## 10. Rollback

A forced failover cannot be undone — the old primary becomes the new standby.
That is acceptable: both AZs are equivalent. If a parameter group was changed
in §8 path D, restore the project group once the instance is stable:

```bash
aws rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --db-parameter-group-name "$(terraform -chdir=terraform/environments/dev output -raw db_parameter_group_name)" \
  --apply-immediately
aws rds reboot-db-instance --db-instance-identifier "$DB_ID"
```

## 11. RTO / RPO impact

| Path                       | Downtime      | Data loss |
| -------------------------- | ------------- | --------- |
| Multi-AZ failover          | 60–120 s      | none — synchronous standby |
| Reboot with force-failover | 60–120 s      | none      |
| Reboot without failover    | 2–5 min       | none      |
| Parameter group revert     | 2–5 min       | none      |
| Restore from snapshot      | 20–45 min     | up to the snapshot age |
| PITR restore               | 30–60 min     | ~5 min (`restore-procedure.md`) |

Target RTO is **5 minutes**. Only the top four paths meet it.

## 12. Preventive actions

- Multi-AZ is on and enforced — `validate.sh` fails if it is turned off.
- Application connection pools must set a short `connect_timeout` and retry;
  a pool that caches a dead endpoint turns a 90-second failover into an
  outage that lasts until someone restarts it. Phase 4 measures exactly this.
- Keep `apply_immediately = false` in any environment where an unplanned
  restart is not acceptable.
- RDS Proxy (Phase 6) absorbs failover from the application's point of view by
  holding the client connection while the backend endpoint moves.

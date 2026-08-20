# <Incident name>

> Template. Every runbook in `runbooks/` follows these twelve sections.
> The point is that a tired on-call engineer at 03:00 can execute it without
> thinking. Commands must be copy-pasteable, not descriptive.

**Severity:** SEV-n · **Owner:** <team> · **Last exercised:** <date, which chaos scenario>

## 1. Symptoms
What the reporter or the alarm actually says. Include the alarm name.

## 2. Impact
Who is affected and how. Read/write? Partial? Total?

## 3. Detection
Which alarm, dashboard or metric surfaces this, and how long it takes to fire.

## 4. Initial investigation
The first three commands to run, in order, before forming a hypothesis.

## 5. AWS commands
```bash
```

## 6. PostgreSQL commands
```sql
```

## 7. Root-cause analysis
The branches. "If X then cause A; if Y then cause B."

## 8. Remediation
Ordered, with the least destructive option first.

## 9. Validation
How you prove it is actually fixed — not "it looks fine."

## 10. Rollback
What to do if remediation made it worse.

## 11. RTO / RPO impact
Time cost of each remediation path, and whether data loss is possible.

## 12. Preventive actions
What change stops this recurring. Link the PR or issue when one exists.

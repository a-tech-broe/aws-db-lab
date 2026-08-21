# What Phase 1 costs

**~$149/month, or $4.89/day, for the environment as currently deployed.**

Rates below came from the AWS Pricing API for `us-east-1` on 2026-08-21, or
were measured from the running environment. They are not hand-copied from a
pricing page, but AWS list prices do change -- re-run the queries if the number
matters.

| Item | Detail | USD/mo | Source |
| --- | --- | ---: | --- |
| RDS `db.t4g.medium`, Multi-AZ | $0.129/hr x 730 | 94.17 | Pricing API |
| RDS gp3 storage, Multi-AZ | $0.23/GB-mo x 50 GB | 11.50 | Pricing API |
| NAT gateway (1) | $0.045/hr x 730 | 32.85 | Pricing API |
| Public IPv4 (NAT) | $0.005/hr x 730 | 3.65 | list price |
| EC2 `t4g.nano` bastion | $0.0042/hr x 730 | 3.07 | Pricing API |
| EBS gp3 8 GB (bastion) | $0.08/GB-mo x 8 | 0.64 | Pricing API |
| KMS customer-managed key | $1.00/key-mo | 1.00 | list price |
| Secrets Manager | $0.40/secret-mo | 0.40 | Pricing API |
| CloudWatch alarms | $0.10 x 9 metric-alarms | 0.90 | list price |
| CloudWatch dashboard | 1 of 3 free | 0.00 | list price |
| Enhanced Monitoring logs | 0.343 GB/mo x $0.50 | 0.17 | measured |
| VPC flow logs | 0.217 GB/mo x $0.50 | 0.11 | measured |
| PostgreSQL logs | 0.047 GB/mo x $0.50 | 0.02 | measured |
| NAT data processing | ~1 GB/mo x $0.045 | 0.04 | measured |
| RDS backup storage | under the 50 GB free allowance | 0.00 | Pricing API |
| Performance Insights | 7-day retention is free | 0.00 | list price |
| **Total** | | **148.52** | |

**The database is 71% of the bill** and the NAT gateway is another 22%.
Everything else together is under $11/month. Optimising anything but those two
is wasted effort.

The three log-volume figures were measured over one hour of light use --
connecting, running queries, an SSM session. Phase 6 (connection storm) and
Phase 7 (bad queries) will push PostgreSQL log ingestion up sharply, because
`log_min_duration_statement=1000`, `log_connections` and `log_disconnections`
are all on. Expect single-digit dollars there during active labs, not tens.

## Cutting it down between sessions

| Action | Saves | Leaves you at |
| --- | ---: | ---: |
| `db_multi_az = false` | -52.84 | $95.69/mo |
| Stop the instance (storage still bills) | -94.17 | $54.35/mo |
| `enable_bastion = false` | -3.71 | $144.82/mo |
| `./scripts/destroy.sh` | -148.52 | ~$0 |

```bash
# Full teardown. Keeps a final snapshot (~$5/mo for 50 GiB), rebuild is one
# apply and about 25 minutes.
./scripts/destroy.sh

# Or just stop the instance. RDS restarts it automatically after 7 days.
aws rds stop-db-instance --db-instance-identifier awsdblab-dev-postgres
```

Note that stopping the instance does **not** stop the NAT gateway, which keeps
billing $36.50/month on its own. For a long pause, destroy rather than stop.

`db_multi_az = false` halves the two largest lines at once -- both the instance
hour and the storage rate drop by half -- but it deletes the Phase 4 failover
lab entirely. Turn it back on before that work.

## Checking the real bill

Cost Explorer lags roughly 24 hours, so a freshly created resource shows $0.

```bash
# Month to date, by service
aws ce get-cost-and-usage --time-period Start=2026-08-01,End=2026-09-01 \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output text | sort -k2 -rn

# Daily, one service -- this is what shows a resource being created or deleted
aws ce get-cost-and-usage --time-period Start=2026-08-01,End=2026-09-01 \
  --granularity DAILY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Relational Database Service"]}}' \
  --query 'ResultsByTime[].[TimePeriod.Start,Total.UnblendedCost.Amount]' --output text
```

Every resource carries `Project=awsdblab` via `default_tags`. To slice the bill
by that tag in Cost Explorer, activate it first in **Billing -> Cost allocation
tags**; tags are not retroactive, so activate early.

## The one that surprises people

NAT gateway data processing is billed per GB *on top of* the hourly rate. Right
now that is $0.04/month because nothing is running. Phase 2 pulls container
images through it on every ECS deployment, which is when it starts to show. A
gateway VPC endpoint for S3 is free and removes most image-layer traffic:

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.networking.vpc_id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.networking.private_app_route_table_ids
}
```

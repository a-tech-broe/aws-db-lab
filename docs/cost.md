# What Phase 1 costs

Rough `us-east-1` on-demand pricing, running continuously for a 30-day month.
Verify against the AWS pricing pages — these move.

| Resource                        | Config                    | ~USD / month |
| ------------------------------- | ------------------------- | ------------ |
| RDS `db.t4g.medium`, Multi-AZ   | 2 x instance-hour         | ~$100        |
| RDS storage `gp3`               | 50 GiB x 2 (Multi-AZ)     | ~$14         |
| Backup storage                  | ~50 GiB beyond free tier  | ~$0–5        |
| NAT gateway                     | 1, `single_nat_gateway`   | ~$33 + data  |
| Elastic IP                      | 1, attached               | $0           |
| KMS CMK                         | 1 key                     | $1           |
| Secrets Manager                 | 1 secret                  | $0.40        |
| CloudWatch alarms               | 8 standard                | ~$0.80       |
| Enhanced Monitoring, 30s        | ingested log data         | ~$2–5        |
| Performance Insights            | 7-day retention           | $0 (free tier) |
| VPC flow logs                   | low-traffic lab           | ~$1–3        |
| Optional bastion `t4g.nano`     | if `enable_bastion`       | ~$3          |
| **Total**                       |                           | **~$155–165** |

## Cutting it down between sessions

The lab does not need to run overnight. In descending order of savings:

```bash
# 1. Full teardown, ~$0/month, keeps a final snapshot (~$5/month for 50 GiB).
#    Rebuild is one apply, ~20 minutes.
./scripts/destroy.sh

# 2. Stop the instance. RDS auto-starts it again after 7 days.
#    Storage and backups still bill; compute does not.
aws rds stop-db-instance --db-instance-identifier awsdblab-dev-postgres
```

Cheaper settings while iterating on Terraform, in `terraform.tfvars`:

```hcl
db_multi_az          = false  # halves the instance and storage bill
db_allocated_storage = 20     # minimum useful size
enable_flow_logs     = false
```

`db_multi_az = false` deletes the Phase 4 failover lab, so turn it back on
before that work starts.

## The one that surprises people

NAT gateway data processing is billed per GB in *addition* to the hourly rate.
Phase 2 pulls container images through it on every ECS deployment. If that
becomes a real line item, add S3 and ECR VPC endpoints — a gateway endpoint for
S3 is free and removes most image-layer traffic from the NAT.

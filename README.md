# aws-db-lab

A database SRE lab: a production-shaped PostgreSQL environment on AWS, built
with Terraform, then deliberately broken in twelve phases so every failure mode
gets measured and written down.

**Status: Phase 1 complete.** 64 resources, `terraform validate` and
`terraform plan` clean. Nothing has been applied to AWS yet — see Quickstart.

| Phase | Scope                              | State           |
| ----- | ---------------------------------- | --------------- |
| 1     | PostgreSQL foundation              | **built**       |
| 2     | Application (ALB → ECS → RDS)      | not started     |
| 3     | Grafana observability              | not started     |
| 4     | Failover lab                       | not started     |
| 5–12  | Backup, connections, performance, replication, security, migration, DR, chaos | not started |

## What Phase 1 builds

```
terraform/
├── bootstrap/                 state bucket, GitHub OIDC provider, deploy role
├── environments/dev/          root module — wires everything, publishes outputs
└── modules/
    ├── networking/            VPC, 3 AZs, 3-tier subnets, NAT, DB subnet group, flow logs
    ├── security/              KMS CMK, Secrets Manager, app + db security groups
    ├── rds/                   Multi-AZ PostgreSQL 16, parameter group, backups, monitoring
    ├── monitoring/            SNS topic, 8 CloudWatch alarms, dashboard
    └── bastion/               optional SSM-only maintenance host (default off)
scripts/
├── bootstrap.sh               preflight: toolchain, credentials, quotas
├── validate.sh                assert the live environment matches its intent
└── destroy.sh                 guarded teardown (clears deletion protection first)
docs/
├── architecture.md            diagram, decisions and their trade-offs
├── cicd.md                    plan on PR, apply on merge, OIDC, remote state
├── cost.md                    ~$155/month, and how to cut it between sessions
└── runbook-template.md        the twelve-section format
runbooks/                      four incidents Phase 1 alarms can actually fire
```

Details, including why each decision was made: **[docs/architecture.md](docs/architecture.md)**.

## Quickstart

```bash
./scripts/bootstrap.sh                      # preflight — tools, credentials, quotas

cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars   # set owner, and alarm_email
terraform init
terraform plan
terraform apply                             # 15–25 min; Multi-AZ is the slow part

cd -
./scripts/validate.sh                       # assert the deployed posture
```

Two things to expect on a first apply:

- The parameter group reports `applying`, not `in-sync`, until the first
  reboot. `shared_preload_libraries` and `rds.force_ssl` are `pending-reboot`
  parameters. Reboot when convenient:
  `aws rds reboot-db-instance --db-instance-identifier awsdblab-dev-postgres`
- Alarms sit in `INSUFFICIENT_DATA` for a few minutes, and
  `LatestRestorableTime` is empty until the first automated backup completes.
  `validate.sh` reports both as warnings, not failures.

Teardown, which `terraform destroy` alone cannot do (deletion protection is on
by design):

```bash
./scripts/destroy.sh                # keeps a final snapshot
./scripts/destroy.sh --no-snapshot  # deletes everything
```

**This costs roughly $155/month if left running.** See [docs/cost.md](docs/cost.md).

## Connecting to the database

There is no public endpoint, and `rds.force_ssl` is enforced. You need to be
inside the VPC. Until the Phase 2 application exists, set `enable_bastion = true`
and use Session Manager — no SSH key, no open port, IAM-authenticated:

```bash
aws ssm start-session --target "$(terraform -chdir=terraform/environments/dev output -raw bastion_instance_id)"

# on the host
SECRET=$(aws secretsmanager get-secret-value --secret-id awsdblab-dev/rds/master \
  --query SecretString --output text)

PGPASSWORD=$(jq -r .password <<<"$SECRET") psql \
  "host=$(jq -r .host <<<"$SECRET") \
   dbname=$(jq -r .dbname <<<"$SECRET") \
   user=$(jq -r .username <<<"$SECRET") \
   sslmode=require"
```

## CI/CD

`.github/workflows/terraform.yml`:

| Event | static | plan | apply |
| --- | --- | --- | --- |
| pull request | yes | yes, posted as a PR comment | no |
| push to `main` | yes | yes | yes, behind an environment approval gate |

The apply job runs only when the plan reported `-detailed-exitcode == 2`
(changes actually present), and it applies the **saved plan artifact** rather
than re-planning — so if state moves between plan and approval, Terraform
refuses the stale plan instead of applying something unreviewed.

Authentication is GitHub OIDC against the role in `terraform/bootstrap`; there
is no AWS access key in this repository. `terraform destroy` is deliberately
absent from the pipeline — teardown stays manual via `scripts/destroy.sh`.

Three one-time steps are required before the pipeline can run: apply
`terraform/bootstrap`, migrate the dev environment onto remote state, and set
the repository variables. **A CI apply cannot work on local state** — it would
start from an empty state file and try to recreate all 74 resources. Full
setup: **[docs/cicd.md](docs/cicd.md)**.

## Design decisions

| | |
| --- | --- |
| Primary region | `us-east-1` (`us-west-2` joins in Phase 11) |
| Database | PostgreSQL 16, Multi-AZ, `db.t4g.medium`, gp3 |
| IaC | Terraform ≥ 1.9, AWS provider ~> 6.0 |
| Compute | ECS Fargate (Phase 2) |
| Observability | CloudWatch now, Prometheus + Grafana in Phase 3 |
| CI/CD | GitHub Actions |
| Secrets | AWS Secrets Manager, KMS-encrypted |
| State | S3 + native lockfile (`use_lockfile`); bootstrapped by `terraform/bootstrap` |

---

# Roadmap

We’ll ultimately build this:
                         GitHub
                            |
                     GitHub Actions
                            |
                     Terraform CI/CD
                            |
                            v
                  +-------------------+
                  |       AWS VPC     |
                  |                   |
                  |  Public Subnets   |
                  |       |           |
                  |      ALB          |
                  |       |           |
                  |  Private Subnets  |
                  |       |           |
                  |     ECS App       |
                  |       |           |
                  |       v           |
                  |   RDS Proxy       |
                  |       |           |
                  |       v           |
                  |  PostgreSQL RDS   |
                  |   Multi-AZ         |
                  +-------------------+
                            |
             +--------------+--------------+
             |                             |
          Backup                       Monitoring
             |                             |
        AWS Backup                    CloudWatch
             |                             |
        PITR / Snapshots             Prometheus
                                           |
                                         Grafana
                                           |
                                        Alerts



Later we’ll evolve it into:
                         PRIMARY REGION
                         us-east-1
                             |
                         Aurora
                             |
                    Global Database
                             |
                             v
                         DR REGION
                         us-west-2



Aurora Global Database is specifically designed to span Regions with a primary cluster and secondary clusters, providing cross-Region replication and regional disaster recovery. 
Phase 1 — Production PostgreSQL Foundation

Our first milestone is:

Deploy a production-style PostgreSQL RDS environment entirely through Terraform.

We’ll deliberately avoid the AWS console as much as possible.

What we’re going to build

aws-database-sre-lab/
│
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │
│   └── modules/
│       ├── networking/
│       ├── security/
│       ├── rds/
│       ├── monitoring/
│       └── backup/
│
├── app/
│
├── scripts/
│
├── chaos/
│
├── monitoring/
│
├── runbooks/
│
├── docs/
│
└── .github/
    └── workflows/

Phase 1 Objectives

By the end of Phase 1, you should have:

Networking

* VPC
* 2–3 AZs
* Public subnets
* Private application subnets
* Private database subnets
* Route tables
* NAT
* DB subnet group

Security

* Database security group
* Application security group
* No public RDS access
* Least-privilege rules
* KMS encryption
* Secrets Manager

Database

* PostgreSQL RDS
* Multi-AZ
* Encryption
* Automated backups
* Backup retention
* Performance monitoring
* Enhanced monitoring
* Parameter group
* Maintenance window

Observability

* CloudWatch alarms
* Database metrics
* Connection monitoring
* Storage monitoring
* CPU monitoring


Phase 2 — Build the Application

We need an application because an SRE doesn’t manage databases in isolation.

We’ll create a small API:
GET /health
GET /db-health
GET /customers
POST /customers
GET /metrics

Architecture:

Internet
   |
  ALB
   |
 ECS Fargate
   |
 RDS Proxy
   |
 PostgreSQL


The /db-health endpoint will test:
SELECT 1;

And /metrics will expose Prometheus metrics.

That gives us a realistic workload to break later.

Phase 3 — Database Observability

We’ll create Grafana dashboards around:

Availability

Database status
Database connections
Failed connections
Failover events

Capacity
CPU
Memory
Storage
IOPS
Network
Connections

Performance
Query latency
Transactions
Queries/sec
Locks
Deadlocks
Long-running queries

Reliability
Replication lag
Backup status
Recovery point
RTO
RPO

Phase 4 — Failover Lab

This is where the project becomes interesting.

We’ll establish a baseline:
Normal state

Application
    |
    v
RDS

Then initiate a controlled failover.

We’ll measure:

T0 = failure initiated

T1 = failure detected

T2 = RDS failover begins

T3 = standby promoted

T4 = application reconnects

T5 = /health returns 200

Calculate:
Detection Time
Failover Time
Recovery Time
Total Downtime
MTTR

Then compare the result against our target:
RTO = 5 minutes

Phase 5 — Backup / Restore

Next:
Application
     |
     v
PostgreSQL
     |
     +----> Automated Backup
     |
     +----> Snapshot
     |
     +----> PITR


RDS point-in-time recovery lets you restore to a specific point within the backup retention period, creating a new database rather than modifying the original. 
We’ll test:

Scenario

10:00
Customer A created

10:10
Customer B created

10:20
Developer accidentally deletes Customer A

10:25
Incident detected

Our objective:

Restore the database to approximately 10:19 without losing legitimate data after that point unnecessarily.

Then validate:

Customer A exists
Customer B does not get incorrectly duplicated
Application works
Database is healthy

We’ll record:
RPO
RTO
Restore duration
Data loss

Phase 6 — Connection Exhaustion

This is one of the most useful real-world exercises.

We’ll intentionally create:

ECS
 |
 +-- Task 1 ---> 100 connections
 +-- Task 2 ---> 100 connections
 +-- Task 3 ---> 100 connections
 +-- Task 4 ---> 100 connections

 Eventually:
 PostgreSQL
     |
     v
max_connections
     |
     v
CONNECTION EXHAUSTION

Then we’ll introduce RDS Proxy.

RDS Proxy pools and shares database connections and is specifically designed to help applications handle connection surges and database failures more resiliently.  

We’ll compare:

WITHOUT RDS PROXY

ECS → PostgreSQL

versus:
WITH RDS PROXY

ECS
 |
 v
RDS Proxy
 |
 +---- connection pool
 |
 v
PostgreSQL

We’ll measure the difference.


Phase 7 — Performance Troubleshooting

Now we’ll create bad queries.

For example:
SELECT *
FROM customers
WHERE email = 'user@example.com';

Then generate enough data to make the query expensive.

We’ll investigate:
CPU
   |
   v
Slow query
   |
   v
EXPLAIN ANALYZE
   |
   v
Full table scan
   |
   v
Missing index
   |
   v
Create index
   |
   v
Validate improvement

We’ll also practice:

* Locks
* Deadlocks
* Long transactions
* Connection leaks
* High CPU
* High I/O
* Query contention

⸻

Phase 8 — Replication Lag

We’ll introduce a read replica.
              RDS PRIMARY
                   |
             replication
                   |
                   v
              READ REPLICA


Then create a workload that causes replication lag.

We’ll monitor:
ReplicaLag

and determine:
Is the replica healthy enough for application reads?

We’ll create an alert such as:

Replication lag > 30 seconds

Then investigate the root cause.

⸻

Phase 9 — Security Incident

We’ll deliberately introduce bad configurations.

For example:

RDS
 |
Security Group
 |
0.0.0.0/0
 |
5432

Our security controls should identify this.

We’ll implement:

* Private RDS
* Security groups
* Secrets Manager
* KMS
* Encryption at rest
* TLS
* IAM
* CloudTrail
* Credential rotation
* Least privilege

We’ll also test:

What happens when the application secret is rotated?

⸻

Phase 10 — Database Migration

We’ll build:

Source PostgreSQL
       |
       | CDC
       v
AWS DMS
       |
       v
Aurora PostgreSQL


AWS DMS supports ongoing replication/CDC, making it appropriate for practicing low-downtime migrations.  

We’ll practice:
Full load
   ↓
CDC
   ↓
Replication monitoring
   ↓
Data validation
   ↓
Application cutover
   ↓
Rollback

Phase 11 — Cross-Region DR

Then we’ll introduce:

We’ll establish:
RPO = 5 minutes
RTO = 15 minutes

Then actually destroy/fail the primary environment and execute the recovery procedure.

Aurora Global Database supports planned switchovers and unplanned failovers, so we’ll practice both.  

⸻

Phase 12 — Chaos Engineering

Finally:

                    CHAOS
                      |
       +--------------+--------------+
       |              |              |
     RDS           Network        Application
    failure        failure          failure
       |              |              |
       +--------------+--------------+
                      |
                      v
                Observability
                      |
                      v
                 Detection
                      |
                      v
                  Alerting
                      |
                      v
                 Remediation
                      |
                      v
                  Recovery


We’ll automate scenarios like:
rds-failover.sh
connection-storm.py
long-running-query.sql
deadlock-test.sql
backup-restore.sh
replication-lag.sh
secret-rotation.sh


Most Important Part: Every Incident Gets a Runbook

For example:
runbooks/
├── rds-unavailable.md
├── rds-failover.md
├── high-cpu.md
├── high-storage.md
├── connection-exhaustion.md
├── replication-lag.md
├── slow-query.md
├── deadlock.md
├── backup-failure.md
├── restore-procedure.md
├── secret-rotation.md
├── security-group-exposure.md
├── migration-failure.md
└── regional-failure.md


Each runbook follows:
1. Symptoms

2. Impact

3. Detection

4. Initial investigation

5. AWS commands

6. PostgreSQL commands

7. Root-cause analysis

8. Remediation

9. Validation

10. Rollback

11. RTO/RPO impact

12. Preventive actions

That documentation becomes excellent material for Senior DevOps/SRE interviews.

⸻

Our First Sprint

I recommend we not build everything at once.

We’ll work through this like an actual engineering project.

Sprint 1

We’ll build:
                    AWS
                     |
                    VPC
                     |
          +----------+----------+
          |                     |
      Private AZ-1          Private AZ-2
          |                     |
          +----------+----------+
                     |
               RDS PostgreSQL
                 Multi-AZ
                     |
              Secrets Manager
                     |
                    KMS
                     |
                CloudWatch



Deliverables

By the end of Sprint 1 you’ll have:

* Terraform repository
* VPC
* 3 AZ architecture
* Private DB subnets
* RDS PostgreSQL
* Multi-AZ
* KMS
* Secrets Manager
* DB security group
* Parameter group
* Backup configuration
* CloudWatch alarms
* Terraform outputs
* README
* Architecture diagram
* Validation script
* Destroy script

And importantly, we’ll build it so that later phases plug into it rather than throwing the architecture away.

One design decision

For the lab, I recommend:

Primary AWS Region: us-east-1
DR AWS Region: us-west-2
Database: PostgreSQL
IaC: Terraform
Compute: ECS Fargate
Observability: CloudWatch + Prometheus + Grafana
CI/CD: GitHub Actions
Secrets: AWS Secrets Manager
Encryption: AWS KMS

We’ll use us-east-1 for the first phase and bring us-west-2 in when we reach cross-region DR.

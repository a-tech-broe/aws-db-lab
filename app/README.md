# Application — Phase 2

Not built yet. A small API exercising the database:

```
GET  /health      liveness, no database dependency
GET  /db-health   SELECT 1 against the writer
GET  /customers
POST /customers
GET  /metrics     Prometheus exposition
```

Runs on ECS Fargate in `private_app_subnet_ids`, behind an ALB in
`public_subnet_ids`, with the `app_security_group_id` attached — which is what
grants it the single ingress path into the database.

Credentials come from `db_secret_arn`. The secret already carries
`host`, `port`, `dbname`, `username`, `password` and `engine`, so no other
configuration is needed to connect.

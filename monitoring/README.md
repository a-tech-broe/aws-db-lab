# Monitoring — Phase 3

Phase 1 ships CloudWatch alarms and a dashboard, defined in
`terraform/modules/monitoring`. This directory holds what comes after that:

- Prometheus scrape configuration and `postgres_exporter` wiring
- Grafana dashboards as JSON, grouped by availability / capacity /
  performance / reliability
- Alert rules that pair with the runbooks

The CloudWatch alarms stay regardless — they are what fires when the
Prometheus stack itself is the thing that is broken.

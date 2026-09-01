# Correlate DNS Current Observations

This directory contains the authoritative Git-owned export of the active n8n workflow that correlates compact DNS current observations into actionable lifecycle events and produces the daily DNS operational report.

## Live workflow identity

- **Workflow:** `Correlate DNS Current Observations`
- **n8n workflow ID:** `6aOCYolK7VbF4oit`
- **Production webhook:** `POST /webhook/leto/dns-observations`
- **Read-back version:** `64845b64-0898-40b0-8e2a-8cbca0431890`
- **Read-back timestamp:** `2026-09-01T13:54:20.268Z`
- **Activation:** active

The adjacent `correlate-dns-current-observations.json` is the direct REST read-back of that workflow. Its name deliberately describes its live responsibility; it is not an inactive draft.

## Responsibility boundary

The workflow authenticates current observations using the existing n8n Header Auth credential, keeps bounded correlation and delivery state in workflow static data, and sends only actionable canonical transitions to the existing local Operational Event Ingress at `/webhook/leto/events`.

It accepts the external observer source `external-dns-resilience` and the internal observer source `internal-dns-monitor`. The external observer's `midway_recursion` evidence is diagnostic-only: Midway-only instability is retained for correlation but never promoted to the Operational Event Ingress.

The export contains n8n credential references only. It contains no credential values, ingress token, or Discord webhook.

## Daily DNS operational report

At **09:00 America/New_York** the same correlation workflow produces one report for the preceding local calendar day and routes it with the existing `Discord - Leto Reports` credential. It does not use the alert credential or create a new observer, poller, heartbeat, or alert path.

The report includes household DNS impact, individual resolver degradation, LAN resolver-selection failures, external-path impairments, Midway fresh-recursion instability, and internal-observer stale periods. It reports episode count, day-clipped total duration, longest episode, and meaningful observed vantage. It explicitly separates user-impacting/actionable incidents from diagnostic-only Midway evidence and still posts a concise healthy-day report.

Schema 2 retains only bounded correlated episode records: up to 512 closed episodes and 35 days of history, plus a small report-delivery outbox/audit. It intentionally does not store raw DNS observations. Evidence before the schema-2 migration has no reconstructable episode duration and is reported as coverage-limited rather than inferred.

## Source and runtime relationship

The external producer source belongs in:

```text
services/external-dns-monitor/
```

It posts authenticated current observations to:

```text
https://ops.wormlogic.com/webhook/leto/dns-observations
```

The producer does not route directly to Discord or to the Operational Event Ingress. The correlation workflow owns the transition from observation to normalized operational event and the daily report; the established ingress and alert-routing workflow own lifecycle-event persistence and alert destination routing.

## Refreshing the export

Use the established Hermes read-only n8n API credential mount. Do not copy, print, rotate, or materialize its value.

```sh
curl -fsS \
  -H "X-N8N-API-KEY: $(<"$N8N_LETO_API_KEY_FILE")" \
  "$N8N_API_BASE_URL/api/v1/workflows/6aOCYolK7VbF4oit" \
  -o n8n/leto-operations/correlate-dns-current-observations.json
```

Before committing a refresh, read back and verify the workflow ID, active state, webhook path, node graph, connections, schedule, and credential references. A REST success alone is not proof of a correct graph.

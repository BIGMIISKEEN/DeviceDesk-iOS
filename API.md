# Bridge protocol v1

All endpoints require HTTPS and `Authorization: Bearer <operator-token>`. Do not put tokens in URLs. Responses use `Cache-Control: no-store`. There is no arbitrary command/script endpoint and no cross-origin browser API.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/v1/capabilities` | API version, operator ID, allowed targets/actions and configured DC |
| POST | `/v1/jobs` | Submit one explicit permitted operation |
| GET | `/v1/jobs/{job-id}` | Retrieve this operator's job state/result |
| GET | `/v1/requests/{request-uuid}` | Reconcile a lost POST response without resubmission |

Job request example:

```json
{
  "requestId": "91b3761b-502e-4317-9aa0-b6641c683132",
  "action": "Inventory",
  "target": "PC001.example.internal",
  "payload": {},
  "confirmed": false
}
```

The POST returns HTTP 202 with `{"id":"job-uuid"}`. Poll the job endpoint. States are `queued`, `running`, `succeeded`, `failed`, `unknown` or `expired`. Success carries `result`; other terminal states may carry `error`. Never interpret `unknown` as failure or permission to retry. A timeout/bridge restart may happen after a Windows write completed.

Request IDs are unique per operator and durable across bridge restarts. A duplicate ID returns the original job; it does not execute again. Reusing the ID with a different action or target returns 409. IDs are operation identities, not a way to submit edited payloads. The iOS client never automatically repeats POSTs; it uses lookup to reconcile.

Payloads:

| Action | Payload keys |
| --- | --- |
| Inventory, DriverUpdates, TempPreview, Restart | none |
| PopupMessage | Title, Message, Seconds |
| TempDelete, TempDiscard | PreviewId, Hash from the target's preview |
| Trim | Id, StartTicks from the scanned process; decimal strings preserve precision |
| DirectorySearch | Kind = Users/Computers, Query |
| DirectoryUnlock | ObjectGUID, DistinguishedName, SamAccountName from search |
| DirectoryResetPassword | Same identity fields plus Password and ChangeAtLogon |

Directory target selection is always replaced with the server-configured domain controller. No client-supplied credential or domain-controller override is accepted. Windows operations use the running bridge account. Write actions require `confirmed: true` in addition to per-operator authorization.

Request bodies are limited to 16 KiB. The bridge accepts at most eight queued/running jobs with four concurrent workers. Each worker has a 15-minute process timeout. Terminating a local worker does not guarantee cancellation of an operation already sent to a remote computer, which is why uncertain writes require reconciliation.

Result bodies expire after 30 minutes on retrieval or subsequent job submission; request/audit metadata remains. Use one process per database. Access tokens are configured as SHA256 hashes and revocation requires changing configuration then restarting the service. Long-running production deployments should add organization-specific identity, monitoring and managed token lifecycle as required; do not share a token across operators.

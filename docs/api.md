# Sent API calls used by SentDM.jl

`src/SentDM.jl` calls the seven Sent endpoints on this page and checks Sent's webhook signatures. This page lists what the client sends and reads. Sent's own pages, linked below, cover everything else.

The client matches Sent's OpenAPI document as published on 2026-11-05.

- URL: `https://docs.sent.dm/api/openapi/v3`
- SHA-256: `73dff4bf66fae2a3fb9cca7931b4be7b323248bd5f41b1dfb021b5e1755684b7`

The document has no version number. Sent publishes its SHA-256 in the `ETag` and `x-sent-spec-sha256` response headers ([OpenAPI specification](https://docs.sent.dm/reference/api/openapi-spec)). A different digest means the document changed after this page was written.

## Every request

- The base URL is `https://api.sent.dm`, and every path starts with `/v3`.
- The `x-api-key` header carries the API key ([Authentication](https://docs.sent.dm/reference/api/authentication)).
- A request with a body sends `Content-Type: application/json`.
- `POST`, `PUT`, and `PATCH` accept an `Idempotency-Key` header of 1 to 255 letters, digits, hyphens, or underscores. Sent keeps a key for 24 hours. A request with the same key, method, path, query, and body bytes gets the first `2xx` answer again. The same key with a different request fails with `422 CONFLICT_005` ([Idempotency](https://docs.sent.dm/reference/api/idempotency)).
- Every answer is the envelope `{"success", "data", "error", "meta"}`. The client returns `data`.
- A non-`2xx` answer carries `error.code` and `error.message`, and every answer carries an `X-Request-Id` header. The client throws `ApiError(status, code, message, request_id)` ([Error handling](https://docs.sent.dm/reference/api/errors), [Error catalog](https://docs.sent.dm/reference/api/error-catalog)).
- HTTP.jl sends a `GET`, a `PUT`, or a request with an `Idempotency-Key` again when the connection drops before an answer or Sent answers `408`, `429`, `500`, `502`, `503`, or `504`. The same key makes the repeat safe. A `POST` without a key is never repeated.

## Endpoints

### Send a message

`send_message` calls `POST /v3/messages` with an `Idempotency-Key` ([Sending messages](https://docs.sent.dm/start/guides/sending-messages)). The client writes the body fields in this order.

| Field | Value |
| --- | --- |
| `to` | One E.164 number, as a one-item array. |
| `channel` | `["sms"]`. |
| `channels` | `{"sms": [{"from": [number]}]}`, only when the caller passes `from`. |
| `template` | `{"id", "parameters"}`, when the caller passes `template_id`. The `parameters` keys are sorted. |
| `text` | The free-form body, when the caller passes `text`. |
| `sandbox` | `true` or `false`. |

Sent answers `202`. The client reads `data.status`, and `message_id`, `to`, and `channel` from each item of `data.recipients`.

### Read a message

`get_message` calls `GET /v3/messages/{id}`. The client returns `data`, which includes `status`, `reason_code`, and `reason`.

### Find a contact by phone number

`find_contact` calls `GET /v3/contacts?page=1&page_size=1&phone=` with the URL-encoded E.164 number ([Opt-outs and consent](https://docs.sent.dm/start/guides/opt-out-and-consent)). The client returns the first item of `data.contacts`, which includes `id` and `opt_out`. Sent answers `404 RESOURCE_001` when no contact has the number, and the client then returns `nothing`.

### Set a contact's opt-out flag

`update_contact` calls `PATCH /v3/contacts/{id}` with an `Idempotency-Key` and the body `{"opt_out": true}` or `{"opt_out": false}`. The client returns `data`, the updated contact.

### List templates

`list_templates` calls `GET /v3/templates?page=&page_size=`. The client returns `data`, which holds `templates` and `pagination`. Each template has `id`, `name`, and `status`. Sent's keyword-reply templates also have `auto_reply_action`, which is `OPT_IN`, `OPT_OUT`, or `HELP` ([Template definition](https://docs.sent.dm/reference/api/template-definition)).

### Create a template

`create_template` calls `POST /v3/templates` with the caller's body. The OpenAPI body fields are `name`, `category`, `language`, `definition`, `creation_source`, `auto_create_for_sp`, and `submit_for_review`. Sent answers `201`, and the client returns `data`, the new template. `GET` never returns a template's `definition`, so the text Sent holds can be read only in the dashboard ([Template definition](https://docs.sent.dm/reference/api/template-definition)).

### Update a template

`update_template` calls `PUT /v3/templates/{id}` with the caller's body. The OpenAPI body fields are `name`, `category`, `language`, `definition`, and `submit_for_review`. The client returns `data`, the updated template.

## Webhooks

Sent signs version 2 webhooks with the Standard Webhooks scheme ([Verifying webhook signatures](https://docs.sent.dm/build/signature-verification), [Events reference](https://docs.sent.dm/start/webhooks/event-types)).

- The headers are `webhook-id`, `webhook-timestamp`, and `webhook-signature`.
- The signed bytes are the id, a period, the timestamp, a period, and the raw body.
- The HMAC-SHA256 key is the signing secret without its `whsec_` prefix, base64-decoded.
- `webhook-signature` holds space-separated `v1,` values, each followed by a base64 HMAC. For 24 hours after a secret rotation, it holds one value for each secret.
- `verify_webhook` rejects a timestamp more than 300 seconds from the server clock.

The body is `{"field", "event", "timestamp", "request_id", "payload"}`. `parse_webhook` returns it as a `Dict{String,Any}`.

## Where Sent's sources disagree

- The OpenAPI document marks `page` and `page_size` as required on `GET /v3/contacts`. Sent's opt-out guide shows `?phone=` alone. The client sends all three.
- Sent's idempotency page says that Sent ignores a malformed `Idempotency-Key`. The OpenAPI document lists `VALIDATION_007` for one. The client refuses a malformed key before it sends anything.
- Sent's authentication page describes API keys as UUIDs. The OpenAPI document describes `sk_live_` and `sk_test_` keys.

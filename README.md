# SentDM.jl

[![CI](https://github.com/JuliaServices/SentDM.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaServices/SentDM.jl/actions/workflows/ci.yml)

Send text messages from Julia through [Sent](https://sent.dm)'s API, and check the
signatures on Sent's webhooks. The package compiles with `juliac --trim=safe`, except
`verify_webhook`: the Base64 standard library it uses stores its stream as an abstract
`IO`, which the trim verifier rejects.

It covers sending an SMS from a template or as free text, reading a message's
status, finding a contact and setting its opt-out flag, and listing, creating, and
updating templates. [docs/api.md](docs/api.md) lists every request it makes.

## Install

```julia
using Pkg
Pkg.add(url = "https://github.com/JuliaServices/SentDM.jl")
```

## Send a text

Set the API key for a block of code; every call inside uses it.

```julia
using SentDM

SentDM.with_sentdm(ENV["SENT_API_KEY"]) do
    result = SentDM.send_message(;
        to = "+18015550123",
        template_id = "7ba7b820-9dad-11d1-80b4-00c04fd430c8",
        parameters = Dict("code" => "123456"),
        idempotency_key = "sign-in-42")       # safe to send again
    result.recipients[1].message_id           # Sent's id for the text
end
```

Pass `text` instead of `template_id` to send free text, and `from` to pick one of
the account's numbers. Pass `base_url` to `with_sentdm` to point the client at
another server, such as a local stub in tests.

A successful send means Sent queued the text. It can still end `BLOCKED` or
`FILTERED`; `SentDM.get_message` and Sent's status webhooks report that.

## Verify a webhook

Check the signature on the raw body before reading it. The secret is the `whsec_`
signing secret Sent shows when the webhook is created.

```julia
using HTTP, SentDM

function handle_sent_webhook(req::HTTP.Request)
    body = Vector{UInt8}(req.body)
    SentDM.verify_webhook(body,
        HTTP.header(req, "webhook-id"),
        HTTP.header(req, "webhook-timestamp"),
        HTTP.header(req, "webhook-signature"),
        ENV["SENT_WEBHOOK_SECRET"]) || return HTTP.Response(401)
    event = SentDM.parse_webhook(body)        # Dict with "field", "event", "payload", ...
    return HTTP.Response(200)
end
```

`verify_webhook` refuses a timestamp more than 5 minutes from the server clock, and
accepts any of the signatures Sent sends for a day after a secret rotation.

## Errors and retries

- `SentDM.ApiError`: Sent refused the request. It carries the HTTP `status`, Sent's
  error `code` (such as `"VALIDATION_002"`), its `message`, and the `request_id`.
- HTTP.jl's connection and timeout errors: Sent could not be reached (10 s to
  connect, 30 s without a byte of the answer).

HTTP.jl sends a `GET`, a `PUT`, or a request with an `Idempotency-Key` again when
the connection drops or Sent answers `408`, `429`, `500`, `502`, `503`, or `504`.
For 24 hours Sent answers a repeated key with its first answer, so a retried
`send_message` with the same key texts once.

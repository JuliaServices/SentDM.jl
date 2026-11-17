module SentDM

using Base64, HTTP, JSON, SHA
using Base.ScopedValues: ScopedValue, @with

const API_BASE_URL = "https://api.sent.dm"
const WEBHOOK_MAX_SKEW_SECONDS = 300
const IDEMPOTENCY_KEY_PATTERN = r"^[A-Za-z0-9_-]{1,255}$"

struct Client
    api_key::String
    base_url::String
end

const CLIENT = ScopedValue{Client}()

"""
A non-2xx answer from Sent. `code` is Sent's error code, such as `VALIDATION_002`. It is empty
when the body has no error envelope, and `message` then holds the start of the body.
`request_id` is the `X-Request-Id` header.
"""
struct ApiError <: Exception
    status::Int
    code::String
    message::String
    request_id::Union{String,Nothing}
end

struct Recipient
    message_id::String
    to::String
    channel::String
end

struct SendResult
    status::String
    recipients::Vector{Recipient}
end

struct TemplateRef
    id::String
    parameters::Union{Dict{String,String},Nothing}
end

struct SendRequest
    to::Vector{String}
    channel::Vector{String}
    channels::Union{Dict{String,Vector{Dict{String,Vector{String}}}},Nothing}
    template::Union{TemplateRef,Nothing}
    text::Union{String,Nothing}
    sandbox::Bool
end

"""
    with_sentdm(f, api_key; base_url=SentDM.API_BASE_URL)

Run `f()` with a Sent client for `api_key`. Every call inside `f` uses it. Pass `base_url` to
send the calls to another server, such as a local stub in tests.
"""
function with_sentdm(f, api_key::String; base_url::String = API_BASE_URL)
    isempty(strip(api_key)) && throw(ArgumentError("Sent API key is required"))
    return @with CLIENT => Client(api_key, rstrip(base_url, '/')) f()
end

function _client()
    isassigned(CLIENT) || error("No Sent client set. Use SentDM.with_sentdm.")
    return CLIENT[]
end

function _dict(value::Any)::Dict{String,Any}
    value isa Dict{String,Any} && return value
    value isa JSON.Object{String,Any} && return Dict{String,Any}(value)
    return Dict{String,Any}()
end

_array(value::Any)::Vector{Any} = value isa Vector{Any} ? value : Any[]
_string(value::Any)::String = value isa String ? value : ""

# String(::Vector{UInt8}) empties the vector it is given, so parse a copy.
_parse(bytes::Vector{UInt8}) = JSON.parse(String(copy(bytes)), Dict{String,Any})

function _api_error(response)::ApiError
    envelope = try
        _parse(response.body)
    catch
        Dict{String,Any}()
    end
    failure = _dict(get(envelope, "error", nothing))
    message = _string(get(failure, "message", nothing))
    request_id = HTTP.header(response, "X-Request-Id", "")
    return ApiError(response.status, _string(get(failure, "code", nothing)),
        isempty(message) ? first(String(copy(response.body)), 500) : message,
        isempty(request_id) ? nothing : String(request_id))
end

function _request(method::String, path::String, body::String = "",
                  idempotency_key::Union{String,Nothing} = nothing)::Dict{String,Any}
    client = _client()
    headers = ["x-api-key" => client.api_key, "Accept" => "application/json"]
    isempty(body) || push!(headers, "Content-Type" => "application/json")
    if idempotency_key !== nothing
        # Sent may ignore a malformed key, and a retry would then send twice.
        occursin(IDEMPOTENCY_KEY_PATTERN, idempotency_key) || throw(ArgumentError(
            "Sent idempotency keys are 1 to 255 letters, digits, hyphens, or underscores"))
        push!(headers, "Idempotency-Key" => idempotency_key)
    end
    # HTTP.jl sends a GET, a PUT, or a request with an Idempotency-Key again when the connection
    # drops or Sent answers 408, 429, 500, 502, 503, or 504, so a dead keep-alive connection
    # doesn't fail the call, and Sent answers a repeated key with its first answer. Without
    # redirect=false, HTTP.jl would send x-api-key on to a redirect's host.
    response = HTTP.request(method, client.base_url * path, headers, body;
        redirect = false, status_exception = false,
        connect_timeout = 10, read_idle_timeout = 30)
    200 <= response.status < 300 || throw(_api_error(response))
    return _dict(get(_parse(response.body), "data", nothing))
end

"""
    send_message(; to, idempotency_key, text=nothing, template_id=nothing,
                 parameters=nothing, from=nothing, sandbox=false) -> SendResult

Send one SMS to the E.164 number `to`. Pass exactly one of `text` or `template_id`, with
`parameters` filling the template's variables. `from` picks one of the account's numbers.

`idempotency_key` is 1 to 255 letters, digits, hyphens, or underscores. Sent keeps it for 24
hours, so a retry with the same key and arguments gets the first answer back instead of a
second text. A successful call means Sent queued the message. The message can still end
`BLOCKED` or `FILTERED`, and `get_message` and the status webhooks report that.
"""
function send_message(; to::String, idempotency_key::String,
                      text::Union{String,Nothing} = nothing,
                      template_id::Union{String,Nothing} = nothing,
                      parameters::Union{Dict{String,String},Nothing} = nothing,
                      from::Union{String,Nothing} = nothing, sandbox::Bool = false)::SendResult
    (text === nothing) == (template_id === nothing) &&
        throw(ArgumentError("Sent send_message takes exactly one of text or template_id"))
    request = SendRequest([to], ["sms"],
        from === nothing ? nothing : Dict("sms" => [Dict("from" => [from])]),
        template_id === nothing ? nothing : TemplateRef(template_id, parameters),
        text, sandbox)
    # Sent compares a retried body byte for byte. Struct fields keep their order, and
    # sort_keys orders the map keys.
    body = JSON.json(request; omit_null = true, sort_keys = true)
    data = _request("POST", "/v3/messages", body, idempotency_key)
    recipients = Recipient[]
    for value in _array(get(data, "recipients", nothing))
        recipient = _dict(value)
        push!(recipients, Recipient(_string(get(recipient, "message_id", nothing)),
            _string(get(recipient, "to", nothing)), _string(get(recipient, "channel", nothing))))
    end
    if isempty(recipients) || any(r -> isempty(r.message_id), recipients)
        error("Sent accepted the send without a message id")
    end
    return SendResult(_string(get(data, "status", nothing)), recipients)
end

"Return Sent's record of the message `id`, including its `status`, `reason_code`, and `reason`."
get_message(id::String) = _request("GET", "/v3/messages/" * HTTP.URIs.escapeuri(id))

"Return Sent's contact for the E.164 number `phone`, or `nothing` when Sent has none."
function find_contact(phone::String)::Union{Dict{String,Any},Nothing}
    data = try
        # The OpenAPI document requires page and page_size on this list call.
        _request("GET", "/v3/contacts?page=1&page_size=1&phone=" * HTTP.URIs.escapeuri(phone))
    catch err
        err isa ApiError && err.status == 404 && err.code == "RESOURCE_001" && return nothing
        rethrow()
    end
    contacts = _array(get(data, "contacts", nothing))
    return isempty(contacts) ? nothing : _dict(contacts[1])
end

"Set the opt-out flag on Sent's contact `id` and return the updated contact."
update_contact(id::String; opt_out::Bool, idempotency_key::String) = _request(
    "PATCH", "/v3/contacts/" * HTTP.URIs.escapeuri(id), JSON.json((; opt_out)), idempotency_key)

"Return one page of the account's templates: a `Dict` with `templates` and `pagination`."
list_templates(; page::Int = 1, page_size::Int = 100) =
    _request("GET", "/v3/templates?page=$page&page_size=$page_size")

"Create a template from `body`, which is written as JSON, and return it."
create_template(body) = _request("POST", "/v3/templates", JSON.json(body))

"""
    update_template(id, body; idempotency_key=nothing)

Update the template `id` with the fields in `body`, which is written as JSON, and return it.
HTTP.jl sends a PUT again when its answer is lost. Without `idempotency_key`, a repeated
`submit_for_review` fails with `409 CONFLICT_006` although the first one worked.
"""
update_template(id::String, body; idempotency_key::Union{String,Nothing} = nothing) =
    _request("PUT", "/v3/templates/" * HTTP.URIs.escapeuri(id), JSON.json(body), idempotency_key)

# The loop reads every byte, so the time taken does not show where a guess first differs.
function _equal_bytes(a::AbstractVector{UInt8}, b::AbstractVector{UInt8})::Bool
    length(a) == length(b) || return false
    difference = 0x00
    for i in eachindex(a, b)
        difference |= a[i] ⊻ b[i]
    end
    return difference == 0x00
end

"""
    verify_webhook(body, id, timestamp, signature, secret; now_unix, max_skew) -> Bool

Check the Standard Webhooks signature that Sent sends in the `webhook-id`, `webhook-timestamp`,
and `webhook-signature` headers. `secret` is the `whsec_` signing secret. The signature header
can hold several space-separated `v1,` signatures, as it does for a day after a secret rotation.
A timestamp more than `max_skew` seconds from `now_unix` fails. `body` is left unchanged.
"""
function verify_webhook(body::Vector{UInt8}, id::AbstractString, timestamp::AbstractString,
                        signature::AbstractString, secret::AbstractString;
                        now_unix::Integer = round(Int, time()),
                        max_skew::Integer = WEBHOOK_MAX_SKEW_SECONDS)::Bool
    (isempty(id) || isempty(timestamp) || isempty(signature) || isempty(secret)) && return false
    sent_at = tryparse(Int, timestamp)
    sent_at === nothing && return false
    abs(now_unix - sent_at) <= max_skew || return false
    key = try
        base64decode(chopprefix(secret, "whsec_"))
    catch
        return false
    end
    isempty(key) && return false
    signed = [codeunits(string(id, '.', timestamp, '.')); body]
    expected = codeunits("v1," * base64encode(hmac_sha256(key, signed)))
    return any(token -> _equal_bytes(codeunits(token), expected), split(signature, ' '))
end

"Parse a webhook body that `verify_webhook` accepted. `body` is left unchanged."
parse_webhook(body::Vector{UInt8}) = _parse(body)

end # module SentDM

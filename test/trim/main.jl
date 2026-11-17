# Compiled with `juliac --trim=safe` in CI to check that the calls, error parsing, and
# webhook parsing stay trim-safe. The calls go to a closed local port, so they fail to
# connect and nothing reaches Sent.
#
# `verify_webhook` is left out: it uses Base64's `base64encode` and `base64decode`, and
# Base64's pipes store their stream as an abstract `IO`, which the trim verifier rejects.
using SentDM

function unreachable(name::String, call)::Bool
    try
        call()
        println(Core.stdout, name, ": unexpected answer")
        return false
    catch e
        e isa SentDM.ApiError && rethrow()
        println(Core.stdout, name, " to a closed port failed: ", nameof(typeof(e)))
        return true
    end
end

function calls()::Bool
    sent = unreachable("send_message", () -> SentDM.send_message(; to = "+18015550123",
        idempotency_key = "trim-1", template_id = "7ba7b820-9dad-11d1-80b4-00c04fd430c8",
        parameters = Dict("code" => "123456"), from = "+18015550100"))
    found = unreachable("find_contact", () -> SentDM.find_contact("+18015550123"))
    updated = unreachable("update_contact", () -> SentDM.update_contact(
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8"; opt_out = true, idempotency_key = "trim-2"))
    return sent && found && updated
end

function (@main)(args::Vector{String})::Cint
    calls_failed = SentDM.with_sentdm(calls, "trim-key"; base_url = "http://127.0.0.1:1")

    # HTTP.request answers with the body as bytes.
    err = SentDM._api_error(SentDM.HTTP.Response(400, ["X-Request-Id" => "req_1"], Vector{UInt8}(
        "{\"success\":false,\"error\":{\"code\":\"VALIDATION_002\",\"message\":\"Invalid phone number format\"}}")))
    parsed = err.status == 400 && err.code == "VALIDATION_002" &&
        err.message == "Invalid phone number format" && err.request_id == "req_1"
    println(Core.stdout, "ApiError parsed: ", parsed)

    event = SentDM.parse_webhook(Vector{UInt8}("{\"field\":\"contact\",\"event\":\"contact.opt_out\"}"))["event"]
    webhook = event isa String && event == "contact.opt_out"
    println(Core.stdout, "webhook parsed: ", webhook)
    return calls_failed && parsed && webhook ? 0 : 1
end

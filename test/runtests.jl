using HTTP, SentDM, Sockets, Test

@testset "Sent webhook signatures" begin
    # Known-answer vector. Python's hmac module and `openssl dgst -hmac` both produce this signature.
    secret = "whsec_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    id = "msg_2LJcP4oRIbOmFrzTeST5bJ9JvAR"
    timestamp = "1730000000"
    text = """{"field":"contact","event":"contact.opt_out","payload":{"from":"+18015550123","opt_out":true}}"""
    signature = "v1,C2jACI3JTSHyzqA7rMd2uDoIaaDe61gi2ccKVOgyItc="
    wrong = "v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    verify(body, id, timestamp, signature, secret; now_unix = 1730000000) =
        SentDM.verify_webhook(body, id, timestamp, signature, secret; now_unix)

    body = Vector{UInt8}(text)
    @test verify(body, id, timestamp, signature, secret)
    @test body == Vector{UInt8}(text)
    @test verify(body, id, timestamp, signature, secret; now_unix = 1730000000 + 300)
    @test !verify(body, id, timestamp, signature, secret; now_unix = 1730000000 + 301)
    @test !verify(body, id, timestamp, wrong, secret)
    @test verify(body, id, timestamp, "$wrong $signature", secret)
    @test !verify(Vector{UInt8}(replace(text, "true" => "True")), id, timestamp, signature, secret)
    @test !verify(body, "", timestamp, signature, secret)
    @test !verify(body, id, "", signature, secret)
    @test !verify(body, id, timestamp, "", secret)
    @test !verify(body, id, timestamp, signature, "")

    @test SentDM.parse_webhook(body)["payload"]["opt_out"] === true
    @test body == Vector{UInt8}(text)
end

@testset "Sent API requests" begin
    port, listener = Sockets.listenany(Sockets.localhost, 0)
    close(listener)
    seen = Ref{Any}(nothing)
    reply = Ref((200, "{}"))
    server = HTTP.serve!("127.0.0.1", port) do req
        seen[] = (method = req.method, target = req.target,
            api_key = HTTP.header(req, "x-api-key"),
            idempotency_key = HTTP.header(req, "Idempotency-Key"),
            content_type = HTTP.header(req, "Content-Type"),
            body = String(copy(req.body)))
        status, body = reply[]
        return HTTP.Response(status,
            ["Content-Type" => "application/json", "X-Request-Id" => "req_7X9zKp2jDw"], body)
    end
    request(method, target; key = "", body = "") = (; method, target, api_key = "test-key",
        idempotency_key = key, content_type = isempty(body) ? "" : "application/json", body)
    ok(data) = (200, """{"success":true,"data":$data,"error":null,"meta":{"request_id":"req_7X9zKp2jDw"}}""")
    refusal(status, code, message) = (status, """{"success":false,"data":null,""" *
        """"error":{"code":"$code","message":"$message"},"meta":{"request_id":"req_7X9zKp2jDw"}}""")
    to = "+18015550123"
    message_id = "8ba7b830-9dad-11d1-80b4-00c04fd430c8"
    try
        SentDM.with_sentdm("test-key"; base_url = "http://127.0.0.1:$port") do
            reply[] = (202, """{"success":true,"data":{"status":"QUEUED",""" *
                """"template_id":"7ba7b820-9dad-11d1-80b4-00c04fd430c8","template_name":"notice",""" *
                """"recipients":[{"message_id":"$message_id","to":"$to","channel":"sms",""" *
                """"body":"Blue Herons: Game 2 moved to 7pm."}]},"error":null,""" *
                """"meta":{"request_id":"req_7X9zKp2jDw"}}""")
            result = SentDM.send_message(; to, idempotency_key = "notification-1",
                template_id = "7ba7b820-9dad-11d1-80b4-00c04fd430c8",
                parameters = Dict("team" => "Blue Herons", "message" => "Game 2 moved to 7pm."),
                from = "+18015550100")
            @test seen[] == request("POST", "/v3/messages"; key = "notification-1",
                body = """{"to":["+18015550123"],"channel":["sms"],""" *
                    """"channels":{"sms":[{"from":["+18015550100"]}]},""" *
                    """"template":{"id":"7ba7b820-9dad-11d1-80b4-00c04fd430c8",""" *
                    """"parameters":{"message":"Game 2 moved to 7pm.","team":"Blue Herons"}},""" *
                    """"sandbox":false}""")
            @test result.status == "QUEUED"
            @test result.recipients == [SentDM.Recipient(message_id, to, "sms")]

            SentDM.send_message(; to, idempotency_key = "notification-2",
                text = "Blue Herons: Game 2 moved to 7pm.", sandbox = true)
            @test seen[] == request("POST", "/v3/messages"; key = "notification-2",
                body = """{"to":["+18015550123"],"channel":["sms"],""" *
                    """"text":"Blue Herons: Game 2 moved to 7pm.","sandbox":true}""")

            reply[] = refusal(400, "VALIDATION_002", "Invalid phone number format")
            @test_throws SentDM.ApiError(400, "VALIDATION_002", "Invalid phone number format",
                "req_7X9zKp2jDw") SentDM.send_message(; to = "+1801", idempotency_key = "k3", text = "Hi")

            seen[] = nothing
            @test_throws ArgumentError SentDM.send_message(; to, idempotency_key = "not valid", text = "Hi")
            @test_throws ArgumentError SentDM.send_message(; to, idempotency_key = "k4",
                text = "Hi", template_id = "7ba7b820-9dad-11d1-80b4-00c04fd430c8")
            @test_throws ArgumentError SentDM.send_message(; to, idempotency_key = "k5")
            @test seen[] === nothing

            reply[] = ok("""{"id":"$message_id","status":"DELIVERED","channel":"sms"}""")
            @test SentDM.get_message(message_id)["status"] == "DELIVERED"
            @test seen[] == request("GET", "/v3/messages/$message_id")

            reply[] = (401, "Unauthorized")
            @test_throws SentDM.ApiError(401, "", "Unauthorized", "req_7X9zKp2jDw") SentDM.get_message(message_id)

            contact_id = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
            reply[] = ok("""{"contacts":[{"id":"$contact_id","phone_number":"$to","opt_out":true}],""" *
                """"pagination":{"page":1,"page_size":1,"total_count":1,"total_pages":1,"has_more":false}}""")
            @test SentDM.find_contact(to)["id"] == contact_id
            @test seen[] == request("GET", "/v3/contacts?page=1&page_size=1&phone=%2B18015550123")
            reply[] = refusal(404, "RESOURCE_001", "Contact not found with the specified phone number")
            @test SentDM.find_contact("+18015550124") === nothing

            reply[] = ok("""{"id":"$contact_id","phone_number":"$to","opt_out":false}""")
            @test SentDM.update_contact(contact_id; opt_out = false,
                idempotency_key = "optin-1")["opt_out"] === false
            @test seen[] == request("PATCH", "/v3/contacts/$contact_id"; key = "optin-1",
                body = """{"opt_out":false}""")

            template_id = "9ba7b840-9dad-11d1-80b4-00c04fd430c8"
            reply[] = ok("""{"templates":[{"id":"$template_id","name":"Opt-out reply",""" *
                """"status":"APPROVED","auto_reply_action":"OPT_OUT"}],"pagination":{"page":1}}""")
            @test SentDM.list_templates()["templates"][1]["auto_reply_action"] == "OPT_OUT"
            @test seen[] == request("GET", "/v3/templates?page=1&page_size=100")

            reply[] = ok("""{"id":"$template_id","name":"Club opt-out reply","status":"DRAFT"}""")
            @test SentDM.update_template(template_id, (; name = "Club opt-out reply"))["status"] == "DRAFT"
            @test seen[] == request("PUT", "/v3/templates/$template_id";
                body = """{"name":"Club opt-out reply"}""")

            reply[] = (201, """{"success":true,"data":{"id":"$template_id","status":"PENDING"}}""")
            @test SentDM.create_template((; name = "Club notification"))["status"] == "PENDING"
            @test seen[] == request("POST", "/v3/templates";
                body = """{"name":"Club notification"}""")
        end
    finally
        HTTP.forceclose(server)
        wait(server)
    end
end

@testset "a send survives a connection Sent closed without answering" begin
    listener = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(listener)[2])
    keys = String[]
    function read_request(socket)
        text = ""
        while !occursin("\r\n\r\n", text)
            text *= String(readavailable(socket))
        end
        headers, body = split(text, "\r\n\r\n"; limit = 2)
        length_header = match(r"content-length: (\d+)"i, headers)
        missing_bytes = parse(Int, length_header.captures[1]) - ncodeunits(body)
        missing_bytes > 0 && read(socket, missing_bytes)
        push!(keys, match(r"idempotency-key: ([^\r]+)"i, headers).captures[1])
    end
    data = """{"success":true,"data":{"status":"QUEUED","recipients":[""" *
        """{"message_id":"m1","to":"+18015550123","channel":"sms"}]}}"""
    server = @async begin
        closed_without_answer = accept(listener)
        read_request(closed_without_answer)
        close(closed_without_answer)
        answered = accept(listener)
        read_request(answered)
        write(answered, "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\n" *
            "Content-Length: $(ncodeunits(data))\r\nConnection: close\r\n\r\n$data")
        close(answered)
    end
    try
        SentDM.with_sentdm("test-key"; base_url = "http://127.0.0.1:$port") do
            result = SentDM.send_message(; to = "+18015550123", idempotency_key = "notification-9",
                template_id = "7ba7b820-9dad-11d1-80b4-00c04fd430c8")
            @test result.recipients == [SentDM.Recipient("m1", "+18015550123", "sms")]
        end
        wait(server)
        @test keys == ["notification-9", "notification-9"]
    finally
        close(listener)
    end
end

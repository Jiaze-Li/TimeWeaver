import Foundation

extension AIWorkbookNormalizer {
    static func requestPayload(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment? = nil
    ) async throws -> AIRequestPayloadResponse {
        let isImageParsing = imageAttachment != nil
        let requestConfiguration = configuration.configurationForRequest(isImageParsing: isImageParsing)
        do {
            let payloadText = try await requestPayloadText(
                configuration: requestConfiguration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
            return AIRequestPayloadResponse(
                payloadData: Data(payloadText.utf8),
                providerUsed: requestConfiguration.provider,
                usedFallback: false
            )
        } catch {
            guard
                shouldRetryWithFallback(for: error),
                let fallback = fallbackRequestConfiguration(from: configuration, isImageParsing: isImageParsing)
            else {
                throw error
            }
            let payloadText = try await requestPayloadText(
                configuration: fallback,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
            return AIRequestPayloadResponse(
                payloadData: Data(payloadText.utf8),
                providerUsed: fallback.provider,
                usedFallback: true
            )
        }
    }

    static func requestPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        let payloadText: String
        switch configuration.requestStyle {
        case .responses:
            payloadText = try await requestResponsesPayloadText(
                configuration: configuration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        case .chatCompletions:
            payloadText = try await requestChatCompletionsPayloadText(
                configuration: configuration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        case .anthropicMessages:
            payloadText = try await requestAnthropicPayloadText(
                configuration: configuration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        case .geminiGenerateContent:
            payloadText = try await requestGeminiPayloadText(
                configuration: configuration,
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                imageAttachment: imageAttachment
            )
        }

        return payloadText
    }

    static func fallbackRequestConfiguration(
        from configuration: AIServiceConfiguration,
        isImageParsing: Bool
    ) -> AIServiceConfiguration? {
        guard let fallback = configuration.fallbackProvider?.configurationForRequest(isImageParsing: isImageParsing) else {
            return nil
        }

        if fallback.provider == configuration.provider,
           fallback.endpointURL == configuration.endpointURL,
           fallback.apiKey == configuration.apiKey,
           fallback.model == configuration.model {
            return nil
        }

        return AIServiceConfiguration(
            provider: fallback.provider,
            endpointURL: fallback.endpointURL,
            apiKey: fallback.apiKey,
            model: fallback.model,
            fallbackProvider: nil
        )
    }

    static func shouldRetryWithFallback(for error: Error) -> Bool {
        guard let appFailure = error as? AppFailure, case .syncFailed(let message) = appFailure else {
            return false
        }

        let normalized = message.lowercased()
        if normalized.contains("invalid or lacks permission")
            || normalized.contains("authentication is required")
            || normalized.contains("policy/safety")
            || normalized.contains("model name is invalid or unavailable") {
            return false
        }

        if normalized.contains("network connection error")
            || normalized.contains("timed out")
            || normalized.contains("rate limited")
            || normalized.contains("http 408")
            || normalized.contains("http 5") {
            return true
        }
        return false
    }

    static func noteProviderUsage(
        for result: AINormalizationResult,
        primaryProvider: AIProvider,
        providerUsed: AIProvider,
        usedFallback: Bool
    ) -> AINormalizationResult {
        if usedFallback {
            return addingNote(
                "AI provider fallback used: \(primaryProvider.title) -> \(providerUsed.title).",
                to: result
            )
        }
        return addingNote("AI provider used: \(providerUsed.title).", to: result)
    }

    static func addingNote(_ note: String, to result: AINormalizationResult) -> AINormalizationResult {
        guard !result.notes.contains(note) else {
            return result
        }
        var adjusted = result
        adjusted.notes.append(note)
        return adjusted
    }

    static func cachedNormalizationResult(for workbookFingerprint: String) -> AINormalizationResult? {
        normalizationCacheLock.lock()
        defer { normalizationCacheLock.unlock() }

        guard let entry = normalizationCache[workbookFingerprint] else {
            return nil
        }
        if entry.expiresAt <= Date() {
            normalizationCache.removeValue(forKey: workbookFingerprint)
            return nil
        }
        return entry.result
    }

    static func cacheNormalizationResult(_ result: AINormalizationResult, for workbookFingerprint: String) {
        normalizationCacheLock.lock()
        defer { normalizationCacheLock.unlock() }

        let now = Date()
        normalizationCache = normalizationCache.filter { $0.value.expiresAt > now }
        normalizationCache[workbookFingerprint] = CachedAINormalizationResult(
            result: result,
            expiresAt: now.addingTimeInterval(normalizationCacheTTL)
        )
    }

    static func requestResponsesPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        let input: Any
        if let imageAttachment {
            input = [[
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": prompt
                    ],
                    [
                        "type": "input_image",
                        "image_url": dataURL(for: imageAttachment)
                    ]
                ]
            ]]
        } else {
            input = prompt
        }

        var body: [String: Any] = [
            "model": configuration.model,
            "instructions": instructions,
            "input": input,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "reservation_occurrences",
                    "schema": schema,
                    "strict": true
                ]
            ]
        ]
        if configuration.provider == .openAI {
            body["reasoning"] = [
                "effort": imageAttachment == nil ? "medium" : "low"
            ]
        }

        let data = try await performAIRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(ResponsesAPIEnvelope.self, from: data)
        guard let payloadText = extractResponsesPayloadText(from: envelope) else {
            throw AppFailure.invalidAIResponse("The AI response did not include structured text.")
        }
        return payloadText
    }

    static func requestChatCompletionsPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        try await requestChatCompletionsPayloadText(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: true
        )
    }

    static func requestChatCompletionsPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?,
        allowRetry: Bool
    ) async throws -> String {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            throw AppFailure.invalidAIResponse("Could not encode the AI schema.")
        }

        let systemPrompt: String
        if configuration.provider == .kimi {
            systemPrompt = """
            \(instructions)
            Return valid JSON only. Do not wrap the answer in markdown.
            Do not return schema definitions such as type, properties, required, or additionalProperties.
            \(kimiSchemaGuidance(for: schema))
            """
        } else {
            systemPrompt = """
            \(instructions)
            Return valid JSON only. Do not wrap the answer in markdown.
            The JSON must match this schema exactly:
            \(schemaText)
            """
        }

        let userContent: Any
        if let imageAttachment {
            userContent = [
                [
                    "type": "text",
                    "text": prompt
                ],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": dataURL(for: imageAttachment)
                    ]
                ]
            ]
        } else {
            userContent = prompt
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userContent
                ]
            ],
            "response_format": [
                "type": "json_object"
            ],
            "temperature": 0
        ]

        let data = try await performAIRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(ChatCompletionsEnvelope.self, from: data)
        guard let content = envelope.choices.first?.message.content else {
            throw AppFailure.invalidAIResponse("The AI response did not include a completion message.")
        }
        if let payloadText = extractJSONText(from: content) {
            return payloadText
        }
        if configuration.provider == .kimi,
           let repaired = try await repairChatCompletionsJSON(
            configuration: configuration,
            schema: schema,
            rawContent: content
           ) {
            return repaired
        }
        guard allowRetry else {
            throw AppFailure.invalidAIResponse("The AI response did not return valid JSON text.")
        }
        let retryInstructions = instructions + "\nYour previous answer was not valid JSON. Return only one compact JSON object and nothing else."
        return try await requestChatCompletionsPayloadText(
            configuration: configuration,
            instructions: retryInstructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: false
        )
    }

    static func repairChatCompletionsJSON(
        configuration: AIServiceConfiguration,
        schema: [String: Any],
        rawContent: String
    ) async throws -> String? {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            return nil
        }
        var repairConfiguration = configuration
        if configuration.provider == .kimi {
            repairConfiguration.model = configuration.provider.automaticSheetModel
        }

        let body: [String: Any] = [
            "model": repairConfiguration.model,
            "messages": [
                [
                    "role": "system",
                    "content": configuration.provider == .kimi
                        ? """
                        Convert the assistant answer into one compact JSON object.
                        Keep only facts already present in the answer.
                        Do not add commentary or markdown.
                        Do not return schema definitions such as type, properties, required, or additionalProperties.
                        \(kimiSchemaGuidance(for: schema))
                        """
                        : """
                        Convert the assistant answer into one compact JSON object.
                        Keep only facts already present in the answer.
                        Do not add commentary or markdown.
                        The JSON must match this schema exactly:
                        \(schemaText)
                        """
                ],
                [
                    "role": "user",
                    "content": "Repair this answer into valid JSON only:\n\(rawContent)"
                ]
            ],
            "response_format": [
                "type": "json_object"
            ],
            "temperature": 0
        ]

        let data = try await performAIRequest(configuration: repairConfiguration, body: body)
        let envelope = try JSONDecoder().decode(ChatCompletionsEnvelope.self, from: data)
        guard let content = envelope.choices.first?.message.content else {
            return nil
        }
        return extractJSONText(from: content)
    }

    static func requestAnthropicPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        try await requestAnthropicPayloadText(
            configuration: configuration,
            instructions: instructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: true
        )
    }

    static func requestAnthropicPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?,
        allowRetry: Bool
    ) async throws -> String {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            throw AppFailure.invalidAIResponse("Could not encode the AI schema.")
        }

        let systemPrompt = """
        \(instructions)
        Return valid JSON only. Do not wrap the answer in markdown or code fences.
        The JSON must match this schema exactly:
        \(schemaText)
        Think step by step: first identify the booking ID in the source, then locate all matching reservations, then construct the JSON.
        """

        var userContent: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt
            ]
        ]
        if let imageAttachment {
            userContent.insert([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": imageAttachment.mimeType,
                    "data": imageAttachment.data.base64EncodedString()
                ]
            ], at: 0)
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 8192,
            "temperature": 0,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": userContent
                ],
                [
                    "role": "assistant",
                    "content": "{\"parser_summary\":"
                ]
            ]
        ]

        let data = try await performAnthropicRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(AnthropicMessagesEnvelope.self, from: data)
        let content = envelope.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
        let prefilled = "{\"parser_summary\":" + content
        if let payloadText = extractJSONText(from: prefilled) {
            return payloadText
        }
        if let payloadText = extractJSONText(from: content) {
            return payloadText
        }
        guard allowRetry else {
            throw AppFailure.invalidAIResponse("The Anthropic response did not return valid JSON text.")
        }
        let retryInstructions = instructions + "\nYour previous answer was not valid JSON. Return only one compact JSON object and nothing else."
        return try await requestAnthropicPayloadText(
            configuration: configuration,
            instructions: retryInstructions,
            prompt: prompt,
            schema: schema,
            imageAttachment: imageAttachment,
            allowRetry: false
        )
    }

    static func requestGeminiPayloadText(
        configuration: AIServiceConfiguration,
        instructions: String,
        prompt: String,
        schema: [String: Any],
        imageAttachment: AIImageAttachment?
    ) async throws -> String {
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        guard let schemaText = String(data: schemaData, encoding: .utf8) else {
            throw AppFailure.invalidAIResponse("Could not encode the AI schema.")
        }

        let fullPrompt = """
        \(instructions)
        Return valid JSON only. Do not wrap the answer in markdown.
        The JSON must match this schema exactly:
        \(schemaText)

        \(prompt)
        """

        var parts: [[String: Any]] = [
            [
                "text": fullPrompt
            ]
        ]
        if let imageAttachment {
            parts.append([
                "inlineData": [
                    "mimeType": imageAttachment.mimeType,
                    "data": imageAttachment.data.base64EncodedString()
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json"
            ]
        ]

        let data = try await performGeminiRequest(configuration: configuration, body: body)
        let envelope = try JSONDecoder().decode(GeminiGenerateContentEnvelope.self, from: data)
        let content = envelope.candidates?
            .compactMap { $0.content?.parts?.compactMap(\.text).joined(separator: "\n") }
            .first ?? ""
        guard let payloadText = extractJSONText(from: content) else {
            throw AppFailure.invalidAIResponse("The Gemini response did not return valid JSON text.")
        }
        return payloadText
    }

    static func performAIRequest(
        configuration: AIServiceConfiguration,
        body: [String: Any]
    ) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 90

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 90
        sessionConfiguration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: sessionConfiguration)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw classifyAITransportError(error)
        }
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw classifyAIHTTPError(statusCode: httpResponse.statusCode, responseData: data)
        }
        return data
    }

    static func performAnthropicRequest(
        configuration: AIServiceConfiguration,
        body: [String: Any]
    ) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 90

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 90
        sessionConfiguration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: sessionConfiguration)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw classifyAITransportError(error)
        }
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw classifyAIHTTPError(statusCode: httpResponse.statusCode, responseData: data)
        }
        return data
    }

    static func performGeminiRequest(
        configuration: AIServiceConfiguration,
        body: [String: Any]
    ) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: geminiRequestURL(for: configuration))
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 90

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 90
        sessionConfiguration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: sessionConfiguration)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw classifyAITransportError(error)
        }
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw classifyAIHTTPError(statusCode: httpResponse.statusCode, responseData: data)
        }
        return data
    }

    static func classifyAITransportError(_ error: Error) -> AppFailure {
        guard let urlError = error as? URLError else {
            return .syncFailed("AI parser request failed: \(error.localizedDescription)")
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .syncFailed("AI parser request failed: network connection error (\(urlError.localizedDescription)).")
        case .timedOut:
            return .syncFailed("AI parser request failed: request timed out. Check network and endpoint latency.")
        case .userAuthenticationRequired:
            return .syncFailed("AI parser request failed: authentication is required by the endpoint.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return .syncFailed("AI parser request failed: TLS/SSL validation error. Check certificate configuration.")
        default:
            return .syncFailed("AI parser request failed: \(urlError.localizedDescription)")
        }
    }

    static func classifyAIHTTPError(statusCode: Int, responseData: Data) -> AppFailure {
        let body = String(data: responseData, encoding: .utf8) ?? ""
        let bodyLower = body.lowercased()

        if statusCode == 401 || statusCode == 403 {
            return .syncFailed("AI parser request failed: API key is invalid or lacks permission (HTTP \(statusCode)).")
        }
        if statusCode == 429 {
            return .syncFailed("AI parser request failed: rate limited by provider (HTTP 429).")
        }
        if bodyLower.contains("refus") || bodyLower.contains("safety") || bodyLower.contains("policy") || bodyLower.contains("blocked") {
            return .syncFailed("AI parser request failed: model refused the request due to policy/safety constraints (HTTP \(statusCode)).")
        }
        if bodyLower.contains("model") && (bodyLower.contains("not found") || bodyLower.contains("does not exist") || bodyLower.contains("invalid")) {
            return .syncFailed("AI parser request failed: model name is invalid or unavailable (HTTP \(statusCode)).")
        }
        let summary = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        if summary.isEmpty {
            return .syncFailed("AI parser request failed with HTTP \(statusCode).")
        }
        return .syncFailed("AI parser request failed with HTTP \(statusCode): \(summary)")
    }

    static func geminiRequestURL(for configuration: AIServiceConfiguration) -> URL {
        let endpoint = configuration.endpointURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.contains(":generateContent"), let url = URL(string: endpoint) {
            return url
        }
        let trimmed = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return URL(string: "\(trimmed)/\(configuration.model):generateContent")!
    }

    static func extractResponsesPayloadText(from envelope: ResponsesAPIEnvelope) -> String? {
        if let outputText = envelope.outputText, !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        for item in envelope.output ?? [] {
            for content in item.content ?? [] {
                if let text = content.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    static func kimiSchemaGuidance(for schema: [String: Any]) -> String {
        if isVisibleFieldSchema(schema) {
            return """
            Return exactly one object with these top-level keys:
            - parser_summary: string
            - occurrences: array
            Each occurrence object must include:
            - sheet_name: string
            - cell_reference: string
            - date_text: string
            - time_text: string
            - start_time_text: string
            - end_time_text: string
            - lesson_text: string
            - start_iso: string (empty string if unavailable)
            - end_iso: string (empty string if unavailable)
            - all_day: boolean
            - confidence: number
            - explanation: string
            """
        }
        return """
        Return exactly one object with these top-level keys:
        - parser_summary: string
        - occurrences: array
        Each occurrence object must include:
        - sheet_name: string
        - cell_reference: string
        - start_iso: string
        - end_iso: string
        - all_day: boolean
        - confidence: number
        - explanation: string
        """
    }

    static func isVisibleFieldSchema(_ schema: [String: Any]) -> Bool {
        guard
            let properties = schema["properties"] as? [String: Any],
            let occurrences = properties["occurrences"] as? [String: Any],
            let items = occurrences["items"] as? [String: Any],
            let itemProperties = items["properties"] as? [String: Any]
        else {
            return false
        }
        return itemProperties["date_text"] != nil
    }

    static func extractJSONText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isJSONObject(trimmed) {
            return trimmed
        }

        if trimmed.hasPrefix("```"), let fenced = extractFencedJSON(from: trimmed), isJSONObject(fenced) {
            return fenced
        }

        if let firstBrace = trimmed.firstIndex(of: "{"), let lastBrace = trimmed.lastIndex(of: "}") {
            let candidate = String(trimmed[firstBrace...lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isJSONObject(candidate) {
                return candidate
            }
        }

        return nil
    }

    static func extractFencedJSON(from text: String) -> String? {
        let components = text.components(separatedBy: "```")
        guard components.count >= 3 else { return nil }
        let candidate = components[1]
            .replacingOccurrences(of: "json", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    static func isJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    static func dataURL(for imageAttachment: AIImageAttachment) -> String {
        "data:\(imageAttachment.mimeType);base64,\(imageAttachment.data.base64EncodedString())"
    }
}

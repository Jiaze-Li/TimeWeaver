import Foundation

enum ParserMode: String, Codable, CaseIterable, Identifiable {
    case rulesOnly = "rules_only"
    case auto = "auto"
    case aiOnly = "ai_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rulesOnly:
            return "Rules"
        case .auto:
            return "Auto"
        case .aiOnly:
            return "AI"
        }
    }

    var summary: String {
        switch self {
        case .rulesOnly:
            return "Use the built-in sheet rules only."
        case .auto:
            return "Try built-in rules first, then ask AI when the layout is unfamiliar."
        case .aiOnly:
            return "Always ask AI to normalize the workbook."
        }
    }

    var inlineSummary: String {
        switch self {
        case .rulesOnly:
            return "Built-in only"
        case .auto:
            return "Try built-in first"
        case .aiOnly:
            return "AI only"
        }
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case kimi = "kimi"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case openRouter = "openrouter"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .deepSeek:
            return "DeepSeek"
        case .kimi:
            return "Kimi"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        case .openRouter:
            return "OpenRouter"
        case .custom:
            return "Custom"
        }
    }

    var pickerTitle: String {
        switch self {
        case .gemini:
            return "\(title) (images, recommended)"
        case .openAI, .anthropic, .openRouter:
            return "\(title) \(supportsImageParsing ? "(images, review)" : "(text only)")"
        case .kimi:
            return "\(title) (images, experimental)"
        case .deepSeek:
            return "\(title) (text only)"
        case .custom:
            return "\(title) \(supportsImageParsing ? "(images, manual)" : "(text only)")"
        }
    }

    var summary: String {
        switch self {
        case .openAI:
            return "Built-in setup for OpenAI Responses API."
        case .deepSeek:
            return "Built-in setup for DeepSeek chat completions."
        case .kimi:
            return "Built-in setup for Moonshot Kimi chat completions. Text uses the standard model and image sources automatically switch to the built-in vision model."
        case .anthropic:
            return "Built-in setup for Anthropic Messages API."
        case .gemini:
            return "Built-in setup for Gemini generateContent."
        case .openRouter:
            return "Built-in setup for OpenRouter chat completions."
        case .custom:
            return "Manual endpoint and model for custom, proxy, or self-hosted deployments."
        }
    }

    var defaultEndpointURL: String {
        switch self {
        case .openAI:
            return defaultOpenAIEndpointURL
        case .deepSeek:
            return defaultDeepSeekEndpointURL
        case .kimi:
            return defaultKimiEndpointURL
        case .anthropic:
            return defaultAnthropicEndpointURL
        case .gemini:
            return defaultGeminiEndpointURL
        case .openRouter:
            return defaultOpenRouterEndpointURL
        case .custom:
            return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            return defaultOpenAIModel
        case .deepSeek:
            return defaultDeepSeekModel
        case .kimi:
            return defaultKimiModel
        case .anthropic:
            return defaultAnthropicModel
        case .gemini:
            return defaultGeminiModel
        case .openRouter:
            return defaultOpenRouterModel
        case .custom:
            return ""
        }
    }

    var automaticSheetModel: String {
        defaultModel
    }

    var defaultImageModel: String? {
        switch self {
        case .kimi:
            return defaultKimiImageModel
        case .openAI, .anthropic, .gemini, .openRouter, .deepSeek, .custom:
            return nil
        }
    }

    var automaticImageModel: String {
        defaultImageModel ?? automaticSheetModel
    }

    var automaticModelSummary: String {
        if automaticImageModel == automaticSheetModel {
            return automaticSheetModel
        }
        return "sheet: \(automaticSheetModel), image: \(automaticImageModel)"
    }

    var supportsImageParsing: Bool {
        switch self {
        case .deepSeek:
            return false
        case .openAI, .kimi, .anthropic, .gemini, .openRouter, .custom:
            return true
        }
    }

    var requiresImageReviewByDefault: Bool {
        switch self {
        case .openAI, .kimi, .anthropic, .gemini, .openRouter, .custom, .deepSeek:
            return true
        }
    }
}

let defaultOpenAIEndpointURL = "https://api.openai.com/v1/responses"
let defaultOpenAIModel = "gpt-5.4"
let defaultDeepSeekEndpointURL = "https://api.deepseek.com/chat/completions"
let defaultDeepSeekModel = "deepseek-chat"
let defaultKimiEndpointURL = "https://api.moonshot.cn/v1/chat/completions"
let defaultKimiModel = "moonshot-v1-8k"
let defaultKimiImageModel = "moonshot-v1-8k-vision-preview"
let defaultAnthropicEndpointURL = "https://api.anthropic.com/v1/messages"
let defaultAnthropicModel = "claude-sonnet-4-20250514"
let defaultGeminiEndpointURL = "https://generativelanguage.googleapis.com/v1beta/models"
let defaultGeminiModel = "gemini-2.5-flash"
let defaultOpenRouterEndpointURL = "https://openrouter.ai/api/v1/chat/completions"
let defaultOpenRouterModel = "openai/gpt-4o-mini"
let defaultAIProvider: AIProvider = .openAI
let defaultAIEndpointURL = defaultOpenAIEndpointURL
let defaultAIModel = defaultOpenAIModel
let aiAverageConfidenceReviewThreshold = 0.90
let aiMinimumConfidenceReviewThreshold = 0.78

func inferAIProvider(fromEndpoint endpoint: String) -> AIProvider {
    let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("deepseek.com") {
        return .deepSeek
    }
    if normalized.contains("moonshot.cn") || normalized.contains("moonshot.ai") {
        return .kimi
    }
    if normalized.contains("anthropic.com") {
        return .anthropic
    }
    if normalized.contains("generativelanguage.googleapis.com") || normalized.contains("googleapis.com") {
        return .gemini
    }
    if normalized.contains("openrouter.ai") {
        return .openRouter
    }
    if normalized.isEmpty || normalized.contains("api.openai.com") {
        return .openAI
    }
    return .custom
}

enum AIRequestStyle {
    case responses
    case chatCompletions
    case anthropicMessages
    case geminiGenerateContent
}

struct AIServiceConfiguration {
    var provider: AIProvider
    var endpointURL: URL
    var apiKey: String
    var model: String

    var requestStyle: AIRequestStyle {
        switch provider {
        case .openAI:
            return .responses
        case .deepSeek, .kimi, .openRouter:
            return .chatCompletions
        case .anthropic:
            return .anthropicMessages
        case .gemini:
            return .geminiGenerateContent
        case .custom:
            let endpoint = endpointURL.absoluteString.lowercased()
            if endpoint.contains("/chat/completions") {
                return .chatCompletions
            }
            if endpoint.contains("anthropic.com") {
                return .anthropicMessages
            }
            if endpoint.contains("generativelanguage.googleapis.com") || endpoint.contains("googleapis.com") {
                return .geminiGenerateContent
            }
            return .responses
        }
    }

    private var manualModelOverride: String? {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedModel.isEmpty ? nil : normalizedModel
    }

    func resolvedModel(forImageParsing: Bool) -> String {
        if let manualModelOverride {
            return manualModelOverride
        }
        return forImageParsing ? provider.automaticImageModel : provider.automaticSheetModel
    }

    func configurationForRequest(isImageParsing: Bool) -> AIServiceConfiguration {
        var adjusted = self
        adjusted.model = resolvedModel(forImageParsing: isImageParsing)
        return adjusted
    }
}

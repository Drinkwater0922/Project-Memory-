import Foundation

public enum OpenRouterError: Error, Equatable {
    case invalidResponse
    case requestFailed(statusCode: Int, body: String)
    case missingContent
}

public struct OpenRouterClient {
    public var apiKey: String
    public var model: String
    public var appTitle: String
    private var session: URLSession

    public init(
        apiKey: String,
        model: String = "openai/gpt-4o-mini",
        appTitle: String = "Project Memory",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.appTitle = appTitle
        self.session = session
    }

    public func complete(prompt: String) async throws -> String {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: [
                    Message(
                        role: "system",
                        content: "你是 Project Memory，一个谨慎的项目记忆助手。只能基于提供的项目证据回答；证据不足时必须明确说明，不要编造。"
                    ),
                    Message(role: "user", content: prompt)
                ]
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenRouterError.requestFailed(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw OpenRouterError.missingContent
        }
        return content
    }
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [Message]
}

private struct Message: Codable {
    var role: String
    var content: String
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]
}

private struct Choice: Decodable {
    var message: Message
}

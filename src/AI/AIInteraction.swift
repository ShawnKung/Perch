import SwiftUI

struct AIClarification: Codable, Equatable {
    struct Question: Codable, Equatable {
        let label: String
        let options: [String]
    }
    let questions: [Question]
    var answers: [String]?

    func response(_ values: [String]) -> String? {
        guard values.count == questions.count else { return nil }
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cleaned.allSatisfy({ !$0.isEmpty && $0.count <= 1000 }) else { return nil }
        return "补充信息：\n" + zip(questions, cleaned).map { "\($0.label)：\($1)" }.joined(separator: "\n")
    }
}

enum AIInteraction {
    static let instruction = """
    只有缺少会实质影响结果的信息、无法合理默认时，调用 ask_clarification 展示最多三个简短问题，可附选项，用户也能自由输入。调用后等待用户回答，不猜测选项。普通说明无需提问。
    完成回答后，若有明确有用的下一步，可以调用 suggest_followups 提供最多三条简短、具体的后续问题；没有必要时不提供，不重复已完成任务。建议由用户点击发送或填入输入框，展示建议本身不代表用户已授权执行。
    引用搜索证据时使用 [简短来源名](实际返回的网址) 紧跟相关论述；不要编造引用或将整个来源列表当作逐条证据。
    """
    static func definitions(protocol api: AIProtocol) -> [[String: Any]] {
        let definitions: [(String, String, [String: Any])] = [
            ("ask_clarification", "展示问题并结束本轮，等待用户提交回答。不是执行操作的授权工具。", [
                "type": "object", "properties": ["questions": ["type": "array", "minItems": 1, "maxItems": 3, "items": [
                    "type": "object", "properties": [
                        "label": ["type": "string", "maxLength": 160],
                        "options": ["type": "array", "maxItems": 5, "items": ["type": "string", "maxLength": 100]]
                    ], "required": ["label", "options"], "additionalProperties": false
                ]]], "required": ["questions"], "additionalProperties": false
            ]),
            ("suggest_followups", "在已完成的回答下提供可选的后续问题，不发送、不执行。", [
                "type": "object", "properties": ["suggestions": ["type": "array", "minItems": 1, "maxItems": 3,
                    "items": ["type": "string", "maxLength": 160]]],
                "required": ["suggestions"], "additionalProperties": false
            ])
        ]
        return definitions.map { name, description, schema in
            switch api {
            case .openAI: return ["type": "function", "function": ["name": name, "description": description, "parameters": schema]]
            case .responses: return ["type": "function", "name": name, "description": description, "parameters": schema]
            case .anthropic: return ["name": name, "description": description, "input_schema": schema]
            }
        }
    }
    static func receive(_ call: AIPageToolCall, message: inout AIMessage) throws -> String {
        do {
            guard call.arguments.utf8.count <= 16384,
                  let input = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any] else {
                throw PerchError("参数必须为完整 JSON 对象。")
            }
            func valid(_ text: String, limit: Int) -> Bool {
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit && !text.contains("\0")
            }
            if call.name == "ask_clarification" {
                guard Set(input.keys) == ["questions"], let questions = input["questions"] as? [[String: Any]],
                      (1...3).contains(questions.count), message.clarification == nil else {
                    throw PerchError("每轮只能展示一次澄清卡，请提供 1–3 个问题。")
                }
                let values = try questions.map { item -> AIClarification.Question in
                    guard Set(item.keys) == ["label", "options"], let label = item["label"] as? String,
                          valid(label, limit: 160), let options = item["options"] as? [String], options.count <= 5,
                          Set(options).count == options.count, options.allSatisfy({ valid($0, limit: 100) }) else {
                        throw PerchError("问题需要 label（最多 160 字）和 options（0–5 个不同的选项，每项最多 100 字）。")
                    }
                    return AIClarification.Question(label: label, options: options)
                }
                guard Set(values.map(\.label)).count == values.count else { throw PerchError("问题不能重复。") }
                message.clarification = AIClarification(questions: values)
                message.followups = nil
                return #"{"status":"awaiting_user","message":"问题已展示；用户尚未回答，请等待下一条用户消息。"}"#
            }
            guard Set(input.keys) == ["suggestions"], let values = input["suggestions"] as? [String],
                  (1...3).contains(values.count), Set(values).count == values.count,
                  values.allSatisfy({ valid($0, limit: 160) }), message.clarification == nil else {
                throw PerchError("suggestions 需要 1–3 条不同的非空短问题（每条最多 160 字），不能与澄清卡同时提供。")
            }
            message.followups = values
            return #"{"status":"ready","message":"后续问题已展示，不代表用户已发送或授权执行。"}"#
        } catch {
            return String(decoding: try JSONSerialization.data(withJSONObject: [
                "error": (error as? PerchError)?.message ?? "参数无效，请使用完整 JSON。"
            ]), as: UTF8.self)
        }
    }
}

struct AIFollowupSuggestion: View {
    @ObservedObject private var theme = PerchTheme.shared
    let text: String
    let send: () -> Void
    let addToConversation: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button(action: send) {
                HStack(spacing: 8) {
                    Text(text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.gray)
                }.padding(.vertical, 7).padding(.leading, 9)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("直接发送")
                .accessibilityLabel("直接发送：\(text)")
            Button(action: addToConversation) {
                Image(systemName: "ellipsis.bubble")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.gray).frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("添加到对话")
                .accessibilityLabel("添加到对话：\(text)")
                .padding(.trailing, 7)
        }
        .font(.system(size: theme.chatDetailFontSize)).foregroundStyle(Style.accent)
        .background(Style.mint, in: RoundedRectangle(cornerRadius: 8))
        .arrowCursor()
    }
}

struct AIClarificationCard: View {
    @ObservedObject private var theme = PerchTheme.shared
    let clarification: AIClarification
    let enabled: Bool
    let submit: ([String]) -> Void
    @State private var values = ["", "", ""]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(clarification.questions.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Text(clarification.questions[index].label).font(.system(size: theme.chatDetailFontSize, weight: .medium))
                    if let answers = clarification.answers, answers.indices.contains(index) {
                        Text(answers[index]).font(.system(size: theme.chatFontSize)).textSelection(.enabled)
                    } else {
                        ForEach(clarification.questions[index].options, id: \.self) { option in
                            Button { values[index] = option } label: {
                                Label(option, systemImage: values[index] == option ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: theme.chatDetailFontSize)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).foregroundStyle(values[index] == option ? Style.accent : Style.ink)
                        }
                        TextField("选择上方选项，或输入你的回答", text: $values[index]).textFieldStyle(.roundedBorder)
                            .font(.system(size: theme.chatFontSize))
                    }
                }
            }
            if clarification.answers == nil {
                Button("提交并继续") { submit(Array(values.prefix(clarification.questions.count))) }
                    .disabled(!enabled || clarification.response(Array(values.prefix(clarification.questions.count))) == nil)
            } else { Text("已提交").font(.system(size: theme.chatFontSize(relativeTo: 10))).foregroundStyle(Style.muted) }
        }.padding(10).background(Style.mint, in: RoundedRectangle(cornerRadius: 8))
            .disabled(!enabled && clarification.answers == nil)
    }
}

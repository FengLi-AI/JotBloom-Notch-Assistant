import Foundation

/// Deterministic protocol handling. No task-model output enters an approval response.
public enum AgentApprovalPolicy {
    public static func question(method: String, params: ToolValue, id: ToolValue, detail: String = "") -> AssistantRuntimeQuestion? {
        var text: String, session = false, questions: [AgentInputQuestion] = []
        switch method {
        case "item/commandExecution/requestApproval":
            text = commandExplanation(params); session = params["networkApprovalContext"] == .null
        case "item/fileChange/requestApproval":
            let item = (try? JSONDecoder().decode(ToolValue.self, from: Data(detail.utf8))) ?? .null
            let changes = params["changes"].array + item["changes"].array
            let paths = Array(Set(changes.compactMap { $0["path"].text }.filter { !$0.isEmpty })).sorted()
            text = paths.isEmpty ? "Codex 想修改文件。" : "Codex 想修改" + paths.prefix(3).map { "《" + displayName($0) + "》" }.joined(separator: "、") + (paths.count > 3 ? "等 \(paths.count) 个文件。" : "。")
            session = true
        case "item/permissions/requestApproval":
            text = params["permissions"]["fileSystem"] != .null ? "Codex 申请额外的文件访问权限。请核对访问路径。" : "Codex 申请这一轮任务的联网权限。"
        case "item/tool/requestUserInput":
            questions = params["questions"].array.compactMap { value in
                guard let id = value["id"].text, let question = value["question"].text, !value["isSecret"].bool else { return nil }
                return .init(id: id, text: question, options: value["options"].array.compactMap { $0["label"].text })
            }
            guard !questions.isEmpty, questions.count == params["questions"].array.count else { return nil }
            text = "Codex 有问题需要你确认。涉及权限的回答只由你决定。"
        case "mcpServer/elicitation/request":
            guard params["mode"].text == "form", params["requestedSchema"]["type"].text == "object" else { return nil }
            let properties = params["requestedSchema"]["properties"].object
            guard !properties.isEmpty, properties.count <= 8, properties.values.allSatisfy({ $0["type"].text == "string" && $0["format"] == .null && $0["items"] == .null }) else { return nil }
            questions = properties.sorted(by: { $0.key < $1.key }).map { .init(id: $0.key, text: $0.value["title"].text ?? $0.key, options: $0.value["enum"].strings ?? []) }
            text = params["message"].text ?? "Codex 连接的工具需要你确认。"
        default: return nil
        }
        if let reason = params["reason"].text, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n原因：" + String(reason.prefix(2000))
        }
        let raw = [params["reason"].text, params["command"].text, params["cwd"].text, params["grantRoot"].text, params["permissions"] == .null ? nil : params["permissions"].json, params["networkApprovalContext"] == .null ? nil : params["networkApprovalContext"].json, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: "\n")
        var question = AssistantRuntimeQuestion(kind: questions.isEmpty ? "approval" : "agentQuestion", text: text)
        let retainedKeys: Set<String> = ["permissions", "questions", "requestedSchema", "mode"]
        // Never persist environment variables, account metadata or suggested global rules.
        let retained = ToolValue.object(params.object.filter { retainedKeys.contains($0.key) })
        question.agent = .init(requestID: id, method: method, parameters: retained, detail: String(raw.prefix(16000)), allowsSession: session, questions: questions)
        return question
    }
    private static func displayText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(120))
    }
    private static func displayName(_ path: String) -> String { displayText(URL(fileURLWithPath: path).lastPathComponent) }
    private static func commandExplanation(_ params: ToolValue) -> String {
        var parts: [String] = []
        if params["networkApprovalContext"] != .null {
            let host = params["networkApprovalContext"]["host"].text.map(displayText) ?? ""
            parts.append(host.isEmpty ? "访问网络" : "访问 " + host)
        }
        let actions = params["commandActions"].array
        let reads = actions.filter { $0["type"].text == "read" }
        if !reads.isEmpty {
            let paths = Set(reads.compactMap { $0["path"].text }.filter { !$0.isEmpty })
            if paths.count == 1, reads.allSatisfy({ $0["path"].text?.isEmpty == false }) {
                parts.append("读取《" + displayName(paths.first!) + "》")
            } else if paths.count > 1, reads.allSatisfy({ $0["path"].text?.isEmpty == false }) { parts.append("读取 \(paths.count) 个文件") }
            else { parts.append("读取文件") }
        }
        for action in actions where action["type"].text == "listFiles" {
            let path = action["path"].text
            parts.append(path?.isEmpty == false ? "查看《\(displayName(path!))》中的文件列表" : "查看文件列表")
        }
        for action in actions where action["type"].text == "search" {
            var phrase = "搜索文件内容"
            if let query = action["query"].text, !query.isEmpty { phrase += "“" + displayText(query) + "”" }
            if let path = action["path"].text, !path.isEmpty { phrase += "（在《" + displayName(path) + "》中）" }
            parts.append(phrase)
        }
        if actions.contains(where: { !["read", "listFiles", "search"].contains($0["type"].text ?? "") }) {
            parts.append("运行无法识别具体用途的命令")
        }
        if parts.isEmpty { return "Codex 想运行一个命令。请在查看详情中核对。" }
        var unique: [String] = []; for part in parts where !unique.contains(part) { unique.append(part) }
        let suffix = unique.count > 5 ? "；还有其他操作，请查看详情" : ""
        return "Codex 想" + unique.prefix(5).joined(separator: "；") + suffix + "。"
    }
    public static func automaticNetwork(method: String, params: ToolValue, scope: TaskScope) -> ToolValue? {
        guard scope.permissionMode != AssistantPermissionMode.askAlways.rawValue, scope.allowNetwork,
              method == "item/permissions/requestApproval", params["permissions"]["network"]["enabled"].bool,
              params["permissions"]["fileSystem"] == .null,
              Set(params["permissions"].object.keys).isSubset(of: ["network"]) else { return nil }
        return .object(["permissions": .object(["network": .object(["enabled": .bool(true)])]), "scope": .string("turn")])
    }
    public static func response(_ question: AssistantRuntimeQuestion, decision: AgentUserDecision, answers: [String: String]) throws -> ToolValue {
        guard let agent = question.agent else { throw AssistantError.stale }
        if decision == .session && !agent.allowsSession { throw AssistantError.invalidTransition }
        switch agent.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            guard decision != .answer else { throw AssistantError.invalidTransition }
            return .object(["decision": .string(decision == .once ? "accept" : decision == .session ? "acceptForSession" : "decline")])
        case "item/permissions/requestApproval":
            return .object(["permissions": decision == .once ? agent.parameters["permissions"] : .object([:]), "scope": .string("turn")])
        case "item/tool/requestUserInput":
            let values = try answerValues(agent, decision: decision, answers: answers)
            return .object(["answers": .object(values.mapValues { .object(["answers": .array([.string($0)])]) })])
        case "mcpServer/elicitation/request":
            if decision == .decline { return .object(["action": .string("decline"), "content": .null]) }
            return .object(["action": .string("accept"), "content": .object(try answerValues(agent, decision: decision, answers: answers).mapValues(ToolValue.string))])
        default: throw AssistantError.invalidTransition
        }
    }
    private static func answerValues(_ agent: AgentApproval, decision: AgentUserDecision, answers: [String: String]) throws -> [String: String] {
        if decision == .decline { return Dictionary(uniqueKeysWithValues: agent.questions.map { ($0.id, "用户拒绝；不要执行需要许可的操作。") }) }
        guard decision == .answer, agent.questions.allSatisfy({ !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw AssistantError.empty }
        return Dictionary(uniqueKeysWithValues: agent.questions.map { ($0.id, String(answers[$0.id, default: ""].prefix(8000))) })
    }
}

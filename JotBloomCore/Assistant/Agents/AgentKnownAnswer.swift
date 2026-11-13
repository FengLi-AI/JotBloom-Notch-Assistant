import Foundation

/// Only ordinary task questions can use quoted, user-confirmed facts. Approval
/// requests and external tool forms never enter this policy or its model context.
public enum AgentKnownAnswer {
    /// Conservative fallback for plain-text questions when a model omits its
    /// answer flag. Structured requestUserInput is handled independently.
    public static func containsQuestion(_ text: String) -> Bool {
        if text.contains("？") || text.contains("?") { return true }
        return ["请确认", "请提供", "请补充", "请告诉", "请选择", "想确认", "需要你提供", "需要您提供", "please confirm", "please clarify", "please provide", "please choose"].contains { text.localizedCaseInsensitiveContains($0) }
    }
    public static func sources(scope: TaskScope, plan: AssistantPlan?, state: AssistantExecutionState) -> [String: String] {
        var result = ["goal": scope.goal, "doneCriteria": scope.doneCriteria, "outputDirectory": scope.outputDirectory]
        if let work = scope.workingDirectory { result["workingDirectory"] = work }
        for (index, answer) in (scope.confirmedAnswers ?? []).enumerated() { result["answer.\(index)"] = answer }
        for (index, text) in state.supplements.enumerated() { result["supplement.\(index)"] = text }
        if let plan {
            result["title"] = plan.brief.title
            if let due = plan.dueAt { result["deadline"] = AssistantDates.text(due) }
            for (index, time) in plan.reminders.enumerated() { result["reminder.\(index)"] = AssistantDates.text(time) }
            for (index, text) in plan.brief.assumptions.enumerated() { result["assumption.\(index)"] = text }
            for (index, text) in plan.brief.approach.enumerated() { result["approach.\(index)"] = text }
        }
        return result
    }
    public static func needsUser(_ text: String, scope: TaskScope) -> Bool {
        if scope.permissionMode == AssistantPermissionMode.askAlways.rawValue { return true }
        let sensitive = ["费用", "付费", "支付", "付款", "花费", "购买", "订阅", "预算", "扣费", "充值", "余额", "发布", "上线", "部署", "推送", "账号", "帐号", "账户", "登录", "登陆", "密码", "密钥", "授权", "权限", "批准", "允许", "同意", "发送给", "对外", "cost", "payment", "pay", "price", "billing", "purchase", "subscribe", "budget", "publish", "release", "deploy", "push", "account", "login", "log in", "password", "credential", "api key", "permission", "approve", "authorize", "consent", "$", "¥"]
        return sensitive.contains { text.localizedCaseInsensitiveContains($0) }
    }
    public static func answers(_ action: AssistantStepAction, questions: [AgentInputQuestion], scope: TaskScope, plan: AssistantPlan?, state: AssistantExecutionState) -> [String: String]? {
        guard action.tool == .continueCodex, action.args["answersCodexQuestion"] == .bool(true),
              !questions.isEmpty, questions.allSatisfy({ !needsUser($0.text, scope: scope) }),
              let entries = action.args["answerEvidence"], entries.array.count == questions.count else { return nil }
        let facts = sources(scope: scope, plan: plan, state: state)
        var result: [String: String] = [:]
        for item in entries.array {
            guard let id = item["questionID"].text, questions.contains(where: { $0.id == id }), result[id] == nil,
                  let source = item["sourceID"].text, let fact = facts[source], let quote = item["quote"].text,
                  !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, quote.count <= 2000,
                  fact.contains(quote), !needsUser(quote, scope: scope) else { return nil }
            // Send the checked quote, never free-form model instructions that could
            // append an invented answer or an authorization to an otherwise valid quote.
            result[id] = quote
        }
        return result.count == questions.count ? result : nil
    }
    public static func record(_ answers: [String: String]) -> String {
        "已依据确认内容回答 Codex：" + answers.sorted { $0.key < $1.key }.map { $0.value }.joined(separator: "；")
    }
}

import Combine
import Foundation

@MainActor
public final class AssistantViewModel: ObservableObject {
    public var onSystemInteraction: ((Bool) -> Void)?
    public var onExternalHandoff: (() -> Void)?
    public let coordinator: AssistantCoordinator
    @Published public private(set) var materials: [AssistantAttachment] = []
    @Published public private(set) var events: [AssistantTaskEvent] = []
    @Published public private(set) var savingTurns: Set<String> = []
    @Published public var feedback: String?
    private var detailID: String?
    private var observation: AnyCancellable?
    public init(coordinator: AssistantCoordinator) {
        self.coordinator = coordinator
        observation = coordinator.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    public var tasks: [AssistantTask] { coordinator.tasks }
    public var links: [String: AssistantTaskLink] { coordinator.links }
    public func task(_ id: String) -> AssistantTask? { tasks.first { $0.id == id } }
    public func convert(_ turn: ChatTurn) {
        guard !savingTurns.contains(turn.token), links[turn.token] == nil else { return }
        savingTurns.insert(turn.token)
        Task {
            defer { savingTurns.remove(turn.token) }
            do { try await coordinator.receive(input: turn.user, source: .chat, turn: turn); feedback = nil }
            catch { feedback = "没能保存任务，请重试。原对话仍保留。" }
        }
    }
    public func loadDetail(_ id: String) async {
        detailID = id; materials = []; events = []
        do {
            let result = try await coordinator.detail(id: id)
            guard detailID == id else { return }
            materials = result.materials; events = result.events
        } catch { feedback = "任务详情读取失败，请重试。" }
    }
    public func cancel(_ id: String) async -> Bool {
        do { try await coordinator.cancel(id: id); return true }
        catch { feedback = error.localizedDescription; return false }
    }
    public func delete(_ id: String) async -> Bool {
        do { try await coordinator.delete(id: id); return true }
        catch { feedback = error.localizedDescription; return false }
    }
}

import JotBloomCore

@MainActor
final class ClipboardCaptureCoordinator {
    private let service: ClipboardService
    private weak var viewModel: ClipboardHistoryViewModel?
    private var pendingTask: Task<Void, Never>?
    private var acceptsSnapshots = true
    private var generation = 0

    init(
        service: ClipboardService,
        viewModel: ClipboardHistoryViewModel
    ) {
        self.service = service
        self.viewModel = viewModel
    }

    func enqueue(_ snapshot: ClipboardSnapshot) {
        guard acceptsSnapshots else { return }
        let previousTask = pendingTask
        let service = service
        let viewModel = viewModel
        let expected = generation
        pendingTask = Task { [weak self, weak viewModel] in
            await previousTask?.value
            guard let self, expected == generation, acceptsSnapshots, !Task.isCancelled else { return }
            do {
                let outcome = try await service.capture(snapshot)
                viewModel?.handleCaptureOutcome(outcome)
            } catch {
                viewModel?.handleCaptureFailure(error)
            }
        }
    }

    func stopAndDrain() async {
        acceptsSnapshots = false
        generation += 1
        let task = pendingTask
        await task?.value
        pendingTask = nil
    }

    func resume() {
        acceptsSnapshots = true
    }
}

import AppKit
import Carbon.HIToolbox
import JotBloomCore
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.jotbloom.mengsheng", category: "lifecycle")

    private var store: JotBloomStore?
    private var inspirationViewModel: InspirationInputViewModel?
    private var inspirationLibraryViewModel: InspirationLibraryViewModel?
    private var clipboardService: ClipboardService?
    private var clipboardViewModel: ClipboardHistoryViewModel?
    private var globalSearchViewModel: GlobalSearchViewModel?
    private var promptViewModel: PromptLibraryViewModel?
    private var chatViewModel: ChatViewModel?
    private var promptTitles: PromptTitleCoordinator?
    private var pasteboardMonitor: PasteboardMonitor?
    private var pasteboardClient: SystemPasteboardClient?
    private var clipboardCaptureCoordinator: ClipboardCaptureCoordinator?
    private var panelController: PanelController?
    private var panelCoordinator: PanelVisibilityCoordinator?
    private var hotKeyManager: HotKeyManager?
    private var hotZoneController: HotZoneWindowController?
    private var menuBarController: MenuBarController?
    private var terminationRetryScheduled = false
    private var clipboardTerminationPrepared = false
    private var inspirationLibraryTerminationPrepared = false
    private var settingsModel: SettingsViewModel?
    private let capturePermission = CapturePermission()
    private var settingsSuite: String?
    private lazy var settingsDefaults: UserDefaults = {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env.keys.contains(where: { $0.hasPrefix("JOTBLOOM_STAGE") && $0.hasSuffix("_SMOKE") }) || env["JOTBLOOM_DEBUG_DATA_DIRECTORY"] != nil {
            let suite = "JotBloom.Settings.Debug." + UUID().uuidString
            settingsSuite = suite
            return UserDefaults(suiteName: suite)!
        }
#endif
        return .standard
    }()
    private var settingsAreIsolated: Bool { _ = settingsDefaults; return settingsSuite != nil }
    private var locationStore: DataLocationStore {
        get throws {
#if DEBUG
            if let path = ProcessInfo.processInfo.environment["JOTBLOOM_DEBUG_DATA_DIRECTORY"], !path.isEmpty {
                return DataLocationStore(controlDirectory: try DataDirectoryResolver.validatedDebugDirectory(path: path))
            }
#endif
            return DataLocationStore(controlDirectory: try DataDirectoryResolver.productionDirectory())
        }
    }

#if DEBUG
    private var ephemeralDataDirectory: URL?
    private var stageThreeSmokeRunner: StageThreeSmokeRunner?
    private var stageFourSmokeRunner: StageFourSmokeRunner?
    private var stageFiveSmokeRunner: StageFiveSmokeRunner?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE10B_SMOKE"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await StageTenOperationsSmokeRunner.run() }
            return
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE10A_SMOKE"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await StageTenAuthorizationSmokeRunner.run() }
            return
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE9_SMOKE"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await StageNineSmokeRunner.run() }
            return
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE8_SMOKE"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await StageEightSmokeRunner.run() }
            return
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE7_SMOKE"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await StageSevenSmokeRunner.run() }
            return
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE6_SMOKE"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in await StageSixSmokeRunner.run() }
            return
        }
        if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE1_SMOKE"] == "1" {
            print("JOTBLOOM_STAGE1_SMOKE did_finish_launching=true")
        }
#endif
        NSApp.setActivationPolicy(.accessory)

        let appSettings = AppSettingsStore(defaults: settingsDefaults).load()
        capturePermission.setAllowed(appSettings.monitoringEnabled)

        let dataDirectory: URL
        let store: JotBloomStore
        let storageStartedAt = ProcessInfo.processInfo.systemUptime
#if DEBUG
        var stageTwoSmokeResult: StageTwoPersistenceSmokeResult?
        var stageThreeSmokeBootstrap: StageThreeSmokeBootstrap?
        var stageFourSmokeBootstrap: StageFourSmokeBootstrap?
        var stageFiveSmokeBootstrap: StageFiveSmokeBootstrap?
#endif

        do {
#if DEBUG
            dataDirectory = try resolveDataDirectory()
#else
            dataDirectory = try locationStore.activeDirectory()
#endif
#if DEBUG
            if isStageThreeSmoke {
                stageThreeSmokeBootstrap = try prepareStageThreeSmokeBootstrap(
                    dataDirectory: dataDirectory
                )
            }
            if isStageTwoSmoke {
                let result = try prepareStageTwoPersistenceSmoke(
                    dataDirectory: dataDirectory
                )
                store = result.store
                stageTwoSmokeResult = result
            } else {
                let isSmoke = isStageOneSmoke || isStageThreeSmoke || isStageFourSmoke || isStageFiveSmoke
                store = try JotBloomStore(dataDirectoryURL: dataDirectory, requireExisting: isSmoke ? false : try locationStore.record() != nil)
            }
            if isStageFourSmoke {
                stageFourSmokeBootstrap = try prepareStageFourSmokeBootstrap(
                    dataDirectory: dataDirectory,
                    store: store
                )
            }
            if isStageFiveSmoke {
                stageFiveSmokeBootstrap = try prepareStageFiveSmokeBootstrap(
                    dataDirectory: dataDirectory,
                    store: store
                )
            }
#else
            store = try JotBloomStore(dataDirectoryURL: dataDirectory, requireExisting: try locationStore.record() != nil)
#endif
        } catch {
            logPersistenceFailure(
                error,
                operation: "bootstrap",
                startedAt: storageStartedAt
            )
            presentStartupStorageError(error)
            return
        }

        let inspirationViewModel = InspirationInputViewModel(store: store)
        inspirationViewModel.start()
        let inspirationLibraryViewModel = InspirationLibraryViewModel(store: store)
        inspirationLibraryViewModel.start()

        let assetStore: ClipboardAssetStore
        do {
            assetStore = try ClipboardAssetStore(
                dataDirectoryURL: dataDirectory
            )
        } catch {
            logPersistenceFailure(
                error,
                operation: "bootstrap_clipboard_assets",
                startedAt: storageStartedAt
            )
            store.close()
            presentStartupStorageError(error)
            return
        }

#if DEBUG
        let isolatedSmokePasteboard = (
            isStageThreeSmoke || isStageFourSmoke || isStageFiveSmoke || settingsAreIsolated
        )
            ? NSPasteboard(
                name: NSPasteboard.Name(
                    "com.jotbloom.mengsheng.stage-smoke.\(UUID().uuidString)"
                )
            )
            : nil
        if let isolatedSmokePasteboard {
            isolatedSmokePasteboard.clearContents()
            if isStageThreeSmoke {
                _ = isolatedSmokePasteboard.setString(
                    "stage-three-prelaunch-value",
                    forType: .string
                )
            }
        }
        let pasteboardClient = SystemPasteboardClient(
            pasteboard: isolatedSmokePasteboard ?? .general
        )
#else
        let pasteboardClient = SystemPasteboardClient()
#endif
#if DEBUG
        let clipboardRetentionPolicy = isStageThreeSmoke
            ? ClipboardRetentionPolicy(
                maximumCount: 2,
                maximumAgeMilliseconds: nil,
                maximumBytes: 10_000_000
            )
            : appSettings.retentionPolicy
#else
        let clipboardRetentionPolicy = appSettings.retentionPolicy
#endif
        let clipboardService = ClipboardService(
            store: store,
            assetStore: assetStore,
            retentionPolicy: clipboardRetentionPolicy,
            capturePermission: capturePermission
        )
        let clipboardViewModel = ClipboardHistoryViewModel(
            service: clipboardService,
            pasteboardWriter: pasteboardClient
        )
        clipboardViewModel.start()
        let globalSearchViewModel = GlobalSearchViewModel(
            store: store,
            pasteboardWriter: pasteboardClient
        )
        let clipboardCaptureCoordinator = ClipboardCaptureCoordinator(
            service: clipboardService,
            viewModel: clipboardViewModel
        )

        let credentialStorage: any CredentialStoring = settingsAreIsolated ? MemoryCredentialStore() : KeychainCredentialStore()
        let credentials: any CredentialStoring = CoordinatedCredentialStore(base: credentialStorage)
        let settingsModel = SettingsViewModel(
            persistence: AppSettingsStore(defaults: settingsDefaults),
            credentials: credentials,
            login: settingsAreIsolated ? IsolatedLoginItemService() : LoginItemService(),
            dataDirectory: dataDirectory
        )
        let promptModel = PromptLibraryViewModel(store: store, writer: pasteboardClient)
        let chatModel = ChatViewModel(store: store, credentials: credentials, configuration: { [weak settingsModel] in
            settingsModel?.value.main ?? ModelConfiguration()
        }, defaultSystemPrompt: { [weak settingsModel] in settingsModel?.value.chatSystemPrompt ?? ChatContext.system })
        self.chatViewModel = chatModel
        Task { await chatModel.start() }
        settingsModel.onMainAIConfigurationChanged = { [weak chatModel] in chatModel?.configurationChanged() }
        let titles = PromptTitleCoordinator(store: store, credentials: credentials, settings: { [weak settingsModel] in settingsModel?.value ?? AppSettings() })
        titles.additionalJob = { [weak store, weak settingsModel, weak inspirationViewModel, weak inspirationLibraryViewModel, weak globalSearchViewModel, weak promptModel] id in
            guard let store, let settingsModel, settingsModel.value.inspirationAIEnabled else { return }
            let config = settingsModel.value.resolvedConfiguration(for: .auxiliary)
            do {
                let snapshot = try await store.inspirationAISnapshot(id)
                try Task.checkCancellation()
                guard let key = try await credentials.readWithoutInteraction(config.credentialSlot) else { throw SettingsError.missingKey }
                try Task.checkCancellation()
                let result = try await InspirationAIService().generate(content: snapshot.content, configuration: config.configuration, key: key)
                try Task.checkCancellation()
                let current = settingsModel.value.resolvedConfiguration(for: .auxiliary)
                guard settingsModel.value.inspirationAIEnabled, current.configuration == config.configuration, current.credentialSlot == config.credentialSlot else { return }
                if try store.applyInspirationAISynchronously(result, expected: snapshot) {
                    inspirationViewModel?.refreshRecentInspirations()
                    await inspirationLibraryViewModel?.refreshAfterAI(id: id)
                    try Task.checkCancellation()
                    globalSearchViewModel?.refresh()
                    if result.title == nil || result.category == nil {
                        inspirationLibraryViewModel?.showAIStatus("原文已保存，AI 部分字段未生成，可在详情重试。")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = "原文已保存，AI 整理未完成：" + ChatViewModel.message(error) + " 如需授权，请到 AI 接口测试对应模型后重试。"
                inspirationViewModel?.showAIStatus(message)
                inspirationLibraryViewModel?.showAIStatus(message)
                promptModel?.feedback = message
            }
        }
        let inspirationCreated: (Int64) -> Void = { [weak titles, weak settingsModel, weak inspirationLibraryViewModel, weak globalSearchViewModel] id in
            if inspirationLibraryViewModel?.screen == .list { inspirationLibraryViewModel?.activate() }
            globalSearchViewModel?.refresh()
            if settingsModel?.value.inspirationAIEnabled == true, titles?.enqueueInspiration(id) == false {
                inspirationLibraryViewModel?.showAIStatus("原文已保存，AI 排队已满，可稍后在详情重试。")
            }
        }
        inspirationViewModel.onInspirationCreated = inspirationCreated
        promptModel.onInspirationCreated = inspirationCreated
        chatModel.onSummaryCreated = { [weak inspirationViewModel] id in inspirationViewModel?.refreshRecentInspirations(); inspirationCreated(id) }
        inspirationLibraryViewModel.onRequestEnrichment = inspirationCreated
        inspirationLibraryViewModel.enrichmentEnabled = { [weak settingsModel] in settingsModel?.value.inspirationAIEnabled == true }
        promptModel.onChange = { [weak clipboardViewModel, weak inspirationViewModel, weak globalSearchViewModel] in
            clipboardViewModel?.refreshAfterMaintenance()
            inspirationViewModel?.refreshRecentInspirations()
            globalSearchViewModel?.refresh()
        }
        titles.onChange = { [weak promptModel, weak globalSearchViewModel] in promptModel?.refresh(); globalSearchViewModel?.refresh() }
        titles.onFailure = { [weak promptModel] _, reason in
            let detail: String
            switch reason {
            case .credentialDenied, .credentialLocked, .credentialCancelled, .credentialUnavailable:
                detail = "请先在设置 → AI 接口测试标题使用的模型并完成授权，再保存新提示词。辅助模型独立配置时需测试辅助模型。"
            default:
                detail = reason.errorDescription ?? "请检查模型配置。"
            }
            promptModel?.feedback = "原文已保存，AI 标题未生成：" + detail
        }
        settingsModel.onAIConfigurationChanged = { [weak titles] in titles?.invalidate() }
        inspirationViewModel.savePrompt = { [weak store] content, token, timestamp in
            guard let store else { throw PersistenceError.databaseClosed }
            return try await store.saveInputPrompt(content: content, token: token, timestamp: timestamp)
        }
        let created: (Int64) -> Void = { [weak promptModel, weak titles, weak globalSearchViewModel] id in
            promptModel?.refresh(); titles?.enqueue(id); globalSearchViewModel?.refresh()
        }
        inspirationViewModel.onPromptCreated = created; promptModel.onPromptCreated = created
        self.promptViewModel = promptModel; self.promptTitles = titles
        let panelController = PanelController(
            inspirationViewModel: inspirationViewModel,
            clipboardViewModel: clipboardViewModel,
            inspirationLibraryViewModel: inspirationLibraryViewModel,
            globalSearchViewModel: globalSearchViewModel,
            dataDirectory: dataDirectory,
            settingsModel: settingsModel,
            promptModel: promptModel,
            chatModel: chatModel
        )
        inspirationViewModel.sendToChat = { [weak chatModel, weak panelController] text in
            guard let chatModel, panelController?.showChat() == true else { throw ChatError.busy }
            try await chatModel.sendFromInspiration(text)
        }
        panelController.onChatCopy = { [weak pasteboardClient, weak pasteboardMonitor, weak chatModel] text in
            do {
                guard let count = try pasteboardClient?.writeText(text) else { throw ClipboardWriteError.writeFailed }
                pasteboardMonitor?.advanceBaseline(to: count)
                chatModel?.feedback = "已复制完整回答，面板保留。"
                return true
            } catch { chatModel?.feedback = "复制未成功，请重试。"; return false }
        }
        let applicationProvider = WorkspaceFrontmostApplicationProvider()
        let coordinator = PanelVisibilityCoordinator(
            panel: panelController,
            frontmostApplicationProvider: applicationProvider,
            ownBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.jotbloom.mengsheng"
        )

        panelController.onRequestHide = { [weak coordinator] in
            coordinator?.hide()
        }
        clipboardViewModel.onRequestCollapse = { [weak coordinator] in
            coordinator?.hide()
        }
        promptModel.onRequestCollapse = { [weak coordinator] in coordinator?.hide() }
        promptModel.onPasteboardWritten = { [weak pasteboardMonitor] count in pasteboardMonitor?.advanceBaseline(to: count) }
        #if DEBUG
        let restoreFocusAfterSearchCopy = !isStageFiveSmoke
        #endif
        globalSearchViewModel.onRequestCollapse = { [weak coordinator] in
#if DEBUG
            coordinator?.hide(restoreFocus: restoreFocusAfterSearchCopy)
#else
            coordinator?.hide()
#endif
        }

        let clipboardSourceProvider = ClipboardSourceApplicationProvider(
            isJotBloomPanelKey: { [weak panelController] in
                panelController?.isPanelKeyWindow == true
            }
        )
        let pasteboardMonitor = PasteboardMonitor(
            pasteboard: pasteboardClient,
            sourceProvider: clipboardSourceProvider.currentSource,
            onSnapshot: { [weak clipboardCaptureCoordinator] snapshot in
                clipboardCaptureCoordinator?.enqueue(snapshot)
            }
        )
        clipboardViewModel.onPasteboardWritten = { [weak pasteboardMonitor] changeCount in
            pasteboardMonitor?.advanceBaseline(to: changeCount)
        }
        globalSearchViewModel.onPasteboardWritten = { [weak pasteboardMonitor] changeCount in
            pasteboardMonitor?.advanceBaseline(to: changeCount)
        }

        let hotZoneController = HotZoneWindowController { [weak coordinator, weak settingsModel] in
            guard settingsModel?.blocksPanelInteraction != true else { return }
            coordinator?.toggle()
        }
        coordinator.onVisibilityChanged = { [weak hotZoneController, weak pasteboardMonitor] isVisible in
            hotZoneController?.setPanelVisible(isVisible)
            pasteboardMonitor?.setPanelVisible(isVisible)
        }

        let hotKeyManager = HotKeyManager { [weak coordinator, weak settingsModel] in
            guard settingsModel?.blocksPanelInteraction != true else { return }
            if let settingsModel, settingsModel.recordingShortcut {
                settingsModel.setShortcut(settingsModel.value.shortcut)
                return
            }
            coordinator?.toggle()
        }
        var registeredShortcut = appSettings.shortcut
#if DEBUG
        if isStageOneSmoke || isStageTwoSmoke || isStageThreeSmoke || isStageFourSmoke || isStageFiveSmoke || settingsAreIsolated {
            // Do not take the user's everyday Option-Space during legacy lifecycle probes.
            registeredShortcut = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey), label: "⌃⌥⇧F19")
        }
#endif
        let hotKeyStatus = hotKeyManager.register(registeredShortcut)
        if hotKeyStatus != noErr {
            logger.error("Default hot key registration failed with status: \(hotKeyStatus, privacy: .public)")
        }

        let menuBarController = MenuBarController(
            onToggle: { [weak coordinator, weak settingsModel] in if settingsModel?.blocksPanelInteraction != true { coordinator?.toggle() } },
            onShow: { [weak coordinator, weak settingsModel] in
                guard settingsModel?.blocksPanelInteraction != true else { return }
                coordinator?.show()
            },
            onSettings: { [weak coordinator, weak panelController, weak settingsModel] in
                guard settingsModel?.blocksPanelInteraction != true else { return }
                coordinator?.show()
                panelController?.openSettings()
            },
            onQuit: { NSApp.terminate(nil) }
        )

        self.store = store
        self.inspirationViewModel = inspirationViewModel
        self.inspirationLibraryViewModel = inspirationLibraryViewModel
        self.clipboardService = clipboardService
        self.clipboardViewModel = clipboardViewModel
        self.globalSearchViewModel = globalSearchViewModel
        self.pasteboardMonitor = pasteboardMonitor
        self.pasteboardClient = pasteboardClient
        self.clipboardCaptureCoordinator = clipboardCaptureCoordinator
        self.panelController = panelController
        self.panelCoordinator = coordinator
        self.hotKeyManager = hotKeyManager
        self.hotZoneController = hotZoneController
        self.menuBarController = menuBarController
        self.settingsModel = settingsModel
        configureSettings(settingsModel)
        if !hotKeyManager.isRegistered {
            settingsModel.restoreMenuPreference()
            settingsModel.feedback = "唤起快捷键注册失败，已恢复菜单栏入口。请在通用设置重新录制。"
        }
        menuBarController.setVisible(settingsModel.value.showMenuBarIcon)

#if DEBUG
        if ProcessInfo.processInfo.environment["JOTBLOOM_UI_WALKTHROUGH"] != "1" { hotZoneController.start() }
#else
        hotZoneController.start()
#endif
        pasteboardMonitor.setUserEnabled(appSettings.monitoringEnabled)
        pasteboardMonitor.start()
        if !settingsAreIsolated, !appSettings.onboardingSeen {
            let hasData = (try? store.listRecentInspirationsSynchronously().isEmpty) == false
                || (try? store.listClipboardItemsSynchronously().isEmpty) == false
                || (try? store.loadDraftSynchronously(kind: .inspiration)?.content.isEmpty) == false
            if hasData { settingsModel.markExistingUser() }
            else {
                settingsModel.reopenOnboarding()
                coordinator.show(); panelController.openSettings()
            }
        }
        logger.info("JotBloom stage-five global search slice started")

#if DEBUG
        if ProcessInfo.processInfo.environment["JOTBLOOM_UI_WALKTHROUGH"] == "1", settingsAreIsolated {
            panelController.debugSetAutomaticDismissalEnabled(false)
            coordinator.show()
        }
        if let stageFiveSmokeBootstrap,
           let isolatedSmokePasteboard {
            let runner = StageFiveSmokeRunner(
                bootstrap: stageFiveSmokeBootstrap,
                store: store,
                namedPasteboard: isolatedSmokePasteboard,
                inputViewModel: inspirationViewModel,
                libraryViewModel: inspirationLibraryViewModel,
                searchViewModel: globalSearchViewModel,
                pasteboardMonitor: pasteboardMonitor,
                coordinator: coordinator,
                panelController: panelController
            )
            stageFiveSmokeRunner = runner
            runner.run()
        } else if let stageFourSmokeBootstrap,
           let isolatedSmokePasteboard {
            let runner = StageFourSmokeRunner(
                bootstrap: stageFourSmokeBootstrap,
                store: store,
                namedPasteboard: isolatedSmokePasteboard,
                inputViewModel: inspirationViewModel,
                libraryViewModel: inspirationLibraryViewModel,
                coordinator: coordinator,
                panelController: panelController
            )
            stageFourSmokeRunner = runner
            runner.run()
        } else if let stageThreeSmokeBootstrap,
                  let isolatedSmokePasteboard {
            let runner = StageThreeSmokeRunner(
                bootstrap: stageThreeSmokeBootstrap,
                store: store,
                service: clipboardService,
                pasteboard: isolatedSmokePasteboard,
                monitor: pasteboardMonitor,
                viewModel: clipboardViewModel,
                coordinator: coordinator,
                panelController: panelController
            )
            stageThreeSmokeRunner = runner
            runner.run()
        } else if let stageTwoSmokeResult {
            runStageTwoSmoke(
                result: stageTwoSmokeResult,
                coordinator: coordinator,
                panelController: panelController,
                hotKeyManager: hotKeyManager,
                hotZoneController: hotZoneController
            )
        } else if ProcessInfo.processInfo.environment["JOTBLOOM_STAGE1_SMOKE"] == "1" {
            runStageOneSmoke(
                panelController: panelController,
                hotKeyManager: hotKeyManager,
                hotZoneController: hotZoneController
            )
        }
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard settingsModel?.allowLeavingPrompt() != false, chatViewModel?.canLeaveChat() != false else { return .terminateCancel }
        if clipboardViewModel?.isClearing == true { return .terminateCancel }
        guard promptViewModel?.flushEdit() != false else { return .terminateCancel }
        if settingsModel?.busy == true || settingsModel?.choosingDirectory == true { settingsModel?.feedback = "请完成或取消当前设置操作后再退出。"; return .terminateCancel }
        settingsModel?.leaveSettings()
        guard let inspirationViewModel,
              let inspirationLibraryViewModel else {
            return .terminateNow
        }

        if inspirationViewModel.hasPendingSave
            || !clipboardTerminationPrepared
            || !inspirationLibraryTerminationPrepared {
            if !terminationRetryScheduled {
                terminationRetryScheduled = true
                pasteboardMonitor?.stop()
                Task {
                    [weak self,
                     weak inspirationViewModel,
                     weak inspirationLibraryViewModel,
                     weak clipboardViewModel,
                     weak clipboardCaptureCoordinator] in
                    guard let self,
                          let inspirationViewModel,
                          let inspirationLibraryViewModel else {
                        return
                    }
                    guard await chatViewModel?.prepareForMaintenance() != false else {
                        terminationRetryScheduled = false
                        pasteboardMonitor?.start()
                        return
                    }
                    await inspirationViewModel.waitForPendingSave()
                    guard await promptViewModel?.prepareForMaintenance() != false else {
                        terminationRetryScheduled = false
                        pasteboardMonitor?.start()
                        return
                    }
                    await promptTitles?.drain()
                    await clipboardCaptureCoordinator?.stopAndDrain()
                    await clipboardViewModel?.prepareForTermination()
                    clipboardTerminationPrepared = true
                    let libraryPrepared = await inspirationLibraryViewModel
                        .prepareForTermination()
                    if !libraryPrepared,
                       !presentTerminationStorageError(
                           messageText: "灵感修改未能保存",
                           informativeText: "修改内容仍在当前窗口中。建议取消退出，检查磁盘空间后重试。"
                       ) {
                        clipboardTerminationPrepared = false
                        inspirationLibraryTerminationPrepared = false
                        terminationRetryScheduled = false
                        clipboardCaptureCoordinator?.resume()
                        pasteboardMonitor?.start()
                        return
                    }
                    inspirationLibraryTerminationPrepared = true
                    guard terminationRetryScheduled else { return }
                    terminationRetryScheduled = false
                    NSApp.terminate(nil)
                }
            }
            return .terminateCancel
        }

        do {
            try chatViewModel?.flushDraft()
            try inspirationViewModel.flushDraftSynchronously()
            return .terminateNow
        } catch {
            if presentTerminationStorageError(
                messageText: "最新草稿未能保存",
                informativeText: "输入内容仍在当前窗口中。建议取消退出，检查磁盘空间后重试。"
            ) {
                return .terminateNow
            }
            clipboardTerminationPrepared = false
            inspirationLibraryTerminationPrepared = false
            clipboardCaptureCoordinator?.resume()
            pasteboardMonitor?.start()
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pasteboardMonitor?.stop()
        hotKeyManager?.unregister()
        hotZoneController?.stop()
        panelController?.close()
        menuBarController?.invalidate()
        store?.close()
        if let settingsSuite { UserDefaults.standard.removePersistentDomain(forName: settingsSuite) }

#if DEBUG
        removeEphemeralDataDirectoryIfNeeded()
#endif

        logger.info("JotBloom stage-five global search slice stopped")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard settingsModel?.blocksPanelInteraction != true else { return true }
        menuBarController?.setVisible(true)
        settingsModel?.restoreMenuPreference()
        panelCoordinator?.show()
        return true
    }

    private func configureSettings(_ model: SettingsViewModel) {
        model.onSystemInteraction = { [weak self] active in self?.panelController?.setSystemInteraction(active) }
        model.onDirectorySelection = { [weak self] active in self?.panelController?.setDirectorySelection(active) }
        model.onShortcut = { [weak self] in self?.hotKeyManager?.register($0) == noErr }
        model.onMenuVisibility = { [weak self] visible in
            guard let self, visible || hotKeyManager?.isRegistered == true else { return false }
            menuBarController?.setVisible(visible); return true
        }
        model.onMonitoring = { [weak self] enabled in
            guard let self else { throw SettingsError.maintenance }
            capturePermission.setAllowed(false)
            pasteboardMonitor?.setUserEnabled(false)
            await clipboardCaptureCoordinator?.stopAndDrain()
            clipboardCaptureCoordinator?.resume()
            capturePermission.setAllowed(enabled)
            pasteboardMonitor?.setUserEnabled(enabled)
        }
        model.onRetention = { [weak self] policy in
            guard let self, let clipboardService else { throw SettingsError.maintenance }
            await clipboardViewModel?.prepareForTermination()
            defer { clipboardViewModel?.refreshAfterMaintenance(); globalSearchViewModel?.refresh() }
            try await clipboardService.applyRetention(policy, nowUTCms: Int64(Date().timeIntervalSince1970 * 1000))
        }
        model.onUsage = { [weak self] in
            guard let service = self?.clipboardService else { throw SettingsError.maintenance }
            return try await service.usage()
        }
        model.onClearSnapshot = { [weak self] in
            guard let store = self?.store else { throw SettingsError.maintenance }
            return try await store.listClipboardItems()
        }
        model.onClear = { [weak self] snapshot in
            guard let self, let clipboardService else { throw SettingsError.maintenance }
            capturePermission.setAllowed(false); pasteboardMonitor?.setMaintenancePaused(true)
            defer { restoreCaptureAfterMaintenance() }
            await clipboardCaptureCoordinator?.stopAndDrain()
            await clipboardViewModel?.prepareForTermination()
            defer { clipboardViewModel?.refreshAfterMaintenance(); globalSearchViewModel?.refresh() }
            let result = try await clipboardService.clearHistory(snapshot: snapshot)
            return result
        }
        model.onRetryCleanup = { [weak self] in
            guard let service = self?.clipboardService else { throw SettingsError.maintenance }
            try await service.retryOrphanCleanup()
        }
        clipboardViewModel?.onClearHistory = model.onClear
        model.onMigrate = { [weak self] parent, progress in
            guard let self, let store, let input = inspirationViewModel, let library = inspirationLibraryViewModel else { throw SettingsError.maintenance }
            capturePermission.setAllowed(false); pasteboardMonitor?.setMaintenancePaused(true)
            defer { restoreCaptureAfterMaintenance() }
            await clipboardCaptureCoordinator?.stopAndDrain()
            guard await chatViewModel?.prepareForMaintenance() != false else { throw SettingsError.migrationFailed }
            try await input.prepareForTermination()
            guard await promptViewModel?.prepareForMaintenance() != false else { throw SettingsError.migrationFailed }
            await promptTitles?.drain()
            guard await library.prepareForTermination() else { throw SettingsError.migrationFailed }
            await clipboardViewModel?.prepareForTermination()
            globalSearchViewModel?.resetForPanelDismissal()
            let location = try locationStore
            let operation = Task.detached {
                try DataDirectoryMigration().migrate(store: store, parent: parent, location: location, progress: progress)
            }
            let target = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            // Rebuild the single object graph; no old service can write to the old store afterwards.
            hotKeyManager?.unregister(); hotZoneController?.stop(); pasteboardMonitor?.stop()
            panelController?.close(); menuBarController?.invalidate(); store.close()
            clipboardTerminationPrepared = false; inspirationLibraryTerminationPrepared = false; terminationRetryScheduled = false
            applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            panelCoordinator?.show(); panelController?.openSettings()
            settingsModel?.feedback = "已切换保存位置，旧目录保留迁移前副本。"
            return target
        }
    }

    private func restoreCaptureAfterMaintenance() {
        clipboardCaptureCoordinator?.resume()
        capturePermission.setAllowed(settingsModel?.value.monitoringEnabled ?? true)
        pasteboardMonitor?.setMaintenancePaused(false)
    }

#if DEBUG
    private var isStageOneSmoke: Bool {
        ProcessInfo.processInfo.environment["JOTBLOOM_STAGE1_SMOKE"] == "1"
    }

    private var isStageTwoSmoke: Bool {
        ProcessInfo.processInfo.environment["JOTBLOOM_STAGE2_SMOKE"] == "1"
    }

    private var isStageThreeSmoke: Bool {
        ProcessInfo.processInfo.environment["JOTBLOOM_STAGE3_SMOKE"] == "1"
    }

    private var isStageFourSmoke: Bool {
        ProcessInfo.processInfo.environment["JOTBLOOM_STAGE4_SMOKE"] == "1"
    }

    private var isStageFiveSmoke: Bool {
        ProcessInfo.processInfo.environment["JOTBLOOM_STAGE5_SMOKE"] == "1"
    }

    private var stageTwoSmokePanelHold: TimeInterval {
        guard let rawValue = ProcessInfo.processInfo
            .environment["JOTBLOOM_STAGE2_SMOKE_PANEL_HOLD_MS"],
              let milliseconds = Double(rawValue),
              (50...10_000).contains(milliseconds) else {
            return 0.05
        }
        return milliseconds / 1_000
    }

    private func prepareStageThreeSmokeBootstrap(
        dataDirectory: URL
    ) throws -> StageThreeSmokeBootstrap {
        let title = "迁移标题 '🌱"
        let body = "迁移正文 %\n第二行\0结尾"
        let draft = "待恢复草稿 \"🌿\"\n\0"
        let productionDirectory = try DataDirectoryResolver.productionDirectory()
        let productionBefore = DebugDirectorySnapshot.capture(
            url: productionDirectory
        )
        try StageThreeDebugHarness.createVersionOneFixture(
            dataDirectoryURL: dataDirectory,
            inspirationTitle: title,
            inspirationBody: body,
            draftContent: draft
        )
        return StageThreeSmokeBootstrap(
            dataDirectoryURL: dataDirectory,
            expectedInspirationTitle: title,
            expectedInspirationBody: body,
            expectedDraftContent: draft,
            productionDirectoryURL: productionDirectory,
            productionSnapshotBefore: productionBefore
        )
    }

    private func prepareStageFourSmokeBootstrap(
        dataDirectory: URL,
        store: JotBloomStore
    ) throws -> StageFourSmokeBootstrap {
        let productionDirectory = try DataDirectoryResolver.productionDirectory()
        let productionBefore = DebugDirectorySnapshot.capture(
            url: productionDirectory
        )
        var seededIDs: [Int64] = []
        for index in 0..<65 {
            let saved = try store.saveManualInspirationSynchronously(
                ParsedInspiration(
                    title: "阶段四种子 \(index) '🌱\0",
                    body: "正文 % \(index)\n第二行\0尾"
                ),
                timestampUTCms: Int64(10_000 + index)
            )
            seededIDs.append(saved.id)
        }
        return StageFourSmokeBootstrap(
            dataDirectoryURL: dataDirectory,
            seededIDs: seededIDs,
            productionDirectoryURL: productionDirectory,
            productionSnapshotBefore: productionBefore,
            generalPasteboardChangeCountBefore: NSPasteboard.general.changeCount
        )
    }

    private func prepareStageFiveSmokeBootstrap(
        dataDirectory: URL,
        store: JotBloomStore
    ) throws -> StageFiveSmokeBootstrap {
        let productionDirectory = try DataDirectoryResolver.productionDirectory()
        let productionBefore = DebugDirectorySnapshot.capture(
            url: productionDirectory
        )
        let baseTime = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let source = ClipboardSourceApplication(
            name: "Stage 5 Smoke",
            bundleIdentifier: "com.jotbloom.mengsheng.stage-five-smoke"
        )

        var clipboardIDs: [String: Int64] = [:]
        let fixedClipboardValues: [(String, String, ClipboardContentType, Int64)] = [
            (
                "sharedText",
                "Stage5-Shared clipboard text exact\nsecond line",
                .text,
                baseTime + 1
            ),
            (
                "sharedLink",
                "https://example.com/stage5-shared",
                .link,
                baseTime + 2
            ),
            (
                "highlight",
                "stage5-highlight middle stage5-highlight",
                .text,
                baseTime + 3
            ),
            (
                "unicode",
                "CAFÉ 中文 🌱 e\u{301}",
                .text,
                baseTime + 4
            ),
            (
                "special",
                "literal %_'\\ marker\0tail",
                .text,
                baseTime + 5
            ),
            (
                "stableA",
                "stable-clipboard A",
                .text,
                baseTime + 6
            ),
            (
                "stableB",
                "stable-clipboard B",
                .text,
                baseTime + 6
            )
        ]
        var scannedCharacterCount = 0
        for (key, text, type, timestamp) in fixedClipboardValues {
            let outcome = try store.upsertClipboardTextSynchronously(
                text: text,
                contentType: type,
                copiedAtUTCms: timestamp,
                sourceApplication: source
            )
            clipboardIDs[key] = clipboardIdentifier(from: outcome)
            scannedCharacterCount += text.count
        }
        let bulkClipboardCount = 192
        for index in 0..<bulkClipboardCount {
            let text = "bulk-common clipboard \(index) tail-clipboard-\(index)"
            _ = try store.upsertClipboardTextSynchronously(
                text: text,
                contentType: .text,
                copiedAtUTCms: baseTime + 100 + Int64(index),
                sourceApplication: source
            )
            scannedCharacterCount += text.count
        }
        let imageName = "Stage5ImageOnly-\(UUID().uuidString).png"
        _ = try store.insertClipboardImageSynchronously(
            names: ClipboardAssetNames(
                imageFileName: imageName,
                thumbnailFileName: "Stage5ImageOnly-thumb-\(UUID().uuidString).png"
            ),
            byteCount: 1,
            sha256: String(repeating: "a", count: 64),
            widthPixels: 1,
            heightPixels: 1,
            copiedAtUTCms: baseTime + 10_000,
            sourceApplication: ClipboardSourceApplication(
                name: "Stage5ImageOnly",
                bundleIdentifier: "com.example.Stage5ImageOnly"
            )
        )

        var oldInspirationID: Int64?
        var stableInspirationIDs: [Int64] = []
        for index in 0..<1_000 {
            let title: String
            let body: String
            switch index {
            case 0:
                title = "Old searchable inspiration"
                body = "stage5-old-detail stage5-shared bulk-common"
            case 1:
                title = "Stage5-Shared inspiration title"
                body = "bulk-common"
            case 2:
                title = "Unicode café 中文 🌱"
                body = "bulk-common"
            case 3:
                title = "Special literal"
                body = "literal %_'\\ marker\0tail bulk-common"
            case 4:
                title = "Repeated highlight"
                body = "stage5-highlight then stage5-highlight bulk-common"
            case 5, 6:
                title = "stable-inspiration \(index)"
                body = "bulk-common"
            default:
                title = "Performance inspiration \(index)"
                body = "bulk-common body \(index) tail-marker-\(index)"
            }
            let timestamp = (index == 5 || index == 6)
                ? baseTime + 20_000
                : baseTime + 20_100 + Int64(index)
            let saved = try store.saveManualInspirationSynchronously(
                ParsedInspiration(title: title, body: body),
                timestampUTCms: timestamp
            )
            if index == 0 {
                oldInspirationID = saved.id
            }
            if index == 5 || index == 6 {
                stableInspirationIDs.append(saved.id)
            }
            scannedCharacterCount += title.count + body.count
        }

        guard let oldInspirationID,
              let sharedTextID = clipboardIDs["sharedText"],
              let sharedLinkID = clipboardIDs["sharedLink"] else {
            throw PersistenceError.invalidStoredValue(column: "stage_five_fixture")
        }
        return StageFiveSmokeBootstrap(
            dataDirectoryURL: dataDirectory,
            sharedTextID: sharedTextID,
            sharedLinkID: sharedLinkID,
            sharedText: fixedClipboardValues[0].1,
            sharedLink: fixedClipboardValues[1].1,
            stableClipboardIDs: [
                clipboardIDs["stableA"],
                clipboardIDs["stableB"]
            ].compactMap { $0 },
            stableInspirationIDs: stableInspirationIDs,
            oldInspirationID: oldInspirationID,
            expectedBulkMatchCount: bulkClipboardCount + 1_000,
            scannedRowCount: 1_199,
            scannedCharacterCount: scannedCharacterCount,
            productionDirectoryURL: productionDirectory,
            productionSnapshotBefore: productionBefore,
            generalPasteboardChangeCountBefore: NSPasteboard.general.changeCount
        )
    }

    private func clipboardIdentifier(
        from outcome: ClipboardCaptureOutcome
    ) -> Int64 {
        switch outcome {
        case let .inserted(item), let .refreshed(item):
            return item.id
        case .skipped:
            preconditionFailure("Stage 5 fixture text cannot be skipped")
        }
    }

    private func prepareStageTwoPersistenceSmoke(
        dataDirectory: URL
    ) throws -> StageTwoPersistenceSmokeResult {
        let fileManager = FileManager.default
        let productionDatabase = try DataDirectoryResolver
            .productionDirectory(fileManager: fileManager)
            .appendingPathComponent(DataDirectoryResolver.databaseFileName)
        let productionBefore = FileSnapshot.capture(
            url: productionDatabase,
            fileManager: fileManager
        )

        let smokeText = "stage-two-smoke-\(UUID().uuidString)"
        var smokeStore = try JotBloomStore(dataDirectoryURL: dataDirectory)
        let schemaVersion = try smokeStore.schemaVersionSynchronously()
        let draftWriteStartedAt = ProcessInfo.processInfo.systemUptime
        try smokeStore.persistDraftSynchronously(
            kind: .inspiration,
            content: smokeText,
            updatedAtUTCms: 1_000
        )
        let draftWriteMilliseconds = (
            ProcessInfo.processInfo.systemUptime - draftWriteStartedAt
        ) * 1_000
        smokeStore.close()

        smokeStore = try JotBloomStore(dataDirectoryURL: dataDirectory)
        let draftRestored = try smokeStore
            .loadDraftSynchronously(kind: .inspiration)?
            .content == smokeText
        guard let parsed = InspirationTextParser.parse(smokeText) else {
            throw PersistenceError.invalidStoredValue(column: "smoke_input")
        }
        let inspirationSaveStartedAt = ProcessInfo.processInfo.systemUptime
        let saved = try smokeStore.saveManualInspirationSynchronously(
            parsed,
            timestampUTCms: 2_000
        )
        let inspirationSaveMilliseconds = (
            ProcessInfo.processInfo.systemUptime - inspirationSaveStartedAt
        ) * 1_000
        let saveCommitted = saved.body == smokeText
        smokeStore.close()

        smokeStore = try JotBloomStore(dataDirectoryURL: dataDirectory)
        let draftCleared = try smokeStore
            .loadDraftSynchronously(kind: .inspiration) == nil
        let inspirationRestored = try smokeStore
            .listRecentInspirationsSynchronously()
            .contains { $0.id == saved.id && $0.body == smokeText }
        let productionAfter = FileSnapshot.capture(
            url: productionDatabase,
            fileManager: fileManager
        )

        return StageTwoPersistenceSmokeResult(
            store: smokeStore,
            schemaVersion: schemaVersion,
            draftRestored: draftRestored,
            saveCommitted: saveCommitted,
            draftCleared: draftCleared,
            inspirationRestored: inspirationRestored,
            productionDataUntouched: productionBefore == productionAfter,
            draftWriteMilliseconds: draftWriteMilliseconds,
            inspirationSaveMilliseconds: inspirationSaveMilliseconds
        )
    }

    private func runStageOneSmoke(
        panelController: PanelController,
        hotKeyManager: HotKeyManager,
        hotZoneController: HotZoneWindowController
    ) {
        DispatchQueue.main.async {
            let hotZoneFrames = hotZoneController.debugWindowFrames
                .map { frame in
                    String(
                        format: "%.1f,%.1f,%.1f,%.1f",
                        frame.minX,
                        frame.minY,
                        frame.width,
                        frame.height
                    )
                }
                .joined(separator: ";")
            print(
                "JOTBLOOM_STAGE1_SMOKE "
                    + "hotkey_registered=\(hotKeyManager.isRegistered) "
                    + "hot_zone_window_count=\(hotZoneController.debugWindowCount) "
                    + "hot_zone_frames=\(hotZoneFrames)"
            )

            let startedAt = ProcessInfo.processInfo.systemUptime
            hotZoneController.debugActivate()
            let presentationMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let snapshot = panelController.debugSnapshot
                let focusObservationMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                print(
                    "JOTBLOOM_STAGE1_SMOKE "
                        + "panel_visible=\(snapshot.isVisible) "
                        + "panel_key=\(snapshot.isKey) "
                        + "text_input_focused=\(snapshot.textInputFocused) "
                        + "hot_zone_window_count_while_panel_visible=\(hotZoneController.debugWindowCount) "
                        + String(format: "presentation_call_ms=%.3f ", presentationMilliseconds)
                        + String(format: "focus_observed_ms=%.3f", focusObservationMilliseconds)
                )

                hotZoneController.debugActivate()
                print(
                    "JOTBLOOM_STAGE1_SMOKE "
                        + "panel_hidden=\(!panelController.debugSnapshot.isVisible) "
                        + "hot_zone_window_count_after_hide=\(hotZoneController.debugWindowCount)"
                )
                NSApp.terminate(nil)
            }
        }
    }

    private func runStageTwoSmoke(
        result: StageTwoPersistenceSmokeResult,
        coordinator: PanelVisibilityCoordinator,
        panelController: PanelController,
        hotKeyManager: HotKeyManager,
        hotZoneController: HotZoneWindowController
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            print(
                "JOTBLOOM_STAGE2_SMOKE "
                    + "database_user_version=\(result.schemaVersion) "
                    + "draft_restored=\(result.draftRestored) "
                    + "save_committed=\(result.saveCommitted) "
                    + "draft_cleared=\(result.draftCleared) "
                    + "inspiration_restored=\(result.inspirationRestored) "
                    + "production_data_untouched=\(result.productionDataUntouched) "
                    + "hotkey_registered=\(hotKeyManager.isRegistered) "
                    + "hot_zone_window_count=\(hotZoneController.debugWindowCount) "
                    + String(
                        format: "draft_write_ms=%.3f ",
                        result.draftWriteMilliseconds
                    )
                    + String(
                        format: "inspiration_save_ms=%.3f",
                        result.inspirationSaveMilliseconds
                    )
            )

            let startedAt = ProcessInfo.processInfo.systemUptime
            coordinator.show()
            let presentationMilliseconds = (
                ProcessInfo.processInfo.systemUptime - startedAt
            ) * 1_000
            DispatchQueue.main.asyncAfter(deadline: .now() + self.stageTwoSmokePanelHold) {
                let snapshot = panelController.debugSnapshot
                let focusObservationMilliseconds = (
                    ProcessInfo.processInfo.systemUptime - startedAt
                ) * 1_000
                print(
                    "JOTBLOOM_STAGE2_SMOKE "
                        + "panel_visible=\(snapshot.isVisible) "
                        + "panel_key=\(snapshot.isKey) "
                        + "text_input_focused=\(snapshot.textInputFocused) "
                        + String(
                            format: "presentation_call_ms=%.3f ",
                            presentationMilliseconds
                        )
                        + String(
                            format: "focus_observed_ms=%.3f",
                            focusObservationMilliseconds
                        )
                )

                coordinator.hide(restoreFocus: false)
                print(
                    "JOTBLOOM_STAGE2_SMOKE "
                        + "panel_hidden=\(!panelController.debugSnapshot.isVisible)"
                )
                NSApp.terminate(nil)
            }
        }
    }

    private func resolveDataDirectory() throws -> URL {
        if isStageOneSmoke
            || isStageTwoSmoke
            || isStageThreeSmoke
            || isStageFourSmoke
            || isStageFiveSmoke {
            let directory = DataDirectoryResolver.makeEphemeralDirectory(
                prefix: "jotbloom-stage-smoke"
            )
            ephemeralDataDirectory = directory
            return directory
        }

        if let debugPath = ProcessInfo.processInfo
            .environment["JOTBLOOM_DEBUG_DATA_DIRECTORY"],
           !debugPath.isEmpty {
            return try DataLocationStore(controlDirectory: DataDirectoryResolver.validatedDebugDirectory(path: debugPath)).activeDirectory()
        }

        return try locationStore.activeDirectory()
    }

    private func removeEphemeralDataDirectoryIfNeeded() {
        guard let ephemeralDataDirectory else { return }
        defer { self.ephemeralDataDirectory = nil }

        let nameIsExpected = ephemeralDataDirectory.lastPathComponent
            .hasPrefix("jotbloom-stage-smoke-")
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = ephemeralDataDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = temporaryRoot.path.hasSuffix("/")
            ? temporaryRoot.path
            : temporaryRoot.path + "/"

        guard nameIsExpected, candidate.path.hasPrefix(rootPath) else {
            logger.error("Refused to remove an unexpected smoke data directory")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
        } catch {
            logger.error("Failed to remove the ephemeral smoke data directory")
        }
    }
#endif

    private func presentStartupStorageError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "萌生无法打开本地数据"
        if case let PersistenceError.dataDirectoryUnavailable(path) = error {
            alert.informativeText = "请检查磁盘空间或目录权限后重新打开。\n\(path)"
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.informativeText += "\n不会新建空库或自动回退旧副本。请接回原磁盘后重试，或重新选择同一数据目录。定位记录损坏时请保留原文件，不能用任意目录替代。"
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "重新定位数据目录")
        alert.addButton(withTitle: "退出萌生")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            DispatchQueue.main.async { [weak self] in self?.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
        } else if response == .alertSecondButtonReturn {
            let picker = NSOpenPanel()
            picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
            picker.message = "选择原数据目录 JotBloom 本身，不是它的父目录。只接受身份一致且版本有效的库。"
            if picker.runModal() == .OK, let url = picker.url {
                do {
                    try locationStore.relocate(to: url)
                    DispatchQueue.main.async { [weak self] in self?.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
                } catch {
                    DispatchQueue.main.async { [weak self] in self?.presentStartupStorageError(error) }
                }
            } else {
                DispatchQueue.main.async { [weak self] in self?.presentStartupStorageError(error) }
            }
        } else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func presentTerminationStorageError(
        messageText: String,
        informativeText: String
    ) -> Bool {
        logger.error("Final draft flush failed during normal termination")
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "取消退出")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func logPersistenceFailure(
        _ error: Error,
        operation: String,
        startedAt: TimeInterval
    ) {
        let metadata = PersistenceDiagnostics.metadata(for: error)
        let sqliteCode = metadata.sqliteResultCode.map(String.init) ?? "none"
        let foundSchema = metadata.foundSchemaVersion.map(String.init) ?? "none"
        let durationMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        let message = "Storage operation=\(operation) failed "
            + "kind=\(metadata.kind) "
            + "sqlite_code=\(sqliteCode) "
            + "found_schema=\(foundSchema) "
            + "supported_schema=\(DatabaseMigrator.currentVersion) "
            + "duration_ms=\(durationMilliseconds)"
        logger.error("\(message, privacy: .public)")
    }
}

#if DEBUG
private struct StageTwoPersistenceSmokeResult {
    let store: JotBloomStore
    let schemaVersion: Int32
    let draftRestored: Bool
    let saveCommitted: Bool
    let draftCleared: Bool
    let inspirationRestored: Bool
    let productionDataUntouched: Bool
    let draftWriteMilliseconds: Double
    let inspirationSaveMilliseconds: Double
}

private struct FileSnapshot: Equatable {
    let exists: Bool
    let size: UInt64?
    let modificationDate: Date?

    static func capture(url: URL, fileManager: FileManager) -> FileSnapshot {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return FileSnapshot(exists: false, size: nil, modificationDate: nil)
        }

        return FileSnapshot(
            exists: true,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }
}
#endif

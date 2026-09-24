import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class ScrollBenchmark: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var model: ClipboardViewModel?
    @Published var status = "Loading synthetic history…"
    @Published var isLoading = false
    @Published var recording = false
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var displayLink: CADisplayLink?
    private var localKeyMonitor: Any?
    private var samples: [Double] = []
    private var previousTick: TimeInterval?
    private var roots: [URL] = []
    private var lastScroll = 0.0
    private var scrollEvents = 0
    private var count = 1_000
    private var openMS = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.setVolatileDomain([L10n.languageDefaultsKey: "en"], forName: UserDefaults.argumentDomain)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Paste Lite Scroll Benchmark"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BenchmarkView(benchmark: self))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        displayLink = window.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: nil)
        // Exercise the same navigation entry point as ClipboardPanelController without real clipboard access.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow, let model = self.model else { return event }
            switch event.keyCode {
            case 125: model.moveSelection(by: 1)
            case 126: model.moveSelection(by: -1)
            default: return event
            }
            return nil
        }
        load(1_000)
    }

    func load(_ count: Int) {
        guard !isLoading, !recording else { return }
        self.count = count
        isLoading = true
        status = "Loading \(count) synthetic records…"
        model = nil
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-scroll-\(UUID())")
        roots.append(root)
        let repository = ClipboardRepository(fileManager: PerformanceFileManager(root: root))
        Task {
            do {
                let batch = try await Task.detached { try PerformanceFixtures.makeBatch(count: count, root: root) }.value
                let preview = try await repository.previewImport(batch)
                _ = try await repository.importBatch(batch, preview: preview, expand: true)
                let model = ClipboardViewModel(repository: repository)
                let queryStart = Date()
                while model.resultCount != count || model.isLoading {
                    guard model.errorMessage == nil, Date().timeIntervalSince(queryStart) < 60 else {
                        throw NSError(domain: "ScrollBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: model.errorMessage ?? "Initial query timed out"])
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let start = Date()
                model.prepareForPresentation(hasAccessibilityPermission: true)
                openMS = Date().timeIntervalSince(start) * 1_000
                model.onPaste = { [weak self] _ in self?.status = "Paste action received" }
                self.model = model
                status = "Ready: \(count) records"
            } catch { status = "Fixture failed: \(error)" }
            isLoading = false
        }
    }

    func showSettings() {
        guard let model else { return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Paste Lite Test Settings"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: SettingsView(
            repository: model.repository, navigation: SettingsNavigation(), onImport: {},
            onClearHistory: {
                defer { ClipboardImageLoader.clearCache() }
                try await model.repository.clearHistory()
            }
        ))
        panel.appearance = window.appearance
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        settingsWindow?.close()
        settingsWindow = panel
    }

    func toggleLanguage() {
        let language: AppLanguage = L10n.language == .english ? .chinese : .english
        UserDefaults.standard.setVolatileDomain([L10n.languageDefaultsKey: language.rawValue], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
    }

    func toggleAppearance() {
        window.appearance = NSAppearance(named: window.appearance?.name == .darkAqua ? .aqua : .darkAqua)
    }

    func toggleRecording() {
        if recording {
            recording = false
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { status = "No samples"; return }
            let result: [String: Any] = [
                "count": count, "sample_count": sorted.count, "scroll_events": scrollEvents, "open_prepare_ms": openMS,
                "callback_median_ms": sorted[sorted.count / 2],
                "callback_p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                "callback_max_ms": sorted.last!,
                "callback_over_50ms": sorted.filter { $0 > 50 }.count
            ]
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PASTE_PERF_OUTPUT"] ?? NSTemporaryDirectory())
            let label = Bundle.main.object(forInfoDictionaryKey: "BenchmarkLabel") as? String ?? "unknown"
            let path = directory.appendingPathComponent("scroll-\(label)-\(count).json")
            do {
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: path)
                status = "Saved \(label) \(count): p95 \(Int(result["callback_p95_ms"] as! Double)) ms"
            } catch { status = "Save failed: \(error)" }
        } else {
            samples.removeAll(keepingCapacity: true)
            previousTick = nil
            lastScroll = 0
            scrollEvents = 0
            recording = true
            status = "Recording: scroll the history"
        }
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView, clip.window == window, recording else { return }
        lastScroll = ProcessInfo.processInfo.systemUptime
        scrollEvents += 1
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let previousTick, now - lastScroll < 0.35 { samples.append((now - previousTick) * 1_000) }
        previousTick = now
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayLink?.invalidate()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        NotificationCenter.default.removeObserver(self)
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }
}

private struct BenchmarkView: View {
    @ObservedObject var benchmark: ScrollBenchmark
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach([1_000, 10_000, 50_000], id: \.self) { count in
                    Button("\(count)") { benchmark.load(count) }
                        .disabled(benchmark.isLoading || benchmark.recording)
                }
                Button(benchmark.recording ? "Stop" : "Record") { benchmark.toggleRecording() }
                    .disabled(benchmark.isLoading)
                Button("Theme") { benchmark.toggleAppearance() }
                Button("Settings") { benchmark.showSettings() }.disabled(benchmark.isLoading)
                Button("中文/EN") { benchmark.toggleLanguage() }
                Spacer()
                Text(benchmark.status).font(.caption)
            }.padding(10).frame(height: 50)
            if let model = benchmark.model {
                ClipboardHistoryView(viewModel: model)
            } else {
                ProgressView().frame(width: 760, height: 560)
            }
        }
    }
}

@main
struct ScrollBenchmarkApp: App {
    @NSApplicationDelegateAdaptor(ScrollBenchmark.self) var benchmark
    var body: some Scene { Settings { EmptyView() } }
}

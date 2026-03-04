import Foundation
import AppKit
import HotKey
import ApplicationServices
import CoreGraphics

@Observable
final class HotkeyManager {
    // MARK: - HotKey Instances (用于普通快捷键)

    /// 活跃的 HotKey 实例 - 保持引用以维护生命周期
    private var activeHotKeys: [UUID: HotKey] = [:]

    // MARK: - Fn Key Monitors (HotKey 库不支持 Fn 键，需要使用 NSEvent)

    /// Fn 键全局监听器
    private var fnKeyGlobalMonitor: Any?
    /// Fn 键本地监听器（当应用在前台时）
    private var fnKeyLocalMonitor: Any?
    /// Fn 键按下状态
    private var fnKeyPressed = false

    // MARK: - State

    private var isMonitoring = false

    // MARK: - Configuration

    private(set) var configuration: HotkeyConfiguration = .defaultConfiguration
    private var configurationObserver: NSObjectProtocol?

    // MARK: - Callbacks

    /// Fn 键按下回调（保持向后兼容）
    var onFnKeyDown: (() -> Void)?
    /// Fn 键释放回调（保持向后兼容）
    var onFnKeyUp: (() -> Void)?
    /// 任意快捷键按下回调
    var onHotkeyDown: (() -> Void)?
    /// 任意快捷键释放回调
    var onHotkeyUp: (() -> Void)?

    // MARK: - Lifecycle

    init() {
        loadConfiguration()
        setupConfigurationObserver()
    }

    deinit {
        stopMonitoring()
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Configuration Management

    private func loadConfiguration() {
        configuration = SettingsStorage.shared.loadHotkeyConfiguration()
    }

    private func setupConfigurationObserver() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let config = notification.userInfo?["configuration"] as? HotkeyConfiguration {
                self?.applyConfiguration(config)
            }
        }
    }

    func applyConfiguration(_ newConfig: HotkeyConfiguration) {
        let wasMonitoring = isMonitoring

        if wasMonitoring {
            stopMonitoring()
        }

        configuration = newConfig

        if wasMonitoring {
            startMonitoring()
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }


        // 1. 如果配置了 Fn 键，使用 NSEvent 监听（HotKey 库不支持 Fn 键）
        if configuration.hasFnKey {
            setupFnKeyMonitors()
        }

        // 2. 对于普通快捷键，使用 HotKey 库
        for hotkey in configuration.hotkeys where hotkey.type != .fnKey {
            registerHotKey(for: hotkey)
        }

        isMonitoring = true
    }

    func stopMonitoring() {
        guard isMonitoring else { return }


        // 移除 Fn 键监听器
        removeFnKeyMonitors()

        // 清除所有 HotKey 实例 - 它们会在 dealloc 时自动注销
        activeHotKeys.removeAll()

        isMonitoring = false
    }

    // MARK: - Private: Fn Key Monitoring (使用 NSEvent)

    private func setupFnKeyMonitors() {
        // 全局监听器 - 当应用不在前台时也能捕获
        fnKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnKeyEvent(event)
        }

        // 本地监听器 - 当应用在前台时
        fnKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFnKeyEvent(event)
            return event
        }

    }

    private func removeFnKeyMonitors() {
        if let monitor = fnKeyGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            fnKeyGlobalMonitor = nil
        }
        if let monitor = fnKeyLocalMonitor {
            NSEvent.removeMonitor(monitor)
            fnKeyLocalMonitor = nil
        }
        fnKeyPressed = false
    }

    private func handleFnKeyEvent(_ event: NSEvent) {
        let fnPressed = event.modifierFlags.contains(.function)

        if fnPressed && !fnKeyPressed {
            // Fn 键按下
            fnKeyPressed = true
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyDown?()
                self?.onFnKeyDown?()
            }
        } else if !fnPressed && fnKeyPressed {
            // Fn 键释放
            fnKeyPressed = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyUp?()
                self?.onFnKeyUp?()
            }
        }
    }

    // MARK: - Private: HotKey Registration (用于普通快捷键)

    private func registerHotKey(for hotkey: Hotkey) {
        // Fn 键由 NSEvent 监听处理，不使用 HotKey 库
        guard hotkey.type != .fnKey else { return }

        guard let key = hotkey.hotKeyKey else { return }

        let modifiers = hotkey.hotKeyModifiers

        let newHotKey = HotKey(key: key, modifiers: modifiers)

        // 设置按下回调
        newHotKey.keyDownHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.onHotkeyDown?()
            }
        }

        // 设置释放回调
        newHotKey.keyUpHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.onHotkeyUp?()
            }
        }

        activeHotKeys[hotkey.id] = newHotKey
    }

    // MARK: - Permission Checks

    /// Check accessibility permission using AXIsProcessTrusted()
    /// Note: CGEvent.tapCreate() requires app restart to detect newly granted permissions,
    /// so we use AXIsProcessTrusted() which updates reliably during the same session.
    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func checkAccessibilityPermissionAsync() async -> Bool {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let result = AXIsProcessTrusted()
                continuation.resume(returning: result)
            }
        }
    }

    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

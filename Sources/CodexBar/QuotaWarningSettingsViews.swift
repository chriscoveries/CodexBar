import CodexBarCore
#if os(macOS)
import AppKit
#endif
import SwiftUI

@MainActor
struct GlobalQuotaWarningSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuotaWarningWindowThresholdRows(settings: self.settings)

            Text(L("quota_warning_global_threshold_subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: self.$settings.quotaWarningSoundEnabled) {
                Text(L("quota_warning_sound"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: self.$settings.quotaWarningOnScreenAlertEnabled) {
                Text(L("quota_warning_onscreen_alert"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 22)
        .background(FocusResigningBackground())
        .listRowSeparator(.hidden)
    }
}

@MainActor
struct ProviderQuotaWarningSettingsView: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore

    var body: some View {
        Section {
            self.windowRow(.session)
            self.windowRow(.weekly)
        } header: {
            Text(L("quota_warnings_title"))
        } footer: {
            Text(L("quota_warning_provider_inherits"))
        }
        .background(FocusResigningBackground())
    }

    private func windowRow(_ window: QuotaWarningWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) },
                set: { isOn in
                    if isOn {
                        self.settings.setQuotaWarningOverride(
                            provider: self.provider,
                            window: window,
                            thresholds: self.settings.quotaWarningThresholds(window),
                            enabled: self.settings.quotaWarningWindowEnabled(window))
                    } else {
                        self.settings.setQuotaWarningOverride(
                            provider: self.provider,
                            window: window,
                            thresholds: nil,
                            enabled: nil)
                    }
                })) {
                    Text(String(format: L("quota_warning_customize_thresholds"), window.localizedDisplayName))
                        .font(.subheadline.weight(.semibold))
                }
                .toggleStyle(.checkbox)

            if self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) {
                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningEnabled(provider: self.provider, window: window) },
                    set: {
                        self.settings.setQuotaWarningWindowEnabled(
                            provider: self.provider,
                            window: window,
                            enabled: $0)
                    })) {
                        Text(String(format: L("quota_warning_enable_warnings"), window.localizedDisplayName))
                            .font(.footnote)
                    }
                    .toggleStyle(.checkbox)
                        .padding(.leading, 20)

                if self.settings.quotaWarningEnabled(provider: self.provider, window: window) {
                    QuotaWarningThresholdField(
                        title: String(
                            format: L("quota_warning_window_warn_at"),
                            window.localizedCapitalizedDisplayName),
                        subtitle: "",
                        shouldCommitOnDisappear: {
                            self.settings.hasQuotaWarningOverride(provider: self.provider, window: window)
                        },
                        thresholds: {
                            self.settings.resolvedQuotaWarningThresholds(provider: self.provider, window: window)
                        },
                        setThresholds: {
                            self.settings.setQuotaWarningThresholdsIfOverridden(
                                provider: self.provider,
                                window: window,
                                thresholds: $0)
                        })
                        .padding(.leading, 20)
                } else {
                    Text(L("quota_warning_off"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            } else {
                Text(String(format: L("quota_warning_inherited"), Self.thresholdText(
                    self.settings.quotaWarningThresholds(window),
                    enabled: self.settings.quotaWarningWindowEnabled(window))))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private static func thresholdText(_ thresholds: [Int], enabled: Bool) -> String {
        guard enabled else { return L("quota_warning_off") }
        let text = QuotaWarningThresholds.active(thresholds).map { "\($0)%" }.joined(separator: ", ")
        return text.isEmpty ? L("quota_warning_depleted_only") : text
    }
}

struct FocusResigningBackground: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                #if os(macOS)
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                #endif
            }
    }
}

extension QuotaWarningWindow {
    fileprivate var localizedDisplayName: String {
        switch self {
        case .session: L("quota_warning_session")
        case .weekly: L("quota_warning_weekly")
        }
    }

    fileprivate var localizedCapitalizedDisplayName: String {
        switch self {
        case .session: L("quota_warning_session_capitalized")
        case .weekly: L("quota_warning_weekly_capitalized")
        }
    }
}

@MainActor
private struct QuotaWarningWindowThresholdRows: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            self.windowThresholdRow(.session)
            self.windowThresholdRow(.weekly)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func windowThresholdRow(_ window: QuotaWarningWindow) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(
                get: { self.settings.quotaWarningWindowEnabled(window) },
                set: { self.settings.setQuotaWarningWindowEnabled(window, enabled: $0) }))
            {
                Text(String(format: L("quota_warning_window_warn_at"), window.localizedCapitalizedDisplayName))
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .toggleStyle(.checkbox)
            .gridColumnAlignment(.leading)

            QuotaWarningThresholdField(
                title: "",
                subtitle: "",
                accessibilityContext: String(
                    format: L("quota_warning_window_warn_at"),
                    window.localizedCapitalizedDisplayName),
                thresholds: { self.settings.quotaWarningThresholds(window) },
                setThresholds: { self.settings.setQuotaWarningThresholds(window, thresholds: $0) })
                .disabled(!self.settings.quotaWarningWindowEnabled(window))
                .opacity(self.settings.quotaWarningWindowEnabled(window) ? 1 : 0.45)
                .gridColumnAlignment(.leading)
        }
    }
}

@MainActor
private struct QuotaWarningThresholdField: View {
    private static let fieldWidth: CGFloat = 44

    let title: String
    let subtitle: String
    var accessibilityContext: String = ""
    var shouldCommitOnDisappear: () -> Bool = { true }
    let thresholds: () -> [Int]
    let setThresholds: ([Int]) -> Void

    @State private var upperText: String = ""
    @State private var lowerText: String = ""
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            self.horizontalEditor

            if !self.subtitle.isEmpty {
                Text(self.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { self.updateText(from: self.thresholds()) }
        .onChange(of: self.focusedField) { previous, current in
            if previous != nil, current == nil {
                self.commit(normalizeText: true)
            }
        }
        .onChange(of: self.thresholds()) { _, value in
            if self.focusedField == nil {
                self.updateText(from: value)
            }
        }
        .onDisappear {
            if self.shouldCommitOnDisappear() {
                self.commit(normalizeText: true)
            }
        }
        .background(self.focusMonitor)
    }

    private var horizontalEditor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            self.titleView

            self.lowerField
            self.upperField
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var titleView: some View {
        if !self.title.isEmpty {
            Text(self.title)
                .font(.footnote.weight(.semibold))
                .frame(width: 110, alignment: .leading)
        }
    }

    private var upperField: some View {
        self.thresholdInput(
            label: L("quota_warning_upper"),
            placeholder: "50",
            text: self.$upperText,
            field: .upper)
    }

    private var lowerField: some View {
        self.thresholdInput(
            label: L("quota_warning_lower"),
            placeholder: "20",
            text: self.$lowerText,
            field: .lower)
    }

    private func thresholdInput(label: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField(label, text: self.thresholdTextBinding(text), prompt: Text(verbatim: placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.fieldWidth)
                .focused(self.$focusedField, equals: field)
                .onSubmit {
                    self.commit(normalizeText: true)
                    self.focusedField = nil
                }
                .accessibilityLabel(Text(self.accessibilityLabel(for: label)))

            Text(verbatim: "%")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func thresholdTextBinding(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { value in
                let filtered = QuotaWarningThresholdEditorText.filteredIntegerText(value)
                text.wrappedValue = filtered
            })
    }

    private func commit(normalizeText: Bool) {
        let sanitized = QuotaWarningThresholdEditorText.resolvedThresholds(
            upperText: self.upperText,
            lowerText: self.lowerText)
        self.setThresholds(sanitized)
        if normalizeText, self.focusedField == nil {
            self.updateText(from: sanitized)
        }
    }

    private func updateText(from thresholds: [Int]) {
        let pair = QuotaWarningThresholdEditorText.displayText(from: thresholds)
        self.upperText = pair.upper.map(String.init) ?? ""
        self.lowerText = pair.lower.map(String.init) ?? ""
    }

    private func accessibilityLabel(for label: String) -> String {
        let context = self.title.isEmpty ? self.accessibilityContext : self.title
        guard !context.isEmpty else { return label }
        return "\(context), \(label)"
    }

    private enum Field: Hashable {
        case upper
        case lower
    }

    @ViewBuilder
    private var focusMonitor: some View {
        #if os(macOS)
        QuotaWarningFocusMonitor(isActive: self.focusedField != nil) {
            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            self.focusedField = nil
        }
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
private struct QuotaWarningFocusMonitor: NSViewRepresentable {
    let isActive: Bool
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> QuotaWarningFocusMonitorView {
        let view = QuotaWarningFocusMonitorView()
        view.isActive = self.isActive
        view.onOutsideClick = self.onOutsideClick
        return view
    }

    func updateNSView(_ nsView: QuotaWarningFocusMonitorView, context: Context) {
        nsView.isActive = self.isActive
        nsView.onOutsideClick = self.onOutsideClick
    }

    static func dismantleNSView(_ nsView: QuotaWarningFocusMonitorView, coordinator: ()) {
        nsView.invalidate()
    }
}

private final class QuotaWarningFocusMonitorView: NSView {
    var onOutsideClick: (() -> Void)?
    var isActive: Bool = false {
        didSet { self.updateMonitor() }
    }

    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func invalidate() {
        self.isActive = false
        self.onOutsideClick = nil
    }

    private func updateMonitor() {
        if self.isActive {
            self.installMonitor()
        } else {
            self.removeMonitor()
        }
    }

    private func installMonitor() {
        guard self.monitor == nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard self.isActive else { return }
        guard let window = self.window, event.window === window else { return }

        let location = self.convert(event.locationInWindow, from: nil)
        guard !self.bounds.contains(location) else { return }
        guard !Self.eventHitsTextInput(event) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onOutsideClick?()
        }
    }

    private static func eventHitsTextInput(_ event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView else { return false }
        let location = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(location) else { return false }
        return hitView.hasAncestor(of: NSTextField.self) || hitView.hasAncestor(of: NSTextView.self)
    }
}

extension NSView {
    fileprivate func hasAncestor<T: NSView>(of type: T.Type) -> Bool {
        var view: NSView? = self
        while let current = view {
            if current is T {
                return true
            }
            view = current.superview
        }
        return false
    }
}
#endif

enum QuotaWarningThresholdEditorText {
    static func displayText(from thresholds: [Int]) -> (upper: Int?, lower: Int?) {
        let sanitized = QuotaWarningThresholds.sanitized(thresholds)
        return (sanitized.first, sanitized.dropFirst().first)
    }

    static func resolvedThresholds(upperText: String, lowerText: String) -> [Int] {
        QuotaWarningThresholds.resolved(
            upper: self.integer(from: upperText),
            lower: self.integer(from: lowerText))
    }

    static func filteredIntegerText(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(2))
    }

    private static func integer(from text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        return Int(text)
    }
}

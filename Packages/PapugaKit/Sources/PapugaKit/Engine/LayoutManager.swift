import Carbon.HIToolbox
import Combine
import Foundation
import Observation

struct InputSourceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let source: TISInputSource

    static func == (lhs: InputSourceInfo, rhs: InputSourceInfo) -> Bool {
        lhs.id == rhs.id
    }
}

@Observable
final class LayoutManager {
    var availableLayouts: [InputSourceInfo] = []
    var currentLayoutID: String = ""

    private var observer: NSObjectProtocol?
    private let logger = AppLogger.layout

    /// Was the Papuga setting `layoutOrder` (default `[]`). The manager rewrites it when the installed
    /// layouts change and reports each rewrite through `onLayoutOrderChange` so the host can persist it.
    var layoutOrder: [String]
    /// Was the Papuga setting `disabledLayouts` (default `[]`).
    var disabledLayouts: [String]
    @ObservationIgnored var onLayoutOrderChange: (([String]) -> Void)?

    init(
        layoutOrder: [String] = [],
        disabledLayouts: [String] = [],
        onLayoutOrderChange: (([String]) -> Void)? = nil
    ) {
        self.layoutOrder = layoutOrder
        self.disabledLayouts = disabledLayouts
        self.onLayoutOrderChange = onLayoutOrderChange
        AppLogger.pre(logger, "LayoutManager.init")
        reloadLayouts()
        currentLayoutID = getCurrentLayoutID()
        startObserving()
        AppLogger.post(logger, "LayoutManager initialized: currentLayoutID=\(currentLayoutID), availableLayouts=\(availableLayouts.count)")
    }

    deinit {
        AppLogger.pre(logger, "LayoutManager.deinit")
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            AppLogger.action(logger, "Removed distributed notification observer")
        }
        AppLogger.post(logger, "LayoutManager deinitialized")
    }

    func reloadLayouts() {
        AutoFixDecision.invalidateLanguageHints()
        AppLogger.pre(logger, "reloadLayouts()")
        let conditions = [
            kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsSelectCapable!: true
        ] as CFDictionary

        guard let sourceList = TISCreateInputSourceList(conditions, false)?.takeRetainedValue() as? [TISInputSource] else {
            AppLogger.error(logger, "TISCreateInputSourceList failed")
            return
        }

        availableLayouts = sourceList.compactMap { source in
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let namePtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
                return nil
            }
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
            return InputSourceInfo(id: id, name: name, source: source)
        }

        AppLogger.action(logger, "Reloaded layouts: count=\(availableLayouts.count)")
        syncLayoutOrder()
        AppLogger.post(logger, "reloadLayouts() completed")
    }

    private func syncLayoutOrder() {
        AppLogger.pre(logger, "syncLayoutOrder()")
        let availableIDs = availableLayouts.map(\.id)
        let availableSet = Set(availableIDs)
        let currentOrder = layoutOrder

        if currentOrder.isEmpty {
            layoutOrder = availableIDs
            onLayoutOrderChange?(availableIDs)
            AppLogger.post(logger, "Layout order initialized with \(availableIDs.count) items")
            return
        }

        let filtered = currentOrder.filter { availableSet.contains($0) }
        let missing = availableIDs.filter { !filtered.contains($0) }
        let syncedOrder = filtered + missing

        if syncedOrder != currentOrder {
            layoutOrder = syncedOrder
            onLayoutOrderChange?(syncedOrder)
            AppLogger.action(logger, "Layout order synced: filtered=\(filtered.count), missing=\(missing.count)")
        }
        AppLogger.post(logger, "syncLayoutOrder() completed")
    }

    func getCurrentLayoutID() -> String {
        AppLogger.pre(logger, "getCurrentLayoutID()")
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            AppLogger.warn(logger, "Current layout id pointer is nil")
            return ""
        }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        AppLogger.post(logger, "getCurrentLayoutID() -> \(id)")
        return id
    }

    func currentSource() -> TISInputSource {
        AppLogger.action(logger, "currentSource() requested")
        return TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    }

    func sourceForID(_ id: String) -> TISInputSource? {
        AppLogger.pre(logger, "sourceForID(\(id))")
        let source = availableLayouts.first(where: { $0.id == id })?.source
        if source == nil {
            AppLogger.warn(logger, "sourceForID(\(id)) -> nil")
        } else {
            AppLogger.post(logger, "sourceForID(\(id)) resolved")
        }
        return source
    }

    func orderedLayouts() -> [String] {
        AppLogger.pre(logger, "orderedLayouts()")
        let order = layoutOrder
        let disabled = Set(disabledLayouts)
        if order.isEmpty {
            let fallback = availableLayouts.map(\.id).filter { !disabled.contains($0) }
            AppLogger.post(logger, "orderedLayouts() fallback to available list count=\(fallback.count)")
            return fallback
        }
        let result = order.filter { id in
            availableLayouts.contains(where: { $0.id == id }) && !disabled.contains(id)
        }
        AppLogger.post(logger, "orderedLayouts() -> \(result.count) items")
        return result
    }

    /// All configured (ordered, enabled) layouts except the current one — the set of plausible
    /// targets auto-fix should evaluate. Unlike `nextLayout`, this does not assume the correct
    /// target is the next one in the cycle; the caller scores every candidate and picks the best.
    func candidateTargets(excluding currentID: String) -> [String] {
        orderedLayouts().filter { $0 != currentID }
    }

    func nextLayout(after currentID: String, direction: SwitchDirection) -> String? {
        AppLogger.pre(logger, "nextLayout(after: \(currentID), direction: \(String(describing: direction)))")
        let order = orderedLayouts()
        guard order.count >= 2,
              let currentIndex = order.firstIndex(of: currentID) else {
            AppLogger.warn(logger, "Cannot compute next layout: orderCount=\(order.count), currentIndexMissing=\(!order.contains(currentID))")
            return nil
        }

        switch direction {
        case .forward:
            let nextIndex = (currentIndex + 1) % order.count
            let nextID = order[nextIndex]
            AppLogger.post(logger, "nextLayout forward -> \(nextID)")
            return nextID
        case .backward:
            let prevIndex = (currentIndex - 1 + order.count) % order.count
            let prevID = order[prevIndex]
            AppLogger.post(logger, "nextLayout backward -> \(prevID)")
            return prevID
        }
    }

    func switchTo(_ id: String) {
        AppLogger.pre(logger, "switchTo(\(id))")
        guard let source = sourceForID(id) else {
            AppLogger.error(logger, "switchTo(\(id)) failed: source not found")
            return
        }
        AppLogger.action(logger, "Selecting input source for id=\(id)")
        TISSelectInputSource(source)
        currentLayoutID = id
        AppLogger.post(logger, "switchTo(\(id)) completed")
    }

    private func startObserving() {
        AppLogger.pre(logger, "startObserving()")
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let updatedID = self.getCurrentLayoutID()
            self.currentLayoutID = updatedID
            AppLogger.action(self.logger, "Observed system layout change -> \(updatedID)")
        }
        AppLogger.post(logger, "startObserving() completed")
    }
}

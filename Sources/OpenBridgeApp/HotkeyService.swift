import AppKit
import Foundation

@MainActor
final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightOptionPressed = false
    private var actionTriggeredForPress = false
    private var pendingShortcutTask: Task<Void, Never>?
    private var currentPressModifiers: NSEvent.ModifierFlags = []
    private var pressSequence = 0
    private var shortcutSettings = ShortcutSettings.defaults

    func start(
        shortcutSettings: ShortcutSettings,
        dictationCallback: @escaping () -> Void,
        handsFreeCallback: @escaping () -> Void,
        cancelCallback: @escaping () -> Void,
        pasteLastCallback: @escaping () -> Void,
        commandModeCallback: @escaping () -> Void
    ) {
        self.shortcutSettings = shortcutSettings
        stop()
        let callbacks = ShortcutCallbacks(
            dictation: dictationCallback,
            handsFree: handsFreeCallback,
            cancel: cancelCallback,
            pasteLast: pasteLastCallback,
            commandMode: commandModeCallback
        )
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.type == .flagsChanged else { return }
            guard let self else { return }

            let optionActive = event.modifierFlags.contains(.option)
            let isRightOption = event.keyCode == ShortcutBinding.rightOptionKeyCode

            if optionActive {
                self.currentPressModifiers = ShortcutBinding.normalizedModifiers(from: event.modifierFlags)
            }

            if !isRightOption {
                if !optionActive {
                    self.resetPressState()
                }
                return
            }

            if optionActive && self.rightOptionPressed == false {
                self.rightOptionPressed = true
                self.actionTriggeredForPress = false
                self.pressSequence += 1
                self.scheduleShortcutAction(callbacks, pressSequence: self.pressSequence)
            } else if !optionActive {
                self.rightOptionPressed = false
                self.actionTriggeredForPress = false
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    func stop() {
        resetPressState(cancelPendingShortcut: true)
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func scheduleShortcutAction(_ callbacks: ShortcutCallbacks, pressSequence: Int) {
        pendingShortcutTask?.cancel()
        pendingShortcutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.pressSequence == pressSequence,
                  !self.actionTriggeredForPress else {
                return
            }

            guard let action = self.shortcutSettings.action(matching: self.currentPressModifiers) else {
                self.pendingShortcutTask = nil
                return
            }

            self.triggerAction(callbacks.callback(for: action))
        }
    }

    private func triggerAction(_ callback: @escaping () -> Void) {
        actionTriggeredForPress = true
        pendingShortcutTask?.cancel()
        pendingShortcutTask = nil
        callback()
    }

    private func resetPressState(cancelPendingShortcut: Bool = false) {
        rightOptionPressed = false
        actionTriggeredForPress = false
        if cancelPendingShortcut {
            pendingShortcutTask?.cancel()
            pendingShortcutTask = nil
        }
    }
}

private struct ShortcutCallbacks {
    let dictation: () -> Void
    let handsFree: () -> Void
    let cancel: () -> Void
    let pasteLast: () -> Void
    let commandMode: () -> Void

    func callback(for action: ShortcutAction) -> () -> Void {
        switch action {
        case .dictation:
            return dictation
        case .handsFree:
            return handsFree
        case .cancel:
            return cancel
        case .pasteLast:
            return pasteLast
        case .commandMode:
            return commandMode
        }
    }
}

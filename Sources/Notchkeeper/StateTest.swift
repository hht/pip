import MascotCore

// "State Testing" in Settings: forces Pip to display a specific state, holds notch open or closed for inspection.
// In-memory only: does not write to config.json or touch guard; restarts revert to real state.
// State storage and mutation reside in Notch.swift's NotchOverrides / NotchController; these are lookup tables.

/// Notch pin state: Auto (follows hover), Always Open, Always Closed. Overrides hover only; cards still pop up as usual, so testing never hides real alert cards.
enum NotchPin: String, CaseIterable, Identifiable {
    case auto, open, closed
    var id: Self { self }

    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .open: return String(localized: "Always Open")
        case .closed: return String(localized: "Always Closed")
        }
    }
}

extension Look {
    /// Name used in "State Testing" and VoiceOver accessibility (docs/mascot.md §2).
    var title: String {
        switch self {
        case .idle: return String(localized: "Idle")
        case .sleeping: return String(localized: "Asleep")
        case .thinking: return String(localized: "Thinking")
        case .working: return String(localized: "Working")
        case .longTurn: return String(localized: "Long Turn")
        case .question: return String(localized: "Waiting for Answer")
        case .approval: return String(localized: "Waiting for Approval")
        case .finished: return String(localized: "Done")
        case .error: return String(localized: "Error")
        case .interrupted: return String(localized: "Interrupted")
        case .dizzy: return String(localized: "Dizzy")
        case .offline: return String(localized: "Offline")
        case .mismatch: return String(localized: "Egress Mismatch")
        case .stale: return String(localized: "Guard Not Responding")
        case .danger: return String(localized: "Danger")
        case .shielded: return String(localized: "Shielded")
        }
    }
}

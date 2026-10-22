import Foundation

public enum SwapError: LocalizedError, Equatable {
    case noClaudeData(String)
    case claudeNotInstalled(String)
    case noSuchAccount(String, saved: String)
    case nameTaken(String)
    case emptyName
    case notSavedYet(String)
    case noOtherAccount
    case notSignedIn
    case alreadyMain(String)
    case openInWindow(String)
    case signedInTwice(String)
    case isMain(String)
    case claudeDidNotQuit
    case claudeRestarted
    case busy
    case launchFailed(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .noClaudeData(let path):
            return "\(path) not found. Open the Claude desktop app once first."
        case .claudeNotInstalled(let path):
            return "Claude isn't installed at \(path)."
        case .noSuchAccount(let query, let saved):
            return "No saved account matches “\(query)”. Saved accounts: \(saved)."
        case .nameTaken(let name):
            return "Another account is already called “\(name)”."
        case .emptyName:
            return "The name is empty."
        case .notSavedYet(let name):
            return "“\(name)” has no saved sign-in yet. It is saved the first time you switch away from it."
        case .noOtherAccount:
            return "No other saved account to switch to. Add another account first."
        case .notSignedIn:
            return "Claude isn't signed in to an account it has identified yet. Open Claude and let it finish loading."
        case .alreadyMain(let name):
            return "“\(name)” is the account in the main Claude."
        case .openInWindow(let name):
            return "“\(name)” is open in its own Claude window. Close that window first, so its sign-in is only in one place."
        case .signedInTwice(let name):
            return "“\(name)” is signed in both in the main Claude and in its own window. Close its window first; nothing was changed."
        case .isMain(let name):
            return "“\(name)” is signed in to the main Claude. Switch to another account first."
        case .claudeDidNotQuit:
            return "Claude didn't quit. If it asked you to confirm quitting, confirm and try again. Nothing was changed."
        case .claudeRestarted:
            return "Claude started again before the switch finished. Nothing was changed; try again."
        case .busy:
            return "Another switch is already running."
        case .launchFailed(let reason):
            return "Couldn't open Claude: \(reason)"
        case .io(let message):
            return message
        }
    }
}

import Foundation
import TeachshelfCore

/// A single official SSO attempt per requested page. Never submits login forms.
struct TeachingLoginRecovery {
    private(set) var destination: URL?
    private(set) var attemptedSSO = false
    private var returnedToDestination = false

    mutating func begin(_ url: URL) {
        destination = TeachingWebsite.isPage(url) ? url : nil
        attemptedSSO = false; returnedToDestination = false
    }

    mutating func next(after url: URL?) -> URL? {
        guard let destination, let url, TeachingWebsite.allowsNavigation(url), url.host == TeachingWebsite.host else { return nil }
        if url.path == "/login/index.php", !attemptedSSO {
            attemptedSSO = true
            return URL(string: "https://\(TeachingWebsite.host)/login/index.php?authCAS=CAS")!
        }
        // CAS may return to the dashboard instead of Moodle's original wanted URL.
        if attemptedSSO, !returnedToDestination, ["/", "/index.php", "/my", "/my/", "/my/index.php"].contains(url.path) {
            returnedToDestination = true
            return destination
        }
        return nil
    }

    mutating func cancel() { destination = nil }
}

enum TeachingLoginState {
    case unknown, checking, renewing, signedIn, needsLogin
    var label: String {
        switch self {
        case .unknown: return "尚未检查登录"
        case .checking: return "正在检查登录"
        case .renewing: return "正在通过学校统一认证恢复登录"
        case .signedIn: return "已登录教学网站"
        case .needsLogin: return "需要在官方网页登录"
        }
    }
}

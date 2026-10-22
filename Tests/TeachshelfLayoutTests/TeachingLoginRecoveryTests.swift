import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

struct TeachingLoginRecoveryTests {
    private let login = URL(string: "https://selearning.nju.edu.cn/login/index.php")!
    private let cas = URL(string: "https://selearning.nju.edu.cn/login/index.php?authCAS=CAS")!

    @Test func expiredMoodleSessionTriesOfficialSSOOnceThenStopsForManualLogin() {
        var recovery = TeachingLoginRecovery()
        recovery.begin(TeachingWebsite.courseURL("411"))
        #expect(recovery.next(after: login) == cas)
        #expect(recovery.next(after: URL(string: "https://authserver.nju.edu.cn/authserver/login")) == nil)
        #expect(recovery.next(after: login) == nil)
        #expect(recovery.next(after: cas) == nil)
    }

    @Test func ssoDashboardReturnsToTheRequestedPageOnlyOnce() {
        var recovery = TeachingLoginRecovery()
        let target = URL(string: "https://selearning.nju.edu.cn/mod/assign/view.php?id=5302")!
        recovery.begin(target)
        let dashboard = URL(string: "https://selearning.nju.edu.cn/my/")!
        #expect(recovery.next(after: dashboard) == nil)
        #expect(recovery.next(after: login) == cas)
        #expect(recovery.next(after: dashboard) == target)
        #expect(recovery.next(after: dashboard) == nil)
        #expect(recovery.next(after: target) == nil)
    }

    @Test func validSessionNeverRequestsSSOAndOtherOriginsCannotTriggerIt() {
        var recovery = TeachingLoginRecovery()
        recovery.begin(TeachingWebsite.courseURL("411"))
        #expect(recovery.next(after: TeachingWebsite.courseURL("411")) == nil)
        for raw in ["https://evil.invalid/login/index.php", "http://selearning.nju.edu.cn/login/index.php", "https://selearning.nju.edu.cn:8443/login/index.php"] {
            #expect(recovery.next(after: URL(string: raw)) == nil)
        }
        #expect(!recovery.attemptedSSO)
    }

    @Test func cancellationPreventsLateNavigationFromRestartingAuthentication() {
        var recovery = TeachingLoginRecovery()
        recovery.begin(TeachingWebsite.courseURL("411"))
        recovery.cancel()
        #expect(recovery.next(after: login) == nil)
        recovery.begin(TeachingWebsite.courseURL("408"))
        #expect(recovery.next(after: login) == cas)
    }
}

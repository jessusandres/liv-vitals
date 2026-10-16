import Foundation
import Testing
@testable import LivCore

struct SudoersRuleTests {
    @Test func theRuleForAUserIsExactlyTheAdminSteps() throws {
        let text = try #require(SudoersRule.contents(for: "asger"))
        #expect(text == """
        # Installed by Liv Vitals. Remove it from Liv Vitals › Settings or delete this file.
        # It lets asger run these fixed commands as root without a password, and nothing else.
        asger ALL=(root) NOPASSWD: /usr/bin/dscacheutil -flushcache
        asger ALL=(root) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
        asger ALL=(root) NOPASSWD: /usr/bin/mdutil -E /
        asger ALL=(root) NOPASSWD: /bin/rm -rf /Library/Caches/com.apple.iconservices.store
        asger ALL=(root) NOPASSWD: /usr/sbin/purge ""

        """)
    }

    @Test func thereAreNoWildcardsAndEveryRuleLineIsAStep() throws {
        let text = try #require(SudoersRule.contents(for: "asger"))
        #expect(!text.contains("*"))
        let rules = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
        #expect(rules.count == MaintenanceCommand.adminSteps.count)
        for (rule, step) in zip(rules, MaintenanceCommand.adminSteps) {
            let command = rule.replacingOccurrences(of: "asger ALL=(root) NOPASSWD: ", with: "")
            // A step without arguments ends in "" so sudo refuses any argument.
            let expected = step.arguments.isEmpty ? "\(step.executable) \"\"" : step.display
            #expect(command == expected)
        }
        // The Dock restart is not an admin step and is not in the rule.
        #expect(!text.contains("Dock"))
    }

    @Test func onlyPlainAccountNamesProduceARule() {
        for bad in ["root;", "a b", "ALL", "", "1abc", "Asger", "a\nb", "a,b", "a=b", "%admin", String(repeating: "a", count: 33)] {
            #expect(SudoersRule.contents(for: bad) == nil, "\(bad.debugDescription)")
            #expect(!SudoersRule.isValidUser(bad))
        }
        for good in ["asger", "_svc", "a-b_c9", String(repeating: "a", count: 32)] {
            #expect(SudoersRule.contents(for: good) != nil, "\(good)")
        }
    }

    @Test func theRuleLivesInTheFixedFile() {
        #expect(SudoersRule.path == "/etc/sudoers.d/livvitals")
    }
}

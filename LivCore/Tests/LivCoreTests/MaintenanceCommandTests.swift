import Foundation
import Testing
@testable import LivCore

struct MaintenanceCommandTests {
    @Test func everyStepIsAnAbsolutePathWithFixedArguments() {
        // Nothing here may depend on data: no shell characters or variables in a program or an argument.
        let forbidden = CharacterSet(charactersIn: "$;|&`<>*?\\\"'()\n")
        for command in MaintenanceCommand.allCases {
            #expect(!command.steps.isEmpty)
            for step in command.steps {
                #expect(step.executable.hasPrefix("/"), "\(command): \(step.executable)")
                #expect(step.executable.rangeOfCharacter(from: forbidden) == nil)
                for argument in step.arguments {
                    #expect(argument.rangeOfCharacter(from: forbidden) == nil, "\(command): \(argument)")
                    #expect(!argument.isEmpty)
                }
            }
        }
    }

    @Test func aTaskRequiresAdminExactlyWhenAStepDoes() {
        let admin = Set(MaintenanceCommand.allCases.filter(\.requiresAdmin).map(\.rawValue))
        #expect(admin == ["dns", "spotlight", "icons", "purge"])
        for command in MaintenanceCommand.allCases {
            #expect(command.task.requiresAdmin == command.steps.contains { $0.needsAdmin })
            #expect(command.task.id == command.rawValue)
        }
    }

    @Test func tasksAreListedWithTheDecidedDefaults() {
        let tasks = MaintenanceCommand.allCases.map(\.task)
        #expect(tasks.map(\.title) == [
            "Flush DNS Cache", "Rebuild Launch Services", "Reset Quick Look Cache",
            "Reindex Spotlight", "Rebuild Icon Cache", "Free Inactive Memory",
        ])
        // Only the cheap, useful ones start checked.
        #expect(Set(tasks.filter(\.isSelectedByDefault).map(\.id)) == ["dns", "quicklook"])
        #expect(Set(tasks.map(\.id)).count == tasks.count)
    }

    @Test func theCommandsAreTheOnesTheSpecificationNames() {
        #expect(MaintenanceCommand.dns.steps == [
            CommandStep("/usr/bin/dscacheutil", ["-flushcache"], needsAdmin: true),
            CommandStep("/usr/bin/killall", ["-HUP", "mDNSResponder"], needsAdmin: true),
        ])
        #expect(MaintenanceCommand.launchservices.steps.map(\.arguments) == [["-gc"], ["-r", "-all", "local,system,user"]])
        #expect(MaintenanceCommand.quicklook.steps.map(\.arguments) == [["-r", "cache"], ["-r"]])
        #expect(MaintenanceCommand.spotlight.steps == [CommandStep("/usr/bin/mdutil", ["-E", "/"], needsAdmin: true)])
        #expect(MaintenanceCommand.purge.steps == [CommandStep("/usr/sbin/purge", needsAdmin: true)])
        // The Dock restart is the one icon step that does not need a password.
        #expect(MaintenanceCommand.icons.steps.map(\.needsAdmin) == [true, false])
        #expect(MaintenanceCommand.icons.steps[0].arguments == ["-rf", "/Library/Caches/com.apple.iconservices.store"])
    }

    @Test func theAdminStepsAreExactlyTheOnesWithoutAPasswordRuleWouldNeed() {
        #expect(MaintenanceCommand.adminSteps.count == 5)
        #expect(MaintenanceCommand.adminSteps.allSatisfy { $0.needsAdmin })
        #expect(Set(MaintenanceCommand.adminSteps.map(\.executable)) == [
            "/usr/bin/dscacheutil", "/usr/bin/killall", "/usr/bin/mdutil", "/bin/rm", "/usr/sbin/purge",
        ])
    }
}

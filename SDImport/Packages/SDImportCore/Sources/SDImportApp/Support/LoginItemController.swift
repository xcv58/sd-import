import Foundation
import ServiceManagement

enum LoginItemController {
    static let identifier = "com.xcv58.SDImport.Agent"

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.loginItem(identifier: identifier)
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}

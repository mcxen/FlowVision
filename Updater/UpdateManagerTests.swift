import Foundation

@main
struct UpdateManagerTests {
    static func main() {
        let valid = URL(string: "https://github.com/mcxen/flowvision/releases/tag/v1.7.6")!
        precondition(FlowVisionUpdateManager.version(fromReleaseURL: valid) == "1.7.6")

        let malformed = URL(string: "https://github.com/mcxen/flowvision/releases/latest")!
        precondition(FlowVisionUpdateManager.version(fromReleaseURL: malformed) == nil)

        precondition(FlowVisionUpdateManager.isVersion("1.10.0", newerThan: "1.9.9"))
        precondition(FlowVisionUpdateManager.isVersion("2.0", newerThan: "1.99.99"))
        precondition(!FlowVisionUpdateManager.isVersion("1.7.6", newerThan: "1.7.6"))
        precondition(!FlowVisionUpdateManager.isVersion("1.7.5", newerThan: "1.7.6"))

        print("UpdateManager version tests passed")
    }
}

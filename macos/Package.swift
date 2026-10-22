// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMultiAccounts",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "claude-multi-accounts", targets: ["claude-multi-accounts"]),
        .executable(name: "ClaudeMultiAccounts", targets: ["ClaudeMultiAccounts"]),
    ],
    targets: [
        .target(name: "MultiAccountsCore"),
        .executableTarget(name: "claude-multi-accounts", dependencies: ["MultiAccountsCore"]),
        .executableTarget(name: "ClaudeMultiAccounts", dependencies: ["MultiAccountsCore"]),
        .testTarget(name: "MultiAccountsCoreTests", dependencies: ["MultiAccountsCore"]),
    ]
)

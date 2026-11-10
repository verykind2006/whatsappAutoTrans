// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AutoTrans",
    platforms: [.macOS(.v14)],
    // 本地翻译：与 vInput 项目同一个 MLX 版本（exact，API 在小版本间变过）。
    // 注意：含 MLX 后必须用 xcodebuild 构建，swift build 编译不了 Metal 着色器（见 build.sh）。
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.29.1"),
        // 语音消息转文字：与 vInput 相同的 WhisperKit 版本
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "AutoTrans",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/AutoTrans",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageModes: [.v5]
)

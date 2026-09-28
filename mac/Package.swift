// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Liana",                 // 可执行/进程名 = Dock 显示名(dev 模式 swift run 取二进制名);Bundle ID 仍 com.voiceflow.mac(存设置的域,别动)
            path: "Sources/VoiceFlow",
            linkerSettings: [

                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "LianaTests",
            dependencies: ["Liana"]
        )
    ]
)

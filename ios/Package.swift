// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ARTOFFICECore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ARTOFFICECore", targets: ["ARTOFFICECore"])],
    targets: [
        .target(name: "ARTOFFICECore", path: "Core"),
        .testTarget(name: "ARTOFFICECoreTests", dependencies: ["ARTOFFICECore"], path: "CoreTests")
    ]
)

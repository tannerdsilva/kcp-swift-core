// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "kcp-swift-core",
	platforms:[
		.macOS(.v15)
	],
    products: [
		.library(name: "kcp-swift", targets: ["kcp-swift"]),
    ],
    targets: [
		.target(
			name: "kcp-swift",
		),
        .testTarget(
            name: "kcp-swiftTests",
            dependencies: ["kcp-swift"]
        ),
    ]
)

// swift-tools-version:5.8

import PackageDescription

let package = Package(
	name: "UniSocket",
  // platforms: [.macOS(.v10_15)],
  platforms: [.macOS(.v13)],

	products: [
		.library(name: "UniSocket", targets: ["UniSocket"])
	],
	dependencies: [
		.package(url: "https://github.com/Bouke/DNS.git", from: "1.2.0")
	],
	targets: [
		.target(name: "UniSocket"),
		.testTarget(name: "UniSocketTests", dependencies: ["UniSocket", "DNS"])
	]
	// swiftLanguageVersions: [.v5]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "TransitCore",
	platforms: [.iOS("26.0"), .macOS(.v14)],
	products: [.library(name: "TransitCore", targets: ["TransitCore"])],
	targets: [
		.target(name: "TransitCore"),
		.testTarget(name: "TransitCoreTests", dependencies: ["TransitCore"], resources: [.copy("Fixtures")])
	]
)

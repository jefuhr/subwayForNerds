// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "FleetOffline",
	platforms: [.iOS("26.0"), .macOS(.v14)],
	products: [.library(name: "FleetOffline", targets: ["FleetOffline"])],
	dependencies: [.package(path: "../TransitCore")],
	targets: [
		.systemLibrary(name: "CSQLite"),
		.target(name: "FleetOffline", dependencies: ["CSQLite", "TransitCore"]),
		.testTarget(name: "FleetOfflineTests", dependencies: ["FleetOffline", "CSQLite", "TransitCore"])
	]
)

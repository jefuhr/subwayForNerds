import Foundation
import TransitCore

/// One fleet download, from the first byte to the saved copy becoming active.
public struct FleetDownloadProgress: Sendable, Equatable {
	public enum Stage: Int, Sendable, CaseIterable {
		case downloading, verifying, importing, checking, activating

		// Each stage's share of the bar, estimated from device timings: the download
		// dominates, then importing records. Byte counts within a stage are exact.
		private static let widths: [Double] = [0.6, 0.05, 0.27, 0.07, 0.01]
		var start: Double { Self.widths.prefix(rawValue).reduce(0, +) }
		var width: Double { Self.widths[rawValue] }
		var label: String {
			switch self {
			case .downloading: "Downloading the fleet pack"
			case .verifying: "Verifying the download checksum"
			case .importing: "Importing fleet records"
			case .checking: "Checking the saved database"
			case .activating: "Switching to the new fleet copy"
			}
		}
	}
	public var stage: Stage
	public var completedBytes: Int64
	/// Zero for a stage measured without bytes.
	public var totalBytes: Int64
	public init(stage: Stage, completedBytes: Int64, totalBytes: Int64) {
		self.stage = stage; self.completedBytes = completedBytes; self.totalBytes = totalBytes
	}

	public var fraction: Double {
		stage.start + stage.width * (totalBytes > 0 ? min(1, Double(max(0, completedBytes)) / Double(totalBytes)) : 0)
	}

	public var load: LoadProgress {
		let bytes = totalBytes > 0 ? " · \(TransferProgress.bytes(min(completedBytes, totalBytes))) of \(TransferProgress.bytes(totalBytes))" : ""
		return LoadProgress(fraction: fraction, detail: "Step \(stage.rawValue + 1) of \(Stage.allCases.count) · \(stage.label)\(bytes)", estimated: true)
	}
}

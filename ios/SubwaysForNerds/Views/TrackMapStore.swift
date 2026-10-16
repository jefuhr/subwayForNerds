import Foundation
import Observation
import PDFKit
import TransitCore

/// The bundled map artwork and its validated topology, ready to draw.
@MainActor
final class TrackMapAssets {
	let document: PDFDocument
	let page: PDFPage
	let transform: TrackMapPageTransform
	let session: TrackMapSession
	init(document: PDFDocument, page: PDFPage, transform: TrackMapPageTransform, session: TrackMapSession) {
		self.document = document; self.page = page; self.transform = transform; self.session = session
	}
}

enum TrackMapAssetState {
	case notLoaded
	case loading
	case unavailable(String)
	case ready(TrackMapAssets)
}

/// Owns the map for the whole app session, so its viewport, filters and last
/// positions survive tab switches. The map files are optional: without them only
/// the Map tab explains that it is unavailable.
@MainActor @Observable
final class TrackMapStore {
	private(set) var state = TrackMapAssetState.notLoaded
	/// The endpoint whose trains the session holds.
	@ObservationIgnored private var sessionEndpoint: String?
	@ObservationIgnored private let bundle: Bundle
	/// UI tests pin the clock; markers then sample the same instant as the rest of the app.
	@ObservationIgnored private let fixedNow = ProcessInfo.processInfo.environment["SFN_TEST_NOW"].flatMap(Double.init)

	init(bundle: Bundle = .main) { self.bundle = bundle }

	var assets: TrackMapAssets? { if case .ready(let assets) = state { assets } else { nil } }
	func now() -> TimeInterval { fixedNow ?? Date().timeIntervalSince1970 }

	func loadIfNeeded() async {
		guard case .notLoaded = state else { return }
		state = .loading
		guard let topologyURL = Self.resource(TrackMapContract.topologyResource, "json", in: bundle),
			let pdfURL = Self.resource(TrackMapContract.pdfResource, "pdf", in: bundle) else {
			state = .unavailable(TrackMapError.assetsMissing.localizedDescription)
			return
		}
		// Reading, hashing and decoding stay off the main thread.
		let loaded = await Task.detached(priority: .userInitiated) { () -> Result<(TrackMapIndex, Data), Error> in
			Result {
				let pdf = try Data(contentsOf: pdfURL, options: .mappedIfSafe)
				let topology = try JSONDecoder().decode(TrackMapTopology.self, from: Data(contentsOf: topologyURL))
				return (try TrackMapIndex(topology: topology, pdfDigest: TrackMapDigest.sha256Hex(pdf)), pdf)
			}
		}.value
		switch loaded {
		case .failure(let error):
			state = .unavailable((error as? TrackMapError)?.localizedDescription ?? "The bundled track map data could not be read.")
		case .success(let (index, data)):
			guard let document = PDFDocument(data: data), document.pageCount == 1, let page = document.page(at: 0) else {
				state = .unavailable("The bundled track map could not be opened.")
				return
			}
			do {
				let transform = try TrackMapPageTransform(cropBox: page.bounds(for: .cropBox), rotation: page.rotation, page: index.topology.page)
				state = .ready(TrackMapAssets(document: document, page: page, transform: transform, session: TrackMapSession(index: index)))
			} catch {
				state = .unavailable((error as? TrackMapError)?.localizedDescription ?? "The bundled track map has an unexpected layout.")
			}
		}
	}

	/// Trains belong to one endpoint; switching endpoints clears them before the next poll.
	func prepare(endpoint: String) {
		guard let session = assets?.session, sessionEndpoint != endpoint else { return }
		if sessionEndpoint != nil { session.reset() }
		sessionEndpoint = endpoint
	}

	/// Synchronized groups may copy the folder or flatten its files into the bundle root.
	static func resource(_ name: String, _ ext: String, in bundle: Bundle) -> URL? {
		for directory in [TrackMapContract.resourceDirectory, "Resources/\(TrackMapContract.resourceDirectory)"] {
			if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: directory) { return url }
		}
		return bundle.url(forResource: name, withExtension: ext)
	}
}

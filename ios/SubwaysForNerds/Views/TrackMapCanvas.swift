import PDFKit
import SwiftUI
import TransitCore
import UIKit

/// What the overlay draws, from the SwiftUI side.
struct TrackMapOverlayInput {
	var snapshot: TrackMapAcceptedSnapshot?
	var routes: Set<String> = []
	var frozenAt: TimeInterval?
	var reduceMotion = false
	/// The map tab is selected, its root is on screen and the scene is active.
	var visible = false
	/// Map points to ring, such as a searched station.
	var highlights: [TrackMapPoint] = []
	var background = UIColor.systemBackground
	var accent = UIColor.tintColor
}

/// Lets SwiftUI controls move the map without owning the UIKit view.
@MainActor
final class TrackMapCanvasController {
	fileprivate weak var view: TrackMapCanvasView?
	func fit() { view?.fit() }
	func focus(_ rect: TrackMapRect) { view?.focus(rect) }
	/// The part of the map on screen, in top-left map coordinates.
	var visibleRect: TrackMapRect? { view?.visibleMapRect }
}

/// The original PDF in PDFKit, which renders only the tiles in view at the current
/// scale, with trains drawn in a separate overlay above it.
struct TrackMapCanvas: UIViewRepresentable {
	let assets: TrackMapAssets
	let controller: TrackMapCanvasController
	let input: TrackMapOverlayInput
	let initialFocus: TrackMapRect?
	let now: @MainActor () -> TimeInterval
	let onSelect: @MainActor ([String]) -> Void

	func makeUIView(context: Context) -> TrackMapCanvasView {
		let view = TrackMapCanvasView(assets: assets, initialFocus: initialFocus, now: now)
		controller.view = view
		view.onSelect = onSelect
		view.update(input)
		return view
	}

	func updateUIView(_ view: TrackMapCanvasView, context: Context) {
		controller.view = view
		view.onSelect = onSelect
		view.update(input)
	}

	static func dismantleUIView(_ view: TrackMapCanvasView, coordinator: ()) { view.stopTimers() }
}

/// A train placed in view coordinates for one frame.
struct TrackMapPlacedMarker {
	let key: String
	let route: String
	let center: CGPoint
	/// View-space heading in radians, when the motion path gives one.
	let angle: CGFloat?
	let positionCertainty: TrackMapPositionCertainty
	let stale: Bool
	let label: String
}

/// PDFKit calls its delegate on the main thread.
final class TrackMapCanvasView: UIView, @preconcurrency PDFViewDelegate, UIGestureRecognizerDelegate {
	/// At or beyond this PDF scale, trains with a heading draw as track-aligned shapes.
	static let closeZoom: CGFloat = 0.45
	static let maxZoom: CGFloat = 4
	static let hitRadius: Double = 22

	private let pdfView = PDFView()
	private let overlay = TrackMapOverlayView()
	private let assets: TrackMapAssets
	private let initialFocus: TrackMapRect?
	private let now: @MainActor () -> TimeInterval
	private var input = TrackMapOverlayInput()
	private weak var scrollView: UIScrollView?
	private var observations: [NSKeyValueObservation] = []
	private var configuredSize = CGSize.zero
	private var layoutGeneration = 0
	private var hasConfigured = false
	/// Set while the canvas itself moves the view, so layout passes do not overwrite the saved viewport.
	private var restoring = false
	private var displayLink: CADisplayLink?
	private var ticker: Timer?
	private var lastAccessibilityUpdate: TimeInterval = 0
	/// Whether a marker in view moved in the last frame.
	private var animatingInView = false
	private var foreground = UIApplication.shared.applicationState == .active
	var onSelect: (@MainActor ([String]) -> Void)?

	init(assets: TrackMapAssets, initialFocus: TrackMapRect?, now: @escaping @MainActor () -> TimeInterval) {
		self.assets = assets
		self.initialFocus = initialFocus
		self.now = now
		super.init(frame: .zero)
		pdfView.document = assets.document
		pdfView.displayMode = .singlePage
		pdfView.displayDirection = .vertical
		pdfView.displaysPageBreaks = false
		pdfView.pageShadowsEnabled = false
		pdfView.autoScales = false
		pdfView.delegate = self
		overlay.isUserInteractionEnabled = false
		overlay.isOpaque = false
		overlay.contentMode = .redraw
		overlay.onActivate = { [weak self] key in self?.onSelect?([key]) }
		addSubview(pdfView)
		addSubview(overlay)
		let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
		tap.cancelsTouchesInView = false
		tap.delegate = self
		addGestureRecognizer(tap)
		NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: .PDFViewScaleChanged, object: pdfView)
		NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: .PDFViewPageChanged, object: pdfView)
		NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(resignedActive), name: UIApplication.willResignActiveNotification, object: nil)
		accessibilityIdentifier = "track-map-canvas"
		accessibilityLabel = "Track map"
		accessibilityContainerType = .semanticGroup
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

	func update(_ value: TrackMapOverlayInput) {
		input = value
		pdfView.backgroundColor = value.background
		overlay.accent = value.accent
		redraw(updateAccessibility: true)
		scheduleUpdates()
	}

	// MARK: Layout and viewport

	override func layoutSubviews() {
		super.layoutSubviews()
		let sizeChanged = configuredSize != bounds.size && bounds.width > 0 && bounds.height > 0
		// Changing PDFView's frame can synchronously change its scroll offset.
		// Preserve the old map center before KVO sees that intermediate layout.
		let saved = assets.session.viewport
		if sizeChanged { restoring = true }
		pdfView.frame = bounds
		overlay.frame = bounds
		attachScrollView()
		guard sizeChanged else { redraw(updateAccessibility: false); return }
		// Rotation and split-view resizes keep the same center and zoom; the first layout restores
		// the viewport from an earlier visit, or focuses the selected station, or fits the map.
		configuredSize = bounds.size
		hasConfigured = true
		updateScaleLimits()
		if let saved { restore(saved) }
		else if let focus = initialFocus { self.focus(focus) }
		else { fit() }
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		scheduleUpdates()
	}

	private func attachScrollView() {
		guard scrollView == nil, let found = Self.firstScrollView(in: pdfView) else { return }
		// SwiftUI already sizes this canvas around navigation and keyboard insets.
		// UIKit's automatic adjustment otherwise moves the PDF again on return.
		found.contentInsetAdjustmentBehavior = .never
		scrollView = found
		observations = [
			found.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.viewportChanged() } },
			found.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.viewportChanged() } }
		]
	}

	private static func firstScrollView(in view: UIView) -> UIScrollView? {
		for subview in view.subviews {
			if let scroll = subview as? UIScrollView { return scroll }
			if let nested = firstScrollView(in: subview) { return nested }
		}
		return nil
	}

	private var fitScale: CGFloat {
		let page = assets.page.bounds(for: .cropBox)
		guard page.width > 0, page.height > 0 else { return 1 }
		return min(bounds.width / page.width, bounds.height / page.height)
	}

	private func updateScaleLimits() {
		let fit = fitScale
		pdfView.minScaleFactor = fit * 0.9
		pdfView.maxScaleFactor = max(Self.maxZoom, fit)
	}

	private func clampedScale(_ value: Double) -> CGFloat { min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, CGFloat(value))) }

	func fit() {
		guard bounds.width > 0 else { return }
		restore(TrackMapViewport(center: assets.session.index.pageRect.center, zoom: Double(fitScale)))
	}

	func focus(_ rect: TrackMapRect) {
		guard bounds.width > 0, rect.width > 0, rect.height > 0 else { return }
		restore(TrackMapViewport(center: rect.center, zoom: Double(min(bounds.width / rect.width, bounds.height / rect.height))))
	}

	private func restore(_ viewport: TrackMapViewport) {
		let target = TrackMapViewport(center: viewport.center, zoom: Double(clampedScale(viewport.zoom)))
		// Search can dismiss the keyboard while changing scale. Save the intended
		// viewport before PDFKit emits intermediate offsets, then center after its
		// document layout. A newer resize or command supersedes this callback.
		restoring = true
		assets.session.viewport = target
		layoutGeneration += 1
		let generation = layoutGeneration
		pdfView.scaleFactor = CGFloat(target.zoom)
		DispatchQueue.main.async { [weak self] in
			guard let self, self.layoutGeneration == generation else { return }
			self.center(on: target.center)
			self.restoring = false
			self.recordViewport()
			self.redraw(updateAccessibility: true)
		}
	}

	private func center(on point: TrackMapPoint) {
		pdfView.layoutIfNeeded()
		let target = pdfView.convert(assets.transform.pdfPoint(point), from: assets.page)
		guard let scrollView else {
			let size = CGSize(width: bounds.width / pdfView.scaleFactor, height: bounds.height / pdfView.scaleFactor)
			let pdf = assets.transform.pdfPoint(point)
			pdfView.go(to: CGRect(x: pdf.x - size.width / 2, y: pdf.y - size.height / 2, width: size.width, height: size.height), on: assets.page)
			return
		}
		let inset = scrollView.adjustedContentInset
		var offset = scrollView.contentOffset
		offset.x += target.x - pdfView.bounds.midX
		offset.y += target.y - pdfView.bounds.midY
		offset.x = min(max(offset.x, -inset.left), max(-inset.left, scrollView.contentSize.width - scrollView.bounds.width + inset.right))
		offset.y = min(max(offset.y, -inset.top), max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom))
		scrollView.setContentOffset(offset, animated: false)
	}

	var visibleMapRect: TrackMapRect { assets.transform.mapRect(pdfView.convert(pdfView.bounds, to: assets.page)) }

	@objc private func viewportChanged() {
		recordViewport()
		redraw(updateAccessibility: false)
	}

	private func recordViewport() {
		guard hasConfigured, !restoring, bounds.width > 0, pdfView.scaleFactor > 0 else { return }
		let center = assets.transform.mapPoint(pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: assets.page))
		guard center.isFinite else { return }
		let viewport = TrackMapViewport(center: center, zoom: Double(pdfView.scaleFactor))
		if assets.session.viewport != viewport { assets.session.viewport = viewport }
		accessibilityValue = viewport.accessibilityValue
	}

	// MARK: Markers

	private func placedMarkers() -> (markers: [TrackMapPlacedMarker], animating: Bool) {
		guard let snapshot = input.snapshot else { return ([], false) }
		let conditions = TrackMapConditions(now: now(), animationAllowed: !input.reduceMotion, frozenAt: input.frozenAt)
		let visible = bounds.insetBy(dx: -40, dy: -40)
		var animating = false
		let markers: [TrackMapPlacedMarker] = TrackMapPresenter.states(snapshot, conditions: conditions, routes: input.routes).compactMap { state in
			guard let point = state.point else { return nil }
			let center = viewPoint(point)
			guard visible.contains(center) else { return nil }
			if state.animating { animating = true }
			var angle: CGFloat?
			if let heading = state.heading {
				// Convert a short step along the heading, so the PDF's flipped axis is handled once.
				let ahead = viewPoint(TrackMapPoint(x: point.x + cos(heading) * 10, y: point.y + sin(heading) * 10))
				angle = atan2(ahead.y - center.y, ahead.x - center.x)
			}
			return TrackMapPlacedMarker(key: state.id, route: state.train.route, center: center, angle: angle, positionCertainty: state.positionCertainty, stale: state.freshness != .live, label: state.accessibilityLabel)
		}
		return (markers, animating)
	}

	private func viewPoint(_ point: TrackMapPoint) -> CGPoint { pdfView.convert(assets.transform.pdfPoint(point), from: assets.page) }

	private func redraw(updateAccessibility: Bool) {
		guard hasConfigured else { return }
		let placed = placedMarkers()
		overlay.markers = placed.markers
		animatingInView = placed.animating
		overlay.highlights = input.highlights.map(viewPoint)
		// Draw reviewed slow-zone paths below train markers. The clock runs for any
		// accepted snapshot, including snapshots with no trains and Reduce Motion.
		overlay.slowZonePaths = TrackMapSlowZonePresenter.state(input.snapshot, now: now(), routes: input.routes, frozenAt: input.frozenAt)
			.highlightedPaths.map { $0.map(viewPoint) }
		overlay.closeZoom = pdfView.scaleFactor >= Self.closeZoom
		overlay.setNeedsDisplay()
		let time = ProcessInfo.processInfo.systemUptime
		if updateAccessibility || time - lastAccessibilityUpdate >= 1 {
			lastAccessibilityUpdate = time
			overlay.updateAccessibilityElements()
		}
	}

	/// A display link runs only while a marker in view is moving; otherwise a one-second
	/// tick fades stale markers, removes expired ones and notices trains moving into view.
	private func scheduleUpdates() {
		switch TrackMapRenderClock.mode(visible: input.visible && window != nil, foreground: foreground, hasSnapshot: input.snapshot != nil, animating: animatingInView, reduceMotion: input.reduceMotion) {
		case .stopped:
			stopTimers()
		case .frames:
			ticker?.invalidate(); ticker = nil
			guard displayLink == nil else { return }
			let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
			link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
			link.add(to: .main, forMode: .common)
			displayLink = link
		case .seconds:
			displayLink?.invalidate(); displayLink = nil
			guard ticker == nil else { return }
			ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
		}
	}

	@objc private func displayLinkFired() { tick() }

	@objc private func becameActive() {
		foreground = true
		tick()
	}

	@objc private func resignedActive() {
		foreground = false
		stopTimers()
	}

	private func tick() {
		redraw(updateAccessibility: false)
		scheduleUpdates()
	}

	func stopTimers() {
		displayLink?.invalidate(); displayLink = nil
		ticker?.invalidate(); ticker = nil
	}

	// MARK: Input

	@objc private func tapped(_ recognizer: UITapGestureRecognizer) {
		let location = recognizer.location(in: overlay)
		let keys = TrackMapOverlap.hits(at: location, candidates: overlay.markers.map { ($0.key, $0.center) }, radius: Self.hitRadius)
		if !keys.isEmpty { onSelect?(keys) }
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

	/// Links in the artwork never open a browser.
	func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}
}

/// Draws trains in route colors. The outline says how certain the position is: solid
/// when reported, dashed when estimated, and a wide halo when only the nearby stop is known.
final class TrackMapOverlayView: UIView {
	var markers: [TrackMapPlacedMarker] = []
	private var markerElements: [String: TrackMapMarkerElement] = [:]
	var highlights: [CGPoint] = []
	var slowZonePaths: [[CGPoint]] = []
	var closeZoom = false
	var accent = UIColor.tintColor
	var onActivate: ((String) -> Void)?

	override func draw(_ rect: CGRect) {
		guard let context = UIGraphicsGetCurrentContext() else { return }
		for points in slowZonePaths {
			guard let first = points.first else { continue }
			let path = UIBezierPath()
			path.move(to: first)
			for point in points.dropFirst() { path.addLine(to: point) }
			path.lineCapStyle = .round
			path.lineJoinStyle = .round
			// A translucent amber halo keeps the reviewed rail visible at every zoom.
			UIColor.systemOrange.withAlphaComponent(0.28).setStroke()
			path.lineWidth = 11
			path.stroke()
			UIColor(trackMapRGB: 0xD97706).withAlphaComponent(0.9).setStroke()
			path.lineWidth = 4
			path.stroke()
		}
		for point in highlights {
			context.setStrokeColor(accent.cgColor)
			context.setLineWidth(3)
			context.strokeEllipse(in: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36))
		}
		for marker in markers where rect.insetBy(dx: -40, dy: -40).contains(marker.center) { draw(marker, in: context) }
	}

	private func draw(_ marker: TrackMapPlacedMarker, in context: CGContext) {
		let fill = UIColor(trackMapRGB: TrackMapRoutes.color(marker.route))
		let ink: UIColor = TrackMapRoutes.darkInk(marker.route) ? .black : .white
		context.saveGState()
		context.setAlpha(marker.stale ? 0.5 : 1)
		if marker.positionCertainty == .nearStop {
			context.setFillColor(fill.withAlphaComponent(0.22).cgColor)
			context.fillEllipse(in: CGRect(x: marker.center.x - 17, y: marker.center.y - 17, width: 34, height: 34))
		}
		let outline: [CGFloat] = marker.positionCertainty == .reported ? [] : [3, 2]
		context.translateBy(x: marker.center.x, y: marker.center.y)
		if let angle = marker.angle {
			context.saveGState()
			context.rotate(by: angle)
			let body: UIBezierPath
			if closeZoom {
				// A train-shaped capsule along the track, with its nose toward the direction of travel.
				body = UIBezierPath(roundedRect: CGRect(x: -16, y: -6, width: 28, height: 12), cornerRadius: 4)
				body.move(to: CGPoint(x: 12, y: -6)); body.addLine(to: CGPoint(x: 19, y: 0)); body.addLine(to: CGPoint(x: 12, y: 6)); body.close()
			} else {
				// A route-colored disc with a pointer in the direction of travel.
				body = UIBezierPath(ovalIn: CGRect(x: -8, y: -8, width: 16, height: 16))
				body.move(to: CGPoint(x: 7, y: -5)); body.addLine(to: CGPoint(x: 13, y: 0)); body.addLine(to: CGPoint(x: 7, y: 5)); body.close()
			}
			stroke(body, fill: fill, dash: outline, in: context)
			context.restoreGState()
		} else {
			stroke(UIBezierPath(ovalIn: CGRect(x: -8, y: -8, width: 16, height: 16)), fill: fill, dash: outline, in: context)
		}
		let text = Display.displayRoute(marker.route) as NSString
		let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .black), .foregroundColor: ink]
		let size = text.size(withAttributes: attributes)
		text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
		context.restoreGState()
	}

	private func stroke(_ path: UIBezierPath, fill: UIColor, dash: [CGFloat], in context: CGContext) {
		fill.setFill()
		path.fill()
		UIColor.white.setStroke()
		path.lineWidth = 1.5
		path.setLineDash(dash, count: dash.count, phase: 0)
		path.stroke()
	}

	/// VoiceOver reaches the trains nearest the middle of the view; the visible-trains list has them all.
	func updateAccessibilityElements() {
		let middle = CGPoint(x: bounds.midX, y: bounds.midY)
		let onScreen = markers.filter { bounds.contains($0.center) }
			.sorted { hypot($0.center.x - middle.x, $0.center.y - middle.y) < hypot($1.center.x - middle.x, $1.center.y - middle.y) }
			.prefix(40)
		var retained: [String: TrackMapMarkerElement] = [:]
		accessibilityElements = onScreen.map { marker in
			// Keep a train's accessibility identity while it remains in view. Replacing
			// it on every tick can invalidate VoiceOver focus and in-flight AX queries.
			let element = markerElements[marker.key] ?? TrackMapMarkerElement(accessibilityContainer: self)
			retained[marker.key] = element
			element.accessibilityLabel = marker.label
			element.accessibilityIdentifier = "track-map-marker-\(marker.key)"
			element.accessibilityTraits = .button
			element.accessibilityFrameInContainerSpace = CGRect(x: marker.center.x - 22, y: marker.center.y - 22, width: 44, height: 44)
			let key = marker.key
			element.activate = { [weak self] in self?.onActivate?(key) }
			return element
		}
		markerElements = retained
	}
}

private final class TrackMapMarkerElement: UIAccessibilityElement {
	var activate: (() -> Void)?
	override func accessibilityActivate() -> Bool {
		activate?()
		return activate != nil
	}
}

extension UIColor {
	convenience init(trackMapRGB rgb: UInt32) {
		self.init(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
	}
}

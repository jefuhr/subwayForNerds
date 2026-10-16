// Local analysis only. Preserve the source artwork's distribution restrictions.
import Foundation
import PDFKit
import CoreGraphics
import AppKit

struct GraphicsState {
	var transform = CGAffineTransform.identity
	var width: Double = 1
	var stroke: [Double] = [0]
	var fill: [Double] = [0]
	var dash: [Double] = []
	var strokeComponents = 3
	var fillComponents = 3
}
final class Extraction {
	var state = GraphicsState()
	var stack: [GraphicsState] = []
	var commands: [[String: Any]] = []
	var paths: [[String: Any]] = []
	var counts: [String: Int] = [:]
	var height: Double = 0
	var origin = CGPoint.zero
	func point(_ x: Double, _ y: Double) -> [Double] {
		let p = CGPoint(x: x, y: y).applying(state.transform)
		return [p.x - origin.x, height - (p.y - origin.y)]
	}
}
func pop(_ scanner: CGPDFScannerRef, _ count: Int) -> [Double] {
	var values: [Double] = []
	for _ in 0..<count { var value: CGPDFReal = 0; guard CGPDFScannerPopNumber(scanner, &value) else { fatalError("Missing numeric PDF operand") }; values.insert(Double(value), at: 0) }
	return values
}
func handle(_ scanner: CGPDFScannerRef, _ raw: UnsafeMutableRawPointer?, _ op: String) {
	let e = Unmanaged<Extraction>.fromOpaque(raw!).takeUnretainedValue()
	e.counts[op, default: 0] += 1
	switch op {
	case "q": e.stack.append(e.state)
	case "Q": guard let s = e.stack.popLast() else { fatalError("Unbalanced PDF graphics state") }; e.state = s
	case "cm": let n = pop(scanner, 6); e.state.transform = CGAffineTransform(a:n[0],b:n[1],c:n[2],d:n[3],tx:n[4],ty:n[5]).concatenating(e.state.transform)
	case "w": e.state.width = pop(scanner, 1)[0]
	case "CS", "cs":
		var name: UnsafePointer<CChar>?; CGPDFScannerPopName(scanner,&name)
		guard let name else { fatalError("Missing color space") }
		let space=String(cString:name)
		// This hash-locked source uses ICC RGB CS0 only. Refuse an unsupported space.
		guard ["CS0","DeviceRGB","DeviceGray","DeviceCMYK"].contains(space) else { fatalError("Unsupported color space \(space)") }
		let components = space == "DeviceGray" ? 1 : space == "DeviceCMYK" ? 4 : 3
		if op == "CS" { e.state.strokeComponents=components } else { e.state.fillComponents=components }
	case "SCN", "SC", "scn", "sc":
		let values = pop(scanner,op.first!.isUppercase ? e.state.strokeComponents : e.state.fillComponents)
		if op.first!.isUppercase { e.state.stroke = values } else { e.state.fill = values }
	case "RG": e.state.stroke = pop(scanner,3)
	case "rg": e.state.fill = pop(scanner,3)
	case "K": e.state.stroke = pop(scanner,4)
	case "k": e.state.fill = pop(scanner,4)
	case "G": e.state.stroke = pop(scanner,1)
	case "g": e.state.fill = pop(scanner,1)
	case "d":
		_ = pop(scanner,1); var a: CGPDFArrayRef?; CGPDFScannerPopArray(scanner,&a)
		e.state.dash = []
		if let a { for i in 0..<CGPDFArrayGetCount(a) { var v: CGPDFReal = 0; CGPDFArrayGetNumber(a,i,&v); e.state.dash.append(v) } }
	case "m", "l": let n = pop(scanner,2); e.commands.append(["op":op,"p":e.point(n[0],n[1])])
	case "c": let n = pop(scanner,6); e.commands.append(["op":op,"p":e.point(n[4],n[5]),"c1":e.point(n[0],n[1]),"c2":e.point(n[2],n[3])])
	case "v", "y": let n = pop(scanner,4); e.commands.append(["op":op,"p":e.point(n[2],n[3]),"c":e.point(n[0],n[1])])
	case "re":
		let n = pop(scanner,4)
		e.commands += [["op":"m","p":e.point(n[0],n[1])],["op":"l","p":e.point(n[0]+n[2],n[1])],["op":"l","p":e.point(n[0]+n[2],n[1]+n[3])],["op":"l","p":e.point(n[0],n[1]+n[3])],["op":"h"]]
	case "h": e.commands.append(["op":"h"])
	case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
		e.paths.append(["id":e.paths.count,"paint":op,"stroke":e.state.stroke,"fill":e.state.fill,"width":e.state.width,"dash":e.state.dash,"commands":e.commands]); e.commands = []
	case "n": e.commands = []
	default: break
	}
}
let args = CommandLine.arguments
if args.count < 4 { fatalError("Usage: swift extract.swift extract|render source.pdf output.json|png [x y width height scale] [overlay.json]") }
let url = URL(fileURLWithPath:args[2])
guard let doc = PDFDocument(url:url), let page = doc.page(at:0), let cg = page.pageRef else { fatalError("Cannot open PDF") }
let box = page.bounds(for:.cropBox)
if args[1] == "render" {
	let region = args.count >= 8 ? CGRect(x:Double(args[4])!,y:Double(args[5])!,width:Double(args[6])!,height:Double(args[7])!) : CGRect(x:0,y:0,width:box.width,height:box.height)
	let scale = args.count >= 9 ? Double(args[8])! : 0.18
	let w = Int(region.width * scale), h = Int(region.height * scale)
	let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
	context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:w,height:h))
	context.scaleBy(x:scale,y:scale)
	context.translateBy(x:-region.minX-box.minX,y:-(box.height-region.maxY)-box.minY)
	context.drawPDFPage(cg)
	if args.count >= 10 {
		let overlay = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[9]))) as! [String:Any]
		context.setStrokeColor(CGColor(red:1,green:0,blue:0.8,alpha:0.85)); context.setLineWidth(2/scale)
		for edge in overlay["edges"] as? [[String:Any]] ?? [] {
			context.beginPath()
			for (i,p) in (edge["points"] as! [[String:Double]]).enumerated() { let point = CGPoint(x:p["x"]!+box.minX,y:box.height-p["y"]!+box.minY); if i == 0 {context.move(to:point)} else {context.addLine(to:point)} }; context.strokePath()
		}
		context.setFillColor(CGColor(red:0,green:0.7,blue:1,alpha:1))
		for station in overlay["stations"] as? [[String:Any]] ?? [] { let p = station["point"] as! [String:Double]; context.fillEllipse(in:CGRect(x:p["x"]!-5,y:box.height-p["y"]!-5,width:10,height:10)) }
	}
	let rep = NSBitmapImageRep(cgImage:context.makeImage()!)
	try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[3]))
} else {
	let e = Extraction(); e.height = box.height; e.origin = box.origin
	let table = CGPDFOperatorTableCreate()!
	CGPDFOperatorTableSetCallback(table, "q") { s, p in handle(s,p,"q") }
	CGPDFOperatorTableSetCallback(table, "Q") { s, p in handle(s,p,"Q") }
	CGPDFOperatorTableSetCallback(table, "cm") { s, p in handle(s,p,"cm") }
	CGPDFOperatorTableSetCallback(table, "w") { s, p in handle(s,p,"w") }
	CGPDFOperatorTableSetCallback(table, "RG") { s, p in handle(s,p,"RG") }
	CGPDFOperatorTableSetCallback(table, "rg") { s, p in handle(s,p,"rg") }
	CGPDFOperatorTableSetCallback(table, "K") { s, p in handle(s,p,"K") }
	CGPDFOperatorTableSetCallback(table, "k") { s, p in handle(s,p,"k") }
	CGPDFOperatorTableSetCallback(table, "G") { s, p in handle(s,p,"G") }
	CGPDFOperatorTableSetCallback(table, "g") { s, p in handle(s,p,"g") }
	CGPDFOperatorTableSetCallback(table, "d") { s, p in handle(s,p,"d") }
	CGPDFOperatorTableSetCallback(table, "m") { s, p in handle(s,p,"m") }
	CGPDFOperatorTableSetCallback(table, "l") { s, p in handle(s,p,"l") }
	CGPDFOperatorTableSetCallback(table, "c") { s, p in handle(s,p,"c") }
	CGPDFOperatorTableSetCallback(table, "v") { s, p in handle(s,p,"v") }
	CGPDFOperatorTableSetCallback(table, "y") { s, p in handle(s,p,"y") }
	CGPDFOperatorTableSetCallback(table, "re") { s, p in handle(s,p,"re") }
	CGPDFOperatorTableSetCallback(table, "h") { s, p in handle(s,p,"h") }
	CGPDFOperatorTableSetCallback(table, "S") { s, p in handle(s,p,"S") }
	CGPDFOperatorTableSetCallback(table, "s") { s, p in handle(s,p,"s") }
	CGPDFOperatorTableSetCallback(table, "f") { s, p in handle(s,p,"f") }
	CGPDFOperatorTableSetCallback(table, "F") { s, p in handle(s,p,"F") }
	CGPDFOperatorTableSetCallback(table, "f*") { s, p in handle(s,p,"f*") }
	CGPDFOperatorTableSetCallback(table, "B") { s, p in handle(s,p,"B") }
	CGPDFOperatorTableSetCallback(table, "B*") { s, p in handle(s,p,"B*") }
	CGPDFOperatorTableSetCallback(table, "b") { s, p in handle(s,p,"b") }
	CGPDFOperatorTableSetCallback(table, "b*") { s, p in handle(s,p,"b*") }
	CGPDFOperatorTableSetCallback(table, "n") { s, p in handle(s,p,"n") }
	CGPDFOperatorTableSetCallback(table, "Do") { s, p in handle(s,p,"Do") }
	CGPDFOperatorTableSetCallback(table, "SCN") { s, p in handle(s,p,"SCN") }
	CGPDFOperatorTableSetCallback(table, "SC") { s, p in handle(s,p,"SC") }
	CGPDFOperatorTableSetCallback(table, "scn") { s, p in handle(s,p,"scn") }
	CGPDFOperatorTableSetCallback(table, "sc") { s, p in handle(s,p,"sc") }
	CGPDFOperatorTableSetCallback(table, "CS") { s, p in handle(s,p,"CS") }
	CGPDFOperatorTableSetCallback(table, "cs") { s, p in handle(s,p,"cs") }
	let stream = CGPDFContentStreamCreateWithPage(cg)
	let scanner = CGPDFScannerCreate(stream,table,Unmanaged.passUnretained(e).toOpaque())
	guard CGPDFScannerScan(scanner) else { fatalError("PDF scan failed") }
	guard page.rotation == 0, e.stack.isEmpty else { fatalError("Unsupported page rotation or unbalanced graphics state") }
	if e.counts["Do",default:0] > 0 { fatalError("Form XObjects require recursive extraction; no extraction was written.") }
	var labels: [[String:Any]] = []
	if let selection = page.selection(for:box) {
		for line in selection.selectionsByLine() { let b = line.bounds(for:page); labels.append(["id":labels.count,"text":line.string ?? "","x":b.minX-box.minX,"y":box.height-(b.maxY-box.minY),"width":b.width,"height":b.height]) }
	}
	let output: [String:Any] = ["page":["width":box.width,"height":box.height,"rotation":page.rotation],"operators":e.counts,"paths":e.paths,"labels":labels]
	try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[3]))
	print("Extracted \(e.paths.count) painted paths and \(labels.count) labels. Operators: \(e.counts)")
}

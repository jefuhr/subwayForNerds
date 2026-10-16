// Local source inspection contact sheets. This creates no accepted annotations.
import Foundation
import PDFKit
import AppKit
import CoreText
let args=CommandLine.arguments
if args.count<5 {fatalError("Usage: swift review-atlas.swift source.pdf candidates.json extracted.json output-directory")}
let document=PDFDocument(url:URL(fileURLWithPath:args[1]))!,page=document.page(at:0)!,box=page.bounds(for:.cropBox)
let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [String:Any]
let extraction=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[3]))) as! [String:Any]
let labels=extraction["labels"] as! [[String:Any]]
let anchors=input["anchors"] as! [[String:Any]]
let columns=4,rows=6,cw=420,ch=240,perSheet=24
try FileManager.default.createDirectory(atPath:args[4],withIntermediateDirectories:true)
for first in stride(from:0,to:anchors.count,by:perSheet) {
	let width=columns*cw,height=rows*ch
	let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
	ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
	for (offset,anchor) in anchors[first..<min(first+perSheet,anchors.count)].enumerated() {
		let x=Double(offset%columns*cw),y=Double(height-(offset/columns+1)*ch)
		let p=anchor["point"] as! [String:Double],ids=anchor["labelIds"] as! [Int]
		var region=CGRect(x:p["x"]!-25,y:p["y"]!-25,width:50,height:50)
		for id in ids {let l=labels[id];region=region.union(CGRect(x:l["x"] as! Double,y:l["y"] as! Double,width:l["width"] as! Double,height:l["height"] as! Double))}
		region=region.insetBy(dx:-35,dy:-35)
		let scale=min(Double(cw-4)/region.width,Double(ch-32)/region.height,3)
		let title="\(first+offset)  \(anchor["partId"]!)  \(anchor["name"]!)"
		ctx.setFillColor(CGColor(gray:0.92,alpha:1));ctx.fill(CGRect(x:x,y:y+Double(ch-28),width:Double(cw),height:28))
		let str=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.black])
		ctx.textPosition=CGPoint(x:x+5,y:y+Double(ch-20));CTLineDraw(CTLineCreateWithAttributedString(str),ctx)
		ctx.saveGState();ctx.clip(to:CGRect(x:x+2,y:y+2,width:Double(cw-4),height:Double(ch-32)))
		ctx.translateBy(x:x+(Double(cw)-region.width*scale)/2,y:y+(Double(ch-30)-region.height*scale)/2)
		ctx.scaleBy(x:scale,y:scale);ctx.translateBy(x:-region.minX,y:-(box.height-region.maxY))
		ctx.drawPDFPage(page.pageRef!)
		ctx.setStrokeColor(CGColor(red:0,green:0.7,blue:1,alpha:1));ctx.setLineWidth(1.5/scale)
		ctx.strokeEllipse(in:CGRect(x:p["x"]!-4,y:box.height-p["y"]!-4,width:8,height:8))
		ctx.restoreGState()
		ctx.setStrokeColor(CGColor(gray:0.6,alpha:1));ctx.setLineWidth(1);ctx.stroke(CGRect(x:x,y:y,width:Double(cw),height:Double(ch)))
	}
	let rep=NSBitmapImageRep(cgImage:ctx.makeImage()!),path=String(format:"%@/anchors-%03d.png",args[4],first)
	try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path));print(path)
}

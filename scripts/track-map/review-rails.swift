// Local inspection only: labels candidate source paths without accepting topology.
import Foundation
import PDFKit
import AppKit
import CoreText
let args=CommandLine.arguments
if args.count != 8 { fatalError("Usage: swift review-rails.swift source.pdf extracted.json output.png x y width height") }
let doc=PDFDocument(url:URL(fileURLWithPath:args[1]))!,page=doc.page(at:0)!,box=page.bounds(for:.cropBox)
let extraction=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [String:Any]
let region=CGRect(x:Double(args[4])!,y:Double(args[5])!,width:Double(args[6])!,height:Double(args[7])!)
let scale=3.0,w=Int(region.width*scale),h=Int(region.height*scale)
let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:w,height:h));ctx.scaleBy(x:scale,y:scale);ctx.translateBy(x:-region.minX,y:-(box.height-region.maxY));ctx.drawPDFPage(page.pageRef!)
for p in extraction["paths"] as! [[String:Any]] {
	let width=p["width"] as! Double

	if width != 1 || p["paint"] as! String != "S" {continue}
	let commands=p["commands"] as! [[String:Any]],points=commands.compactMap{$0["p"] as? [Double]}
	guard let first=points.first else{continue}
	var b=CGRect(x:first[0],y:first[1],width:0,height:0)
	for point in points {b=b.union(CGRect(x:point[0],y:point[1],width:0,height:0))}
	let visible=points.filter{region.contains(CGPoint(x:$0[0],y:$0[1]))}
	if visible.isEmpty {continue}
	for index in Set([0,visible.count/2,visible.count-1]).sorted() {
	let x=visible[index][0],y=box.height-visible[index][1]
	ctx.setStrokeColor(CGColor(red:0,green:0.7,blue:1,alpha:1));ctx.setLineWidth(0.5);ctx.strokeEllipse(in:CGRect(x:x-2,y:y-2,width:4,height:4))
	let str=NSAttributedString(string:"\(p["id"]!)",attributes:[.font:NSFont.systemFont(ofSize:4),.foregroundColor:NSColor.magenta,.backgroundColor:NSColor.white])
	ctx.textPosition=CGPoint(x:x+3,y:y+1);CTLineDraw(CTLineCreateWithAttributedString(str),ctx)
	}
}
let rep=NSBitmapImageRep(cgImage:ctx.makeImage()!);try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[3]))

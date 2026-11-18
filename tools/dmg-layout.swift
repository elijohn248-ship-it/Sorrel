// The look of Birch's "drag to Applications" disk image, without scripting Finder.
//
//   swift tools/dmg-layout.swift background <out.png> <out@2x.png>   the window's picture, 1x and 2x
//   swift tools/dmg-layout.swift dsstore <mounted volume> <App.app>   writes <volume>/.DS_Store
//   swift tools/dmg-layout.swift dump <.DS_Store>                     prints what a .DS_Store holds (a check)
//
// tools/release.sh (make_dmg) runs the first two while the image is mounted read-write and hidden
// (hdiutil attach -nobrowse). Finder keeps a folder's window size, view, icon positions and background
// picture in that folder's .DS_Store, so writing that file ourselves gives the styled window with no Finder
// window, no AppleScript, no focus change and no Automation prompt. This follows the file format as Finder
// writes it (the same records dmgbuild writes): a "buddy allocator" file holding one B-tree of records.
// The background is named twice, as an old-style alias record and as a bookmark: Finder reads either.
import AppKit
import Foundation

// ---- Layout (points; y measured down from the top of the window's content) ----
let windowSize = (w: 600, h: 400)                 // the content area the picture is made for
let pictureHeight = 440                           // spare plain strip at the bottom, in case Finder counts
                                                  // the title bar in the window height
let windowOrigin = (x: 200, y: 140)               // where the window opens on screen
let appCentre = (x: 160, y: 168)                  // icon centres (Finder positions icons by their centre)
let applicationsCentre = (x: 440, y: 168)
let iconSize = 128.0
let textSize = 13.0
let backgroundFile = ".background/background.tiff"
// Hidden items, parked outside the window in case someone shows hidden files.
let hiddenItems = [".background", ".DS_Store", ".fseventsd", ".metadata_never_index", ".VolumeIcon.icns", ".Trashes"]

// ---- Picture: the icon's pastel tile (lavender -> sky -> mint), lightened so Finder's black labels read ----
let tileStops: [UInt32] = [0xEBDDF5, 0xCFE3F6, 0xB8EAD2]   // same as tools/make-icon.swift
let ink: UInt32 = 0x1C4F3D                                  // the leaf green
let title = "Drag Birch to Applications"
let hint = "The first time you open Birch, macOS can’t verify it, because it isn’t notarized.\nOpen System Settings ▸ Privacy & Security and click Open Anyway, once."

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func drawBackground(scale: Int, to path: String) throws {
    let w = windowSize.w, h = pictureHeight
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw Fail("couldn't make a bitmap") }
    rep.size = NSSize(width: w, height: h)        // points, so the 2x picture says 144 dpi
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    func up(_ y: Int) -> CGFloat { CGFloat(h - y) }   // AppKit draws y-up

    let wash = tileStops.map { color($0).blended(withFraction: 0.5, of: .white)! }
    NSGradient(colors: wash)!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 330)

    // Arrow from the app to Applications: a soft stroke with a rounded chevron head, one path so the
    // see-through ink isn't doubled where the head meets the shaft.
    let y = up(appCentre.y)
    let from = CGFloat(appCentre.x) + 84, to = CGFloat(applicationsCentre.x) - 84
    color(ink, alpha: 0.55).setStroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: from, y: y)); arrow.line(to: NSPoint(x: to, y: y))
    arrow.move(to: NSPoint(x: to - 16, y: y + 15)); arrow.line(to: NSPoint(x: to, y: y))
    arrow.line(to: NSPoint(x: to - 16, y: y - 15))
    arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()

    let centred = NSMutableParagraphStyle(); centred.alignment = .center; centred.lineSpacing = 3
    NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: color(ink),
        .paragraphStyle: centred,
    ]).draw(in: NSRect(x: 20, y: up(300), width: CGFloat(w - 40), height: 26))
    NSAttributedString(string: hint, attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: color(ink, alpha: 0.72), .paragraphStyle: centred,
    ]).draw(in: NSRect(x: 20, y: up(352), width: CGFloat(w - 40), height: 42))

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw Fail("couldn't encode PNG") }
    try png.write(to: URL(fileURLWithPath: path))
}

// ---- .DS_Store ----

struct Fail: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

extension Data {
    mutating func u8(_ v: UInt8) { append(v) }
    mutating func u16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func u32(_ v: UInt32) { for s in [24, 16, 8, 0] { append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    mutating func code(_ s: String) { let b = Array(s.utf8); precondition(b.count == 4); append(contentsOf: b) }
    mutating func utf16(_ s: String) { for c in s.utf16 { u16(c) } }
    mutating func padEven() { if count % 2 == 1 { append(0) } }
}

enum Value {
    case long(UInt32), type(String), blob(Data)
}
struct Record { let name: String, code: String, value: Value }

func encode(_ r: Record) -> Data {
    var d = Data()
    d.u32(UInt32(r.name.utf16.count)); d.utf16(r.name); d.code(r.code)
    switch r.value {
    case .long(let v): d.code("long"); d.u32(v)
    case .type(let t): d.code("type"); d.code(t)
    case .blob(let b): d.code("blob"); d.u32(UInt32(b.count)); d.append(b)
    }
    return d
}

func bplist(_ object: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

/// Icon location: centre x, centre y, then Finder's fixed trailer.
func iloc(_ x: Int, _ y: Int) -> Data {
    var d = Data(); d.u32(UInt32(x)); d.u32(UInt32(y)); d.append(contentsOf: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0])
    return d
}

let macEpochOffset: Double = 2_082_844_800        // seconds from 1904-01-01 to 1970-01-01

func fileID(_ path: String) throws -> UInt32 {
    var st = stat()
    guard lstat(path, &st) == 0 else { throw Fail("can't stat \(path)") }
    return UInt32(truncatingIfNeeded: st.st_ino)   // on HFS+ the inode number is the catalog node id
}

/// A classic (version 2) Alias Manager record for a file on the mounted image, laid out as Finder writes it.
func aliasRecord(volume: String, relative: String) throws -> Data {
    let fileURL = URL(fileURLWithPath: volume).appendingPathComponent(relative)
    let folderURL = fileURL.deletingLastPathComponent()
    let volumeValues = try URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeNameKey, .creationDateKey])
    guard let volName = volumeValues.volumeName, let volCreated = volumeValues.creationDate,
          let fileCreated = try fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate
    else { throw Fail("can't read the volume's name and dates") }
    let volDate = volCreated.timeIntervalSince1970 + macEpochOffset
    let fileDate = fileCreated.timeIntervalSince1970 + macEpochOffset
    let fileName = fileURL.lastPathComponent, folderName = folderURL.lastPathComponent
    let fileCNID = try fileID(fileURL.path), folderCNID = try fileID(folderURL.path)

    func pascal(_ s: String, _ size: Int) -> Data {
        let b = Array(s.replacingOccurrences(of: ":", with: "/").utf8.prefix(size - 1))
        var d = Data([UInt8(b.count)]); d.append(contentsOf: b); d.append(Data(count: size - 1 - b.count)); return d
    }
    func tag(_ t: Int16, _ body: Data, into d: inout Data) {
        d.u16(UInt16(bitPattern: t)); d.u16(UInt16(body.count)); d.append(body); d.padEven()
    }
    func unicode(_ s: String) -> Data { var b = Data(); b.u16(UInt16(s.utf16.count)); b.utf16(s); return b }

    var d = Data()
    d.append(Data(count: 4)); d.u16(0); d.u16(2)  // app creator, length (filled in below), version 2
    d.u16(0)                                      // kind: file
    d.append(pascal(volName, 28)); d.u32(UInt32(volDate))
    d.append(contentsOf: Array("H+".utf8)); d.u16(5)   // file system, disk type: ejectable
    d.u32(folderCNID); d.append(pascal(fileName, 64)); d.u32(fileCNID); d.u32(UInt32(fileDate))
    d.append(Data(count: 8))                      // creator and type codes
    d.u16(0xffff); d.u16(0xffff)                  // levels from / to: unused
    d.u32(0); d.append(Data(count: 2)); d.append(Data(count: 10))   // volume attributes, fs id, reserved
    tag(0, Data(folderName.utf8), into: &d)       // parent folder name
    var hiVol = Data(); hiVol.u64(UInt64(volDate * 65536)); tag(16, hiVol, into: &d)
    var hiFile = Data(); hiFile.u64(UInt64(fileDate * 65536)); tag(17, hiFile, into: &d)
    var cnids = Data(); cnids.u32(folderCNID); tag(1, cnids, into: &d)
    tag(2, Data("\(volName):\(folderName):\u{0}\(fileName)".utf8), into: &d)   // Carbon path, Finder's spelling
    tag(14, unicode(fileName), into: &d)
    tag(15, unicode(volName), into: &d)
    tag(18, Data("/\(relative)".utf8), into: &d)
    tag(19, Data(volume.utf8), into: &d)
    d.u16(0xffff); d.u16(0)                       // end
    d[4] = UInt8(d.count >> 8); d[5] = UInt8(d.count & 0xff)
    return d
}

func dsStore(_ records: [Record]) throws -> Data {
    // Buddy-allocated file: 4-byte prefix, then addresses relative to byte 4. Blocks (address | log2 size):
    //   0x0000/32 header · 0x0020/32 DSDB header · 0x0800/2048 allocator info (block 0) · 0x1000/4096 leaf node
    let infoAddr = 0x800, dsdbAddr = 0x20, leafAddr = 0x1000, end = 0x2000
    let sorted = records.sorted { ($0.name.lowercased(), $0.code) < ($1.name.lowercased(), $1.code) }
    var leaf = Data(); leaf.u32(0); leaf.u32(UInt32(sorted.count))
    for r in sorted { leaf.append(encode(r)) }
    guard leaf.count <= 0x1000 else { throw Fail("the records don't fit in one node (\(leaf.count) bytes)") }

    var info = Data()
    let blocks: [UInt32] = [UInt32(infoAddr | 11), UInt32(dsdbAddr | 5), UInt32(leafAddr | 12)]
    info.u32(UInt32(blocks.count)); info.u32(0)
    for i in 0..<256 { info.u32(i < blocks.count ? blocks[i] : 0) }
    info.u32(1); info.u8(4); info.code("DSDB"); info.u32(1)   // table of contents: DSDB is block 1
    // Free lists by size (2^0 ... 2^31): what a buddy allocator over 2^31 bytes has left after these blocks.
    let free: [Int: UInt32] = [6: 0x40, 7: 0x80, 8: 0x100, 9: 0x200, 10: 0x400]
    for width in 0..<32 {
        if let a = free[width] { info.u32(1); info.u32(a) }
        else if width >= 13 && width <= 30 { info.u32(1); info.u32(UInt32(1) << UInt32(width)) }
        else { info.u32(0) }
    }

    var dsdb = Data()
    dsdb.u32(2); dsdb.u32(0); dsdb.u32(UInt32(sorted.count)); dsdb.u32(1); dsdb.u32(0x1000)  // root node, levels, records, nodes, page size

    var file = Data(count: 4 + end)
    func place(_ d: Data, at addr: Int) { file.replaceSubrange((4 + addr)..<(4 + addr + d.count), with: d) }
    var header = Data()
    header.u32(1); header.code("Bud1"); header.u32(UInt32(infoAddr)); header.u32(0x800); header.u32(UInt32(infoAddr))
    header.append(contentsOf: [0, 0, 0x10, 0x0c, 0, 0, 0, 0x87, 0, 0, 0x20, 0x0b, 0, 0, 0, 0])   // as Finder writes it
    file.replaceSubrange(0..<header.count, with: header)
    place(dsdb, at: dsdbAddr); place(info, at: infoAddr); place(leaf, at: leafAddr)
    return file
}

func writeStore(volume: String, app: String) throws {
    let bg = URL(fileURLWithPath: volume).appendingPathComponent(backgroundFile)
    guard FileManager.default.fileExists(atPath: bg.path) else { throw Fail("\(bg.path) is missing") }
    let bounds = "{{\(windowOrigin.x), \(windowOrigin.y)}, {\(windowSize.w), \(windowSize.h)}}"
    let bwsp: [String: Any] = [
        "ContainerShowSidebar": false, "PreviewPaneVisibility": false, "ShowPathbar": false, "ShowSidebar": false,
        "ShowStatusBar": false, "ShowTabView": false, "ShowToolbar": false, "SidebarWidth": 0,
        "WindowBounds": bounds,
    ]
    let icvp: [String: Any] = [
        "arrangeBy": "none", "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "backgroundImageAlias": try aliasRecord(volume: volume, relative: backgroundFile), "backgroundType": 2,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": iconSize, "labelOnBottom": true,
        "showIconPreview": true, "showItemInfo": false, "textSize": textSize, "viewOptionsVersion": 1,
    ]
    let bookmark = try bg.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    var records = [
        Record(name: ".", code: "bwsp", value: .blob(try bplist(bwsp))),
        Record(name: ".", code: "icvp", value: .blob(try bplist(icvp))),
        Record(name: ".", code: "pBBk", value: .blob(bookmark)),
        Record(name: ".", code: "vSrn", value: .long(1)),
        Record(name: ".", code: "vstl", value: .type("icnv")),
        Record(name: app, code: "Iloc", value: .blob(iloc(appCentre.x, appCentre.y))),
        Record(name: "Applications", code: "Iloc", value: .blob(iloc(applicationsCentre.x, applicationsCentre.y))),
    ]
    for (i, name) in hiddenItems.enumerated() {
        records.append(Record(name: name, code: "Iloc", value: .blob(iloc(windowSize.w + 200 + 100 * i, 100))))
    }
    try dsStore(records).write(to: URL(fileURLWithPath: volume).appendingPathComponent(".DS_Store"))
}

// ---- dump: read a .DS_Store back (checks what dsstore wrote) ----

func dump(_ path: String) throws {
    let f = try Data(contentsOf: URL(fileURLWithPath: path))
    func u32(_ o: Int) -> Int { Int(f[o]) << 24 | Int(f[o + 1]) << 16 | Int(f[o + 2]) << 8 | Int(f[o + 3]) }
    func str(_ o: Int, _ n: Int) -> String { String(decoding: f[o..<(o + n)], as: UTF8.self) }
    guard u32(0) == 1, str(4, 4) == "Bud1" else { throw Fail("not a .DS_Store") }
    let info = 4 + u32(8)
    let count = u32(info)
    let offsets = (0..<count).map { u32(info + 8 + 4 * $0) }
    var o = info + 8 + 4 * ((count + 255) / 256 * 256)
    var toc: [String: Int] = [:]
    for _ in 0..<u32(o) { let n = Int(f[o + 4]); toc[str(o + 5, n)] = u32(o + 5 + n); o += 5 + n + 4 }
    guard let db = toc["DSDB"] else { throw Fail("no DSDB") }
    let dsdb = 4 + (offsets[db] & ~31)
    let root = u32(dsdb), levels = u32(dsdb + 4)
    print("dump: blocks=\(offsets.map { String(format: "0x%x", $0) }) root=\(root) levels=\(levels) records=\(u32(dsdb + 8))")
    var p = 4 + (offsets[root] & ~31)
    guard u32(p) == 0 else { throw Fail("only single-leaf stores are read here") }
    let n = u32(p + 4); p += 8
    for _ in 0..<n {
        let len = u32(p); p += 4
        var units: [UInt16] = []
        for i in 0..<len { units.append(UInt16(f[p + 2 * i]) << 8 | UInt16(f[p + 2 * i + 1])) }
        p += 2 * len
        let name = String(decoding: units, as: UTF16.self), code = str(p, 4), type = str(p + 4, 4); p += 8
        switch type {
        case "long", "shor": print("dump: \(name) \(code) \(type) \(u32(p))"); p += 4
        case "type": print("dump: \(name) \(code) type \(str(p, 4))"); p += 4
        case "bool": print("dump: \(name) \(code) bool \(f[p])"); p += 1
        case "blob":
            let size = u32(p); let blob = f[(p + 4)..<(p + 4 + size)]; p += 4 + size
            if let plist = try? PropertyListSerialization.propertyList(from: Data(blob), format: nil) as? [String: Any] {
                let shown = plist.keys.sorted().map { k -> String in
                    if let d = plist[k] as? Data { return "\(k)=<\(d.count) bytes>" }
                    return "\(k)=\(plist[k]!)"
                }
                print("dump: \(name) \(code) plist {\(shown.joined(separator: ", "))}")
            } else if code == "pBBk" {   // with the image mounted, this should name the background picture
                var stale = false
                let url = try? URL(resolvingBookmarkData: Data(blob), options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
                print("dump: \(name) pBBk bookmark \(size) bytes, resolves to \(url?.path ?? "nothing")")
            } else if code == "Iloc" {
                let b = Data(blob); print("dump: \(name) Iloc x=\(Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])) y=\(Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7]))")
            } else {
                print("dump: \(name) \(code) blob \(size) bytes")
            }
        default: throw Fail("unknown record type \(type)")
        }
    }
}

let args = CommandLine.arguments
do {
    switch (args.count > 1 ? args[1] : "", args.count) {
    case ("background", 4): try drawBackground(scale: 1, to: args[2]); try drawBackground(scale: 2, to: args[3])
    case ("dsstore", 4): try writeStore(volume: args[2], app: args[3])
    case ("dump", 3): try dump(args[2])
    default:
        FileHandle.standardError.write(Data("usage: dmg-layout.swift background <1x.png> <2x.png> | dsstore <volume> <App.app> | dump <.DS_Store>\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("dmg-layout: \(error)\n".utf8))
    exit(1)
}

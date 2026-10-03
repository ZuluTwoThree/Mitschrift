import Foundation

@main
struct ICNSMaker {
    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let entries: [(String, String)] = [
            ("icp4", "icon_16x16.png"),
            ("ic11", "icon_16x16@2x.png"),
            ("icp5", "icon_32x32.png"),
            ("ic12", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"),
            ("ic13", "icon_128x128@2x.png"),
            ("ic08", "icon_256x256.png"),
            ("ic14", "icon_256x256@2x.png"),
            ("ic09", "icon_512x512.png"),
            ("ic10", "icon_512x512@2x.png")
        ]

        var payload = Data()
        for (type, filename) in entries {
            let png = try Data(contentsOf: directory.appendingPathComponent(filename))
            payload.append(type.data(using: .ascii)!)
            appendUInt32(UInt32(png.count + 8), to: &payload)
            payload.append(png)
        }

        var result = Data("icns".utf8)
        appendUInt32(UInt32(payload.count + 8), to: &result)
        result.append(payload)
        try result.write(to: output, options: .atomic)
    }
}

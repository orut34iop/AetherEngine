import Foundation
import AetherLibavcodec
import AetherLibavutil

struct SubtitleTextPlacement {
    let alignment: Int
    let position: CGPoint?
}

/// Real shipped pgssub decoders + production packet store. Both streams deliberately
/// reuse palette/object id 0, so a shared decoder would overwrite the other role.
@main struct DualPGSDecodeStandalone {
    static func segment(_ type: UInt8, _ body: [UInt8]) -> Data {
        Data([type, UInt8(body.count >> 8), UInt8(body.count & 255)] + body)
    }
    static func pcs(x: Int, state: UInt8, clear: Bool = false) -> Data {
        var body: [UInt8] = [7, 128, 4, 56, 16, 0, 1, state, 0, 0, clear ? 0 : 1]
        if !clear { body += [0, 0, 0, 0, UInt8(x >> 8), UInt8(x & 255), 3, 132] }
        return segment(0x16, body)
    }
    static func displaySet(x: Int, luminance: UInt8) -> Data {
        let palette = segment(0x14, [0, 0, 0, 16, 128, 128, 0, 1, luminance, 128, 128, 255])
        let rle = Array(repeating: [0, 0x88, 1, 0, 0] as [UInt8], count: 8).flatMap { $0 }
        let object = segment(0x15, [0, 0, 0, 0xc0, 0, 0, 44, 0, 8, 0, 8] + rle)
        return pcs(x: x, state: 0x80) + palette + object + segment(0x80, [])
    }
    final class Decoder {
        var context: UnsafeMutablePointer<AVCodecContext>?
        init() {
            let codec = avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE)!
            context = avcodec_alloc_context3(codec)!
            context!.pointee.pkt_timebase = AVRational(num: 1, den: 90_000)
            precondition(avcodec_open2(context, codec, nil) >= 0)
        }
        deinit { avcodec_free_context(&context) }
        func decode(_ data: Data, time: Double) -> (count: UInt32, x: Int32, palette: UInt32) {
            let packet = av_packet_alloc()!
            precondition(av_new_packet(packet, Int32(data.count)) >= 0)
            data.copyBytes(to: packet.pointee.data, count: data.count)
            packet.pointee.pts = Int64(time * 90_000)
            var sub = AVSubtitle()
            var got: Int32 = 0
            let result = avcodec_decode_subtitle2(context, &sub, &got, packet)
            var optionalPacket: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&optionalPacket)
            precondition(result >= 0 && got == 1, "each complete PGS display set must decode")
            defer { avsubtitle_free(&sub) }
            precondition(abs(Double(sub.pts) / 1_000_000 - time) < 0.001)
            guard sub.num_rects > 0, let rect = sub.rects[0] else { return (0, 0, 0) }
            precondition(rect.pointee.w == 8 && rect.pointee.h == 8)
            let color = UnsafeRawPointer(rect.pointee.data.1!).assumingMemoryBound(to: UInt32.self)[1]
            return (sub.num_rects, rect.pointee.x, color)
        }
    }
    static func main() {
        let store = SubtitlePacketStore()
        let primaryPayload = displaySet(x: 100, luminance: 235)
        let secondaryPayload = displaySet(x: 300, luminance: 100)
        for (id, payload) in [(Int32(3), primaryPayload), (Int32(4), secondaryPayload)] {
            store.harvestChunk(streamIndex: id, ptsSeconds: 769, durationSeconds: 0,
                               flags: 0, payload: payload, assembleSplitDisplaySets: true)
        }
        let primary = Decoder()
        var secondary: Decoder? = Decoder()
        func packet(_ id: Int32) -> Data {
            let packets = store.entries(streamIndex: id, from: 768, through: 770)
            precondition(packets.count == 1)
            return packets[0].payload
        }
        let p = primary.decode(packet(3), time: 769)
        let s = secondary!.decode(packet(4), time: 769)
        precondition(p.count == 1 && s.count == 1 && p.x == 100 && s.x == 300)
        precondition(p.palette != s.palette, "two PGS palettes must remain independent")
        let cleared = secondary!.decode(pcs(x: 300, state: 0, clear: true) + segment(0x80, []), time: 771)
        precondition(cleared.count == 0)
        let stillPrimary = primary.decode(pcs(x: 100, state: 0) + segment(0x80, []), time: 772)
        precondition(stillPrimary.count == 1 && stillPrimary.palette == p.palette)
        secondary = nil // turning secondary off must not close primary's decoder
        let afterOff = primary.decode(pcs(x: 100, state: 0) + segment(0x80, []), time: 773)
        precondition(afterOff.count == 1)
        secondary = Decoder() // post-seek reconstruction uses each role's own cached packets
        let rebuilt = secondary!.decode(packet(4), time: 769)
        precondition(rebuilt.x == 300 && rebuilt.palette == s.palette)
        let rebuiltPrimary = Decoder().decode(packet(3), time: 769)
        precondition(rebuiltPrimary.x == 100 && rebuiltPrimary.palette == p.palette)
        print("PASS: dual PGS real decode, independent palettes/objects, clear, off, cached reconstruction")
    }
}

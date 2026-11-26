import CoreMedia
import CryptoKit
import Foundation

struct FixedDecodeFixture {
    let samples: [CMSampleBuffer]
    let format: CMFormatDescription
    let id: String
    let sha256: String

    private struct Asset {
        let codec: CMVideoCodecType
        let width: Int
        let height: Int
        let frameCount: Int
        let id: String
        let fileName: String
        let expectedSHA256: String
    }

    private enum FixtureError: LocalizedError {
        case unsupportedCodec(CMVideoCodecType)
        case unsupportedWidth(Int)
        case resourceMissing(String)
        case unreadableResource(String)
        case checksumMismatch(file: String, expected: String, actual: String)
        case invalidStream(String)
        case coreMedia(operation: String, status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedCodec(let codec):
                return String(format: "没有固定解码素材对应 codec FourCC 0x%08x", codec)
            case .unsupportedWidth(let width):
                return "没有宽度为 \(width) 的固定解码素材"
            case .resourceMissing(let name):
                return "应用资源中缺少固定解码素材 \(name)"
            case .unreadableResource(let name):
                return "无法读取固定解码素材 \(name)"
            case .checksumMismatch(let file, let expected, let actual):
                return "固定解码素材校验失败 \(file)，预期 SHA-256 \(expected)，实际 \(actual)"
            case .invalidStream(let reason):
                return "固定解码素材格式无效：\(reason)"
            case .coreMedia(let operation, let status):
                return "CoreMedia \(operation) 失败，OSStatus=\(status)"
            }
        }
    }

    private static let assets: [Asset] = [
        Asset(codec: kCMVideoCodecType_H264,
              width: 1920, height: 1080, frameCount: 120,
              id: "gpuz.h264.1080p.120f.30fps.v1",
              fileName: "h264-1080p-120f",
              expectedSHA256: "44302a9e9d2460e7a85cff47ab0cdc832668881538489d1f1bca213abd042cf5"),
        Asset(codec: kCMVideoCodecType_HEVC,
              width: 1920, height: 1080, frameCount: 120,
              id: "gpuz.hevc.1080p.120f.30fps.v1",
              fileName: "hevc-1080p-120f",
              expectedSHA256: "7cbd1c678ed0ade4ea534b9e201a5789df0b56544971977258488902c611ac5e"),
        Asset(codec: kCMVideoCodecType_H264,
              width: 3840, height: 2160, frameCount: 48,
              id: "gpuz.h264.4k.48f.30fps.v1",
              fileName: "h264-4k-48f",
              expectedSHA256: "6f846d3e50d3874ef2f32b7fcff0f8902a14895f97dac3290f059e1cae48cc2e"),
        Asset(codec: kCMVideoCodecType_HEVC,
              width: 3840, height: 2160, frameCount: 48,
              id: "gpuz.hevc.4k.48f.30fps.v1",
              fileName: "hevc-4k-48f",
              expectedSHA256: "da161736ebbe2e8b0d44ae5d8b3f7f08936a8413c8c4040688a5c62dedae5d80"),
    ]

    static func expectedEvidence(for item: String) -> (id: String, sha256: String)? {
        let asset = assets.first { asset in
            let codec = asset.codec == kCMVideoCodecType_H264 ? "H.264" : "HEVC"
            let resolution = asset.width == 1920 ? "1080p" : "4K"
            return item == "\(codec) \(resolution)"
        }
        return asset.map { ($0.id, $0.expectedSHA256) }
    }

    static func load(codec: CMVideoCodecType, width: Int = 1920,
                     bundle: Bundle = .main) throws -> FixedDecodeFixture {
        guard width == 1920 || width == 3840 else {
            throw FixtureError.unsupportedWidth(width)
        }
        guard let asset = assets.first(where: { $0.codec == codec && $0.width == width }) else {
            throw FixtureError.unsupportedCodec(codec)
        }
        let ext = codec == kCMVideoCodecType_H264 ? "h264" : "hevc"
        guard let url = bundle.url(forResource: asset.fileName, withExtension: ext,
                                   subdirectory: "CodecFixtures") else {
            throw FixtureError.resourceMissing(asset.fileName + "." + ext)
        }
        return try load(asset: asset, from: url)
    }

    static func load(codec: CMVideoCodecType, width: Int = 1920,
                     from url: URL) throws -> FixedDecodeFixture {
        guard width == 1920 || width == 3840 else {
            throw FixtureError.unsupportedWidth(width)
        }
        guard let asset = assets.first(where: { $0.codec == codec && $0.width == width }) else {
            throw FixtureError.unsupportedCodec(codec)
        }
        return try load(asset: asset, from: url)
    }

    private static func load(asset: Asset, from url: URL) throws -> FixedDecodeFixture {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw FixtureError.unreadableResource(url.lastPathComponent)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.expectedSHA256 else {
            throw FixtureError.checksumMismatch(file: url.lastPathComponent,
                                                expected: asset.expectedSHA256, actual: digest)
        }

        let parsed = try parseAnnexB(data, codec: asset.codec, expectedFrameCount: asset.frameCount)
        let description = try createFormatDescription(codec: asset.codec,
                                                      parameterSets: parsed.parameterSets,
                                                      width: asset.width,
                                                      height: asset.height)
        let samples = try parsed.accessUnits.enumerated().map { index, accessUnit in
            try createSample(accessUnit, index: index, format: description)
        }
        guard samples.count == asset.frameCount else {
            throw FixtureError.invalidStream("预期 \(asset.frameCount) 个访问单元，实际 \(samples.count) 个")
        }
        return FixedDecodeFixture(samples: samples, format: description, id: asset.id, sha256: digest)
    }

    private struct ParsedStream {
        let parameterSets: [Data]
        let accessUnits: [(data: Data, isSync: Bool)]
    }

    private static func parseAnnexB(_ data: Data, codec: CMVideoCodecType,
                                    expectedFrameCount: Int) throws -> ParsedStream {
        let bytes = [UInt8](data)
        var nals: [Data] = []
        var starts: [(offset: Int, payload: Int)] = []
        var cursor = 0
        while cursor + 3 <= bytes.count {
            if bytes[cursor] == 0 && bytes[cursor + 1] == 0 && bytes[cursor + 2] == 1 {
                starts.append((cursor, cursor + 3))
                cursor += 3
            } else if cursor + 4 <= bytes.count && bytes[cursor] == 0 && bytes[cursor + 1] == 0 &&
                      bytes[cursor + 2] == 0 && bytes[cursor + 3] == 1 {
                starts.append((cursor, cursor + 4))
                cursor += 4
            } else {
                cursor += 1
            }
        }
        guard !starts.isEmpty else { throw FixtureError.invalidStream("找不到 Annex B NAL 起始码") }

        for index in starts.indices {
            let lower = starts[index].payload
            var upper = index + 1 < starts.count ? starts[index + 1].offset : bytes.count
            while upper > lower && bytes[upper - 1] == 0 { upper -= 1 }
            guard upper > lower else { continue }
            nals.append(Data(bytes[lower..<upper]))
        }

        let isH264 = codec == kCMVideoCodecType_H264
        func nalType(_ nal: Data) -> Int {
            guard let first = nal.first else { return -1 }
            return isH264 ? Int(first & 0x1f) : Int((first >> 1) & 0x3f)
        }
        let parameterSetTypes = isH264 ? Set([7, 8]) : Set([32, 33, 34])
        var parameterSets: [Data] = []
        var accessUnits: [(data: Data, isSync: Bool)] = []
        var currentNals: [Data] = []
        var currentIsSync = false

        func finishAccessUnit() throws {
            guard !currentNals.isEmpty else { return }
            var payload = Data()
            for nal in currentNals {
                guard nal.count <= Int(UInt32.max) else {
                    throw FixtureError.invalidStream("NAL 单元超过四字节长度字段的范围")
                }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(nal)
            }
            accessUnits.append((payload, currentIsSync))
            currentNals.removeAll(keepingCapacity: true)
            currentIsSync = false
        }

        for nal in nals {
            let type = nalType(nal)
            let isAUD = isH264 ? type == 9 : type == 35
            if isAUD {
                try finishAccessUnit()
                continue
            }
            if parameterSetTypes.contains(type) {
                parameterSets.append(nal)
                continue
            }
            if isH264 ? type == 5 : (19...21).contains(type) {
                currentIsSync = true
            }
            currentNals.append(nal)
        }
        try finishAccessUnit()

        let requiredSetTypes = isH264 ? Set([7, 8]) : Set([32, 33, 34])
        let actualSetTypes = Set(parameterSets.map(nalType))
        guard requiredSetTypes.isSubset(of: actualSetTypes) else {
            throw FixtureError.invalidStream("codec 参数集不完整")
        }
        guard accessUnits.count == expectedFrameCount else {
            throw FixtureError.invalidStream("预期 \(expectedFrameCount) 个访问单元，实际 \(accessUnits.count) 个")
        }
        guard accessUnits.first?.isSync == true else {
            throw FixtureError.invalidStream("第一个访问单元不是关键帧")
        }
        return ParsedStream(parameterSets: parameterSets, accessUnits: accessUnits)
    }

    private static func createFormatDescription(codec: CMVideoCodecType,
                                                parameterSets: [Data],
                                                width: Int,
                                                height: Int) throws -> CMFormatDescription {
        let isH264 = codec == kCMVideoCodecType_H264
        let expectedTypes = isH264 ? Set([7, 8]) : Set([32, 33, 34])
        let selected = parameterSets.filter { nal in
            guard let first = nal.first else { return false }
            let type = isH264 ? Int(first & 0x1f) : Int((first >> 1) & 0x3f)
            return expectedTypes.contains(type)
        }
        guard selected.count >= expectedTypes.count else {
            throw FixtureError.invalidStream("无法从码流创建 codec format description")
        }

        let allocated = selected.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { allocated.forEach { $0.deallocate() } }
        let pointers = allocated.map { UnsafePointer($0) }
        let sizes = selected.map(\.count)
        var format: CMFormatDescription?
        let status: OSStatus
        if isH264 {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: selected.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format)
        } else {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: selected.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format)
        }
        guard status == noErr, let format else {
            throw FixtureError.coreMedia(operation: "创建视频格式说明", status: status)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == width, dimensions.height == height else {
            throw FixtureError.invalidStream("format description 分辨率预期为 \(width)×\(height)，实际为 \(dimensions.width)×\(dimensions.height)")
        }
        return format
    }

    private static func createSample(_ accessUnit: (data: Data, isSync: Bool),
                                     index: Int, format: CMFormatDescription) throws -> CMSampleBuffer {
        let data = accessUnit.data
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw FixtureError.coreMedia(operation: "创建压缩帧缓冲", status: status)
        }
        status = data.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else {
            throw FixtureError.coreMedia(operation: "复制压缩帧", status: status)
        }

        let presentationTime = CMTime(value: Int64(index), timescale: 30)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: presentationTime)
        var size = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                          dataBuffer: blockBuffer,
                                          formatDescription: format,
                                          sampleCount: 1,
                                          sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 1,
                                          sampleSizeArray: &size,
                                          sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw FixtureError.coreMedia(operation: "创建压缩样本", status: status)
        }
        if !accessUnit.isSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let pointer = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = unsafeBitCast(pointer, to: CFMutableDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            CFDictionarySetValue(dictionary, key, value)
        }
        return sampleBuffer
    }
}

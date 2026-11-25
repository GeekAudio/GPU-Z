import CoreMedia
import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func verifyFixture(codec: CMVideoCodecType, width: Int, height: Int, frameCount: Int,
                           file: String, id: String, sha256: String) throws {
    let fixture = try FixedDecodeFixture.load(codec: codec, width: width,
                                             from: URL(fileURLWithPath: file))
    check(fixture.id == id, "stable fixture ID")
    check(fixture.sha256 == sha256, "content checksum")
    check(fixture.samples.count == frameCount, "fixture has \(frameCount) samples")
    check(CMFormatDescriptionGetMediaType(fixture.format) == kCMMediaType_Video, "video format description")
    check(CMFormatDescriptionGetMediaSubType(fixture.format) == codec, "codec matches format description")
    let dimensions = CMVideoFormatDescriptionGetDimensions(fixture.format)
    check(dimensions.width == width && dimensions.height == height,
          "\(width)×\(height) format description")

    for (index, sample) in fixture.samples.enumerated() {
        check(CMSampleBufferIsValid(sample), "sample \(index) is valid")
        check(CMSampleBufferDataIsReady(sample), "sample \(index) data is ready")
        check(CMSampleBufferGetTotalSampleSize(sample) > 4, "sample \(index) has encoded data")
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        check(pts == CMTime(value: Int64(index), timescale: 30), "sample \(index) has stable 30 fps PTS")
        check(CMSampleBufferGetDuration(sample) == CMTime(value: 1, timescale: 30),
              "sample \(index) has a 1/30 second duration")
    }
    let firstAttachments = CMSampleBufferGetSampleAttachmentsArray(fixture.samples[0], createIfNecessary: false)
    check(firstAttachments == nil, "sync sample needs no NotSync attachment")
    let secondAttachments = CMSampleBufferGetSampleAttachmentsArray(fixture.samples[1], createIfNecessary: false)
    guard let secondAttachments else { check(false, "predictive sample is marked not sync"); return }
    let secondDictionary = unsafeBitCast(CFArrayGetValueAtIndex(secondAttachments, 0), to: CFDictionary.self)
    let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
    check(CFDictionaryGetValue(secondDictionary, key) == Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
          "predictive sample is marked not sync")
    print("PASS: \(id), \(frameCount) samples, SHA-256 \(fixture.sha256)")
}

private func verifyBundledFixture(codec: CMVideoCodecType, width: Int, frameCount: Int,
                                  id: String, sha256: String) throws {
    let fixture = try FixedDecodeFixture.load(codec: codec, width: width, bundle: .main)
    check(fixture.id == id, "bundle lookup stable fixture ID")
    check(fixture.sha256 == sha256, "bundle lookup checksum")
    check(fixture.samples.count == frameCount, "bundle lookup returns all \(frameCount) samples")
    print("PASS: Bundle.main resolves \(id)")
}

do {
    guard CommandLine.arguments.count == 5 else {
        fputs("Usage: fixed-decode-fixture-tests H264_1080_FILE HEVC_1080_FILE H264_4K_FILE HEVC_4K_FILE\n", stderr)
        exit(2)
    }
    try verifyFixture(codec: kCMVideoCodecType_H264, width: 1920, height: 1080, frameCount: 120,
                      file: CommandLine.arguments[1],
                      id: "gpuz.h264.1080p.120f.30fps.v1",
                      sha256: "44302a9e9d2460e7a85cff47ab0cdc832668881538489d1f1bca213abd042cf5")
    try verifyFixture(codec: kCMVideoCodecType_HEVC, width: 1920, height: 1080, frameCount: 120,
                      file: CommandLine.arguments[2],
                      id: "gpuz.hevc.1080p.120f.30fps.v1",
                      sha256: "7cbd1c678ed0ade4ea534b9e201a5789df0b56544971977258488902c611ac5e")
    try verifyFixture(codec: kCMVideoCodecType_H264, width: 3840, height: 2160, frameCount: 48,
                      file: CommandLine.arguments[3],
                      id: "gpuz.h264.4k.48f.30fps.v1",
                      sha256: "6f846d3e50d3874ef2f32b7fcff0f8902a14895f97dac3290f059e1cae48cc2e")
    try verifyFixture(codec: kCMVideoCodecType_HEVC, width: 3840, height: 2160, frameCount: 48,
                      file: CommandLine.arguments[4],
                      id: "gpuz.hevc.4k.48f.30fps.v1",
                      sha256: "da161736ebbe2e8b0d44ae5d8b3f7f08936a8413c8c4040688a5c62dedae5d80")
    try verifyBundledFixture(codec: kCMVideoCodecType_H264, width: 1920, frameCount: 120,
                             id: "gpuz.h264.1080p.120f.30fps.v1",
                             sha256: "44302a9e9d2460e7a85cff47ab0cdc832668881538489d1f1bca213abd042cf5")
    try verifyBundledFixture(codec: kCMVideoCodecType_HEVC, width: 1920, frameCount: 120,
                             id: "gpuz.hevc.1080p.120f.30fps.v1",
                             sha256: "7cbd1c678ed0ade4ea534b9e201a5789df0b56544971977258488902c611ac5e")
    try verifyBundledFixture(codec: kCMVideoCodecType_H264, width: 3840, frameCount: 48,
                             id: "gpuz.h264.4k.48f.30fps.v1",
                             sha256: "6f846d3e50d3874ef2f32b7fcff0f8902a14895f97dac3290f059e1cae48cc2e")
    try verifyBundledFixture(codec: kCMVideoCodecType_HEVC, width: 3840, frameCount: 48,
                             id: "gpuz.hevc.4k.48f.30fps.v1",
                             sha256: "da161736ebbe2e8b0d44ae5d8b3f7f08936a8413c8c4040688a5c62dedae5d80")
    print("Fixed fixture tests passed: 2 codecs × (120 1080p + 48 4K) samples")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}

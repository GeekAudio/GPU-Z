import Foundation

/// Canonical identities shared by the test matrices, worker protocol and report rows.
/// IDs intentionally use BenchRow's existing group|item|mode representation.
enum CodecTestPlan {
    struct Case: Hashable, Identifiable {
        let group: String
        let item: String
        let mode: String

        var id: String { [group, item, mode].joined(separator: "|") }
    }

    static let cases: [Case] = [
        Case(group: "编码", item: "H.264 1080p", mode: "强制硬件"),
        Case(group: "编码", item: "H.264 1080p", mode: "软件编码"),
        Case(group: "编码", item: "H.264 4K", mode: "强制硬件"),
        Case(group: "编码", item: "HEVC 1080p", mode: "强制硬件"),
        Case(group: "编码", item: "HEVC 1080p", mode: "软件编码"),
        Case(group: "编码", item: "HEVC 4K", mode: "强制硬件"),
        Case(group: "解码", item: "H.264 1080p", mode: "强制硬件"),
        Case(group: "解码", item: "H.264 1080p", mode: "软件解码"),
        Case(group: "解码", item: "HEVC 1080p", mode: "强制硬件"),
        Case(group: "解码", item: "H.264 4K", mode: "强制硬件"),
        Case(group: "解码", item: "HEVC 4K", mode: "强制硬件"),
        Case(group: "编码", item: "H.264 4K", mode: "软件编码"),
        Case(group: "解码", item: "HEVC 1080p", mode: "软件解码"),
        Case(group: "解码", item: "H.264 4K", mode: "软件解码"),
        Case(group: "解码", item: "HEVC 4K", mode: "软件解码")
    ]

    static let allCaseIDs = cases.map(\.id)
    static let allCaseIDSet = Set(allCaseIDs)
    // Keep older reports and explicitly selected worker invocations readable.
    // The slow HEVC software encoder is excluded from current batch runs.
    private static let legacyHEVCSoftwareEncodeID = id(group: "编码", item: "HEVC 1080p", mode: "软件编码")
    static let defaultCaseIDs = allCaseIDs.filter { $0 != legacyHEVCSoftwareEncodeID }
    /// Default GUI round: hardware encode/decode cases only. Software comparisons remain opt-in.
    static let hardwareCaseIDs = Set(cases.filter { $0.mode == "强制硬件" }.map(\.id))
    static let softwareCaseIDs = Set(defaultCaseIDs).subtracting(hardwareCaseIDs)
    static let softwareComparisonCaseIDs = softwareCaseIDs.union(
        softwareCaseIDs.compactMap { hardwareComparisonCaseID(forSoftwareCaseID: $0) }
    )
    /// Schema-version-1 reports without an explicit plan came from the original nine-case matrix.
    static let legacyCaseIDs = Array(allCaseIDs.prefix(9))

    /// Returns the approved forced-hardware case paired with a software comparison case.
    /// Group and item must match, so an encode comparison can never be paired with a decode case.
    static func hardwareComparisonCaseID(forSoftwareCaseID id: String) -> String? {
        guard let softwareCase = cases.first(where: {
            $0.id == id && ($0.mode == "软件编码" || $0.mode == "软件解码")
        }) else { return nil }
        return cases.first(where: {
            $0.group == softwareCase.group && $0.item == softwareCase.item
                && $0.mode == "强制硬件" && hardwareCaseIDs.contains($0.id)
        })?.id
    }

    static func id(group: String, item: String, mode: String) -> String {
        [group, item, mode].joined(separator: "|")
    }

    enum SelectionError: Error, LocalizedError, Equatable {
        case empty
        case duplicate(String)
        case unknown(String)
        case malformedArguments

        var errorDescription: String? {
            switch self {
            case .empty: return "至少选择一项测试。"
            case .duplicate(let id): return "测试项目重复：\(id)"
            case .unknown(let id): return "未知测试项目：\(id)"
            case .malformedArguments: return "测试项目参数格式错误。"
            }
        }
    }

    /// Validates explicit selections and returns them in the grid's stable order.
    /// `nil` selects the current full matrix; an empty selection is always an error.
    static func validate(_ requestedIDs: [String]?) throws -> [String] {
        guard let requestedIDs else { return defaultCaseIDs }
        guard !requestedIDs.isEmpty else { throw SelectionError.empty }

        var seen = Set<String>()
        for id in requestedIDs {
            guard seen.insert(id).inserted else { throw SelectionError.duplicate(id) }
            guard allCaseIDSet.contains(id) else { throw SelectionError.unknown(id) }
        }
        return allCaseIDs.filter(seen.contains)
    }

    /// Repeated flags keep the worker command line unambiguous and safely escaped by Process.arguments.
    static func arguments(for selectedIDs: Set<String>) throws -> [String] {
        try validate(Array(selectedIDs))
            .flatMap { ["--case-id", $0] }
    }

    /// Parses only worker selection flags. No flags preserves existing full-matrix invocations.
    static func selection(in arguments: [String]) throws -> [String] {
        var selected: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--case-id=") || (argument.hasPrefix("--case-id") && argument != "--case-id") {
                throw SelectionError.malformedArguments
            }
            if argument == "--case-id" {
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--case-id"),
                      !arguments[index + 1].hasPrefix("--") else {
                    throw SelectionError.malformedArguments
                }
                selected.append(arguments[index + 1])
                index += 1
            }
            index += 1
        }
        return try validate(selected.isEmpty ? nil : selected)
    }
}

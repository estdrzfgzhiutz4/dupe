import SwiftUI
import AppKit
import QuickLookThumbnailing
import Vision
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// Media Duplicate Reviewer 2.1 — safety/rotation/video-candidate revision
// Native macOS reviewer. No HTML reports and no exported thumbnails.
// - Exact duplicates: SHA-256 grouping across the full selected collection.
// - Similar photos: indexed perceptual-neighbour search, then Apple Vision confirmation.
// - Similar videos: indexed three-frame perceptual candidates, then Vision confirmation at 10%, 50%, 90%.
// - Possible Live Photo companions: paired conservatively in memory by same-folder/same-basename image + video.

enum MediaKind: String, Codable {
    case image = "Image"
    case video = "Video"
}

struct ScanRoot: Identifiable, Hashable {
    let id: String
    let label: String
    let url: URL
}

struct MediaItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let normalizedStem: String
    let kind: MediaKind
    let byteSize: Int64
    let pixelWidth: Int?
    let pixelHeight: Int?
    let durationSeconds: Double?
    let fileCreated: Date?
    let captureDateText: String?
    let cameraModel: String?
    let rootLabel: String
    let relativePath: String
    let companionLookupKey: String

    init(url: URL, kind: MediaKind, byteSize: Int64, pixelWidth: Int?, pixelHeight: Int?,
         durationSeconds: Double?, fileCreated: Date?, captureDateText: String?, cameraModel: String?,
         root: ScanRoot) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.name = url.lastPathComponent
        self.normalizedStem = MediaItem.normalizeStem(url.deletingPathExtension().lastPathComponent)
        self.kind = kind
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.fileCreated = fileCreated
        self.captureDateText = captureDateText
        self.cameraModel = cameraModel
        self.rootLabel = root.label
        let rootPath = root.url.standardizedFileURL.path.hasSuffix("/") ? root.url.standardizedFileURL.path : root.url.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
        self.relativePath = "\(root.url.lastPathComponent)/\(relative)"
        self.companionLookupKey = url.deletingPathExtension().standardizedFileURL.path.lowercased()
    }

    var pixelCount: Int? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return w * h
    }

    var dimensionsText: String {
        guard let w = pixelWidth, let h = pixelHeight else { return "—" }
        return "\(w) × \(h)"
    }

    var durationText: String {
        guard let seconds = durationSeconds, seconds.isFinite else { return "—" }
        let value = Int(seconds.rounded())
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    var extensionLower: String { url.pathExtension.lowercased() }

    var normalizedFormat: String {
        switch extensionLower {
        case "jpg", "jpeg": return "jpeg"
        case "heic", "heif": return "heic"
        default: return extensionLower
        }
    }

    var metadataSummary: String {
        let date = captureDateText ?? "No capture date"
        if let cameraModel, !cameraModel.isEmpty { return "\(date) · \(cameraModel)" }
        return date
    }

    static func normalizeStem(_ stem: String) -> String {
        var s = stem.lowercased()
        let patterns = [
            #"[\s_-]*(original|copy|duplicate|edited|edit)$"#,
            #"\s*\(\d+\)$"#,
            #"[\s_-]+copy[\s_-]*\d*$"#
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ExactGroup: Identifiable {
    let id: String
    var items: [MediaItem]
}

enum PairType: String {
    case similarImage = "Visually matching image"
    case similarVideo = "Likely matching video"
}

struct ReviewPair: Identifiable {
    let id: String
    let left: MediaItem
    let right: MediaItem
    let type: PairType
    let similarityDistance: Float?
    let reason: String
    let suggestedTrashID: String?
    let suggestionText: String?
}

enum ReviewSection: String, CaseIterable, Identifiable {
    case exact = "Exact Copies"
    case photos = "Similar Photos"
    case videos = "Video Review"
    case selected = "Selected"
    var id: String { rawValue }
}

struct PairKey: Hashable {
    let first: String
    let second: String
    init(_ a: String, _ b: String) {
        if a < b { first = a; second = b } else { first = b; second = a }
    }
}

final class HammingBKTree {
    final class Node {
        let hash: UInt64
        var ids: [String]
        var children: [Int: Node] = [:]
        init(hash: UInt64, id: String) { self.hash = hash; self.ids = [id] }
    }
    private var root: Node?

    func insert(_ hash: UInt64, id: String) {
        guard let root else { self.root = Node(hash: hash, id: id); return }
        var node = root
        while true {
            let distance = (node.hash ^ hash).nonzeroBitCount
            if distance == 0 { node.ids.append(id); return }
            if let child = node.children[distance] { node = child }
            else { node.children[distance] = Node(hash: hash, id: id); return }
        }
    }

    func query(_ hash: UInt64, within radius: Int) -> [String] {
        guard let root else { return [] }
        var answer: [String] = []
        func search(_ node: Node) {
            let distance = (node.hash ^ hash).nonzeroBitCount
            if distance <= radius { answer.append(contentsOf: node.ids) }
            let minimum = max(0, distance - radius)
            let maximum = distance + radius
            for (edge, child) in node.children where edge >= minimum && edge <= maximum { search(child) }
        }
        search(root)
        return answer
    }
}

final class MediaScanner {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "webp"
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "mpg", "mpeg", "3gp", "webm"
    ]

    static func rootsOverlap(_ first: URL, _ second: URL) -> Bool {
        let a = first.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let b = second.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let prefixLength = min(a.count, b.count)
        return Array(a.prefix(prefixLength)) == Array(b.prefix(prefixLength))
    }

    static func scan(roots: [ScanRoot], progress: @escaping (String) -> Void) -> [MediaItem] {
        var results: [MediaItem] = []
        var seenPaths = Set<String>()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentTypeKey]
        for root in roots {
            if Task.isCancelled { return results }
            progress("Scanning Root \(root.label): \(root.url.path)…")
            guard let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    progress("Skipped \(url.lastPathComponent): \(error.localizedDescription)")
                    return true
                }
            ) else { continue }
            var count = 0
            for case let url as URL in enumerator {
                if Task.isCancelled { return results }
                autoreleasepool {
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
                    guard !seenPaths.contains(canonical),
                          let values = try? url.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { return }
                    let ext = url.pathExtension.lowercased()
                    let kind: MediaKind?
                    if let type = values.contentType, type.conforms(to: .image) { kind = .image }
                    else if let type = values.contentType, type.conforms(to: .movie) { kind = .video }
                    else if imageExtensions.contains(ext) { kind = .image }
                    else if videoExtensions.contains(ext) { kind = .video }
                    else { kind = nil }
                    guard let mediaKind = kind else { return }
                    seenPaths.insert(canonical)
                    let item = mediaItem(url: url, kind: mediaKind, values: values, root: root)
                    results.append(item)
                    count += 1
                    if count % 250 == 0 { progress("Root \(root.label): found \(count) media files…") }
                }
            }
        }
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    static func mediaItem(url: URL, kind: MediaKind, values: URLResourceValues, root: ScanRoot) -> MediaItem {
        let bytes = Int64(values.fileSize ?? 0)
        var width: Int?
        var height: Int?
        var duration: Double?
        var captureDate: String?
        var cameraModel: String?
        if kind == .image,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                captureDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            }
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            }
        } else if kind == .video {
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite && seconds >= 0 { duration = seconds }
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                width = Int(abs(size.width).rounded())
                height = Int(abs(size.height).rounded())
            }
        }
        return MediaItem(url: url, kind: kind, byteSize: bytes, pixelWidth: width, pixelHeight: height,
                         durationSeconds: duration, fileCreated: values.creationDate,
                         captureDateText: captureDate, cameraModel: cameraModel, root: root)
    }

    static func possibleCompanions(items: [MediaItem]) -> [String: MediaItem] {
        let byKey = Dictionary(grouping: items, by: \.companionLookupKey)
        var companions: [String: MediaItem] = [:]
        for group in byKey.values {
            guard let image = group.first(where: { $0.kind == .image }),
                  let video = group.first(where: { $0.kind == .video }) else { continue }
            companions[image.id] = video
            companions[video.id] = image
        }
        return companions
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func exactGroups(items: [MediaItem], progress: @escaping (String) -> Void) -> [ExactGroup] {
        let possible = Dictionary(grouping: items.filter { $0.byteSize > 0 }, by: \.byteSize)
            .values.filter { $0.count > 1 }.flatMap { $0 }
        var hashes: [String: [MediaItem]] = [:]
        for (index, item) in possible.enumerated() {
            if Task.isCancelled { return [] }
            if let hash = sha256(item.url) { hashes[hash, default: []].append(item) }
            if index % 20 == 0 { progress("Hashing files with matching byte size: \(index + 1) of \(possible.count)…") }
        }
        return hashes.compactMap { hash, files in
            guard files.count > 1 else { return nil }
            return ExactGroup(id: hash, items: files.sorted { $0.relativePath < $1.relativePath })
        }.sorted { ($0.items.first?.name ?? "") < ($1.items.first?.name ?? "") }
    }

    static func thumbnailCGImage(_ url: URL, maxPixel: Int = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func dHash(_ image: CGImage) -> UInt64? {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var value: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<height {
            for x in 0..<8 {
                if pixels[y * width + x] > pixels[y * width + x + 1] { value |= (1 << bit) }
                bit += 1
            }
        }
        return value
    }

    static func featurePrint(from image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch { return nil }
    }

    static func longShortDimensions(_ item: MediaItem) -> (Int, Int)? {
        guard let width = item.pixelWidth, let height = item.pixelHeight else { return nil }
        return (max(width, height), min(width, height))
    }

    static func rotationEquivalentDimensions(_ first: MediaItem, _ second: MediaItem) -> Bool {
        guard let a = longShortDimensions(first), let b = longShortDimensions(second) else { return false }
        return a.0 == b.0 && a.1 == b.1
    }

    static func aspectRatio(_ item: MediaItem) -> Double? {
        guard let dimensions = longShortDimensions(item), dimensions.1 > 0 else { return nil }
        return Double(dimensions.0) / Double(dimensions.1)
    }

    // Compare aspect independently of EXIF/display orientation. A portrait image and a
    // landscape image with swapped dimensions can still depict the same rotated original.
    static func compatibleAspect(_ first: MediaItem, _ second: MediaItem, tolerance: Double = 0.035) -> Bool {
        guard let a = aspectRatio(first), let b = aspectRatio(second) else { return true }
        return abs(a - b) / max(a, b) <= tolerance
    }

    static func appendPairs(in group: [MediaItem], reason: String, into candidates: inout [PairKey: Set<String>], limit: Int = 200) {
        guard group.count >= 2, group.count <= limit else { return }
        for i in 0..<(group.count - 1) {
            for j in (i + 1)..<group.count {
                candidates[PairKey(group[i].id, group[j].id), default: []].insert(reason)
            }
        }
    }

    static func photoSuggestion(_ first: MediaItem, _ second: MediaItem, distance: Float, ambiguous: Bool) -> (String?, String?) {
        if ambiguous {
            return (nil, "No automatic selection: at least one of these files matches multiple variants. Choose the keeper after reviewing the related rows.")
        }

        // Suggestions are more conservative than listing a visual match.
        // This prevents two merely similar shots from becoming automatic deletion candidates.
        guard distance <= 0.060, compatibleAspect(first, second, tolerance: 0.025),
              let firstPixels = first.pixelCount, let secondPixels = second.pixelCount else {
            return (nil, nil)
        }

        if rotationEquivalentDimensions(first, second) {
            let rotationNote = (first.pixelWidth == second.pixelWidth && first.pixelHeight == second.pixelHeight)
                ? ""
                : " Dimensions are equivalent after orientation/rotation."
            if first.normalizedFormat == "heic", second.normalizedFormat == "jpeg" {
                return (second.id, "Suggested: same-size visually matched image; keep HEIC and trash JPEG unless compatibility matters to you.\(rotationNote)")
            }
            if second.normalizedFormat == "heic", first.normalizedFormat == "jpeg" {
                return (first.id, "Suggested: same-size visually matched image; keep HEIC and trash JPEG unless compatibility matters to you.\(rotationNote)")
            }
            if first.normalizedFormat == second.normalizedFormat, first.byteSize != second.byteSize {
                let inferior = first.byteSize < second.byteSize ? first : second
                return (inferior.id, "Suggested: very strong visual match with the same format and equivalent pixel dimensions; keep the larger file. The size difference may be compression or metadata, so inspect before trashing.\(rotationNote)")
            }
        }

        let high = max(firstPixels, secondPixels)
        let low = min(firstPixels, secondPixels)
        if low > 0 && Double(high) / Double(low) >= 1.03 {
            let inferior = firstPixels < secondPixels ? first : second
            let superior = firstPixels < secondPixels ? second : first
            return (inferior.id, "Suggested: lower resolution (\(inferior.dimensionsText) versus \(superior.dimensionsText)); inspect before trashing.")
        }
        return (nil, nil)
    }

    static func isAllowedSimilarityPair(_ first: MediaItem, _ second: MediaItem, crossRootOnly: Bool) -> Bool {
        guard first.id != second.id else { return false }
        return !crossRootOnly || first.rootLabel != second.rootLabel
    }

    static func similarPhotos(items: [MediaItem], excluding exactIDs: Set<String>, exhaustive: Bool, crossRootOnly: Bool,
                              progress: @escaping (String) -> Void) -> [ReviewPair] {
        let images = items.filter { $0.kind == .image && !exactIDs.contains($0.id) }
        guard images.count >= 2 else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        var candidates: [PairKey: Set<String>] = [:]

        if exhaustive {
            progress("Exhaustive mode: scheduling all \(images.count * (images.count - 1) / 2) photo pairs…")
            for i in 0..<(images.count - 1) {
                for j in (i + 1)..<images.count {
                    if Task.isCancelled { return [] }
                    guard isAllowedSimilarityPair(images[i], images[j], crossRootOnly: crossRootOnly) else { continue }
                    candidates[PairKey(images[i].id, images[j].id), default: []].insert("exhaustive visual scan")
                }
            }
        } else {
            progress("Indexing visual fingerprints for \(images.count) photos…")
            let tree = HammingBKTree()
            var hashes: [String: UInt64] = [:]
            for (index, item) in images.enumerated() {
                if Task.isCancelled { return [] }
                if let thumbnail = thumbnailCGImage(item.url, maxPixel: 256), let hash = dHash(thumbnail) {
                    hashes[item.id] = hash
                    for neighbor in tree.query(hash, within: 10) {
                        guard let other = byID[neighbor], isAllowedSimilarityPair(item, other, crossRootOnly: crossRootOnly) else { continue }
                        candidates[PairKey(item.id, neighbor), default: []].insert("perceptual-hash neighbour")
                    }
                    tree.insert(hash, id: item.id)
                }
                if index % 100 == 0 { progress("Indexing visual fingerprints: \(index + 1) of \(images.count)…") }
            }

            let byStem = Dictionary(grouping: images.filter { !$0.normalizedStem.isEmpty }, by: \.normalizedStem)
            for group in byStem.values { appendPairs(in: group, reason: "related filename", into: &candidates, limit: 100) }

            let byCapture = Dictionary(grouping: images.filter { $0.captureDateText != nil }) { item in
                "\(item.captureDateText ?? "")|\(item.cameraModel ?? "")"
            }
            for group in byCapture.values { appendPairs(in: group, reason: "matching capture metadata", into: &candidates, limit: 100) }
        }

        if crossRootOnly {
            candidates = candidates.filter { key, _ in
                guard let first = byID[key.first], let second = byID[key.second] else { return false }
                return first.rootLabel != second.rootLabel
            }
        }

        progress("Confirming \(candidates.count) photo candidate pair(s) with Apple Vision…")
        var featureCache: [String: VNFeaturePrintObservation] = [:]
        var matches: [(MediaItem, MediaItem, Float, Set<String>)] = []
        for (index, entry) in candidates.enumerated() {
            if Task.isCancelled { return [] }
            guard let first = byID[entry.key.first], let second = byID[entry.key.second] else { continue }
            if featureCache[first.id] == nil, let image = thumbnailCGImage(first.url, maxPixel: 720) {
                featureCache[first.id] = featurePrint(from: image)
            }
            if featureCache[second.id] == nil, let image = thumbnailCGImage(second.url, maxPixel: 720) {
                featureCache[second.id] = featurePrint(from: image)
            }
            guard let a = featureCache[first.id], let b = featureCache[second.id] else { continue }
            var distance: Float = 0
            if (try? a.computeDistance(&distance, to: b)) != nil, distance <= 0.115 {
                matches.append((first, second, distance, entry.value))
            }
            if index % 100 == 0 { progress("Vision-confirmed candidates: \(index + 1) of \(candidates.count)…") }
        }

        // Keep every confirmed pair so multiple converted/compressed variants are visible.
        // Automatic selection is suppressed for overlapping rows: applying suggestions
        // pair-by-pair could otherwise select both sides of another valid match.
        var occurrenceCount: [String: Int] = [:]
        for match in matches {
            occurrenceCount[match.0.id, default: 0] += 1
            occurrenceCount[match.1.id, default: 0] += 1
        }

        var pairs: [ReviewPair] = []
        for match in matches.sorted(by: { $0.2 < $1.2 }) {
            let ambiguous = (occurrenceCount[match.0.id] ?? 0) > 1 || (occurrenceCount[match.1.id] ?? 0) > 1
            let suggestion = photoSuggestion(match.0, match.1, distance: match.2, ambiguous: ambiguous)
            let evidence = match.3.sorted().joined(separator: ", ")
            pairs.append(ReviewPair(
                id: "photo:\(match.0.id)|\(match.1.id)", left: match.0, right: match.1,
                type: .similarImage, similarityDistance: match.2,
                reason: "Visual match confirmed (\(evidence)); Vision distance \(String(format: "%.4f", match.2)).",
                suggestedTrashID: suggestion.0, suggestionText: suggestion.1
            ))
        }
        return pairs.sorted { $0.left.relativePath < $1.left.relativePath }
    }

    struct VideoSample {
        let prints: [VNFeaturePrintObservation]
        let perceptualHashes: [UInt64]
    }

    static func videoSamples(_ item: MediaItem) -> VideoSample? {
        guard item.kind == .video, let duration = item.durationSeconds, duration > 0 else { return nil }
        let asset = AVURLAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        var observations: [VNFeaturePrintObservation] = []
        var hashes: [UInt64] = []
        for fraction in [0.10, 0.50, 0.90] {
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil),
                  let observation = featurePrint(from: frame),
                  let hash = dHash(frame) else { return nil }
            observations.append(observation)
            hashes.append(hash)
        }
        return VideoSample(prints: observations, perceptualHashes: hashes)
    }

    static func similarVideos(items: [MediaItem], excluding exactIDs: Set<String>, crossRootOnly: Bool, progress: @escaping (String) -> Void) -> [ReviewPair] {
        let videos = items.filter { $0.kind == .video && !exactIDs.contains($0.id) }
        guard videos.count >= 2 else { return [] }

        progress("Preparing three-frame fingerprints for \(videos.count) non-identical videos…")
        var sampleCache: [String: VideoSample] = [:]
        for (index, item) in videos.enumerated() {
            if Task.isCancelled { return [] }
            if let samples = videoSamples(item) { sampleCache[item.id] = samples }
            if index % 10 == 0 { progress("Reading video frame samples: \(index + 1) of \(videos.count)…") }
        }

        let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        var candidates = Set<PairKey>()

        // Matching filename remains only a candidate path; Vision still must confirm it.
        let byStem = Dictionary(grouping: videos.filter { !$0.normalizedStem.isEmpty }, by: \.normalizedStem)
        for group in byStem.values where group.count <= 100 {
            for i in 0..<(group.count - 1) {
                for j in (i + 1)..<group.count {
                    let first = group[i], second = group[j]
                    guard isAllowedSimilarityPair(first, second, crossRootOnly: crossRootOnly) else { continue }
                    if let a = first.durationSeconds, let b = second.durationSeconds,
                       abs(a - b) <= 1.0, compatibleAspect(first, second, tolerance: 0.04) {
                        candidates.insert(PairKey(first.id, second.id))
                    }
                }
            }
        }

        // Use a separate perceptual-neighbour index for each sampled frame.
        // A pair becomes a Vision candidate only if it is nearby at two or more positions.
        let trees = [HammingBKTree(), HammingBKTree(), HammingBKTree()]
        var visualVotes: [PairKey: Int] = [:]
        for item in videos {
            if Task.isCancelled { return [] }
            guard let sample = sampleCache[item.id] else { continue }
            for frameIndex in 0..<3 {
                for neighborID in trees[frameIndex].query(sample.perceptualHashes[frameIndex], within: 10) {
                    guard let other = byID[neighborID],
                          isAllowedSimilarityPair(item, other, crossRootOnly: crossRootOnly),
                          let firstDuration = item.durationSeconds,
                          let otherDuration = other.durationSeconds,
                          abs(firstDuration - otherDuration) <= 1.0,
                          compatibleAspect(item, other, tolerance: 0.04) else { continue }
                    visualVotes[PairKey(item.id, neighborID), default: 0] += 1
                }
                trees[frameIndex].insert(sample.perceptualHashes[frameIndex], id: item.id)
            }
        }
        for (pair, votes) in visualVotes where votes >= 2 { candidates.insert(pair) }
        if crossRootOnly {
            candidates = Set(candidates.filter { key in
                guard let first = byID[key.first], let second = byID[key.second] else { return false }
                return first.rootLabel != second.rootLabel
            })
        }

        progress("Confirming \(candidates.count) indexed video candidate pair(s) at 10%, 50% and 90%…")
        var scored: [(MediaItem, MediaItem, Float, Int)] = []
        for (index, key) in candidates.enumerated() {
            if Task.isCancelled { return [] }
            guard let first = byID[key.first], let second = byID[key.second],
                  let a = sampleCache[first.id], let b = sampleCache[second.id] else { continue }
            var distances: [Float] = []
            for position in 0..<3 {
                var value: Float = 0
                if (try? a.prints[position].computeDistance(&value, to: b.prints[position])) != nil {
                    distances.append(value)
                }
            }
            let close = distances.filter { $0 <= 0.115 }
            if close.count >= 2 {
                let average = close.reduce(0, +) / Float(close.count)
                scored.append((first, second, average, close.count))
            }
            if index % 20 == 0 { progress("Video confirmations: \(index + 1) of \(candidates.count)…") }
        }

        var occurrenceCount: [String: Int] = [:]
        for result in scored {
            occurrenceCount[result.0.id, default: 0] += 1
            occurrenceCount[result.1.id, default: 0] += 1
        }

        var pairs: [ReviewPair] = []
        for result in scored.sorted(by: { $0.2 < $1.2 }) {
            var suggestionID: String?
            var suggestionText: String?
            let ambiguous = (occurrenceCount[result.0.id] ?? 0) > 1 || (occurrenceCount[result.1.id] ?? 0) > 1
            if ambiguous {
                suggestionText = "No automatic selection: at least one video matches multiple variants. Inspect the related rows and keep the version(s) you need."
            } else if result.2 <= 0.060,
                      let aPixels = result.0.pixelCount, let bPixels = result.1.pixelCount,
                      compatibleAspect(result.0, result.1, tolerance: 0.025),
                      Double(max(aPixels, bPixels)) / Double(max(min(aPixels, bPixels), 1)) >= 1.03 {
                let inferior = aPixels < bPixels ? result.0 : result.1
                suggestionID = inferior.id
                suggestionText = "Suggested only after playback check: lower video resolution (\(inferior.dimensionsText))."
            }
            pairs.append(ReviewPair(
                id: "video:\(result.0.id)|\(result.1.id)", left: result.0, right: result.1,
                type: .similarVideo, similarityDistance: result.2,
                reason: "Matched at \(result.3) of 3 indexed sampled frames (10%, 50%, 90%); average Vision distance \(String(format: "%.4f", result.2)). Inspect playback before deleting.",
                suggestedTrashID: suggestionID, suggestionText: suggestionText
            ))
        }
        return pairs.sorted { $0.left.relativePath < $1.left.relativePath }
    }

}

@MainActor
final class ReviewModel: ObservableObject {
    @Published var rootA: URL?
    @Published var rootB: URL?
    @Published var useExhaustivePhotoScan = false
    @Published var section: ReviewSection = .exact
    @Published var exactGroups: [ExactGroup] = []
    @Published var photoPairs: [ReviewPair] = []
    @Published var videoPairs: [ReviewPair] = []
    @Published var selectedIDs = Set<String>()
    @Published var status = "Choose Root A. Root B is optional; a single root finds duplicates inside that tree."
    @Published var isWorking = false
    @Published var page = 0
    @Published var hasScanned = false

    private var allItems: [MediaItem] = []
    private var exactIDs = Set<String>()
    private var companionByID: [String: MediaItem] = [:]
    private var activeTask: Task<Void, Never>?
    let pageSize = 50

    var itemsByID: [String: MediaItem] { Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) }) }
    var selectedItems: [MediaItem] { selectedIDs.compactMap { itemsByID[$0] }.sorted { $0.relativePath < $1.relativePath } }
    var currentPairs: [ReviewPair] { section == .photos ? photoPairs : videoPairs }
    var currentPairPage: [ReviewPair] {
        let start = page * pageSize
        guard start < currentPairs.count else { return [] }
        return Array(currentPairs[start..<min(currentPairs.count, start + pageSize)])
    }
    var currentExactPage: [ExactGroup] {
        let start = page * pageSize
        guard start < exactGroups.count else { return [] }
        return Array(exactGroups[start..<min(exactGroups.count, start + pageSize)])
    }
    var totalPages: Int {
        let count: Int
        switch section {
        case .exact: count = exactGroups.count
        case .photos: count = photoPairs.count
        case .videos: count = videoPairs.count
        case .selected: count = selectedItems.count
        }
        return max(1, Int(ceil(Double(count) / Double(pageSize))))
    }

    func chooseRoot(label: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose Root \(label)"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if label == "A" { rootA = url } else { rootB = url }
        }
    }
    func clearRootB() { rootB = nil }
    func resetPage() { page = 0 }

    func startScan() {
        guard let aURL = rootA else { status = "Choose Root A first."; return }
        activeTask?.cancel()
        if let bURL = rootB, MediaScanner.rootsOverlap(aURL, bURL) {
            showMessage(title: "Overlapping roots are not allowed", text: "Choose either the larger folder by itself, or two non-overlapping folders. A single root already finds duplicates inside that folder tree.")
            return
        }
        let roots = [ScanRoot(id: "A", label: "A", url: aURL)] + (rootB.map { [ScanRoot(id: "B", label: "B", url: $0)] } ?? [])
        let crossRootOnly = rootB != nil
        exactGroups = []; photoPairs = []; videoPairs = []; selectedIDs = []; exactIDs = []; allItems = []; companionByID = [:]
        page = 0; hasScanned = false; isWorking = true; status = "Scanning selected collection…"
        let exhaustive = useExhaustivePhotoScan
        activeTask = Task.detached(priority: .userInitiated) {
            let progress: (String) -> Void = { text in Task { @MainActor in self.status = text } }
            let items = MediaScanner.scan(roots: roots, progress: progress)
            guard !Task.isCancelled else { await MainActor.run { self.status = "Scan stopped."; self.isWorking = false }; return }
            let companions = MediaScanner.possibleCompanions(items: items)
            progress("Checking exact duplicates throughout the collection…")
            let exact = MediaScanner.exactGroups(items: items, progress: progress)
            guard !Task.isCancelled else { await MainActor.run { self.status = "Scan stopped."; self.isWorking = false }; return }
            let exactSet = Set(exact.flatMap { $0.items.map(\.id) })
            let photos = MediaScanner.similarPhotos(items: items, excluding: exactSet, exhaustive: exhaustive, crossRootOnly: crossRootOnly, progress: progress)
            guard !Task.isCancelled else { await MainActor.run { self.status = "Scan stopped."; self.isWorking = false }; return }
            await MainActor.run {
                self.allItems = items
                self.companionByID = companions
                self.exactGroups = exact
                self.exactIDs = exactSet
                self.photoPairs = photos
                self.section = exact.isEmpty ? .photos : .exact
                self.page = 0
                self.hasScanned = true
                self.isWorking = false
                self.status = "Done: \(items.count) media files, \(exact.count) exact-copy group(s), \(photos.count) visually confirmed photo pair(s). Video analysis is optional."
                self.activeTask = nil
            }
        }
    }

    func analyzeVideos() {
        guard hasScanned, !isWorking else { return }
        activeTask?.cancel()
        isWorking = true
        status = "Analyzing non-identical videos using three sampled frames…"
        let items = allItems, exclusions = exactIDs
        let crossRootOnly = rootB != nil
        activeTask = Task.detached(priority: .userInitiated) {
            let progress: (String) -> Void = { text in Task { @MainActor in self.status = text } }
            let pairs = MediaScanner.similarVideos(items: items, excluding: exclusions, crossRootOnly: crossRootOnly, progress: progress)
            guard !Task.isCancelled else { await MainActor.run { self.status = "Video analysis stopped."; self.isWorking = false }; return }
            await MainActor.run {
                self.videoPairs = pairs
                self.section = .videos
                self.page = 0
                self.isWorking = false
                let suggestions = pairs.filter { $0.suggestedTrashID != nil }.count
                self.status = "Video review complete: \(pairs.count) likely pair(s), \(suggestions) automatic lower-resolution suggestion(s). Exact identical videos are in Exact Copies."
                self.activeTask = nil
            }
        }
    }

    func stopCurrentWork() {
        guard isWorking else { return }
        activeTask?.cancel()
        activeTask = nil
        isWorking = false
        status = "Stopped."
    }

    func toggle(_ item: MediaItem, against other: MediaItem? = nil) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { if let other { selectedIDs.remove(other.id) }; selectedIDs.insert(item.id) }
    }

    func toggleExact(_ item: MediaItem, group: ExactGroup) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id); return }
        if group.items.filter({ selectedIDs.contains($0.id) }).count >= group.items.count - 1 {
            showMessage(title: "Keep one exact copy", text: "At least one byte-identical copy must remain in this group.")
            return
        }
        selectedIDs.insert(item.id)
    }

    func selectExactKeeping(preferredRoot: String?) {
        for group in exactGroups {
            let keep: MediaItem
            if let preferredRoot, let preferred = group.items.first(where: { $0.rootLabel == preferredRoot }) { keep = preferred }
            else { keep = group.items.sorted { $0.relativePath < $1.relativePath }.first! }
            for item in group.items where item.id != keep.id { selectedIDs.insert(item.id) }
            selectedIDs.remove(keep.id)
        }
    }

    func selectSuggestions() {
        let pairs = section == .photos ? photoPairs : videoPairs
        let suggested = pairs.compactMap(\.suggestedTrashID)
        if suggested.isEmpty {
            let text = section == .videos
                ? "These reviewed video pairs have no automatic keeper suggestion. Exact identical videos are handled in Exact Copies; inspect playback before choosing non-identical videos."
                : "No automatic quality suggestions are available in this section."
            showMessage(title: "No suggestions to select", text: text)
            return
        }
        for pair in pairs {
            if let id = pair.suggestedTrashID {
                selectedIDs.insert(id)
                selectedIDs.remove(pair.left.id == id ? pair.right.id : pair.left.id)
            }
        }
    }

    func clearSelection() { selectedIDs.removeAll() }
    func reveal(_ item: MediaItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func open(_ item: MediaItem) { NSWorkspace.shared.open(item.url) }
    func companion(for item: MediaItem) -> MediaItem? { companionByID[item.id] }

    func moveSelectedToTrash() {
        let items = selectedItems
        guard !items.isEmpty else { return }

        // Safety: a visually matched file can appear in several rows. Never proceed
        // when both alternatives in a displayed visual-match row are selected.
        let doubleSelectedPhotoPairs = photoPairs.filter { selectedIDs.contains($0.left.id) && selectedIDs.contains($0.right.id) }
        let doubleSelectedVideoPairs = videoPairs.filter { selectedIDs.contains($0.left.id) && selectedIDs.contains($0.right.id) }
        if let conflict = (doubleSelectedPhotoPairs + doubleSelectedVideoPairs).first {
            showMessage(title: "Two matched alternatives are selected",
                        text: "Both files in a visual-match row are selected:\n\n\(conflict.left.relativePath)\n\(conflict.right.relativePath)\n\nReview overlapping variants and leave at least one of this matched pair unselected before moving files to Trash.")
            return
        }

        for group in exactGroups where group.items.allSatisfy({ selectedIDs.contains($0.id) }) {
            showMessage(title: "Keep one exact copy", text: "Your selection includes every exact copy of \(group.items.first?.name ?? "a file"). Unselect one before continuing.")
            return
        }
        let separatedCompanions = items.compactMap { item -> String? in
            guard let companion = companionByID[item.id], !selectedIDs.contains(companion.id) else { return nil }
            return "• \(item.relativePath)\n  companion: \(companion.relativePath)"
        }
        let alert = NSAlert()
        alert.messageText = "Move \(items.count) selected file(s) to Trash?"
        var info = "The files will be moved to macOS Trash and can be recovered until Trash is emptied."
        if !separatedCompanions.isEmpty {
            info += "\n\nWarning: \(separatedCompanions.count) selected file(s) appear to have an image/video companion with the same basename that is not selected. This may be part of a Live Photo export:\n" + separatedCompanions.prefix(6).joined(separator: "\n")
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isWorking = true; status = "Moving selected files to Trash…"
        Task.detached(priority: .userInitiated) {
            var moved = Set<String>()
            var failures: [String] = []
            for item in items {
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: &resultingURL)
                    moved.insert(item.id)
                } catch { failures.append("\(item.relativePath): \(error.localizedDescription)") }
            }
            let movedResult = moved
            let failuresResult = failures
            await MainActor.run {
                self.selectedIDs.subtract(movedResult)
                self.photoPairs.removeAll { movedResult.contains($0.left.id) || movedResult.contains($0.right.id) }
                self.videoPairs.removeAll { movedResult.contains($0.left.id) || movedResult.contains($0.right.id) }
                self.exactGroups = self.exactGroups.compactMap { group in
                    let remaining = group.items.filter { !movedResult.contains($0.id) }
                    return remaining.count >= 2 ? ExactGroup(id: group.id, items: remaining) : nil
                }
                self.allItems.removeAll { movedResult.contains($0.id) }
                self.isWorking = false; self.page = 0
                self.status = failuresResult.isEmpty ? "Moved \(movedResult.count) file(s) to Trash." : "Moved \(movedResult.count) file(s); \(failuresResult.count) failed."
                if !failuresResult.isEmpty { self.showMessage(title: "Some files could not be moved", text: failuresResult.prefix(8).joined(separator: "\n")) }
            }
        }
    }

    private func showMessage(title: String, text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "OK"); alert.runModal()
    }
}

final class ThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false
    private let url: URL
    private var request: QLThumbnailGenerator.Request?
    init(url: URL) { self.url = url }
    func load() {
        guard image == nil, request == nil else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let value = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 330, height: 220), scale: scale, representationTypes: .thumbnail)
        request = value
        QLThumbnailGenerator.shared.generateBestRepresentation(for: value) { [weak self] representation, _ in
            DispatchQueue.main.async { if let image = representation?.nsImage { self?.image = image } else { self?.failed = true } }
        }
    }
    func cancel() { if let request { QLThumbnailGenerator.shared.cancel(request); self.request = nil } }
}

struct NativePreview: View {
    @StateObject private var loader: ThumbnailLoader
    init(url: URL) { _loader = StateObject(wrappedValue: ThumbnailLoader(url: url)) }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor))
            if let image = loader.image { Image(nsImage: image).resizable().scaledToFit().padding(5) }
            else if loader.failed { VStack(spacing: 7) { Image(systemName: "doc.richtext"); Text("Preview unavailable").font(.caption) }.foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }.frame(height: 210).onAppear { loader.load() }.onDisappear { loader.cancel() }
    }
}

struct MediaSideCard: View {
    @EnvironmentObject var model: ReviewModel
    let item: MediaItem
    let other: MediaItem?
    let suggested: Bool
    var selected: Bool { model.selectedIDs.contains(item.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.toggle(item, against: other) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Root \(item.rootLabel)").font(.caption).fontWeight(.semibold)
                        if suggested { Text("SUGGESTED TO TRASH").font(.caption2).fontWeight(.bold).padding(.horizontal, 6).padding(.vertical, 3).background(Color.orange.opacity(0.22)).clipShape(Capsule()) }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? .red : .secondary)
                    }
                    NativePreview(url: item.url)
                    Text(item.name).font(.headline).lineLimit(2)
                    Text("\(item.kind.rawValue) · \(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)) · \(item.dimensionsText)").font(.caption).foregroundStyle(.secondary)
                    if item.kind == .video { Text("Duration: \(item.durationText)").font(.caption).foregroundStyle(.secondary) }
                    Text(item.metadataSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(item.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    if let companion = model.companion(for: item) { Text("Possible Live Photo companion: \(companion.name)").font(.caption2).foregroundStyle(.orange) }
                }.padding(10).background(selected ? Color.red.opacity(0.10) : Color.clear).overlay {
                    RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.red : (suggested ? Color.orange.opacity(0.65) : Color.gray.opacity(0.16)), lineWidth: selected ? 2 : 1)
                }.contentShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
            HStack { Button("Open") { model.open(item) }; Button("Show in Finder") { model.reveal(item) } }.font(.caption)
        }
    }
}

struct PairCard: View {
    @EnvironmentObject var model: ReviewModel
    let pair: ReviewPair
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(pair.type.rawValue).font(.headline); Spacer(); if let distance = pair.similarityDistance { Text("Visual distance \(String(format: "%.4f", distance))").font(.caption).foregroundStyle(.secondary) } }
            Text(pair.reason).font(.caption).foregroundStyle(.secondary)
            if let text = pair.suggestionText { Text(text).font(.caption).fontWeight(.medium).foregroundStyle(.orange) }
            HStack(alignment: .top, spacing: 12) {
                MediaSideCard(item: pair.left, other: pair.right, suggested: pair.suggestedTrashID == pair.left.id)
                MediaSideCard(item: pair.right, other: pair.left, suggested: pair.suggestedTrashID == pair.right.id)
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ExactGroupCard: View {
    @EnvironmentObject var model: ReviewModel
    let group: ExactGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Byte-identical copies · \(group.items.count) files").font(.headline)
            Text("Same SHA-256 content. Select extras to trash only after checking their folders; at least one copy must remain.").font(.caption).foregroundStyle(.secondary)
            ForEach(group.items) { item in
                HStack(spacing: 10) {
                    Button { model.toggleExact(item, group: group) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(model.selectedIDs.contains(item.id) ? .red : .secondary)
                            Text("Root \(item.rootLabel)").font(.caption).fontWeight(.bold).frame(width: 50, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.relativePath).lineLimit(2).truncationMode(.middle)
                                if let companion = model.companion(for: item) { Text("Possible Live Photo companion: \(companion.relativePath)").font(.caption2).foregroundStyle(.orange) }
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }.padding(9).contentShape(Rectangle()).background(model.selectedIDs.contains(item.id) ? Color.red.opacity(0.10) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                    Button("Open") { model.open(item) }
                    Button("Finder") { model.reveal(item) }
                }
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SelectedRow: View {
    @EnvironmentObject var model: ReviewModel
    let item: MediaItem
    var body: some View {
        HStack {
            Text("Root \(item.rootLabel)").font(.caption).fontWeight(.bold).frame(width: 58, alignment: .leading)
            VStack(alignment: .leading) { Text(item.relativePath); if let companion = model.companion(for: item) { Text("Possible companion not necessarily selected: \(companion.relativePath)").font(.caption2).foregroundStyle(.orange) } }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)).foregroundStyle(.secondary)
            Button("Unselect") { model.toggle(item) }
            Button("Open") { model.open(item) }
        }.padding(10).background(Color.red.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: ReviewModel
    var body: some View { VStack(spacing: 0) { header; Divider(); toolbar; Divider(); results }.frame(minWidth: 1120, minHeight: 780) }
    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media Duplicate Reviewer").font(.system(size: 27, weight: .bold))
            Text("Exact copies are grouped across all selected folders, including within one root. Similar photos/videos use within-root matching only when one root is selected; with two roots selected, they compare Root A ↔ Root B only. Ambiguous multi-variant matches never auto-select.").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                rootChooser(label: "A", url: model.rootA) { model.chooseRoot(label: "A") }
                rootChooser(label: "B (optional)", url: model.rootB) { model.chooseRoot(label: "B") }
                if model.rootB != nil { Button("Clear B") { model.clearRootB() } }
                Button("Scan & Compare") { model.startScan() }.buttonStyle(.borderedProminent).disabled(model.isWorking || model.rootA == nil)
            }
            Toggle("Exhaustive photo scan (slow; one root: within that root, two roots: Root A ↔ Root B only)", isOn: $model.useExhaustivePhotoScan).font(.caption)
        }.padding(18)
    }
    func rootChooser(label: String, url: URL?, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(alignment: .leading, spacing: 4) { Text("Root \(label)").font(.caption).fontWeight(.bold); Text(url?.path ?? "Choose folder…").font(.caption).lineLimit(1).truncationMode(.middle) }.frame(maxWidth: .infinity, alignment: .leading).padding(9) }.buttonStyle(.bordered)
    }
    var toolbar: some View {
        VStack(spacing: 10) {
            HStack { Text(model.status).font(.callout); if model.isWorking { ProgressView().controlSize(.small) }; Spacer()
                if model.hasScanned {
                    if model.isWorking { Button("Stop") { model.stopCurrentWork() }.tint(.orange) }
                    Button("Analyze Non-identical Videos") { model.analyzeVideos() }.disabled(model.isWorking)
                    if model.section == .exact {
                        Menu("Select Exact Extras") {
                            Button("Keep one per group, prefer Root A") { model.selectExactKeeping(preferredRoot: "A") }
                            if model.rootB != nil { Button("Keep one per group, prefer Root B") { model.selectExactKeeping(preferredRoot: "B") } }
                            Button("Keep first path in each group") { model.selectExactKeeping(preferredRoot: nil) }
                        }
                    } else if model.section == .photos || model.section == .videos {
                        Button("Select Suggestions") { model.selectSuggestions() }
                    }
                    Button("Clear Selection") { model.clearSelection() }.disabled(model.selectedIDs.isEmpty)
                    Button("Move Selected to Trash (\(model.selectedIDs.count))") { model.moveSelectedToTrash() }.buttonStyle(.borderedProminent).tint(.red).disabled(model.selectedIDs.isEmpty || model.isWorking)
                }
                if !model.hasScanned && model.isWorking { Button("Stop") { model.stopCurrentWork() }.tint(.orange) }
            }
            if model.hasScanned {
                HStack {
                    Picker("Review section", selection: $model.section) {
                        Text("Exact Copies (\(model.exactGroups.count))").tag(ReviewSection.exact)
                        Text("Similar Photos (\(model.photoPairs.count))").tag(ReviewSection.photos)
                        Text("Video Review (\(model.videoPairs.count))").tag(ReviewSection.videos)
                        Text("Selected (\(model.selectedIDs.count))").tag(ReviewSection.selected)
                    }.pickerStyle(.segmented).onChange(of: model.section) { _ in model.resetPage() }
                    Spacer()
                    if model.section != .selected { Button("Previous") { model.page = max(0, model.page - 1) }.disabled(model.page == 0); Text("Page \(model.page + 1) of \(model.totalPages)").font(.caption).frame(minWidth: 92); Button("Next") { model.page = min(model.totalPages - 1, model.page + 1) }.disabled(model.page >= model.totalPages - 1) }
                }
            }
        }.padding(14)
    }
    @ViewBuilder var results: some View {
        if !model.hasScanned && !model.isWorking {
            VStack(spacing: 15) { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(.secondary); Text("Choose one folder tree, or two non-overlapping folder trees, then scan.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView { LazyVStack(spacing: 14) {
                switch model.section {
                case .exact:
                    if model.exactGroups.isEmpty { empty("No byte-identical duplicate groups found.") }
                    ForEach(model.currentExactPage) { ExactGroupCard(group: $0) }
                case .photos:
                    if model.photoPairs.isEmpty { empty("No visually confirmed non-identical photo pairs found with the current scan mode.") }
                    ForEach(model.currentPairPage) { PairCard(pair: $0) }
                case .videos:
                    if model.videoPairs.isEmpty { empty("Run Analyze Non-identical Videos. Exact identical videos already appear under Exact Copies.") }
                    ForEach(model.currentPairPage) { PairCard(pair: $0) }
                case .selected:
                    if model.selectedItems.isEmpty { empty("No files selected for Trash.") }
                    ForEach(model.selectedItems) { SelectedRow(item: $0) }
                }
            }.padding(16) }
        }
    }
    func empty(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).padding(30).frame(maxWidth: .infinity) }
}

@main
struct MediaDuplicateReviewerApp: App {
    @StateObject private var model = ReviewModel()
    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}

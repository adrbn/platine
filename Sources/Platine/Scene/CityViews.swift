import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A city seen through the window: a day and a night photograph, freely licensed
/// (CC0, public domain, CC BY, CC BY-SA), each with its credit.
struct CityView: Identifiable, Hashable {
    struct Credit: Codable, Hashable {
        let title: String?
        let creator: String?
        let license: String
        let license_version: String?
        let source: String?
    }

    let id: String
    let name: String
    let day: URL?
    let night: URL?
    let credits: [Credit]

    var creditLine: String {
        credits.map { c in
            let license = c.license == "cc0" || c.license == "pdm" ? "public domain"
                : "CC \(c.license.uppercased()) \(c.license_version ?? "")".trimmingCharacters(in: .whitespaces)
            return "\(c.title ?? "Untitled") by \(c.creator ?? "unknown") (\(license))"
        }.joined(separator: "; ")
    }
}

enum CityViews {
    static let defaultID = "sao-paulo"

    private struct Entry: Codable {
        var name: String
        var day: CityView.Credit?
        var night: CityView.Credit?
    }

    private static let bundled = Bundle.main.url(forResource: "Cities", withExtension: nil)
    static var customDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Platine/Cities", isDirectory: true)
    }

    /// The library, then the cities found by search, by name.
    static func all() -> [CityView] {
        (load(bundled, prefix: "") + load(customDirectory, prefix: "custom-")).sorted { $0.name < $1.name }
    }

    static func find(_ id: String) -> CityView? {
        all().first { $0.id == id } ?? all().first { $0.id == defaultID }
    }

    private static func load(_ directory: URL?, prefix: String) -> [CityView] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
            let slug = file.deletingPathExtension().lastPathComponent
            func photo(_ kind: String) -> URL? {
                let url = directory.appendingPathComponent("\(slug)-\(kind).jpg")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            let view = CityView(id: prefix + slug, name: e.name, day: photo("day"), night: photo("night"),
                                credits: [e.day, e.night].compactMap { $0 })
            return view.day == nil && view.night == nil ? nil : view
        }
    }

    // MARK: Finding your own

    enum SearchError: LocalizedError {
        case nothingFound(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .nothingFound(let q): return "No free photo of \(q) found. Try the English name."
            case .unreadable(let n): return "Couldn't read \(n) as a photo."
            }
        }
    }

    private struct Results: Decodable {
        struct Image: Decodable {
            let url: String
            let width: Int?
            let height: Int?
            let title: String?
            let creator: String?
            let license: String
            let license_version: String?
            let foreign_landing_url: String?
        }
        let results: [Image]
    }

    /// Looks the city up on Openverse (free licenses only) and keeps a day and a night
    /// photograph. `attempt` walks further down the results, for "another photo".
    static func search(_ name: String, attempt: Int = 0) async throws -> CityView {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = slugify(name)
        guard !slug.isEmpty else { throw SearchError.nothingFound(name) }
        var entry = Entry(name: name)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        // Openverse can be slow: both searches at once, and the night one may fail alone.
        async let day = candidates("\(name) skyline")
        async let night = candidates("\(name) skyline night")
        // Not a city (a sea, a mountain…): no skyline, so a plain view of it.
        var days = try await day
        if days.isEmpty { days = try await candidates("\(name) landscape") }
        for (kind, found) in [("day", days), ("night", (try? await night) ?? [])] {
            guard !found.isEmpty else { continue }
            let pick = found[attempt % found.count]
            guard let url = URL(string: pick.url), url.scheme == "https" else { continue }
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 10_000 else { continue }
            try data.write(to: customDirectory.appendingPathComponent("\(slug)-\(kind).jpg"))
            let credit = CityView.Credit(title: pick.title, creator: pick.creator, license: pick.license,
                                         license_version: pick.license_version, source: pick.foreign_landing_url)
            if kind == "day" { entry.day = credit } else { entry.night = credit }
        }
        guard entry.day != nil || entry.night != nil else { throw SearchError.nothingFound(name) }
        // A photo from an earlier search would show without its credit.
        for (kind, credit) in [("day", entry.day), ("night", entry.night)] where credit == nil {
            try? FileManager.default.removeItem(at: customDirectory.appendingPathComponent("\(slug)-\(kind).jpg"))
        }
        try JSONEncoder().encode(entry).write(to: customDirectory.appendingPathComponent("\(slug).json"))
        guard let view = find("custom-\(slug)"), view.id == "custom-\(slug)" else { throw SearchError.nothingFound(name) }
        return view
    }

    private static func candidates(_ query: String) async throws -> [Results.Image] {
        var c = URLComponents(string: "https://api.openverse.org/v1/images/")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "license", value: "cc0,pdm,by,by-sa"),
                        URLQueryItem(name: "page_size", value: "20")]
        let (data, _) = try await session.data(from: c.url!)
        // Wide, big enough, and not a panorama strip.
        return try JSONDecoder().decode(Results.self, from: data).results.filter {
            guard let w = $0.width, let h = $0.height, h > 0 else { return false }
            return w >= 1000 && (1.3...2.2).contains(Double(w) / Double(h))
        }
    }

    /// Your own photograph, as the day view (at night it is dimmed, like any view without
    /// a night photo). Copied in, upright, at most 4096 px wide.
    static func importPhoto(_ url: URL) throws -> CityView {
        let name = url.deletingPathExtension().lastPathComponent
        let slug = "photo-" + slugify(name)
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw SearchError.unreadable(name) }
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        let out = customDirectory.appendingPathComponent("\(slug)-day.jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw SearchError.unreadable(name) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SearchError.unreadable(name) }
        try? FileManager.default.removeItem(at: customDirectory.appendingPathComponent("\(slug)-night.jpg"))
        try JSONEncoder().encode(Entry(name: name)).write(to: customDirectory.appendingPathComponent("\(slug).json"))
        guard let view = find("custom-\(slug)"), view.id == "custom-\(slug)" else { throw SearchError.unreadable(name) }
        return view
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func slugify(_ name: String) -> String {
        let ascii = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return ascii.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined().split(separator: "-").joined(separator: "-")
    }
}

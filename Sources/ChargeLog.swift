import Foundation

/// One row of the CSV log: everything the phone said at one instant.
struct LogRow {
    let elapsed: TimeInterval
    let at: Date
    let percent: Int
    let inputV: Double
    let inputA: Double
    let cellV: Double
    let cellA: Double
    let temp: Double?
    /// Whether the phone reported itself charging at this instant.
    let charging: Bool

    var inputW: Double { inputV * inputA }
    var cellW: Double { cellV * cellA }
}

/// What a finished session amounted to.
///
/// The number that decides anything is the rate the level rose at *while the
/// phone said it was charging*. Peak watts alone cannot answer the question that
/// actually got asked -- "why did this take all night" -- because a charge that
/// finished at 00:40 and then sat full until 06:30 has a perfectly good peak and
/// a terrible average over the night. Only the charging span tells them apart.
///
/// Every field added after the first release is optional: summaries written by
/// an older build have to keep decoding.
struct SessionSummary: Codable, Identifiable {
    var id: String
    var startedAt: Date
    var endedAt: Date
    var seconds: Double
    var rows: Int
    var firstPercent: Int
    var lastPercent: Int
    var peakInputW: Double
    var peakCellW: Double
    var peakInputWBelow50: Double
    var sawBelow50: Bool
    var avgInputW: Double
    var maxTemp: Double?
    var cellVoltsNear50: Double?

    // Added with the charging-state column.
    /// Seconds the phone actually reported charging, excluding gaps in sampling.
    var chargingSeconds: Double?
    /// When the level first reached 100 percent.
    var fullAt: Date?
    /// Number of interruptions longer than two minutes.
    var gaps: Int?
    var longestGap: Double?
    /// Watts implied by how fast the level rose while charging.
    var levelWatts: Double?
    /// Percent gained per hour over the charging span.
    var percentPerHour: Double?

    static func summarise(id: String, rows: [LogRow], packWh: Double) -> SessionSummary? {
        guard let first = rows.first, let last = rows.last else { return nil }

        var peakIn = 0.0
        var peakCell = 0.0
        var peakInBelow50 = 0.0
        var sawBelow50 = false
        var sumIn = 0.0
        var maxTemp: Double?
        var near50: (distance: Double, volts: Double)?
        var fullAt: Date?

        for row in rows {
            peakIn = max(peakIn, row.inputW)
            peakCell = max(peakCell, row.cellW)
            sumIn += row.inputW
            if row.percent < 50 {
                sawBelow50 = true
                peakInBelow50 = max(peakInBelow50, row.inputW)
            }
            if let t = row.temp, t > 0, t < 120 {
                maxTemp = max(maxTemp ?? t, t)
            }
            if row.cellV > 2.0, row.cellV < 5.0 {
                let distance = abs(Double(row.percent) - 50)
                if distance < (near50?.distance ?? .infinity) {
                    near50 = (distance, row.cellV)
                }
            }
            if fullAt == nil, row.percent >= 100 {
                fullAt = row.at
            }
        }

        // Seconds genuinely spent charging, and the level gained over them.
        //
        // An interrupted interval is skipped rather than counted: between two
        // rows four hours apart the phone may have charged, idled or been
        // unplugged, and guessing would put a fabricated number in the one
        // figure that is supposed to be trustworthy.
        var chargedSeconds = 0.0
        var chargedPercent = 0
        var gaps = 0
        var longestGap = 0.0

        if rows.count > 1 {
            for index in 1..<rows.count {
                let previous = rows[index - 1]
                let current = rows[index]
                let dt = current.elapsed - previous.elapsed
                guard dt > 0 else { continue }
                if dt > 120 {
                    gaps += 1
                    longestGap = max(longestGap, dt)
                    continue
                }
                guard previous.charging, current.charging else { continue }
                chargedSeconds += dt
                chargedPercent += current.percent - previous.percent
            }
        }

        var levelWatts: Double?
        var percentPerHour: Double?
        if chargedSeconds >= 60, chargedPercent > 0 {
            let percentPerSecond = Double(chargedPercent) / chargedSeconds
            levelWatts = percentPerSecond / 100.0 * packWh * 3600.0
            percentPerHour = percentPerSecond * 3600.0
        }

        return SessionSummary(
            id: id,
            startedAt: first.at,
            endedAt: last.at,
            seconds: last.elapsed,
            rows: rows.count,
            firstPercent: first.percent,
            lastPercent: last.percent,
            peakInputW: peakIn,
            peakCellW: peakCell,
            peakInputWBelow50: peakInBelow50,
            sawBelow50: sawBelow50,
            avgInputW: sumIn / Double(rows.count),
            maxTemp: maxTemp,
            cellVoltsNear50: near50?.volts,
            chargingSeconds: chargedSeconds,
            fullAt: fullAt,
            gaps: gaps,
            longestGap: longestGap,
            levelWatts: levelWatts,
            percentPerHour: percentPerHour)
    }
}

/// Appends samples to disk while a charge is being watched, and settles whatever
/// a previous run left behind.
///
/// Writing as we go is the whole point: iOS suspends this app a few seconds after
/// the screen goes off, so anything held only in memory is gone by morning. On
/// disk it survives, and the level at the start against the level now still spans
/// the night even though almost no samples do.
final class ChargeLog {
    static let shared = ChargeLog()

    private let fm = FileManager.default
    private let root: URL
    private let stamp: DateFormatter

    private var handle: FileHandle?
    private(set) var currentID: String?
    private(set) var currentURL: URL?
    private(set) var rowsWritten = 0

    private let header = "elapsed_s,time,percent,charging,input_V,input_A,input_W,cell_V,cell_A,cell_W,temp_C"

    private struct OpenMarker: Codable {
        var id: String
        var startedAt: Date
        var packWh: Double
    }

    private init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("ChargeLog", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    var folder: URL { root }

    private var openMarkerURL: URL { root.appendingPathComponent("open.json") }

    private func csvURL(_ id: String) -> URL { root.appendingPathComponent("\(id).csv") }
    private func summaryURL(_ id: String) -> URL { root.appendingPathComponent("\(id).json") }

    var isRecording: Bool { handle != nil }

    // MARK: - Recording

    @discardableResult
    func begin(packWh: Double, resuming: Bool = false) -> URL? {
        if resuming, let existing = currentID {
            return csvURL(existing)
        }
        close()
        let id = Self.sessionID(for: Date())
        let url = csvURL(id)
        fm.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        currentID = id
        currentURL = url
        rowsWritten = 0
        write(header + "\n")
        let marker = OpenMarker(id: id, startedAt: Date(), packWh: packWh)
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: openMarkerURL)
        }
        return url
    }

    /// Reopen the session an earlier run left open, so a background wake-up
    /// appends to the same charge instead of starting a new one.
    @discardableResult
    func reopen(packWh: Double) -> Bool {
        guard let data = try? Data(contentsOf: openMarkerURL),
              let marker = try? JSONDecoder().decode(OpenMarker.self, from: data)
        else { return false }
        let url = csvURL(marker.id)
        guard fm.fileExists(atPath: url.path),
              let h = try? FileHandle(forWritingTo: url)
        else { return false }
        try? h.seekToEnd()
        handle = h
        currentID = marker.id
        currentURL = url
        rowsWritten = 0
        return true
    }

    func append(_ row: LogRow) {
        guard handle != nil else { return }
        let temp = row.temp.map { String(format: "%.1f", $0) } ?? ""
        // Built by concatenation rather than one format string: `%d` reads 32 bits
        // and Swift's `Int` is 64, which silently garbles the column on arm64.
        let line = String(format: "%.1f", row.elapsed) + ","
            + stamp.string(from: row.at) + ","
            + "\(row.percent)" + ","
            + (row.charging ? "1" : "0") + ","
            + String(format: "%.3f,%.3f,%.2f", row.inputV, row.inputA, row.inputW) + ","
            + String(format: "%.3f,%.3f,%.2f", row.cellV, row.cellA, row.cellW) + ","
            + temp + "\n"
        write(line)
        rowsWritten += 1
    }

    /// Push what has been written to disk without ending the session.
    ///
    /// Called when the app is about to be suspended: the process freezes a few
    /// seconds later, so this is the last chance to make the rows durable. The
    /// session itself stays open -- the marker on disk is what lets the next
    /// launch pick the charge up again instead of throwing the night away.
    func flush() {
        try? handle?.synchronize()
    }

    /// Close the file and write the summary beside it.
    func close(packWh: Double = 12.7) {
        guard let id = currentID else { return }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let rows = readRows(id)
        if let summary = SessionSummary.summarise(id: id, rows: rows, packWh: packWh) {
            writeSummary(summary)
        }
        try? fm.removeItem(at: openMarkerURL)
        currentID = nil
        currentURL = nil
    }

    /// Whether a session is still marked as open on disk.
    var hasOpenSession: Bool {
        fm.fileExists(atPath: openMarkerURL.path)
    }

    var openSessionStartedAt: Date? {
        guard let data = try? Data(contentsOf: openMarkerURL),
              let marker = try? JSONDecoder().decode(OpenMarker.self, from: data)
        else { return nil }
        return marker.startedAt
    }

    // MARK: - Settling a run that never got to stop

    /// Find a session a previous run left open, summarise it, and report it.
    ///
    /// This is what turns "I charged all night and saw nothing" into an answer:
    /// the marker on disk says a session was under way, and the CSV still holds
    /// the level it started at.
    func settleOrphanedSession(packWh: Double) -> SessionSummary? {
        guard let data = try? Data(contentsOf: openMarkerURL),
              let marker = try? JSONDecoder().decode(OpenMarker.self, from: data)
        else { return nil }

        var rows = readRows(marker.id)
        if rows.isEmpty {
            try? fm.removeItem(at: openMarkerURL)
            return nil
        }

        // The last row was written before the process froze; append where the
        // phone is now so the summary spans the whole night. The gap is visible
        // as a gap in the summary, not silently smoothed over.
        if let last = rows.last, let now = PowerSources()?.read() {
            let gap = Date().timeIntervalSince(last.at)
            if gap > 30 {
                rows.append(LogRow(elapsed: last.elapsed + gap,
                                   at: Date(),
                                   percent: now.percent,
                                   inputV: last.inputV,
                                   inputA: last.inputA,
                                   cellV: last.cellV,
                                   cellA: last.cellA,
                                   temp: last.temp,
                                   charging: now.charging))
            }
        }

        guard let summary = SessionSummary.summarise(id: marker.id, rows: rows, packWh: packWh) else {
            try? fm.removeItem(at: openMarkerURL)
            return nil
        }
        writeSummary(summary)
        try? fm.removeItem(at: openMarkerURL)
        return summary
    }

    // MARK: - Reading back

    func summaries() -> [SessionSummary] {
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [SessionSummary] = []
        for name in names where name.hasSuffix(".json") && name != "open.json" {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let summary = try? JSONDecoder().decode(SessionSummary.self, from: data)
            else { continue }
            out.append(summary)
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    func csvText(_ id: String) -> String {
        (try? String(contentsOf: csvURL(id), encoding: .utf8)) ?? ""
    }

    /// Every row of a session, for drawing its curve.
    func rows(_ id: String) -> [LogRow] { readRows(id) }

    func csvURLFor(_ id: String) -> URL { csvURL(id) }

    func delete(_ id: String) {
        try? fm.removeItem(at: csvURL(id))
        try? fm.removeItem(at: summaryURL(id))
    }

    // MARK: - Plumbing

    private func write(_ text: String) {
        guard let handle, let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private func writeSummary(_ summary: SessionSummary) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(summary) {
            try? data.write(to: summaryURL(summary.id))
        }
    }

    private func readRows(_ id: String) -> [LogRow] {
        guard let text = try? String(contentsOf: csvURL(id), encoding: .utf8) else { return [] }
        var out: [LogRow] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            // Two column layouts in the wild: the first release wrote ten fields,
            // everything after it writes eleven with the charging flag in fourth.
            let tagged = fields.count >= 11
            let v = tagged ? 4 : 3
            guard fields.count > v + 6,
                  let elapsed = Double(fields[0]),
                  let at = stamp.date(from: String(fields[1])),
                  let percent = Int(fields[2]),
                  let inputV = Double(fields[v]),
                  let inputA = Double(fields[v + 1]),
                  let cellV = Double(fields[v + 3]),
                  let cellA = Double(fields[v + 4])
            else { continue }

            let tempIndex = v + 6
            let temp = fields.count > tempIndex ? Double(fields[tempIndex]) : nil
            // Untagged rows have no charging flag; a cell taking current is the
            // best available evidence that it was.
            let charging = tagged ? fields[3] == "1" : cellA > 0.05

            out.append(LogRow(elapsed: elapsed, at: at, percent: percent,
                              inputV: inputV, inputA: inputA,
                              cellV: cellV, cellA: cellA,
                              temp: temp, charging: charging))
        }
        return out
    }

    private static func sessionID(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

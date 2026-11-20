import SwiftUI

struct ContentView: View {
    @ObservedObject private var d = Diagnosis.shared
    @Environment(\.scenePhase) private var scenePhase

    private let bg = Color(red: 0.06, green: 0.07, blue: 0.09)
    private let card = Color(red: 0.11, green: 0.12, blue: 0.15)
    private let dim = Color(red: 0.55, green: 0.58, blue: 0.64)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    bigNumber
                    grid
                    chartCard
                    detailRows
                    actionButton
                    if let verdict = d.verdict {
                        verdictCard(verdict)
                    }
                    if let mismatch = d.voltageMismatch() {
                        noteCard(mismatch, tint: Color(red: 0.98, green: 0.68, blue: 0.19))
                    }
                    if let error = d.sensorError {
                        noteCard(error, tint: Color(red: 0.95, green: 0.34, blue: 0.30))
                    }
                    sessionsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $d.showingShares) {
            ShareSheet(items: d.shareItems())
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .inactive, .background: d.sceneWillResignActive()
            case .active: d.sceneDidBecomeActive()
            @unknown default: break
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("充电诊断")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(d.running ? "正在记录" : (d.charging ? "正在充电" : "未连接充电器"))
                    .font(.system(size: 13))
                    .foregroundColor(d.running ? Color(red: 0.35, green: 0.72, blue: 1.0)
                                               : (d.charging ? Color(red: 0.20, green: 0.78, blue: 0.45) : dim))
            }
            Spacer()
            Text("\(d.percent)%")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.top, 8)
    }

    private var bigNumber: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", d.inputWatts))
                    .font(.system(size: 66, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("W")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(dim)
            }
            Text("充电器输入 · 当前")
                .font(.system(size: 13))
                .foregroundColor(dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var grid: some View {
        HStack(spacing: 10) {
            statTile("本次峰值", String(format: "%.1f", d.peakInput), "W",
                     tint: Color(red: 0.35, green: 0.72, blue: 1.0))
            statTile("低电量峰值", String(format: "%.1f", d.peakInputBelow50), "W",
                     tint: Color(red: 0.66, green: 0.55, blue: 0.98))
            statTile("电池温度", d.batteryTemp.map { String(format: "%.0f", $0) } ?? "—", "°C",
                     tint: Color(red: 0.98, green: 0.68, blue: 0.19))
        }
    }

    private func statTile(_ title: String, _ value: String, _ unit: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundColor(dim)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("功率曲线")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text(d.chartLabel)
                    .font(.system(size: 11))
                    .foregroundColor(dim)
                    .lineLimit(1)
            }
            WattsCurve(rows: d.chart)
                .frame(height: 148)
            HStack(spacing: 16) {
                legendDot(Color(red: 0.35, green: 0.72, blue: 1.0), "充电器输入")
                legendDot(Color(red: 0.66, green: 0.55, blue: 0.98), "进入电池")
                Spacer()
            }
        }
        .padding(14)
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(dim)
        }
    }

    private var detailRows: some View {
        VStack(spacing: 0) {
            row("USB-C 输入", String(format: "%.2f V × %.2f A", d.inputVolts, d.inputAmps))
            divider
            row("进入电池", String(format: "%.1f W", d.cellWatts))
            divider
            row("已记录", "\(d.rows) 条 · \(timeText)")
            divider
            row("容量假设", d.packWhText)
        }
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 16)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(dim)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var timeText: String {
        let total = Int(d.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var actionButton: some View {
        Button {
            if d.running { d.stop() } else { d.start() }
        } label: {
            Text(d.running ? "停止并保存日志" : "开始记录")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func verdictCard(_ verdict: Verdict) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(verdict.level.tint)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(verdict.headline)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(verdict.level.tint)
                Text(verdict.detail)
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.80, green: 0.82, blue: 0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func noteCard(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(tint)
                .padding(.top, 3)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.75, green: 0.77, blue: 0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("历史记录")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                if !d.sessions.isEmpty {
                    Button {
                        d.showingShares = true
                    } label: {
                        Text("导出日志")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 0.35, green: 0.72, blue: 1.0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)

            if d.sessions.isEmpty {
                Text("还没有记录。点上面的按钮开始，或者插上充电器放一晚上，下次打开会自动结算。")
                    .font(.system(size: 12))
                    .foregroundColor(dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                ForEach(d.sessions.prefix(8)) { summary in
                    sessionCard(summary)
                }
            }
        }
    }

    private func sessionCard(_ summary: SessionSummary) -> some View {
        let peak = summary.sawBelow50 ? summary.peakInputWBelow50 : summary.peakInputW
        let tint: Color = peak >= 18 ? Color(red: 0.20, green: 0.78, blue: 0.45)
            : (peak >= 12 ? Color(red: 0.98, green: 0.68, blue: 0.19) : Color(red: 0.95, green: 0.34, blue: 0.30))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: "峰值 %.1f W", peak))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(tint)
            }
            Text("\(summary.firstPercent)% → \(summary.lastPercent)% · \(summary.rows) 条 · " + duration(summary.seconds))
                .font(.system(size: 11))
                .foregroundColor(dim)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { d.loadChart(for: summary) }
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return "\(total / 3600) 小时 \((total % 3600) / 60) 分"
        }
        return "\(max(1, total / 60)) 分"
    }
}

/// The charge's shape: charger input and what reached the cell, against time.
///
/// Drawn by hand rather than with Swift Charts, which needs iOS 16 -- this app
/// still installs on 15. Two lines is not worth raising the floor for.
private struct WattsCurve: View {
    let rows: [LogRow]

    private let inputColor = Color(red: 0.35, green: 0.72, blue: 1.0)
    private let cellColor = Color(red: 0.66, green: 0.55, blue: 0.98)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if rows.count < 2 || w < 10 || h < 10 {
                Text("记录开始后，这里会画出功率随时间的变化。")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.45, green: 0.48, blue: 0.54))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let pts = Self.thin(rows, to: 260)
                let t0 = pts[0].elapsed
                let t1 = max(pts[pts.count - 1].elapsed, t0 + 1)
                let peak = max(pts.map { $0.inputW }.max() ?? 0, 5)
                let top = max(5, (peak / 5).rounded(.up) * 5)

                ZStack(alignment: .topLeading) {
                    grid(top: top, w: w, h: h)

                    area(pts, t0: t0, t1: t1, top: top, w: w, h: h)
                        .fill(LinearGradient(colors: [inputColor.opacity(0.28), inputColor.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))

                    line(pts, value: { $0.cellW }, t0: t0, t1: t1, top: top, w: w, h: h)
                        .stroke(cellColor.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

                    line(pts, value: { $0.inputW }, t0: t0, t1: t1, top: top, w: w, h: h)
                        .stroke(LinearGradient(colors: [inputColor, inputColor.opacity(0.65)],
                                               startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(format: "%.0f W", top))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(red: 0.45, green: 0.48, blue: 0.54))
                        Spacer()
                        Text("0")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(red: 0.45, green: 0.48, blue: 0.54))
                    }
                }
            }
        }
    }

    private func grid(top: Double, w: CGFloat, h: CGFloat) -> some View {
        Path { p in
            for step in 0...4 {
                let y = h * CGFloat(step) / 4
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
            }
        }
        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
    }

    private func line(_ pts: [LogRow],
                      value: (LogRow) -> Double,
                      t0: Double, t1: Double, top: Double,
                      w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        for (index, row) in pts.enumerated() {
            let x = CGFloat((row.elapsed - t0) / (t1 - t0)) * w
            let y = h - CGFloat(min(max(value(row), 0), top) / top) * h
            if index == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }

    private func area(_ pts: [LogRow],
                      t0: Double, t1: Double, top: Double,
                      w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        for (index, row) in pts.enumerated() {
            let x = CGFloat((row.elapsed - t0) / (t1 - t0)) * w
            let y = h - CGFloat(min(max(row.inputW, 0), top) / top) * h
            if index == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }

    private static func thin(_ rows: [LogRow], to limit: Int) -> [LogRow] {
        guard rows.count > limit else { return rows }
        let step = Double(rows.count) / Double(limit)
        var out: [LogRow] = []
        out.reserveCapacity(limit + 1)
        var i = 0.0
        while Int(i) < rows.count {
            out.append(rows[Int(i)])
            i += step
        }
        if let last = rows.last, out.last?.at != last.at { out.append(last) }
        return out
    }
}

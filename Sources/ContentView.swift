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
                    keeperCard
                    if let verdict = d.verdict {
                        verdictCard(verdict)
                    }
                    if let mismatch = d.voltageMismatch() {
                        noteCard(mismatch, tint: Color(red: 0.98, green: 0.68, blue: 0.19))
                    }
                    if let error = d.sensorError {
                        noteCard(error, tint: Color(red: 0.95, green: 0.34, blue: 0.30))
                    }
                    if d.running {
                        noteCard(keepingNote, tint: keepingTint)
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
            Text(d.charging ? "充电器输入 · 当前" : "充电器输入 · 未在充电")
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

    /// A hook that installed proves only that the method exists. The count is the
    /// half that matters: it only rises when the system actually asked to suspend us
    /// and was refused.
    private var sceneText: String {
        guard d.sceneHookInstalled else { return "不可用" }
        if d.blockedTransitions > 0 { return "已拦下 \(d.blockedTransitions) 次" }
        return d.running ? "已安装，尚未触发" : "已安装"
    }

    private var audioText: String {
        guard d.useAudio else { return "关" }
        return d.backgroundAudio ? "运行中" : "已开启，未启动"
    }

    private var keepingNote: String {
        if d.blockedTransitions > 0 {
            return "系统已经 \(d.blockedTransitions) 次想把 App 挂起，都被拦下了，锁屏后仍会持续记录。"
        }
        if d.sceneHookInstalled {
            return "挂起拦截已装好，但还没拦下过任何一次。锁屏几分钟再回来看这里的数字。"
        }
        if d.backgroundAudio {
            return "挂起拦截不可用，现在是音频会话在保活，整晚能连续记录，但会占用音频通道。"
        }
        return "两条保活通道都没生效，锁屏后系统会冻结这个 App，只能在偶尔唤醒时补采。"
    }

    private var keepingTint: Color {
        if d.blockedTransitions > 0 { return Color(red: 0.20, green: 0.78, blue: 0.45) }
        if d.sceneHookInstalled { return Color(red: 0.35, green: 0.72, blue: 1.0) }
        if d.backgroundAudio { return Color(red: 0.98, green: 0.68, blue: 0.19) }
        return Color(red: 0.98, green: 0.68, blue: 0.19)
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
                Text("断口 = 息屏未采到")
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.42, green: 0.45, blue: 0.52))
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
            row("充电状态", d.charging ? "充电中" : "未充电")
            divider
            row("挂起拦截", sceneText)
            divider
            row("音频保活", audioText)
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

    private var keeperCard: some View {
        VStack(spacing: 0) {
            keeperRow(
                "保持屏幕常亮",
                "长时间亮屏有残影风险，一般用不到",
                isOn: Binding(get: { d.keepScreenOn }, set: { d.keepScreenOn = $0 })
            )
            divider
            keeperRow(
                "静音音频保活",
                "会和正在播放的音乐、视频抢音频通道，只在挂起拦截不可用时才需要",
                isOn: Binding(get: { d.useAudio }, set: { d.useAudio = $0 })
            )
        }
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func keeperRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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
        // Judge on the rate the level rose at, falling back to the peak for
        // summaries written before the charging column existed.
        let judged = summary.levelWatts ?? (summary.sawBelow50 ? summary.peakInputWBelow50 : summary.peakInputW)
        let tint: Color = judged >= 12 ? Color(red: 0.20, green: 0.78, blue: 0.45)
            : (judged >= 6 ? Color(red: 0.98, green: 0.68, blue: 0.19) : Color(red: 0.95, green: 0.34, blue: 0.30))

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: "%.1f W", judged))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(tint)
            }
            Text("\(summary.firstPercent)% → \(summary.lastPercent)% · 跨度 \(duration(summary.seconds)) · \(summary.rows) 条")
                .font(.system(size: 11))
                .foregroundColor(dim)

            if let charged = summary.chargingSeconds, charged > 0 {
                HStack(spacing: 10) {
                    chip("充电 \(duration(charged))")
                    if let perHour = summary.percentPerHour {
                        chip(String(format: "%.0f%%/h", perHour))
                    }
                    if let gaps = summary.gaps, gaps > 0 {
                        chip("断口 \(gaps)")
                    }
                    if let fullAt = summary.fullAt {
                        chip("满于 " + fullAt.formatted(date: .omitted, time: .shortened))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { d.loadChart(for: summary) }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(Color(red: 0.62, green: 0.66, blue: 0.74))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())
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
///
/// Intervals the app was frozen for are left as breaks in the line. Joining them
/// would draw a smooth curve through data that does not exist, which is exactly
/// how a night that finished at one in the morning comes to look like it took
/// six hours.
private struct WattsCurve: View {
    let rows: [LogRow]

    private let inputColor = Color(red: 0.35, green: 0.72, blue: 1.0)
    private let cellColor = Color(red: 0.66, green: 0.55, blue: 0.98)
    /// Anything longer than this is a suspension, not a sampling interval.
    private static let gapThreshold: TimeInterval = 120

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

                    segment(pts, value: { $0.cellW }, t0: t0, t1: t1, top: top, w: w, h: h)
                        .stroke(cellColor.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

                    segment(pts, value: { $0.inputW }, t0: t0, t1: t1, top: top, w: w, h: h)
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

    /// A path that starts a new subpath wherever the sampling stopped, so a
    /// suspension shows as a break instead of a straight line across it.
    private func segment(_ pts: [LogRow],
                         value: (LogRow) -> Double,
                         t0: Double, t1: Double, top: Double,
                         w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        var previous: LogRow?
        for row in pts {
            let x = CGFloat((row.elapsed - t0) / (t1 - t0)) * w
            let y = h - CGFloat(min(max(value(row), 0), top) / top) * h
            let broken = previous.map { row.elapsed - $0.elapsed > Self.gapThreshold } ?? true
            if broken {
                p.move(to: CGPoint(x: x, y: y))
            } else {
                p.addLine(to: CGPoint(x: x, y: y))
            }
            previous = row
        }
        return p
    }

    private func area(_ pts: [LogRow],
                      t0: Double, t1: Double, top: Double,
                      w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        var runStart: CGFloat?

        func closeRun(_ endX: CGFloat) {
            guard let startX = runStart else { return }
            p.addLine(to: CGPoint(x: endX, y: h))
            p.addLine(to: CGPoint(x: startX, y: h))
            p.closeSubpath()
            runStart = nil
        }

        var previous: LogRow?
        for row in pts {
            let x = CGFloat((row.elapsed - t0) / (t1 - t0)) * w
            let y = h - CGFloat(min(max(row.inputW, 0), top) / top) * h
            let broken = previous.map { row.elapsed - $0.elapsed > Self.gapThreshold } ?? false

            if broken {
                closeRun(CGFloat((previous!.elapsed - t0) / (t1 - t0)) * w)
            }
            if runStart == nil {
                runStart = x
                p.move(to: CGPoint(x: x, y: y))
            } else {
                p.addLine(to: CGPoint(x: x, y: y))
            }
            previous = row
        }
        closeRun(w)
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

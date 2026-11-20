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
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return "\(total / 3600) 小时 \((total % 3600) / 60) 分"
        }
        return "\(max(1, total / 60)) 分"
    }
}

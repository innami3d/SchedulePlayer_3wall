import SwiftUI
import AppKit
import PlayerCore

struct ProjectSettingsView: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject var devices: OutputDevices
    private func binding<T>(_ path: WritableKeyPath<PlayerProject, T>) -> Binding<T> {
        Binding(get: { store.project[keyPath: path] }, set: { value in store.change { $0[keyPath: path] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("プロジェクト").font(.caption).foregroundStyle(.secondary)
                    Text("出力設定").font(.title2).fontWeight(.semibold)
                }
                Spacer()
                Button("出力機器を再取得", systemImage: "arrow.clockwise") { devices.refresh() }.controlHover()
            }
            Form {
                Section("プロジェクト") {
                    LabeledContent("プロジェクト名") {
                        Text(store.project.name).textSelection(.enabled)
                    }
                    Text("プロジェクト名はファイル名と同期します。変更するには「名前を付けて保存…」を使ってください。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(store.fileURL?.path ?? "未保存のプロジェクト").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section("映像出力 · 4K固定 / 1系統") {
                    Picker("映像出力先", selection: Binding(get: { store.selectedDisplay?.id ?? store.project.displayID.map { _ in UInt32.max } }, set: store.selectDisplay)) {
                        Text("出力先を選択").tag(nil as UInt32?)
                        if store.selectedDisplay == nil, store.project.displayID != nil {
                            Text("\(store.project.displayName ?? "前回のディスプレイ")（未接続・自動再接続待ち）").tag(Optional(UInt32.max))
                        }
                        ForEach(devices.displays) { display in Text(display.name).tag(Optional(display.id)) }
                    }.fieldHover()
                    if rates.isEmpty {
                        Text("接続先に対応する4Kモードがありません。4K対応の出力先を選択してください。")
                            .foregroundStyle(.orange).font(.caption)
                    } else {
                        Picker("送出リフレッシュレート", selection: binding(\.refreshRate)) {
                            if !rates.contains(where: { abs($0 - store.project.refreshRate) < 0.01 }) {
                                Text("\(store.project.refreshRate.formatted()) Hz（現在未対応）").tag(store.project.refreshRate)
                            }
                            ForEach(rates, id: \.self) { rate in Text("\(rate.formatted()) Hz").tag(rate) }
                        }.fieldHover()
                    }
                    Text("出力開始時に4K信号へ切り替え、終了時に元の画面設定へ戻します。素材のfpsは変更しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("音声出力") {
                    Picker("音声出力先", selection: Binding(get: { store.project.audioDeviceUID }, set: store.selectAudioDevice)) {
                        Text("システムのデフォルト").tag(nil as String?)
                        if let uid = store.project.audioDeviceUID, !devices.audio.contains(where: { $0.id == uid }) {
                            Text("\(store.project.audioDeviceName ?? "前回の音声機器")（未接続・自動再接続待ち）").tag(Optional(uid))
                        }
                        ForEach(devices.audio) { device in Text(device.name).tag(Optional(device.id)) }
                    }.fieldHover()
                }
            }.formStyle(.grouped).disabled(store.locked)
            Text("再生する日時と開始・終了フェードは「スケジューラ設定」で指定します。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
    private var rates: [Double] { store.selectedDisplay?.rates ?? [] }
}

struct TimeField: View {
    var title: String
    @Binding var value: TimeOfDay
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("HH:mm:ss", text: $draft).monospacedDigit().textFieldStyle(.roundedBorder).fieldHover()
                .focused($focused).onSubmit(commit)
                .onAppear { draft = value.text }
                .onChange(of: focused) { _, now in if !now { commit() } }
                .onChange(of: value) { _, now in if !focused { draft = now.text } }
                .onChange(of: draft) { _, now in if focused, let parsed = TimeOfDay(text: now), parsed != value { value = parsed } }
            if invalid { Text("00:00:00〜23:59:59で入力").font(.caption).foregroundStyle(.red) }
        }
    }
    private func commit() {
        if let parsed = TimeOfDay(text: draft) { value = parsed; draft = parsed.text; invalid = false }
        else { invalid = true }
    }
}

struct NumberField: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var maximumFractionDigits: Int = 3
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } }), format: .number.precision(.fractionLength(0...maximumFractionDigits)))
                .textFieldStyle(.roundedBorder).monospacedDigit().fieldHover()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ImageDurationUnit: String, CaseIterable, Identifiable {
    case hours = "時間", minutes = "分", seconds = "秒"
    var id: Self { self }
    var secondsPerUnit: Double {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3600
        }
    }
}

struct ImageDurationField: View {
    @Binding var seconds: Double
    var maximum: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("画像表示時間").font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(ImageDurationUnit.allCases) { component in
                    NumberField(title: component.rawValue, value: value(in: component),
                                range: range(for: component),
                                maximumFractionDigits: component == .seconds ? 3 : 0)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("画像表示時間・\(component.rawValue)")
                }
            }
        }
    }

    private func range(for component: ImageDurationUnit) -> ClosedRange<Double> {
        switch component {
        case .hours: return 0...floor(maximum / 3600)
        case .minutes: return 0...59
        case .seconds: return 0...59.999
        }
    }

    private func componentValue(_ component: ImageDurationUnit) -> Double {
        switch component {
        case .hours: return floor(seconds / 3600)
        case .minutes: return floor(seconds / 60).truncatingRemainder(dividingBy: 60)
        case .seconds: return seconds.truncatingRemainder(dividingBy: 60)
        }
    }

    func value(in component: ImageDurationUnit) -> Binding<Double> {
        Binding(get: { componentValue(component) }, set: { value in
            guard value.isFinite else { return }
            let bounds = range(for: component)
            let clamped = min(bounds.upperBound, max(bounds.lowerBound, value))
            let replacement = component == .seconds ? clamped : floor(clamped)
            let converted = seconds + (replacement - componentValue(component)) * component.secondsPerUnit
            seconds = min(maximum, max(0.1, converted))
        })
    }
}

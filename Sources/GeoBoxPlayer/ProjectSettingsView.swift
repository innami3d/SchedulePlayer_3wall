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
                    Text("出力・稼働時間").font(.title2).fontWeight(.semibold)
                }
                Spacer()
                Button("出力機器を再取得", systemImage: "arrow.clockwise") { devices.refresh() }
            }
            Form {
                Section("プロジェクト") {
                    TextField("プロジェクト名", text: binding(\.name))
                    Text(store.fileURL?.path ?? "未保存のプロジェクト").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section("映像出力 · 4K固定 / 1系統") {
                    Picker("映像出力先", selection: Binding(get: { store.selectedDisplay?.id ?? store.project.displayID.map { _ in UInt32.max } }, set: store.selectDisplay)) {
                        Text("出力先を選択").tag(nil as UInt32?)
                        if store.selectedDisplay == nil, store.project.displayID != nil {
                            Text("\(store.project.displayName ?? "前回のディスプレイ")（未接続・自動再接続待ち）").tag(Optional(UInt32.max))
                        }
                        ForEach(devices.displays) { display in Text(display.name).tag(Optional(display.id)) }
                    }
                    if rates.isEmpty {
                        Text("接続先に対応する4Kモードがありません。4K対応の出力先を選択してください。")
                            .foregroundStyle(.orange).font(.caption)
                    } else {
                        Picker("送出リフレッシュレート", selection: binding(\.refreshRate)) {
                            if !rates.contains(where: { abs($0 - store.project.refreshRate) < 0.01 }) {
                                Text("\(store.project.refreshRate.formatted()) Hz（現在未対応）").tag(store.project.refreshRate)
                            }
                            ForEach(rates, id: \.self) { rate in Text("\(rate.formatted()) Hz").tag(rate) }
                        }
                    }
                    Text("出力開始時に4K信号へ切り替え、終了時に元の画面設定へ戻します。素材のfpsは変更しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    OutputScheduleFields(store: store, lane: .video)
                }
                Section("音声出力") {
                    Picker("音声出力先", selection: Binding(get: { store.project.audioDeviceUID }, set: store.selectAudioDevice)) {
                        Text("システムのデフォルト").tag(nil as String?)
                        if let uid = store.project.audioDeviceUID, !devices.audio.contains(where: { $0.id == uid }) {
                            Text("\(store.project.audioDeviceName ?? "前回の音声機器")（未接続・自動再接続待ち）").tag(Optional(uid))
                        }
                        ForEach(devices.audio) { device in Text(device.name).tag(Optional(device.id)) }
                    }
                    OutputScheduleFields(store: store, lane: .audio)
                }
                Section("共通再生設定") {
                    HStack {
                        NumberField(title: "映像トラック間 IN（秒）", value: binding(\.defaults.videoTrackFades.fadeIn), range: 0...safeFadeMax)
                        NumberField(title: "映像トラック間 OUT（秒）", value: binding(\.defaults.videoTrackFades.fadeOut), range: 0...safeFadeMax)
                    }
                    HStack {
                        NumberField(title: "音声トラック間 IN（秒）", value: binding(\.defaults.audioTrackFades.fadeIn), range: 0...safeFadeMax)
                        NumberField(title: "音声トラック間 OUT（秒）", value: binding(\.defaults.audioTrackFades.fadeOut), range: 0...safeFadeMax)
                    }
                    ColorPicker("映像フェード先", selection: Binding(get: { Color(nsColor: NSColor(hex: store.project.fadeColorHex)) }, set: { color in
                        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                        store.change { $0.fadeColorHex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) }
                    }), supportsOpacity: false)
                    Text("トラック間フェードは全対象に適用し、0秒でフェードなしになります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(store.locked)
            Text("時刻は日付なしで毎日適用。終了時刻に全体のフェードアウトを開始します。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
    private var safeFadeMax: Double { max(0, store.project.defaults.fadeMax) }
    private var rates: [Double] { store.selectedDisplay?.rates ?? [] }
}

struct OutputScheduleFields: View {
    @ObservedObject var store: PlayerStore
    var lane: MediaLane
    private var schedule: OutputSchedule { store.project.schedule(for: lane) }
    private func binding<T>(_ path: WritableKeyPath<OutputSchedule, T>) -> Binding<T> {
        Binding(get: { schedule[keyPath: path] }, set: { value in
            store.change { if lane == .video { $0.video[keyPath: path] = value } else { $0.audio[keyPath: path] = value } }
        })
    }
    var body: some View {
        Picker("デフォルト再生プレイリスト", selection: binding(\.initialPlaylistID)) {
            Text("指定なし").tag(nil as UUID?)
            ForEach(store.project.playlists.filter { $0.lane == lane }) { p in Text(p.name).tag(Optional(p.id)) }
            if let id = schedule.initialPlaylistID, store.project.playlist(id) == nil { Text("指定先は削除済み").tag(Optional(id)) }
        }
        HStack {
            TimeField(title: "開始時刻", value: binding(\.start))
            TimeField(title: "終了時刻（OUT開始）", value: binding(\.end))
        }
        HStack {
            NumberField(title: "開始フェード（秒）", value: binding(\.fades.fadeIn), range: 0...max(0, store.project.defaults.fadeMax))
            NumberField(title: "終了フェード（秒）", value: binding(\.fades.fadeOut), range: 0...max(0, store.project.defaults.fadeMax))
        }
    }
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
            TextField("HH:mm:ss", text: $draft).monospacedDigit().textFieldStyle(.roundedBorder)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } }), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI
import PlayerCore

struct SchedulerSettingsView: View {
    @ObservedObject var store: PlayerStore
    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @State private var dayView = false
    @State private var editing: CalendarEditSession?
    @State private var pendingMove: CalendarEditSession?
    @State private var hoveredSlot: CalendarHoverSlot?
    @State private var resizePreview: CalendarResizePreview?
    @State private var movePreview: CalendarResizePreview?
    @State private var rangePreview: CalendarRangePreview?
    @GestureState private var isSelectingRange = false
    @GestureState private var isMoving = false
    @GestureState private var isResizing = false
    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 64
    private var days: [Date] {
        (0..<(dayView ? 1 : 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: anchor) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("プロジェクト").font(.caption).foregroundStyle(.secondary)
                    Text("スケジューラ設定").font(.title2).fontWeight(.semibold)
                }
                Spacer()
                Button("予定を追加", systemImage: "plus") { create(at: Date()) }
                    .controlHover().disabled(store.locked || store.project.playlists.isEmpty)
            }
            HStack {
                Button("今日") { anchor = calendar.startOfDay(for: Date()) }.controlHover()
                Button { navigate(-1) } label: { Image(systemName: "chevron.left") }.controlHover()
                Button { navigate(1) } label: { Image(systemName: "chevron.right") }.controlHover()
                Text(anchor.formatted(.dateTime.year().month().day()))
                    .font(.headline).monospacedDigit()
                Spacer()
                Picker("表示", selection: $dayView) {
                    Text("週").tag(false)
                    Text("日").tag(true)
                }.pickerStyle(.segmented).frame(width: 110).controlHover()
            }
            HStack(spacing: 16) {
                Label("映像", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("音声", systemImage: "circle.fill").foregroundStyle(.orange)
                Text("空き時間をなぞって予定を追加 · ダブルクリックでも追加 · 予定本体で移動・上下端で長さ調整")
                    .foregroundStyle(.secondary)
            }.font(.caption)
            calendarGrid
            Text("終了時刻にフェードアウトを開始します。同じ系統の予定が重なる場合は開始が遅い予定を優先し、終了後は残っている予定へ戻ります。")
                .font(.caption).foregroundStyle(.secondary)
            if store.project.playlists.isEmpty {
                Text("左のメニューでプレイリストを作成し、カレンダーへドラッグしてください。")
                    .foregroundStyle(.secondary)
            }
        }.padding(24)
            .onChange(of: isResizing) { _, active in if !active { resizePreview = nil } }
            .onChange(of: isMoving) { _, active in if !active { movePreview = nil } }
            .onChange(of: isSelectingRange) { _, active in if !active { rangePreview = nil } }
            .onChange(of: store.locked) { _, _ in resizePreview = nil; movePreview = nil; hoveredSlot = nil; rangePreview = nil }
            .onChange(of: anchor) { _, _ in hoveredSlot = nil; rangePreview = nil }
            .onChange(of: dayView) { _, _ in hoveredSlot = nil; rangePreview = nil }
            .sheet(item: $editing) { session in
                CalendarEntryEditor(store: store, session: session)
            }
            .confirmationDialog("変更する繰り返し予定の範囲", isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible, presenting: pendingMove) { move in
                ForEach(CalendarEditScope.allCases) { scope in
                    Button(scope.title) {
                        if let id = move.sourceID {
                            store.editCalendarEntry(id: id, occurrenceStart: move.occurrenceStart, replacement: move.entry, scope: scope)
                        }
                        pendingMove = nil
                    }
                }
                Button("キャンセル", role: .cancel) { pendingMove = nil }
            }
    }
    private var calendarGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("時刻").font(.caption).frame(width: 52)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                        Text(day.formatted(.dateTime.day())).font(.title3).fontWeight(.medium)
                        HStack { Text("映像"); Text("音声") }.font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                        .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : .primary)
                        .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(0.08) : .clear)
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in
                                Text(String(format: "%02d:00", hour)).font(.caption2).monospacedDigit()
                                    .foregroundStyle(.secondary).frame(width: 52, height: hourHeight, alignment: .top)
                                    .id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in dayColumn(day) }
                    }.padding(.top, 8).coordinateSpace(name: "calendarTimeline")
                }.frame(height: 540)
                    .onAppear { proxy.scrollTo(max(0, calendar.component(.hour, from: Date()) - 1), anchor: .top) }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.quaternary) }
    }
    private func dayColumn(_ day: Date) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard !store.locked, !store.project.playlists.isEmpty, !isResizing, !isMoving, !isSelectingRange else { hoveredSlot = nil; return }
                        switch phase {
                        case .active(let point):
                            let slot = CalendarHoverSlot(day: day, lane: point.x < geometry.size.width / 2 ? .video : .audio,
                                minutes: min(1425, max(0, Int(point.y / hourHeight * 4) * 15)))
                            if hoveredSlot != slot { hoveredSlot = slot }
                        case .ended:
                            if hoveredSlot?.day == day { hoveredSlot = nil }
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 4)
                        .updating($isSelectingRange) { _, active, _ in active = true }
                        .onChanged { value in
                            guard !store.locked, !store.project.playlists.isEmpty else { rangePreview = nil; return }
                            hoveredSlot = nil
                            rangePreview = CalendarRangePreview(day: day,
                                lane: value.startLocation.x < geometry.size.width / 2 ? .video : .audio,
                                range: selectedRange(from: value.startLocation.y, through: value.location.y))
                        }
                        .onEnded { value in
                            defer { rangePreview = nil }
                            guard !store.locked, !store.project.playlists.isEmpty else { return }
                            let range = selectedRange(from: value.startLocation.y, through: value.location.y)
                            guard let interval = range.interval(on: day, calendar: calendar) else { return }
                            let lane: MediaLane = value.startLocation.x < geometry.size.width / 2 ? .video : .audio
                            create(at: interval.start, lane: lane, end: interval.end)
                        }, including: store.locked ? .none : .all)
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                        guard !store.locked else { return }
                        let minutes = min(1425, max(0, Int(tap.location.y / hourHeight * 4) * 15))
                        guard let start = calendar.date(byAdding: .minute, value: minutes, to: day) else { return }
                        let lane: MediaLane = tap.location.x < geometry.size.width / 2 ? .video : .audio
                        create(at: start, lane: lane)
                    })
                if let slot = hoveredSlot, slot.day == day, !store.locked, !isResizing, !isMoving, !isSelectingRange {
                    let tint: Color = slot.lane == .video ? .blue : .orange
                    HStack(spacing: 2) {
                        Text(String(format: "%02d:%02d", slot.minutes / 60, slot.minutes % 60)).monospacedDigit()
                        Image(systemName: "plus")
                    }.font(.system(size: 9)).foregroundStyle(tint)
                        .frame(width: max(20, geometry.size.width / 2 - 2), height: hourHeight / 4)
                        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.45)) }
                        .offset(x: slot.lane == .video ? 1 : geometry.size.width / 2 + 1,
                                y: CGFloat(slot.minutes) / 60 * hourHeight)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    ForEach(0..<48) { slot in
                        Rectangle().fill(slot % 2 == 0 ? Color.secondary.opacity(0.22) : Color.secondary.opacity(0.08))
                            .frame(height: 1)
                            .frame(height: hourHeight / 2, alignment: .top)
                    }
                }.allowsHitTesting(false)
                Rectangle().fill(.quaternary).frame(width: 1).allowsHitTesting(false)
                Rectangle().fill(.quaternary).frame(width: 1).offset(x: geometry.size.width / 2).allowsHitTesting(false)
                ForEach(occurrences(on: day)) { occurrence in
                    eventBlock(occurrence, day: day, width: geometry.size.width)
                }
                if let selection = rangePreview, selection.day == day, !store.locked {
                    let tint: Color = selection.lane == .video ? .blue : .orange
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selection.range.timeLabel).font(.system(size: 9)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.65)
                        if selection.range.endMinute - selection.range.startMinute >= 45 {
                            Text("新しい予定").font(.caption2).fontWeight(.medium)
                        }
                    }.padding(3)
                        .frame(width: max(20, geometry.size.width / 2 - 4),
                               height: CGFloat(selection.range.endMinute - selection.range.startMinute) / 60 * hourHeight,
                               alignment: .topLeading)
                        .foregroundStyle(tint)
                        .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])) }
                        .offset(x: selection.lane == .video ? 2 : geometry.size.width / 2 + 2,
                                y: CGFloat(selection.range.startMinute) / 60 * hourHeight)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if calendar.isDate(context.date, inSameDayAs: day) {
                        Rectangle().fill(.red).frame(height: 1)
                            .offset(y: CGFloat(TimeOfDay.at(context.date).seconds) / 3600 * hourHeight)
                            .allowsHitTesting(false)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, location in
                    guard !store.locked, let value = items.first else { return false }
                    let minutes = min(1425, max(0, Int(location.y / hourHeight * 4) * 15))
                    guard let start = calendar.date(byAdding: .minute, value: minutes, to: day) else { return false }
                    if value.hasPrefix("playlist:"), let id = UUID(uuidString: String(value.dropFirst(9))),
                       let added = store.addCalendarEntry(playlistID: id, start: start) {
                        if let entry = store.project.calendarEntries?.first(where: { $0.id == added }) {
                            editing = CalendarEditSession(entry: entry, sourceID: entry.id, occurrenceStart: entry.start)
                        }; return true
                    }
                    let parts = value.split(separator: ":")
                    if parts.count == 3, parts[0] == "event", let id = UUID(uuidString: String(parts[1])),
                       let timestamp = Double(parts[2]),
                       let entry = store.project.calendarEntries?.first(where: { $0.id == id }) {
                        let occurrenceStart = Date(timeIntervalSince1970: timestamp)
                        guard let interval = entry.occurrence(on: occurrenceStart) else { return false }
                        var moved = entry; moved.start = start
                        moved.end = start.addingTimeInterval(interval.duration)
                        if let parent = store.project.calendarEntries?.first(where: { $0.id == entry.parentSeriesID }) { moved.repetition = parent.repetition }
                        let session = CalendarEditSession(entry: moved, sourceID: id, occurrenceStart: interval.start)
                        if isRepeating(entry) { pendingMove = session }
                        else { store.editCalendarEntry(id: id, occurrenceStart: interval.start, replacement: moved, scope: .all) }
                        return true
                    }
                    return false
                }
        }.frame(maxWidth: .infinity).frame(height: 24 * hourHeight).clipped()
    }
    private func occurrences(on day: Date) -> [CalendarOccurrence] {
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        return CalendarScheduler.occurrences(project: store.project, from: day.addingTimeInterval(-7 * 86_400), through: end)
            .filter { $0.interval.start < end && $0.interval.end > day }
    }
    private func eventBlock(_ occurrence: CalendarOccurrence, day: Date, width: CGFloat) -> some View {
        let entry = occurrence.entry
        let playlist = store.project.playlist(entry.playlistID)
        let lane = playlist?.lane ?? .video
        let color: Color = lane == .video ? .blue : .orange
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let resizing = resizePreview?.occurrenceID == occurrence.id ? resizePreview?.entry : nil
        let moving = movePreview?.occurrenceID == occurrence.id ? movePreview?.entry : nil
        let draft = resizing ?? moving
        let interval = draft.map { DateInterval(start: $0.start, end: $0.end) } ?? occurrence.interval
        let start = max(day, interval.start)
        let end = min(endOfDay, interval.end)
        let top = CGFloat(TimeOfDay.at(start).seconds) / 3600 * hourHeight
        let bottom: CGFloat = end == endOfDay ? 24 * hourHeight : CGFloat(TimeOfDay.at(end).seconds) / 3600 * hourHeight
        return Button {
            var draft = entry
            draft.start = occurrence.interval.start; draft.end = occurrence.interval.end
            if let parent = store.project.calendarEntries?.first(where: { $0.id == entry.parentSeriesID }) { draft.repetition = parent.repetition }
            editing = CalendarEditSession(entry: draft, sourceID: entry.id, occurrenceStart: occurrence.interval.start)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist?.name ?? "削除済み").font(.caption).fontWeight(.semibold).lineLimit(2)
                Text(interval.start.formatted(.dateTime.hour().minute()) + "–" + interval.end.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10)).monospacedDigit().lineLimit(1)
                    .allowsHitTesting(false)
                if entry.repetition != .once { Image(systemName: "repeat").font(.system(size: 9)) }
            }.padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(color)
            .frame(width: max(20, width / 2 - 4), height: max(20, bottom - top - 2))
            .rowHover(tint: color, radius: 4)
            .onHover { if $0 { hoveredSlot = nil } }
            .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("calendarTimeline"))
                .updating($isMoving) { _, active, _ in active = true }
                .onChanged { value in
                    guard !store.locked else { movePreview = nil; return }
                    hoveredSlot = nil
                    movePreview = CalendarResizePreview(occurrenceID: occurrence.id,
                        entry: moveDraft(occurrence, translation: value.translation.height))
                }
                .onEnded { value in
                    defer { movePreview = nil }
                    guard !store.locked else { return }
                    let updated = moveDraft(occurrence, translation: value.translation.height)
                    applyTimeChange(updated, occurrence: occurrence)
                }, including: store.locked ? .none : .all)
            .overlay(alignment: .bottomTrailing) {
                if !store.locked {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9))
                        .padding(3).controlHover(tint: color)
                        .draggable("event:" + entry.id.uuidString + ":" + String(occurrence.interval.start.timeIntervalSince1970))
                        .accessibilityLabel("別の日へドラッグして移動")
                        .help("別の日へドラッグして移動")
                        .padding(.bottom, 9).padding(.trailing, 1)
                }
            }
            .overlay(alignment: .top) {
                if !store.locked, occurrence.interval.start >= day {
                    resizeHandle(occurrence, edge: .start, color: color)
                }
            }
            .overlay(alignment: .bottom) {
                if !store.locked, occurrence.interval.end <= endOfDay {
                    resizeHandle(occurrence, edge: .end, color: color)
                }
            }
            .offset(x: lane == .video ? 2 : width / 2 + 2, y: top)
            .help("\(playlist?.name ?? "") · \(interval.start.formatted())〜\(interval.end.formatted())")
    }
    private func resizeHandle(_ occurrence: CalendarOccurrence, edge: CalendarResizeEdge, color: Color) -> some View {
        Capsule().fill(color.opacity(0.8)).frame(width: 22, height: 3)
            .frame(maxWidth: .infinity).frame(height: 8)
            .contentShape(Rectangle())
            .controlHover(tint: color)
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("calendarTimeline"))
                .updating($isResizing) { _, active, _ in active = true }
                .onChanged { value in
                    guard !store.locked else { resizePreview = nil; return }
                    resizePreview = CalendarResizePreview(occurrenceID: occurrence.id,
                        entry: resizeDraft(occurrence, edge: edge, translation: value.translation.height))
                }
                .onEnded { value in
                    defer { resizePreview = nil }
                    guard !store.locked else { return }
                    let updated = resizeDraft(occurrence, edge: edge, translation: value.translation.height)
                    applyTimeChange(updated, occurrence: occurrence)
                })
            .accessibilityLabel(edge == .start ? "開始時刻をドラッグして調整" : "終了時刻をドラッグして調整")
            .help(edge == .start ? "ドラッグして開始時刻を調整（15分単位）" : "ドラッグして終了時刻を調整（15分単位）")
    }
    private func moveDraft(_ occurrence: CalendarOccurrence, translation: CGFloat) -> CalendarEntry {
        occurrence.entry.moved(occurrence: occurrence.interval,
                               minutes: Int((translation / hourHeight * 60).rounded()), calendar: calendar)
    }
    private func applyTimeChange(_ entry: CalendarEntry, occurrence: CalendarOccurrence) {
        var updated = entry
        guard updated.start != occurrence.interval.start || updated.end != occurrence.interval.end else { return }
        if let parent = store.project.calendarEntries?.first(where: { $0.id == updated.parentSeriesID }) { updated.repetition = parent.repetition }
        if isRepeating(occurrence.entry) {
            pendingMove = CalendarEditSession(entry: updated, sourceID: occurrence.entry.id, occurrenceStart: occurrence.interval.start)
        } else {
            store.editCalendarEntry(id: occurrence.entry.id, occurrenceStart: occurrence.interval.start, replacement: updated, scope: .all)
        }
    }
    private func resizeDraft(_ occurrence: CalendarOccurrence, edge: CalendarResizeEdge, translation: CGFloat) -> CalendarEntry {
        occurrence.entry.resized(occurrence: occurrence.interval, edge: edge,
                                 minutes: Int((translation / hourHeight * 60).rounded()), calendar: calendar)
    }
    private func navigate(_ direction: Int) {
        anchor = calendar.date(byAdding: .day, value: direction * (dayView ? 1 : 7), to: anchor) ?? anchor
    }
    private func isRepeating(_ entry: CalendarEntry) -> Bool {
        entry.repetition != .once || entry.parentSeriesID != nil
    }
    private func selectedRange(from startY: CGFloat, through endY: CGFloat) -> CalendarSelectionRange {
        CalendarSelectionRange(anchorMinute: Int((startY / hourHeight * 60).rounded(.down)),
                               currentMinute: Int((endY / hourHeight * 60).rounded()))
    }
    private func create(at date: Date, lane: MediaLane? = nil, end: Date? = nil) {
        guard !store.locked,
              let playlist = store.project.playlists.first(where: { $0.lane == lane }) ?? store.project.playlists.first else { return }
        let start = lane == nil ? calendar.date(bySettingHour: calendar.component(.hour, from: date), minute: 0, second: 0, of: anchor) ?? anchor : date
        let entry = CalendarEntry(playlistID: playlist.id, start: start, end: end ?? start.addingTimeInterval(3600))
        editing = CalendarEditSession(entry: entry, sourceID: nil, occurrenceStart: start)
    }
}

private struct CalendarRangePreview {
    var day: Date
    var lane: MediaLane
    var range: CalendarSelectionRange
}

private struct CalendarHoverSlot: Equatable {
    var day: Date
    var lane: MediaLane
    var minutes: Int
}

private struct CalendarResizePreview {
    var occurrenceID: String
    var entry: CalendarEntry
}

private struct CalendarEditSession: Identifiable {
    let id = UUID()
    var entry: CalendarEntry
    var sourceID: UUID?
    var occurrenceStart: Date
}

private struct CalendarEntryEditor: View {
    @ObservedObject var store: PlayerStore
    @State private var entry: CalendarEntry
    var session: CalendarEditSession
    @State private var selectingScope = false
    @State private var deleting = false
    private var isNew: Bool { session.sourceID == nil }
    private var recurring: Bool {
        guard let source = store.project.calendarEntries?.first(where: { $0.id == session.sourceID }) else { return false }
        return source.repetition != .once || source.parentSeriesID != nil
    }
    init(store: PlayerStore, session: CalendarEditSession) {
        self.store = store; self.session = session; _entry = State(initialValue: session.entry)
    }
    @Environment(\.dismiss) private var dismiss
    private var valid: Bool {
        entry.end > entry.start && entry.end.timeIntervalSince(entry.start) <= 7 * 86_400
            && store.project.playlist(entry.playlistID) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "再生予定を追加" : "再生予定を編集").font(.title2).fontWeight(.semibold)
            Form {
                Picker("プレイリスト", selection: $entry.playlistID) {
                    ForEach(store.project.playlists) { playlist in
                        Text("\(playlist.lane.title) · \(playlist.name)").tag(playlist.id)
                    }
                }.fieldHover()
                DatePicker("開始", selection: $entry.start).fieldHover()
                DatePicker("終了（OUT開始）", selection: $entry.end).fieldHover()
                Picker("繰り返し", selection: $entry.repetition) {
                    ForEach(ScheduleRepeat.allCases) { Text($0.title).tag($0) }
                }.fieldHover()
                HStack {
                    NumberField(title: "開始フェード（秒）", value: $entry.fades.fadeIn, range: 0...store.project.defaults.fadeMax)
                    NumberField(title: "終了フェード（秒）", value: $entry.fades.fadeOut, range: 0...store.project.defaults.fadeMax)
                }.labelsHidden()
                if !valid { Text("終了は開始より後、予定の長さは7日以内に設定してください。") .font(.caption).foregroundStyle(.red) }
                if recurring { Text("保存・削除時に、この予定のみ／これ以降／すべての予定を選択できます。") .font(.caption).foregroundStyle(.secondary) }
            }.disabled(store.locked)
            HStack {
                if !isNew {
                    Button("削除", role: .destructive) {
                        deleting = true
                        if recurring { selectingScope = true } else { apply(.all) }
                    }.controlHover(tint: .red).disabled(store.locked)
                }
                Spacer()
                Button("キャンセル") { dismiss() }.controlHover().keyboardShortcut(.cancelAction)
                Button("保存") {
                    deleting = false
                    if recurring { selectingScope = true } else { apply(.all) }
                }.controlHover().keyboardShortcut(.defaultAction).disabled(store.locked || !valid)
            }
        }.padding(24).frame(width: 510)
            .confirmationDialog(deleting ? "削除する繰り返し予定の範囲" : "変更する繰り返し予定の範囲", isPresented: $selectingScope, titleVisibility: .visible) {
                ForEach(CalendarEditScope.allCases) { scope in
                    Button(scope.title, role: deleting ? .destructive : nil) { apply(scope) }
                }
                Button("キャンセル", role: .cancel) {}
            }
    }
    private func apply(_ scope: CalendarEditScope) {
        if let id = session.sourceID {
            store.editCalendarEntry(id: id, occurrenceStart: session.occurrenceStart, replacement: deleting ? nil : entry, scope: scope)
        } else if !deleting {
            store.change {
                if $0.calendarEntries == nil { $0.calendarEntries = [] }
                $0.calendarEntries?.append(entry)
            }
        }
        dismiss()
    }
}

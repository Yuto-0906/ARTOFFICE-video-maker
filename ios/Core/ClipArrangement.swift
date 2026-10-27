import Foundation

struct ClipGroup: Identifiable {
    let clips: [Clip]
    var id: UUID { clips[0].id }
}
extension Project {
    var arrangedGroups: [ClipGroup] { groups.map { ClipGroup(clips: $0) } }
    mutating func sortGroupsByDisplayName() {
        clips = groups.sorted { left, right in
            let a = Naming.parse(left[0].displayTitle + ".mp4")?.order ?? Int.max
            let b = Naming.parse(right[0].displayTitle + ".mp4")?.order ?? Int.max
            return a == b ? left[0].displayTitle.localizedStandardCompare(right[0].displayTitle) == .orderedAscending : a < b
        }.flatMap { $0 }
    }
    mutating func moveGroups(from offsets: IndexSet, to destination: Int) {
        let original = groups
        guard offsets.allSatisfy({ original.indices.contains($0) }), (0...original.count).contains(destination) else { return }
        let moving = offsets.sorted().map { original[$0] }
        var remaining = original.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: insertion)
        clips = remaining.flatMap { $0 }
    }
    mutating func movePart(_ id: UUID, by delta: Int) {
        var values = groups
        guard let group = values.firstIndex(where: { $0.contains(where: { $0.id == id }) }),
              let index = values[group].firstIndex(where: { $0.id == id }), values[group].indices.contains(index + delta) else { return }
        let title = values[group][0].bandName
        values[group].swapAt(index, index + delta)
        for i in values[group].indices { values[group][i].joinPrevious = i > 0 }
        values[group][0].bandName = title
        clips = values.flatMap { $0 }
    }
}

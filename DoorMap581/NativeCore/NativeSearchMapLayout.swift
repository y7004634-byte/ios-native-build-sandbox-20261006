import Foundation

/// Rendering plan only: the query/candidate pool stays complete in its owner.
/// Every identity remains accounted for as visible, offscreen, or unprojectable.
/// No fixed first-N cap and no source-name/coordinate substitution.
public enum DoorSearchMapLayout {
    public struct Point: Sendable, Equatable {
        public let id: String
        public let x: Double
        public let y: Double
        public init(id: String, x: Double, y: Double) { self.id=id; self.x=x; self.y=y }
    }
    public struct Group: Sendable, Equatable {
        public let memberIDs: [String]
        public let x: Double
        public let y: Double
        public var key: String { memberIDs.joined(separator: "\u{1f}") }
    }
    public struct Plan: Sendable, Equatable {
        public let groups: [Group]
        public let offscreenIDs: [String]
        public let unprojectableIDs: [String]
        public let duplicateIDs: [String]
        public var visibleIDs: [String] { groups.flatMap(\.memberIDs) }
        public var accountedUniqueCount: Int { visibleIDs.count + offscreenIDs.count + unprojectableIDs.count }
    }
    private struct Cell: Hashable { let x: Int; let y: Int }
    private struct Bucket { var ids: [String]; var sumX: Double; var sumY: Double }
    public static func plan(_ points: [Point], width: Double, height: Double,
                            cellSize: Double = 56, margin: Double = 56) -> Plan {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              cellSize.isFinite, cellSize >= 16, margin.isFinite, margin >= 0,
              width <= 100_000, height <= 100_000, margin <= 100_000 else {
            var seen = Set<String>()
            let ids=points.map(\.id).filter { seen.insert($0).inserted }
            return Plan(groups:[],offscreenIDs:[],unprojectableIDs:ids,duplicateIDs:[])
        }
        var seen=Set<String>(), cells:[Cell:Int]=[:], buckets:[Bucket]=[]
        var offscreen:[String]=[], unprojectable:[String]=[], duplicates:[String]=[]
        for point in points {
            guard seen.insert(point.id).inserted else { duplicates.append(point.id); continue }
            guard point.x.isFinite, point.y.isFinite else { unprojectable.append(point.id); continue }
            guard point.x >= -margin, point.y >= -margin,
                  point.x <= width+margin, point.y <= height+margin else {
                offscreen.append(point.id); continue
            }
            let cell=Cell(x:Int(floor(point.x/cellSize)),y:Int(floor(point.y/cellSize)))
            if let i=cells[cell] {
                buckets[i].ids.append(point.id); buckets[i].sumX += point.x; buckets[i].sumY += point.y
            } else {
                cells[cell]=buckets.count
                buckets.append(Bucket(ids:[point.id],sumX:point.x,sumY:point.y))
            }
        }
        let groups=buckets.map { b in
            Group(memberIDs:b.ids,x:b.sumX/Double(b.ids.count),y:b.sumY/Double(b.ids.count))
        }
        return Plan(groups:groups,offscreenIDs:offscreen,unprojectableIDs:unprojectable,duplicateIDs:duplicates)
    }
}

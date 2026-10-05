import Foundation

/// The 30-row limit is UI pagination, never a limit on candidate ingestion.
public enum DoorSearchWindow {
    public static let pageSize = 30
    public static let primaryRadius = 3000.0
    public static let expandedRadius = 8000.0
    public static let primaryMinimum = 6
    private static let addressExpression = try! NSRegularExpression(pattern: "(?:[0-9]+.*(?:號|路|街|大道|段|巷|弄)|(?:路|街|大道|段|巷|弄).*[0-9０-９]|(?:市|縣).*(?:區|鄉|鎮).*(?:路|街|大道))", options:.caseInsensitive)
    public static func isAddressLike(_ query: String) -> Bool {
        addressExpression.firstMatch(in:query,range:NSRange(query.startIndex...,in:query)) != nil
    }
    public struct Presentation: Sendable {
        public let candidates: [DoorSearchCore.Result]
        public let list: [DoorSearchCore.Result]
        public let pins: [DoorSearchCore.Result]
        public let listRadiusM: Double?
        public let primaryCount: Int
        public var expanded: Bool { listRadiusM == expandedRadius }
        public func page(through count: Int = pageSize) -> [DoorSearchCore.Result] {
            Array(list.prefix(max(0,count)))
        }
    }
    public static func present(_ candidates: [DoorSearchCore.Result], query: String, center: DoorCoordinate?) -> Presentation {
        guard let center, !isAddressLike(query) else {
            return .init(candidates:candidates,list:candidates,pins:candidates,listRadiusM:nil,primaryCount:candidates.count)
        }
        // Original planner window is nearest-first; exact-name priority remains in the candidate universe.
        var ranked: [(Int, DoorSearchCore.Result, Double)] = []
        for (index, result) in candidates.enumerated() {
            let distance = DoorSearchCore.meters(center,result.record.coordinate)
            if distance.isFinite { ranked.append((index,result,distance)) }
        }
        ranked.sort { a, b in a.2 == b.2 ? a.0 < b.0 : a.2 < b.2 }
        let primary = ranked.filter { $0.2 <= primaryRadius }.map { $0.1 }
        let radius = primary.count >= primaryMinimum ? primaryRadius : expandedRadius
        let list = ranked.filter { $0.2 <= radius }.map { $0.1 }
        return .init(candidates:candidates,list:list,pins:primary,listRadiusM:radius,primaryCount:primary.count)
    }
}

/// Value-type request ownership. A provider cannot publish an old query, old
/// map area, or a response arriving after Clear. No DOM state determines this.
public struct DoorSearchSession: Sendable {
    public enum Provider: Int, CaseIterable, Sendable { case supplemental, community, local, apple, remote, address }
    public struct Ticket: Equatable, Sendable {
        public let generation: UInt64
        public let query: String
        public let center: DoorCoordinate?
    }
    public enum Display: String, Codable, Sendable { case closed, candidates, mapResults }
    public private(set) var generation: UInt64 = 0
    public private(set) var ticket: Ticket?
    public private(set) var display: Display = .closed
    public private(set) var renderLimit = DoorSearchWindow.pageSize
    public private(set) var mapAreaDirty = false
    private var groups: [Provider:[DoorSearchCore.Prepared]] = [:]
    public init() {}
    @discardableResult public mutating func begin(query: String, center: DoorCoordinate?, submitted: Bool = false) -> Ticket {
        generation &+= 1
        let trimmed = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let request = Ticket(generation:generation,query:trimmed,center:center?.isValid == true ? center:nil)
        ticket = request; groups.removeAll(); renderLimit = DoorSearchWindow.pageSize; mapAreaDirty = false
        display = trimmed.isEmpty ? .closed : (submitted ? .mapResults:.candidates)
        return request
    }
    @discardableResult public mutating func publish(_ values: [DoorSearchCore.Prepared], provider: Provider, for request: Ticket) -> Bool {
        guard request == ticket, !request.query.isEmpty else { return false }
        groups[provider] = values
        return true
    }
    public mutating func clear() {
        generation &+= 1; ticket = nil; groups.removeAll(); display = .closed
        renderLimit = DoorSearchWindow.pageSize; mapAreaDirty = false
    }
    public mutating func showCandidates() { if ticket?.query.isEmpty == false { display = .candidates } }
    public mutating func showMapResults() { if ticket?.query.isEmpty == false { display = .mapResults } }
    public mutating func loadMore() { renderLimit = min(renderLimit + DoorSearchWindow.pageSize, presentation.list.count) }
    public mutating func mapMovedByUser() { if ticket?.query.isEmpty == false { mapAreaDirty = true } }
    public var presentation: DoorSearchWindow.Presentation {
        guard let request = ticket else { return DoorSearchWindow.present([],query:"",center:nil) }
        var ranked = DoorSearchCore.rank(Provider.allCases.map { groups[$0] ?? [] },query:request.query,center:request.center)
        let nonApple = ranked.filter { $0.record.source != "apple-mklocalsearch" }
        // Preserve the existing provider merge contract; Apple results never change public records.
        ranked = ranked.filter { r in
            r.record.source != "apple-mklocalsearch" || r.record.appleBrandKey == nil ||
                !nonApple.contains { DoorSearchCore.meters($0.record.coordinate,r.record.coordinate) <= 30 }
        }
        return DoorSearchWindow.present(ranked,query:request.query,center:request.center)
    }
}

/// Mode/state foundation shared by the future UIKit surface, not a second
/// route implementation. Camera gestures never own the raw sensor stream.
public struct DoorNavigationState: Sendable {
    public enum Mode: String, Codable, Sendable { case browse, routePlanning, navigating, routeEditing }
    public enum CameraOwner: String, Codable, Sendable { case free, north, heading, navigation, fitDistance, fitTime }
    public struct Destination: Equatable, Sendable {
        public let coordinate: DoorCoordinate
        public let title: String
        public let source: String
        public init(coordinate:DoorCoordinate,title:String,source:String) { self.coordinate=coordinate; self.title=title; self.source=source }
    }
    public private(set) var mode: Mode = .browse
    public private(set) var cameraOwner: CameraOwner = .free
    public private(set) var rawPosition: DoorCoordinate?
    public private(set) var displayPosition: DoorCoordinate?
    public private(set) var destination: Destination?
    public private(set) var correctionDraft: DoorCoordinate?
    public private(set) var destinationRevision: UInt64 = 0
    public private(set) var searchRequested = false
    public init() {}
    public var searchVisible: Bool { searchRequested || (mode == .browse) }
    public mutating func requestSearch() { if mode != .routeEditing { searchRequested = true } }
    public mutating func dismissSearch() { searchRequested = false }
    public mutating func setMode(_ value: Mode) { mode=value; if value == .routeEditing { searchRequested=false } }
    public mutating func setCameraOwner(_ value: CameraOwner) { cameraOwner=value }
    public mutating func acceptRawPosition(_ point: DoorCoordinate) { guard point.isValid else{return}; rawPosition=point; displayPosition=point }
    public mutating func setDisplayPosition(_ point: DoorCoordinate) { if point.isValid { displayPosition=point } }
    public mutating func selectDestination(_ value: Destination) {
        guard value.coordinate.isValid else{return}
        destination=value; correctionDraft=nil; destinationRevision &+= 1; searchRequested=false
    }
    public mutating func beginCorrection() { correctionDraft=destination?.coordinate }
    public mutating func moveCorrection(_ point: DoorCoordinate) { if correctionDraft != nil && point.isValid { correctionDraft=point } }
    public mutating func cancelCorrection() { correctionDraft=nil }
    @discardableResult public mutating func applyCorrection(expectedRevision: UInt64) -> Bool {
        guard expectedRevision == destinationRevision, let draft=correctionDraft, let original=destination else{return false}
        destination = .init(coordinate:draft,title:original.title,source:"manual-correction")
        correctionDraft=nil; destinationRevision &+= 1
        return true // Caller plans before replacing the committed route; raw GPS remains untouched.
    }
}

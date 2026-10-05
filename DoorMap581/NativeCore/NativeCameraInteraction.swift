import Foundation

/// Selection is supplied by the single navigation owner. This controller never
/// owns GPS or changes FIT/follow selection in response to a touch.
public struct DoorCameraInteraction: Sendable {
    public struct Selection: Codable, Equatable, Sendable {
        public var fitLocked: Bool, following: Bool, cameraUserOverride: Bool
        public var navigationActive: Bool, navigationRequested: Bool, headingMode: Bool, editing: Bool
        public init(fitLocked: Bool = false, following: Bool = false, cameraUserOverride: Bool = false,
                    navigationActive: Bool = false, navigationRequested: Bool = false, headingMode: Bool = true, editing: Bool = false) {
            self.fitLocked=fitLocked; self.following=following; self.cameraUserOverride=cameraUserOverride
            self.navigationActive=navigationActive; self.navigationRequested=navigationRequested; self.headingMode=headingMode; self.editing=editing
        }
        public var isProtected: Bool { fitLocked || (following && !cameraUserOverride && (navigationActive || navigationRequested || headingMode)) }
        fileprivate var key: [Bool] { [fitLocked,following,cameraUserOverride,headingMode] }
    }
    public struct Effect: Codable, Equatable, Sendable {
        public var stopProgrammaticCamera=false, resume=false
        public init(stopProgrammaticCamera: Bool = false, resume: Bool = false) { self.stopProgrammaticCamera=stopProgrammaticCamera; self.resume=resume }
    }
    public struct Preference: Codable, Equatable, Sendable {
        public enum Owner: String, Codable, Sendable { case fit, heading, north, manual }
        public enum Mode: String, Codable, Sendable { case heading, north }
        public let v: Int, owner: Owner, mode: Mode, navigationRequested: Bool
        public static func decode(_ data: Data) -> Self? {
            guard data.count <= 2048, let p=try? JSONDecoder().decode(Self.self,from:data), p.v == 1 else { return nil }
            return p
        }
        public init(selection: Selection) {
            v=1; owner=selection.fitLocked ? .fit : (selection.following && !selection.cameraUserOverride ? (selection.headingMode ? .heading : .north) : .manual)
            mode=selection.headingMode ? .heading : .north; navigationRequested=selection.navigationRequested || selection.navigationActive
        }
    }
    public private(set) var holding=false, fitHolding=false, active=false, moved=false
    public private(set) var resumeAtMS: Double?
    public private(set) var resumes=0
    private var origin: DoorScreenPoint?
    private var pointers=Set<Int>()
    private var selectedKey: [Bool]?
    public init() {}
    public var pointerCount: Int { pointers.count }
    private mutating func clearHold() {
        active=false; moved=false; origin=nil; pointers.removeAll(); holding=false; fitHolding=false
    }
    public mutating func selectionChanged(_ selection: Selection) {
        if !selection.isProtected || (selectedKey != nil && selectedKey != selection.key) { resumeAtMS=nil; clearHold() }
        selectedKey=selection.key
    }
    public mutating func begin(id: Int, at point: DoorScreenPoint, selection: Selection, foreground: Bool) -> Effect {
        guard selection.isProtected, !selection.editing, foreground else { return .init() }
        resumeAtMS=nil
        if !active { active=true; moved=false; origin=point }
        pointers.insert(id); holding=true; fitHolding=selection.fitLocked
        return .init(stopProgrammaticCamera:true)
    }
    public mutating func move(to point: DoorScreenPoint) {
        guard active, let origin else { return }
        if hypot(point.x-origin.x,point.y-origin.y) >= 8 { moved=true }
    }
    /// Native pinch/rotation start must not cancel the native gesture again.
    public mutating func transformBegan(isUserGesture: Bool, selection: Selection, foreground: Bool) -> Effect {
        guard isUserGesture, selection.isProtected, !selection.editing else { return .init() }
        if foreground { moved=true }
        return .init()
    }
    public mutating func end(id: Int, cancelled: Bool, remainingTouches: Int = 0, nowMS: Double,
                             selection: Selection, foreground: Bool) -> Effect {
        guard active else { return .init() }
        if cancelled { return finish(delay:0,nowMS:nowMS,selection:selection,foreground:foreground) }
        pointers.remove(id)
        guard pointers.isEmpty, remainingTouches == 0 else { return .init() }
        return finish(delay:moved ? 1500 : 0,nowMS:nowMS,selection:selection,foreground:foreground)
    }
    public mutating func keyboardOrWheel(nowMS: Double, selection: Selection, foreground: Bool) -> Effect {
        guard selection.isProtected, !selection.editing, foreground else { return .init() }
        holding=true; fitHolding=selection.fitLocked
        var effect=finish(delay:900,nowMS:nowMS,selection:selection,foreground:foreground)
        effect.stopProgrammaticCamera=true; return effect
    }
    private mutating func finish(delay: Double, nowMS: Double, selection: Selection, foreground: Bool) -> Effect {
        resumeAtMS=nil; active=false; origin=nil; pointers.removeAll()
        guard foreground else { clearHold(); return .init() }
        if delay > 0 { resumeAtMS=nowMS+delay; return .init() }
        clearHold()
        if selection.isProtected && !selection.editing { resumes += 1; return .init(resume:true) }
        return .init()
    }
    public mutating func advance(nowMS: Double, selection: Selection, foreground: Bool) -> Effect {
        guard let deadline=resumeAtMS, nowMS >= deadline else { return .init() }
        return finish(delay:0,nowMS:nowMS,selection:selection,foreground:foreground)
    }
    public mutating func lifecycle(foreground: Bool, selection: Selection) -> Effect {
        resumeAtMS=nil; clearHold()
        if !foreground { return .init(stopProgrammaticCamera:true) }
        if selection.isProtected && !selection.editing { resumes += 1; return .init(resume:true) }
        return .init()
    }
    public mutating func destroy() { resumeAtMS=nil; clearHold() }
}

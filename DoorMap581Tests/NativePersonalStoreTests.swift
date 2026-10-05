import XCTest
@testable import DoorMap581

final class NativePersonalStoreTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("581-personal-" + UUID().uuidString) }
    private func memory() -> DoorRouteMemory {
        let p:[DoorCoordinate] = [.init(lat:24.135,lng:120.688),.init(lat:24.1355,lng:120.6887),.init(lat:24.136,lng:120.6894)]
        return .init(id:"ignored",source:.edit,points:p,heading:0,updatedAt:Date().timeIntervalSince1970*1000)
    }
    func testSaveLoadExportImportAndRollbackStayInsideTransaction() async throws {
        let url=root(); defer { try? FileManager.default.removeItem(at:url) }
        let store=try NativePersonalStore(root:url)
        var prefs=MapPreferences(); prefs.appearance = .light
        let area=DoorAvoidArea(id:"a",lat:24.135,lng:120.688,radius:80)
        let first=try await store.save(.init(preferences:prefs,avoidAreas:[area],routeMemories:[memory()]))
        XCTAssertEqual(first.preferences.appearance,.light); XCTAssertEqual(first.avoidAreas.count,1); XCTAssertEqual(first.routeMemories.count,1)
        let loaded=try await store.load(); XCTAssertEqual(loaded,first)
        let exported=try await store.exportData(loaded); XCTAssertLessThanOrEqual(exported.count,NativePersonalStore.maxBackupBytes)
        var second=loaded; second.preferences.appearance = .dark; second.avoidAreas=[]
        let importedBytes=try await store.exportData(second); let imported=try await store.importData(importedBytes)
        XCTAssertEqual(imported.preferences.appearance,.dark); XCTAssertTrue(imported.avoidAreas.isEmpty)
        let rolled=try await store.rollback(); XCTAssertEqual(rolled?.preferences.appearance,.light); XCTAssertEqual(rolled?.avoidAreas.count,1)
    }
    func testMalformedOrOversizedBackupDoesNotReplaceCurrent() async throws {
        let url=root(); defer { try? FileManager.default.removeItem(at:url) }
        let store=try NativePersonalStore(root:url)
        let original=try await store.save(.init(avoidAreas:[.init(id:"x",lat:24.135,lng:120.688)]))
        do { _=try await store.importData(Data("{bad".utf8)); XCTFail("malformed accepted") }
        catch { XCTAssertEqual(error as? DoorPersonalError,.invalidBackup) }
        let afterMalformed = try await store.load(); XCTAssertEqual(afterMalformed,original)
        do { _=try await store.importData(Data(repeating:0,count:NativePersonalStore.maxBackupBytes+1)); XCTFail("oversized accepted") }
        catch { XCTAssertEqual(error as? DoorPersonalError,.tooLarge) }
        let afterOversized = try await store.load(); XCTAssertEqual(afterOversized,original)
    }
    func testMemoryValidationRejectsPassiveOrInvalidGeometryShape() async throws {
        let url=root(); defer { try? FileManager.default.removeItem(at:url) }
        let store=try NativePersonalStore(root:url)
        let bad=DoorRouteMemory(id:"bad",source:.edit,points:[.init(lat:24.135,lng:120.688)],heading:0,updatedAt:1)
        do { _=try await store.save(.init(routeMemories:[bad])); XCTFail("bad memory accepted") }
        catch { XCTAssertEqual(error as? DoorPersonalError,.invalidMemory) }
        let afterRejected = try await store.load(); XCTAssertTrue(afterRejected.routeMemories.isEmpty)
    }
}

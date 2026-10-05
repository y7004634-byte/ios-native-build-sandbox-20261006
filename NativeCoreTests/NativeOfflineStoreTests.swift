import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DoorMapCore
#else
@testable import DoorMap581
#endif

final class NativeOfflineStoreTests:XCTestCase {
    private func root()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("door581-native-offline-tests-"+UUID().uuidString)}
    private func fixture(_ version:String)->(DoorOfflineManifest,[String:Data]) {
        let data=["core/poi.json":Data("POI-\(version)".utf8),"official/addresses.json":Data("ADDRESSES-\(version)".utf8),"destination/geometry.json":Data("GEOMETRY-\(version)".utf8)]
        let entries=data.keys.sorted().map{DoorOfflineManifest.File(path:$0,component:$0.components(separatedBy:"/")[0],bytes:Int64(data[$0]!.count),sha256:DoorDigest.sha256(data[$0]!))}
        return (.init(packageID:"door581-public",version:version,requiredComponents:["core","official","destination"],files:entries),data)
    }
    private func install(_ store:DoorOfflineStore,_ version:String) async throws -> DoorOfflineReceipt {
        let (manifest,bytes)=fixture(version)
        return try await store.install(manifest,trustedManifestSHA256:manifest.identity,origin:"bundled-seed",load:{bytes[$0.path]!})
    }
    func testSHA256KnownVectorsAndStreamingFile() throws {
        XCTAssertEqual(DoorDigest.sha256(Data()),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(DoorDigest.sha256(Data("abc".utf8)),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let data=Data(repeating:97,count:1_000_000)
        XCTAssertEqual(DoorDigest.sha256(data),"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        let url=root();defer{try? FileManager.default.removeItem(at:url)};try data.write(to:url)
        XCTAssertEqual(try DoorDigest.sha256(file:url),DoorDigest.sha256(data))
    }
    func testThreeComponentsInstallAndSurviveStoreReopen() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url)
        let empty=try await store.activeReceipt();XCTAssertNil(empty)
        let receipt=try await install(store,"v1")
        XCTAssertEqual(receipt.fileCount,3);XCTAssertEqual(receipt.components,["core","destination","official"])
        XCTAssertEqual(receipt.origin,"bundled-seed") // not falsely described as a network download
        let reopened=try DoorOfflineStore(root:url),restored=try await reopened.verifyActivePackage()
        XCTAssertEqual(restored,receipt)
        let resource=try await reopened.validatedResource("core/poi.json")
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(resource)),Data("POI-v1".utf8))
    }
    func testFailedAddonLeavesPreviousGenerationActive() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url),old=try await install(store,"v1")
        let (manifest,bytes)=fixture("v2")
        do {
            _ = try await store.install(manifest,trustedManifestSHA256:manifest.identity,origin:"validated-download",load:{ f in
                if f.component=="official" {throw DoorOfflineError.missingFile(f.path)}
                return bytes[f.path]!
            });XCTFail("Missing required addon must not succeed")
        } catch {XCTAssertEqual(error as? DoorOfflineError,.missingFile("official/addresses.json"))}
        let active=try await store.verifyActivePackage();XCTAssertEqual(active,old)
    }
    actor Counter {var paths:[String]=[];func record(_ path:String){paths.append(path)};func count()->Int{paths.count}}
    func testCancelRetainsPreviousAndResumeReusesVerifiedStagingFiles() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url),old=try await install(store,"v1")
        let (manifest,bytes)=fixture("v2"),first=Counter(),second=Counter()
        do {
            _ = try await store.install(manifest,trustedManifestSHA256:manifest.identity,origin:"bundled-seed",load:{ f in
                await first.record(f.path)
                if f.component=="official" {await store.cancelInstall()}
                return bytes[f.path]!
            });XCTFail("Cancellation must not activate partial data")
        } catch {XCTAssertEqual(error as? DoorOfflineError,.cancelled)}
        let active=try await store.activeReceipt();XCTAssertEqual(active,old)
        let completed=try await store.install(manifest,trustedManifestSHA256:manifest.identity,origin:"bundled-seed",load:{f in await second.record(f.path);return bytes[f.path]!})
        let firstCount=await first.count(),secondCount=await second.count()
        XCTAssertEqual(firstCount,3);XCTAssertEqual(secondCount,1);XCTAssertEqual(completed.version,"v2")
        let reopened=try DoorOfflineStore(root:url),verified=try await reopened.verifyActivePackage();XCTAssertEqual(verified,completed)
    }
    func testChecksumFailureCannotBecomeActiveOrCorruptOldFiles() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url),old=try await install(store,"v1"),f=fixture("v2")
        do {
            _ = try await store.install(f.0,trustedManifestSHA256:f.0.identity,origin:"bundled-seed",load:{entry in Data(repeating:0,count:Int(entry.bytes))});XCTFail("Corrupt bytes accepted")
        } catch {XCTAssertEqual(error as? DoorOfflineError,.checksum("core/poi.json"))}
        let active=try await store.verifyActivePackage();XCTAssertEqual(active,old)
    }
    func testInsufficientSpaceFailsBeforeLoadingAnyFiles() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url),f=fixture("v1"),counter=Counter()
        do {
            _ = try await store.install(f.0,trustedManifestSHA256:f.0.identity,origin:"bundled-seed",availableBytes:0,load:{entry in await counter.record(entry.path);return f.1[entry.path]!});XCTFail("Insufficient space accepted")
        } catch {XCTAssertEqual(error as? DoorOfflineError,.insufficientSpace)}
        let count=await counter.count(),active=try await store.activeReceipt();XCTAssertEqual(count,0);XCTAssertNil(active)
    }
    func testMalformedManifestAndUntrustedIdentityRejected() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url),f=fixture("v1")
        for path in ["../escape","/tmp/escape","x/../../bad","C:\\bad","a//b","a/%2e%2e/b","a/./b"] {
            let m=DoorOfflineManifest(packageID:"x",version:"1",requiredComponents:["core"],files:[.init(path:path,component:"core",bytes:1,sha256:String(repeating:"a",count:64))])
            XCTAssertThrowsError(try m.validate(),path)
        }
        do {_ = try await store.install(f.0,trustedManifestSHA256:String(repeating:"0",count:64),origin:"bundled-seed",load:{f.1[$0.path]!});XCTFail("Untrusted metadata accepted")}
        catch{XCTAssertEqual(error as? DoorOfflineError,.untrustedManifest)}
        let missing=DoorOfflineManifest(packageID:"x",version:"1",requiredComponents:["missing"],files:f.0.files)
        XCTAssertThrowsError(try missing.validate())
        let duplicate=DoorOfflineManifest(packageID:"x",version:"1",requiredComponents:["core"],files:[f.0.files[0],f.0.files[0]])
        XCTAssertThrowsError(try duplicate.validate())
    }
    func testAlreadyInstalledPackageVerifiesWithoutDuplicateLoading() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url),old=try await install(store,"v1"),f=fixture("v1")
        let current=try await store.install(f.0,trustedManifestSHA256:f.0.identity,origin:"bundled-seed",load:{_ in throw DoorOfflineError.incomplete})
        XCTAssertEqual(current,old)
    }
    func testModifiedActiveResourceIsDetectedInsteadOfFalseReady() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url);_ = try await install(store,"v1")
        let found=try await store.validatedResource("core/poi.json");let resource=try XCTUnwrap(found)
        try Data("ALTERED".utf8).write(to:resource)
        do {_ = try await store.verifyActivePackage();XCTFail("Corruption not detected")}
        catch{XCTAssertEqual(error as? DoorOfflineError,.checksum("core/poi.json"))}
    }
    func testIndependentStoreCannotInstallWhileExistingWriterOwnsLease() async throws {
        let url=root();defer{try? FileManager.default.removeItem(at:url)}
        let store=try DoorOfflineStore(root:url),other=try DoorOfflineStore(root:url),f=fixture("v1")
        let lease=try DoorInstallLease(directory:url)
        do {
            _ = try await other.install(f.0,trustedManifestSHA256:f.0.identity,origin:"bundled-seed",load:{f.1[$0.path]!})
            XCTFail("Second instance obtained live lease")
        } catch {XCTAssertEqual(error as? DoorOfflineError,.writerBusy)}
        withExtendedLifetime(lease) {}
        let active=try await store.activeReceipt();XCTAssertNil(active)
    }
    func testSymlinkOutsideStoreIsNotReadOrWritten() async throws {
        let url=root(),outside=root();defer{try? FileManager.default.removeItem(at:url);try? FileManager.default.removeItem(at:outside)}
        let store=try DoorOfflineStore(root:url),f=fixture("v1")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:url.appendingPathComponent("staging"),withDestinationURL:outside)
        do {_ = try await store.install(f.0,trustedManifestSHA256:f.0.identity,origin:"bundled-seed",load:{f.1[$0.path]!});XCTFail("Escaped sandbox root")}
        catch{XCTAssertEqual(error as? DoorOfflineError,.unsafePath)}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path),[])
    }
}

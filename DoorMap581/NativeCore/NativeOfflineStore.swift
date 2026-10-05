import Foundation

/// Manifest describes stored bytes (including .gz) from already accepted public
/// datasets. Decoded hashes remain a resolver responsibility, not another download.
public struct DoorOfflineManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path:String, component:String, sha256:String
        public let bytes:Int64
        public init(path:String,component:String,bytes:Int64,sha256:String){self.path=path;self.component=component;self.bytes=bytes;self.sha256=sha256}
    }
    public let schema:Int, packageID:String, version:String, requiredComponents:[String], files:[File]
    public init(packageID:String,version:String,requiredComponents:[String],files:[File]) {
        schema=1;self.packageID=packageID;self.version=version;self.requiredComponents=requiredComponents;self.files=files
    }
    public func validate() throws {
        guard schema==1,!packageID.isEmpty,packageID.count<=120,!version.isEmpty,version.count<=160,
              !files.isEmpty,files.count<=20000,!requiredComponents.isEmpty,requiredComponents.count<=100,
              Set(requiredComponents).count==requiredComponents.count else {throw DoorOfflineError.invalidManifest}
        var paths=Set<String>(),components=Set<String>()
        for f in files {
            guard Self.safePath(f.path),!f.component.isEmpty,f.component.count<=120,
                  f.bytes>=0,f.bytes<=128*1024*1024,
                  f.sha256.count==64,f.sha256.unicodeScalars.allSatisfy({("0123456789abcdef".unicodeScalars).contains($0)}),
                  paths.insert(f.path.lowercased()).inserted else {throw DoorOfflineError.invalidManifest}
            components.insert(f.component)
        }
        guard Set(requiredComponents).isSubset(of:components) else {throw DoorOfflineError.missingComponent}
    }
    public static func safePath(_ path:String)->Bool {
        guard !path.isEmpty,path.utf8.count<=1024,!path.contains("\\"),!path.contains(":"),!path.contains("%"),!path.contains("\0"),!path.hasPrefix("/") else{return false}
        return path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy{!$0.isEmpty && $0 != "." && $0 != ".."}
    }
    public func canonicalData() throws -> Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(self)}
    public var identity:String {get throws {try DoorDigest.sha256(canonicalData())}}
}

public enum DoorOfflineError:Error,Equatable {
    case invalidManifest,missingComponent,untrustedManifest,writerBusy,cancelled,insufficientSpace
    case unsafePath,checksum(String),size(String),incomplete,corruptReceipt,missingFile(String),network(Int)
}

public struct DoorOfflineReceipt:Codable,Equatable,Sendable {
    public let schema:Int,packageID:String,version:String,manifestSHA256:String,generation:String
    public let fileCount:Int,storedBytes:Int64,components:[String],origin:String
    public let installedAt:Date
}

/// A single actor owns installation. The only visible switch is active.json,
/// written atomically AFTER every required component and file is verified.
/// Cancellation leaves only a resumable staging directory; no existing pack is erased.
public actor DoorOfflineStore {
    public enum Phase:String,Sendable {case idle,verifying,loading,committing}
    public struct Status:Sendable {
        public let phase:Phase,completed:Int,total:Int,path:String?
    }
    private let root:URL
    private let fm=FileManager.default
    private var operation:UUID?
    private var cancelled=false
    public private(set) var status=Status(phase:.idle,completed:0,total:0,path:nil)
    public init(root:URL) throws {
        guard root.isFileURL,!root.path.isEmpty,root.path != "/" else{throw DoorOfflineError.unsafePath}
        self.root=root.standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at:self.root,withIntermediateDirectories:true)
    }
    public func cancelInstall(){if operation != nil {cancelled=true}}
    private func checkCancellation() throws {if cancelled || Task.isCancelled {throw DoorOfflineError.cancelled}}
    private func owned(_ path:String,under base:URL) throws -> URL {
        guard DoorOfflineManifest.safePath(path) else{throw DoorOfflineError.unsafePath}
        let expected=base.standardizedFileURL
        guard expected.path==root.path || expected.path.hasPrefix(root.path+"/") else{throw DoorOfflineError.unsafePath}
        let url=expected.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(expected.path+"/") else{throw DoorOfflineError.unsafePath}
        // Foundation may leave an existing symlink ancestor unresolved when a
        // later component does not exist yet. Reject every symlink explicitly.
        let relative=String(url.path.dropFirst(root.path.count+1))
        var cursor=root
        for part in relative.split(separator:"/") {
            cursor.appendPathComponent(String(part))
            if let attributes=try? fm.attributesOfItem(atPath:cursor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {throw DoorOfflineError.unsafePath}
        }
        return url
    }
    private func matches(_ file:DoorOfflineManifest.File,at url:URL) throws -> Bool {
        guard fm.fileExists(atPath:url.path) else{return false}
        let attrs=try fm.attributesOfItem(atPath:url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value==file.bytes else{return false}
        return try DoorDigest.sha256(file:url)==file.sha256
    }
    private func receiptURL()->URL {root.appendingPathComponent("active.json")}
    public func activeReceipt() throws -> DoorOfflineReceipt? {
        let url=try owned("active.json",under:root);guard fm.fileExists(atPath:url.path) else{return nil}
        let data=try Data(contentsOf:url)
        guard data.count<=16384,let receipt=try? JSONDecoder().decode(DoorOfflineReceipt.self,from:data),
              receipt.schema==1,receipt.manifestSHA256.count==64,
              receipt.generation==receipt.manifestSHA256 else{throw DoorOfflineError.corruptReceipt}
        let base=try owned("versions/"+receipt.generation,under:root)
        let manifestURL=try owned("manifest.json",under:base)
        let manifestBytes=try Data(contentsOf:manifestURL)
        guard DoorDigest.sha256(manifestBytes)==receipt.manifestSHA256,
              let manifest=try? JSONDecoder().decode(DoorOfflineManifest.self,from:manifestBytes) else{throw DoorOfflineError.corruptReceipt}
        try manifest.validate()
        guard manifest.packageID==receipt.packageID,manifest.version==receipt.version,
              manifest.files.count==receipt.fileCount,manifest.requiredComponents.sorted()==receipt.components,
              manifest.files.reduce(Int64(0),{$0+$1.bytes})==receipt.storedBytes else{throw DoorOfflineError.corruptReceipt}
        return receipt
    }
    public func validatedResource(_ path:String) throws -> URL? {
        guard let receipt=try activeReceipt() else{return nil}
        let base=try owned("versions/"+receipt.generation,under:root)
        let manifest=try JSONDecoder().decode(DoorOfflineManifest.self,from:Data(contentsOf:base.appendingPathComponent("manifest.json")))
        guard let entry=manifest.files.first(where:{$0.path==path}) else{return nil}
        let url=try owned("payload/"+path,under:base)
        guard try matches(entry,at:url) else{throw DoorOfflineError.checksum(path)}
        return url
    }
    public func verifyActivePackage() throws -> DoorOfflineReceipt? {
        guard let receipt=try activeReceipt() else{return nil}
        let base=try owned("versions/"+receipt.generation,under:root)
        let manifest=try JSONDecoder().decode(DoorOfflineManifest.self,from:Data(contentsOf:base.appendingPathComponent("manifest.json")))
        for f in manifest.files {guard try matches(f,at:owned("payload/"+f.path,under:base)) else{throw DoorOfflineError.checksum(f.path)}}
        return receipt
    }
    @discardableResult public func deleteInstalledCopy() throws -> DoorOfflineReceipt? {
        guard operation==nil else{throw DoorOfflineError.writerBusy}
        let lease=try DoorInstallLease(directory:root);defer{withExtendedLifetime(lease){}}
        let current=try activeReceipt()
        var generations=Set<String>()
        if let current{generations.insert(current.generation)}
        let previousURL=try owned("previous.json",under:root)
        if fm.fileExists(atPath:previousURL.path),let data=try? Data(contentsOf:previousURL),
           let previous=try? JSONDecoder().decode(DoorOfflineReceipt.self,from:data),previous.schema==1{
            generations.insert(previous.generation)
        }
        for generation in generations{
            let dir=try owned("versions/"+generation,under:root)
            if fm.fileExists(atPath:dir.path){try fm.removeItem(at:dir)}
        }
        for name in ["active.json","previous.json"]{
            let url=try owned(name,under:root);if fm.fileExists(atPath:url.path){try fm.removeItem(at:url)}
        }
        let staging=try owned("staging",under:root)
        if fm.fileExists(atPath:staging.path){try fm.removeItem(at:staging)}
        return current
    }
    public func install(_ manifest:DoorOfflineManifest, trustedManifestSHA256:String, origin:String,
                        availableBytes:Int64?=nil, reserveBytes:Int64=16*1024*1024,
                        load:@Sendable (DoorOfflineManifest.File) async throws -> Data,
                        progress:(@Sendable (Status) -> Void)?=nil) async throws -> DoorOfflineReceipt {
        guard operation==nil else{throw DoorOfflineError.writerBusy}
        try manifest.validate()
        let manifestData=try manifest.canonicalData(),identity=DoorDigest.sha256(manifestData)
        guard identity==trustedManifestSHA256,origin=="bundled-seed" || origin=="validated-download" else{throw DoorOfflineError.untrustedManifest}
        let lease=try DoorInstallLease(directory:root)
        defer { withExtendedLifetime(lease) {} }
        let token=UUID();operation=token;cancelled=false
        defer{if operation==token{operation=nil;status=Status(phase:.idle,completed:0,total:0,path:nil)}}
        let staging=try owned("staging/"+identity,under:root),final=try owned("versions/"+identity,under:root)
        let old=try activeReceipt()
        if old?.manifestSHA256==identity {if let verified=try verifyActivePackage(){return verified}}
        try fm.createDirectory(at:staging,withIntermediateDirectories:true)
        // A final but not yet activated generation may exist after termination.
        let reusableFinal=fm.fileExists(atPath:final.path)
        let work=reusableFinal ? final:staging
        var needed:Int64=max(0,reserveBytes)
        for f in manifest.files {
            let path=try owned("payload/"+f.path,under:work)
            if try !matches(f,at:path) {needed += f.bytes}
        }
        if let availableBytes,availableBytes<needed {throw DoorOfflineError.insufficientSpace}
        for (i,f) in manifest.files.enumerated() {
            try checkCancellation()
            status=Status(phase:.verifying,completed:i,total:manifest.files.count,path:f.path);progress?(status)
            let path=try owned("payload/"+f.path,under:work)
            if try !matches(f,at:path) {
                status=Status(phase:.loading,completed:i,total:manifest.files.count,path:f.path);progress?(status)
                let bytes=try await load(f)
                try checkCancellation()
                guard Int64(bytes.count)==f.bytes else{throw DoorOfflineError.size(f.path)}
                guard DoorDigest.sha256(bytes)==f.sha256 else{throw DoorOfflineError.checksum(f.path)}
                try fm.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
                // Recheck after potential directory creation; never follow a new symlink outside our generation.
                _ = try owned("payload/"+f.path,under:work)
                try bytes.write(to:path,options:.atomic)
            }
        }
        try checkCancellation()
        for f in manifest.files {guard try matches(f,at:owned("payload/"+f.path,under:work)) else{throw DoorOfflineError.incomplete}}
        try manifestData.write(to:work.appendingPathComponent("manifest.json"),options:.atomic)
        status=Status(phase:.committing,completed:manifest.files.count,total:manifest.files.count,path:nil);progress?(status)
        try checkCancellation()
        if !reusableFinal {
            try fm.createDirectory(at:final.deletingLastPathComponent(),withIntermediateDirectories:true)
            try fm.moveItem(at:work,to:final)
        }
        let receipt=DoorOfflineReceipt(schema:1,packageID:manifest.packageID,version:manifest.version,
                                       manifestSHA256:identity,generation:identity,fileCount:manifest.files.count,
                                       storedBytes:manifest.files.reduce(0,{$0+$1.bytes}),components:manifest.requiredComponents.sorted(),
                                       origin:origin,installedAt:Date())
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        if let old {try encoder.encode(old).write(to:root.appendingPathComponent("previous.json"),options:.atomic)}
        try encoder.encode(receipt).write(to:receiptURL(),options:.atomic)
        return receipt
    }
}

extension DoorOfflineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "離線資料 manifest 無效"
        case .missingComponent: return "離線資料缺少必要元件"
        case .untrustedManifest: return "離線資料不是已核對版本"
        case .writerBusy: return "已有一個離線資料作業正在執行"
        case .cancelled: return "離線資料作業已取消"
        case .insufficientSpace: return "裝置可用空間不足"
        case .unsafePath: return "離線資料路徑不安全"
        case .checksum(let path): return "資料校驗失敗：" + path
        case .size(let path): return "資料大小不符：" + path
        case .incomplete: return "離線資料未完整安裝"
        case .corruptReceipt: return "離線資料收據損毀"
        case .missingFile(let path): return "找不到離線資料：" + path
        case .network(let status): return status > 0 ? "離線資料下載失敗 HTTP \(status)" : "離線資料下載失敗"
        }
    }
}

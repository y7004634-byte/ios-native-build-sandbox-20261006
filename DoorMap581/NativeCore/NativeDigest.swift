import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum DoorDigest {
    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        #else
        // Portable test-host implementation only; Apple builds use CryptoKit.
        var h = PortableSHA256();h.update(data);return h.finalize()
        #endif
    }
    public static func sha256(file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
        #if canImport(CryptoKit)
        var hasher=SHA256()
        #else
        var hasher=PortableSHA256()
        #endif
        while let bytes=try handle.read(upToCount:1<<20),!bytes.isEmpty {
            #if canImport(CryptoKit)
            hasher.update(data:bytes)
            #else
            hasher.update(bytes)
            #endif
        }
        #if canImport(CryptoKit)
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
        #else
        return hasher.finalize()
        #endif
    }
}

#if !canImport(CryptoKit)
private struct PortableSHA256 {
    private var words:[UInt32]=[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    private var tail:[UInt8]=[]
    private var count:UInt64=0
    private static let k:[UInt32]=[
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    private func r(_ x:UInt32,_ n:UInt32)->UInt32 { (x>>n)|(x<<(32-n)) }
    mutating func update(_ data:Data) {
        count &+= UInt64(data.count)
        for b in data { tail.append(b);if tail.count==64 { block(tail);tail.removeAll(keepingCapacity:true) } }
    }
    private mutating func block(_ bytes:[UInt8]) {
        var w=[UInt32](repeating:0,count:64)
        for i in 0..<16 { let o=i*4;w[i]=(UInt32(bytes[o])<<24)|(UInt32(bytes[o+1])<<16)|(UInt32(bytes[o+2])<<8)|UInt32(bytes[o+3]) }
        for i in 16..<64 { let x=w[i-15],y=w[i-2];let a=r(x,7)^r(x,18)^(x>>3),b=r(y,17)^r(y,19)^(y>>10);w[i]=w[i-16]&+a&+w[i-7]&+b }
        var a=words[0],b=words[1],c=words[2],d=words[3],e=words[4],f=words[5],g=words[6],h=words[7]
        for i in 0..<64 {
            let s1=r(e,6)^r(e,11)^r(e,25),ch=(e&f)^((~e)&g),t1=h&+s1&+ch&+Self.k[i]&+w[i]
            let s0=r(a,2)^r(a,13)^r(a,22),maj=(a&b)^(a&c)^(b&c),t2=s0&+maj
            h=g;g=f;f=e;e=d&+t1;d=c;c=b;b=a;a=t1&+t2
        }
        for (i,x) in [a,b,c,d,e,f,g,h].enumerated(){words[i] &+= x}
    }
    mutating func finalize()->String {
        let bits=count &* 8;tail.append(0x80)
        while tail.count%64 != 56 {tail.append(0)}
        for shift in stride(from:56,through:0,by:-8){tail.append(UInt8((bits>>UInt64(shift))&0xff))}
        for i in stride(from:0,to:tail.count,by:64){block(Array(tail[i..<(i+64)]))}
        return words.map{String(format:"%08x",$0)}.joined()
    }
}
#endif

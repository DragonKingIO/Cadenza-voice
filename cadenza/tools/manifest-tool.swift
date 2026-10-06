// 模型清单签名工具（Ed25519）。清单决定应用会下载什么、校验什么，所以远端清单应当签名。
//
//   swift tools/manifest-tool.swift keygen  private.key            # 生成私钥（保密！）并打印公钥（填入 LocalModelCatalog.manifestPublicKeys）
//   swift tools/manifest-tool.swift sign    private.key models-manifest.json   # 生成 models-manifest.json.sig
//   swift tools/manifest-tool.swift verify  <公钥base64> models-manifest.json models-manifest.json.sig
//   swift tools/manifest-tool.swift hash    <文件>                 # 计算 SHA256 与大小，填入清单
import Foundation
import CryptoKit

let a = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
guard a.count >= 3 else { fail("usage: keygen|sign|verify|hash ...") }
switch a[1] {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(toFile: a[2], atomically: true, encoding: .utf8)
    chmod(a[2], 0o600)
    print("public key: " + key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard a.count >= 4, let raw = try? String(contentsOfFile: a[2], encoding: .utf8), let k = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: k), let body = FileManager.default.contents(atPath: a[3]) else { fail("cannot read key or manifest") }
    let sig = try key.signature(for: body).base64EncodedString()
    try sig.write(toFile: a[3] + ".sig", atomically: true, encoding: .utf8)
    print("wrote \(a[3]).sig")
case "verify":
    guard a.count >= 5, let pub = Data(base64Encoded: a[2]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
          let body = FileManager.default.contents(atPath: a[3]), let s = try? String(contentsOfFile: a[4], encoding: .utf8),
          let sig = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("bad arguments") }
    print(key.isValidSignature(sig, for: body) ? "valid" : "INVALID"); exit(key.isValidSignature(sig, for: body) ? 0 : 2)
case "hash":
    guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: a[2])) else { fail("cannot open") }
    var hasher = SHA256(), size = 0
    while let c = try h.read(upToCount: 1 << 20), !c.isEmpty { hasher.update(data: c); size += c.count }
    print("sha256 \(hasher.finalize().map { String(format: "%02x", $0) }.joined())  size \(size)")
default: fail("unknown command")
}

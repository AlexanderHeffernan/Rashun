import Foundation
import Crypto
#if canImport(Security)
import Security
#endif

public final class SecretProtector:@unchecked Sendable {
    private let key:SymmetricKey
    public init(storageDirectory:URL,service:String="com.alexanderheffernan.rashun.sync") throws {
        let material:Data
        try FileManager.default.createDirectory(at:storageDirectory,withIntermediateDirectories:true)
        let url=storageDirectory.appendingPathComponent(".sync-master-key")
        if FileManager.default.fileExists(atPath:url.path){
            material=try Data(contentsOf:url)
            let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
            guard (attrs[.posixPermissions] as? NSNumber)?.intValue==0o600 else{throw SecretProtectionError.insecurePermissions}
        }else{
            #if canImport(Security)
            // Migrate installations created before the file-backed key was introduced. Reading
            // the old item can produce one final Keychain prompt; subsequent launches never do.
            let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"database-master-key",kSecReturnData as String:true]
            var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result)
            if status==errSecSuccess,let found=result as? Data{material=found}
            else if status==errSecItemNotFound{material=Self.random()}
            else{throw SecretProtectionError.storageUnavailable}
            #else
            material=Self.random()
            #endif
            try material.write(to:url,options:[.atomic])
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
        guard material.count==32 else{throw SecretProtectionError.invalidKey};key=SymmetricKey(data:material)
    }
    public func seal(_ plaintext:Data)throws->Data{let box=try AES.GCM.seal(plaintext,using:key);guard let combined=box.combined else{throw SecretProtectionError.encryptionFailed};return Data("RSE1".utf8)+combined}
    public func open(_ protected:Data)throws->Data{guard protected.starts(with:Data("RSE1".utf8)) else{return protected};return try AES.GCM.open(.init(combined:protected.dropFirst(4)),using:key)}
    public func isProtected(_ data:Data)->Bool{data.starts(with:Data("RSE1".utf8))}
    private static func random()->Data{var rng=SystemRandomNumberGenerator();return Data((0..<32).map{_ in UInt8.random(in:.min ... .max,using:&rng)})}
}
public enum SecretProtectionError:Error{case storageUnavailable,insecurePermissions,invalidKey,encryptionFailed}

import Foundation
import AppKit
import Security
import Darwin

// Only this folder is shared with the sandboxed extension. No browser stores or
// credentials are written here. Credentials remain in the login Keychain.
enum DesktopStorage {
    static let extensionID = "local.plainwebkit.browser.desktopwidgets"
    static var home: URL { URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir)) }
    static var directory: URL {
        #if WEBBY_WIDGET_TESTS
        return URL(fileURLWithPath:ProcessInfo.processInfo.environment["WEBBY_WIDGET_TEST_ROOT"]!)
        #else
        return home.appendingPathComponent("Library/Application Support/Webby Desktop Widgets")
        #endif
    }
    static var configuration: URL { directory.appendingPathComponent("profiles.json") }
    static func write<T: Encodable>(_ value:T, to url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONEncoder().encode(value)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func read<T:Decodable>(_ type:T.Type,from url:URL)->T? {
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size < 3_000_000,
              let data=try? Data(contentsOf:url) else{return nil}
        return try? JSONDecoder().decode(type,from:data)
    }
    static func profiles()->[DesktopProfile] { read([DesktopProfile].self,from:configuration) ?? [] }
    static func cache(_ profile:UUID,_ kind:String)->URL { directory.appendingPathComponent("\(profile.uuidString)-\(kind).json") }
}
struct DesktopProfile:Codable,Identifiable,Hashable {
    var id:UUID
    var name:String
    var city:String
    var stock:String
    var note:String
}
struct DesktopMusic:Codable {
    var title:String;var artist:String;var album:String;var artworkURL:String
    var position:Double;var duration:Double;var isPlaying:Bool
}
struct DesktopUsage:Codable {
    struct Window:Codable {var used:Double;var minutes:Int;var resets:Date?}
    struct Chat:Codable {var id:String;var title:String;var directory:String;var updated:Date}
    var chats:[Chat];var windows:[Window];var updated:Date;var usageUpdated:Date?
}
struct DesktopLocal:Codable {
    var music:DesktopMusic?
    var usage:DesktopUsage?
    var clipboard:String?
    var downloads:[String]=[]
    var updated:Date=Date()
}
// Never allow a timeline refresh to cause a Keychain prompt. Foreground setup
// authorizes a separate copy for the two signed desktop executables only.
enum DesktopCredentials {
    static func read(service:String,profile:UUID,prompt:Bool)->Data? {
        var q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
                           kSecAttrAccount as String:profile.uuidString,kSecReturnData as String:true]
        if !prompt {q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail}
        var result:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess else{return nil}
        return result as? Data
    }
    static func prune(profiles:Set<UUID>) {
        for suffix in ["calendar-feed","github-widgets"] {
            let service="local.webby.desktop."+suffix
            let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecReturnAttributes as String:true,kSecMatchLimit as String:kSecMatchLimitAll,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
            var result:CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let entries=result as? [[String:Any]] else{continue}
            for entry in entries {
                guard let account=entry[kSecAttrAccount as String] as? String,let id=UUID(uuidString:account) else{continue}
                let original:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.plainwebkit."+suffix,kSecAttrAccount as String:account,kSecReturnAttributes as String:true,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
                let status=SecItemCopyMatching(original as CFDictionary,nil)
                if !profiles.contains(id) || status==errSecItemNotFound {
                    let remove:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
                    SecItemDelete(remove as CFDictionary)
                }
            }
        }
    }
    static func copy(service:String,profile:UUID,extensionPath:String) throws -> Bool {
        guard let data=read(service:service,profile:profile,prompt:true) else{return false}
        var trusted:SecTrustedApplication?
        let trustStatus=SecTrustedApplicationCreateFromPath(extensionPath,&trusted)
        guard trustStatus==errSecSuccess,let trusted else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(trustStatus))}
        var host:SecTrustedApplication?
        let hostStatus=SecTrustedApplicationCreateFromPath(nil,&host)
        guard hostStatus==errSecSuccess,let host else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(hostStatus))}
        var access:SecAccess?
        let accessStatus=SecAccessCreate("Webby desktop widgets" as CFString,[host,trusted] as CFArray,&access)
        guard accessStatus==errSecSuccess,let access else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(accessStatus))}
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service.replacingOccurrences(of:"local.plainwebkit.",with:"local.webby.desktop."),
            kSecAttrAccount as String:profile.uuidString]
        let values:[String:Any]=[kSecValueData as String:data,kSecAttrAccess as String:access]
        var result=SecItemUpdate(q as CFDictionary,values as CFDictionary)
        if result==errSecItemNotFound {result=SecItemAdd(q.merging(values){_,v in v} as CFDictionary,nil)}
        guard result==errSecSuccess else{throw NSError(domain:NSOSStatusErrorDomain,code:Int(result))}
        return true
    }
}

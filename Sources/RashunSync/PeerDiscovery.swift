import Foundation
#if canImport(Network)
import Network
#endif

public struct DiscoveredPeer:Hashable,Sendable {public let serviceName:String;public let host:String?;public let port:UInt16?;public init(serviceName:String,host:String?=nil,port:UInt16?=nil){self.serviceName=serviceName;self.host=host;self.port=port}}
public protocol PeerDiscovery:Sendable {func events() -> AsyncStream<[DiscoveredPeer]>}

#if canImport(Network)
public final class AppleBonjourDiscovery:PeerDiscovery,@unchecked Sendable {
    private let queue=DispatchQueue(label:"com.rashun.discovery")
    public init(){}
    public func events()->AsyncStream<[DiscoveredPeer]>{AsyncStream{continuation in
        let browser=NWBrowser(for:.bonjour(type:"_rashun-sync._tcp",domain:nil),using:.tcp)
        browser.browseResultsChangedHandler={results,_ in continuation.yield(results.compactMap{result in guard case let .service(name,_,_,_)=result.endpoint else{return nil};return DiscoveredPeer(serviceName:name)})}
        browser.stateUpdateHandler={if case .failed=($0){continuation.finish()}}
        continuation.onTermination={_ in browser.cancel()};browser.start(queue:self.queue)
    }}
}
#endif

public enum ManualPeerAddress {
    public static func validate(_ value:String,allowLoopbackHTTP:Bool=false)throws->URL{guard let url=URL(string:value),url.host != nil,(url.scheme=="https" || (allowLoopbackHTTP && url.scheme=="http" && ["localhost","127.0.0.1","::1"].contains(url.host))) else{throw URLError(.badURL)};return url}
    public static func priority(_ urls:[URL])->[URL]{urls.sorted{lhs,rhs in func rank(_ u:URL)->Int{if u.host?.hasSuffix(".ts.net")==true{return 0};if u.scheme=="https"{return 1};return 2};return rank(lhs)<rank(rhs)}}
}

public enum DNSServiceOutputParser {
    public static func avahi(_ line:String)->DiscoveredPeer?{let fields=line.split(separator:";",omittingEmptySubsequences:false).map(String.init);guard fields.count>=9,fields[0]=="=",fields[4]=="_rashun-sync._tcp",let port=UInt16(fields[8])else{return nil};return .init(serviceName:fields[3],host:fields[6].trimmingCharacters(in:CharacterSet(charactersIn:".")),port:port)}
    public static func windowsPTR(_ text:String)->[DiscoveredPeer]{text.split(whereSeparator:\.isNewline).compactMap{line in let value=line.trimmingCharacters(in:.whitespaces);guard value.hasSuffix("._rashun-sync._tcp.local")else{return nil};return .init(serviceName:String(value.dropLast("._rashun-sync._tcp.local".count)))}}
}

#if os(Linux)
public final class AvahiPeerDiscovery:PeerDiscovery,@unchecked Sendable {public init(){};public func events()->AsyncStream<[DiscoveredPeer]>{AsyncStream{continuation in let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/avahi-browse");process.arguments=["-rtp","_rashun-sync._tcp"];let pipe=Pipe();process.standardOutput=pipe;pipe.fileHandleForReading.readabilityHandler={handle in let text=String(decoding:handle.availableData,as:UTF8.self),values=text.split(whereSeparator:\.isNewline).compactMap{DNSServiceOutputParser.avahi(String($0))};if !values.isEmpty{continuation.yield(values)}};do{try process.run()}catch{continuation.finish()};continuation.onTermination={_ in process.terminate()}}}}
#elseif os(Windows)
public final class WindowsDNSPeerDiscovery:PeerDiscovery,@unchecked Sendable {public init(){};public func events()->AsyncStream<[DiscoveredPeer]>{AsyncStream{continuation in let process=Process();process.executableURL=URL(fileURLWithPath:"C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe");process.arguments=["-NoProfile","-Command","(Resolve-DnsName -Type PTR _rashun-sync._tcp.local -ErrorAction SilentlyContinue).NameHost"];let pipe=Pipe();process.standardOutput=pipe;process.terminationHandler={_ in let values=DNSServiceOutputParser.windowsPTR(String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self));continuation.yield(values);continuation.finish()};do{try process.run()}catch{continuation.finish()};continuation.onTermination={_ in process.terminate()}}}}
#endif

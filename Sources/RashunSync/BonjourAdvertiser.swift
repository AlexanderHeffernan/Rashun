import Foundation

#if os(macOS) || os(iOS)
public final class BonjourAdvertiser:NSObject,@unchecked Sendable {
    private var service:NetService?
    public override init(){super.init()}
    public func start(name:String,port:Int){let service=NetService(domain:"local.",type:"_rashun-sync._tcp.",name:name,port:Int32(port));service.includesPeerToPeer=false;service.publish();self.service=service}
    public func stop(){service?.stop();service=nil}
    deinit{service?.stop()}
}
#else
public final class BonjourAdvertiser:@unchecked Sendable {public init(){};public func start(name:String,port:Int){};public func stop(){}}
#endif

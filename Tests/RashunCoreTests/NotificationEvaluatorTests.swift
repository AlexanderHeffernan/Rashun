import XCTest
@testable import RashunCore

final class NotificationEvaluatorTests:XCTestCase {
    func testInjectedClockControlsCooldownAndEventIdentityIsDeterministic(){let now=Date(timeIntervalSince1970:10_000),definition=NotificationDefinition(id:"test",title:"Test",detail:"",inputs:[]){_ in NotificationEvent(title:"Title",body:"Body",cooldownSeconds:60,cycleKey:nil)},context=NotificationContext(sourceName:"Codex",metricId:"weekly",metricTitle:"Weekly",current:usage(40),previous:UsageSnapshot(timestamp:Date(timeIntervalSince1970:9_900),usage:usage(50)),history:[],now:now){_,value in value}
        let first=NotificationEvaluator.evaluate(definition:definition,context:context,state:nil,now:now);XCTAssertNotNil(first);XCTAssertEqual(first?.eventID,NotificationEvaluator.evaluate(definition:definition,context:context,state:nil,now:now.addingTimeInterval(300))?.eventID)
        XCTAssertNil(NotificationEvaluator.evaluate(definition:definition,context:context,state:.init(lastFiredAt:now.addingTimeInterval(-30),lastFiredCycleKey:nil),now:now));XCTAssertNotNil(NotificationEvaluator.evaluate(definition:definition,context:context,state:.init(lastFiredAt:now.addingTimeInterval(-61),lastFiredCycleKey:nil),now:now))
    }
    func testContextSnapshotUsesInjectedClock(){let now=Date(timeIntervalSince1970:1000),old=UsageSnapshot(timestamp:Date(timeIntervalSince1970:700),usage:usage(80)),future=UsageSnapshot(timestamp:Date(timeIntervalSince1970:950),usage:usage(70)),context=NotificationContext(sourceName:"x",metricId:nil,metricTitle:nil,current:usage(60),previous:nil,history:[old,future],now:now){_,v in v};XCTAssertEqual(context.snapshot(minutesAgo:2)?.timestamp,old.timestamp)}
    private func usage(_ value:Double)->UsageResult{.init(remaining:value,limit:100,resetDate:nil,cycleStartDate:nil)}
}

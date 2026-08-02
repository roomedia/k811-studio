import Foundation
import XCTest

@testable import K811Core

final class K811AgentStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 완료 알림 자동 소등

    func testCompletedExpiresWhenNotSuperseded() {
        var state = K811AgentState()
        let signal = K811AgentSignal(source: .claude, kind: .completed, sessionID: "a")
        state.apply(signal, at: now)

        XCTAssertTrue(state.expireCompleted(key: signal.key, notNewerThan: now))
        XCTAssertNil(state.activeSignal)
    }

    func testCompletedSurvivesWhenNewerSignalArrivedAfterScheduling() {
        var state = K811AgentState()
        let signal = K811AgentSignal(source: .claude, kind: .completed, sessionID: "a")
        // 예약 시점보다 나중에 같은 키가 갱신되면 그 예약은 무효다.
        state.apply(signal, at: now.addingTimeInterval(300))

        XCTAssertFalse(state.expireCompleted(key: signal.key, notNewerThan: now))
        XCTAssertEqual(state.activeSignal?.kind, .completed)
    }

    func testWaitingStatesAreNeverExpiredByTime() {
        for kind in [K811AgentEventKind.question, .approval, .failure] {
            var state = K811AgentState()
            let signal = K811AgentSignal(source: .claude, kind: kind, sessionID: "a")
            state.apply(signal, at: now)

            XCTAssertFalse(
                state.expireCompleted(key: signal.key, notNewerThan: now),
                "\(kind) 는 사람이 응답해야만 꺼져야 한다"
            )
            XCTAssertEqual(state.activeSignal?.kind, kind)
        }
    }

    func testExpiringAnUnknownKeyIsANoop() {
        var state = K811AgentState()
        state.apply(K811AgentSignal(source: .claude, kind: .completed, sessionID: "a"), at: now)

        XCTAssertFalse(state.expireCompleted(key: "claude:missing", notNewerThan: now))
        XCTAssertEqual(state.entries.count, 1)
    }

    // MARK: - clear 의 범위

    func testSessionScopedClearLeavesOtherSessionsPending() {
        var state = K811AgentState()
        state.apply(K811AgentSignal(source: .claude, kind: .approval, sessionID: "a"), at: now)
        state.apply(K811AgentSignal(source: .claude, kind: .completed, sessionID: "b"), at: now)

        state.apply(K811AgentSignal(source: .claude, kind: .clear, sessionID: "b"), at: now)

        XCTAssertEqual(state.entries.count, 1)
        XCTAssertEqual(state.activeSignal?.kind, .approval)
        XCTAssertEqual(state.activeSignal?.sessionID, "a")
    }

    func testClearWithoutSessionStillWipesThatSourceOnly() {
        var state = K811AgentState()
        state.apply(K811AgentSignal(source: .claude, kind: .approval, sessionID: "a"), at: now)
        state.apply(K811AgentSignal(source: .codex, kind: .failure, sessionID: "z"), at: now)

        state.apply(K811AgentSignal(source: .claude, kind: .clear, sessionID: nil), at: now)

        XCTAssertEqual(state.entries.count, 1)
        XCTAssertEqual(state.activeSignal?.source, .codex)
    }

    // MARK: - 심각도 우선순위

    func testHighestSeverityWinsAndClearingItRestoresTheNextOne() {
        var state = K811AgentState()
        state.apply(K811AgentSignal(source: .claude, kind: .completed, sessionID: "a"), at: now)
        state.apply(K811AgentSignal(source: .claude, kind: .failure, sessionID: "b"), at: now)
        XCTAssertEqual(state.activeSignal?.kind, .failure)

        state.apply(K811AgentSignal(source: .claude, kind: .clear, sessionID: "b"), at: now)
        XCTAssertEqual(state.activeSignal?.kind, .completed)
    }

    // MARK: - 최전면 판정에 쓰는 조상 추적

    func testAncestorProcessIDsIncludesSelfAndTerminates() {
        let ancestors = K811Presence.ancestorProcessIDs()

        XCTAssertTrue(ancestors.contains(getpid()))
        XCTAssertFalse(ancestors.contains(0))
        // launchd 까지 거슬러 올라가도 사슬은 짧다. 순환하면 여기서 걸린다.
        XCTAssertLessThan(ancestors.count, 64)
    }

    func testParentProcessIDOfSelfIsResolvable() {
        XCTAssertNotNil(K811Presence.parentProcessID(of: getpid()))
    }
}

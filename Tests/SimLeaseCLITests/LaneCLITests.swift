import Foundation
import XCTest
import SimLeaseCore
@testable import SimLeaseCLI

final class LaneCLITests: XCTestCase {
    func testAcquireJSONUsesSharedSchema() throws {
        let fixture = Fixture()
        let code = SimLeaseCLI.run(
            arguments: [
                "simlease", "lane", "acquire",
                "--project", "ExplorerDex",
                "--device-type", "iPhone 17 Pro",
                "--runtime", "latest",
                "--json",
            ],
            environment: [:],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(
            try JSONDecoder.simLease.decode(
                LaneAcquireResult.self,
                from: Data(fixture.output.value.utf8)
            ).lane?.udid,
            "UDID-1"
        )
    }

    func testAcquireHumanOutputProvidesExactNextActions() {
        let fixture = Fixture()
        let code = SimLeaseCLI.run(
            arguments: [
                "simlease", "lane", "acquire",
                "--project", "ExplorerDex",
                "--device-type", "iPhone 17 Pro",
                "--runtime", "latest",
            ],
            environment: [:],
            configuration: fixture.configuration
        )

        XCTAssertEqual(code, 0)
        XCTAssertTrue(fixture.output.value.contains("Acquired lane-1"))
        XCTAssertTrue(fixture.output.value.contains("UDID: UDID-1"))
        XCTAssertTrue(fixture.output.value.contains("export SIMLEASE_LANE_FILE="))
        XCTAssertTrue(fixture.output.value.contains("platform=iOS Simulator,id=UDID-1"))
        XCTAssertTrue(fixture.output.value.contains("simlease lane release"))
    }

    func testReleaseRequiresDescriptorEnvironment() {
        let fixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "lane", "release"],
                environment: [:],
                configuration: fixture.configuration
            ),
            64
        )
    }

    func testCapacityFullHumanOutputExplainsNoMutationAndRetry() {
        let fixture = Fixture(acquireError: .capacityFull(.fixture))
        let code = fixture.acquire(json: false)

        XCTAssertEqual(code, 75)
        XCTAssertTrue(fixture.errors.value.contains("observed 2 reserved lane(s); capacity is 2"))
        XCTAssertTrue(fixture.errors.value.contains("state were unchanged"))
        XCTAssertTrue(fixture.errors.value.contains("Current owners"))
        XCTAssertTrue(fixture.errors.value.contains("Simulator validation"))
        XCTAssertTrue(fixture.errors.value.contains("Retry:"))
    }

    func testCapacityFullJSONUsesAcquireSchema() throws {
        let fixture = Fixture(acquireError: .capacityFull(.fixture))
        XCTAssertEqual(fixture.acquire(json: true), 75)

        let result = try JSONDecoder.simLease.decode(
            LaneAcquireResult.self,
            from: Data(fixture.output.value.utf8)
        )
        XCTAssertEqual(result.state, .capacityFull)
        XCTAssertNil(result.lane)
        XCTAssertFalse(result.nextActions.isEmpty)
        XCTAssertEqual(fixture.errors.value, "")
    }

    func testUnavailableRuntimePrintsValidLocalChoices() {
        let fixture = Fixture(acquireError: .runtimeUnavailable(
            requested: "iOS 99",
            available: ["com.apple.CoreSimulator.SimRuntime.iOS-27-0"]
        ))
        XCTAssertEqual(fixture.acquire(json: false), 74)
        XCTAssertTrue(fixture.errors.value.contains("iOS 99"))
        XCTAssertTrue(fixture.errors.value.contains("iOS-27-0"))
        XCTAssertTrue(fixture.errors.value.contains("--runtime <exact-choice>"))
    }

    func testStatusConfigAndReleaseUseService() throws {
        let fixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "lane", "status", "--json"],
                environment: [:],
                configuration: fixture.configuration
            ),
            0
        )
        XCTAssertEqual(
            try JSONDecoder.simLease.decode(
                LaneStatusReport.self,
                from: Data(fixture.output.value.utf8)
            ).configuration.maxActive,
            2
        )

        let configFixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "lane", "config", "--max-active", "3"],
                environment: [:],
                configuration: configFixture.configuration
            ),
            0
        )
        XCTAssertTrue(configFixture.output.value.contains("Maximum active lanes: 3"))

        let releaseFixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: ["simlease", "lane", "release"],
                environment: ["SIMLEASE_LANE_FILE": "/tmp/lane.json"],
                configuration: releaseFixture.configuration
            ),
            0
        )
        XCTAssertTrue(releaseFixture.output.value.contains("was not deleted"))
    }

    func testRecoveryPlanJSONAndHumanApplyContracts() throws {
        let planFixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: [
                    "simlease", "lane", "recover", "plan", "lane-1", "--json",
                ],
                environment: [:],
                configuration: planFixture.configuration
            ),
            0
        )
        XCTAssertEqual(
            try JSONDecoder.simLease.decode(
                LaneLifecyclePlan.self,
                from: Data(planFixture.output.value.utf8)
            ).fingerprint.udid,
            "UDID-1"
        )

        let applyFixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: [
                    "simlease", "lane", "recover", "apply", "ABC123",
                    "--lane", "lane-1",
                ],
                environment: [:],
                configuration: applyFixture.configuration
            ),
            0
        )
        XCTAssertTrue(applyFixture.output.value.contains("Recovered lane-1"))
        XCTAssertTrue(applyFixture.output.value.contains("not deleted"))
    }

    func testDisposalPlanAndApplyHumanContracts() {
        let planFixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: [
                    "simlease", "lane", "dispose", "plan", "UDID-1",
                ],
                environment: [:],
                configuration: planFixture.configuration
            ),
            0
        )
        XCTAssertTrue(planFixture.output.value.contains("No change made"))
        XCTAssertTrue(planFixture.output.value.contains("UDID-1"))
        XCTAssertTrue(planFixture.output.value.contains("ABC123"))

        let applyFixture = Fixture()
        XCTAssertEqual(
            SimLeaseCLI.run(
                arguments: [
                    "simlease", "lane", "dispose", "apply", "ABC123",
                    "--target", "UDID-1",
                ],
                environment: [:],
                configuration: applyFixture.configuration
            ),
            0
        )
        XCTAssertTrue(applyFixture.output.value.contains("Deleted managed simulator UDID-1"))
    }
}

private final class Fixture {
    let output = TextBox()
    let errors = TextBox()
    let service: LaneServiceStub

    init(acquireError: LaneServiceError? = nil) {
        service = LaneServiceStub(acquireError: acquireError)
    }

    func acquire(json: Bool) -> Int32 {
        var arguments = [
            "simlease", "lane", "acquire",
            "--project", "ExplorerDex",
            "--device-type", "iPhone 17 Pro",
            "--runtime", "latest",
        ]
        if json { arguments.append("--json") }
        return SimLeaseCLI.run(
            arguments: arguments,
            environment: [:],
            configuration: configuration
        )
    }

    lazy var configuration = CLIConfiguration(
        paths: LeasePaths(root: URL(fileURLWithPath: "/tmp/lane-cli")),
        timing: .production,
        standardOutput: { [output] in output.append($0) },
        standardError: { [errors] in errors.append($0) },
        laneService: service
    )
}

private final class LaneServiceStub: LaneServicing, @unchecked Sendable {
    private let acquireError: LaneServiceError?

    init(acquireError: LaneServiceError?) {
        self.acquireError = acquireError
    }

    func acquire(request: LaneAcquireRequest, identity: LeaseIdentity) throws -> LaneAcquireResult {
        if let acquireError { throw acquireError }
        let descriptor = LaneDescriptor(
            laneID: "lane-1",
            slot: 1,
            token: "TOKEN-1",
            project: request.project,
            threadID: identity.threadID,
            threadTitle: identity.threadTitle,
            udid: "UDID-1",
            deviceTypeIdentifier: "TYPE-1",
            deviceTypeName: "iPhone 17 Pro",
            runtimeIdentifier: "RUNTIME-1",
            runtimeName: "iOS 27.0",
            derivedDataPath: "/tmp/DerivedData",
            acquiredAt: Date(timeIntervalSince1970: 1_000),
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 8_200)
        )
        return LaneAcquireResult(
            state: .acquired,
            lane: descriptor,
            environment: ["SIMLEASE_LANE_FILE": "/tmp/lane.json"],
            xcodebuildArguments: [
                "-destination", "platform=iOS Simulator,id=UDID-1",
                "-derivedDataPath", "/tmp/DerivedData",
            ],
            derivedDataPath: "/tmp/DerivedData",
            resultBundlePath: "/tmp/Results/lane-1.xcresult",
            releaseCommand: ["simlease", "lane", "release"],
            nextActions: []
        )
    }

    func status(now: Date) throws -> LaneStatusReport { .fixture }
    func configure(maxActive: Int?) throws -> LaneConfigurationReport {
        LaneConfigurationReport(
            configuration: LaneConfiguration(maxActive: maxActive ?? 2),
            reservationCount: 1
        )
    }
    func renew(descriptorURL: URL, now: Date) throws -> LaneDescriptor { fatalError() }
    func release(descriptorURL: URL, identity: LeaseIdentity) throws -> LaneReleaseResult {
        LaneReleaseResult(
            laneID: "lane-1",
            udid: "UDID-1",
            state: "idle",
            disposalPlanCommand: ["simlease", "lane", "dispose", "plan", "UDID-1"]
        )
    }
    func createRecoveryPlan(laneID: String, now: Date) throws -> LaneLifecyclePlan {
        lifecyclePlan(kind: .recovery, laneID: laneID)
    }
    func applyRecovery(planID: String, laneID: String, now: Date) throws -> LaneReleaseResult {
        LaneReleaseResult(
            laneID: laneID,
            udid: "UDID-1",
            state: "idle",
            disposalPlanCommand: ["simlease", "lane", "dispose", "plan", "UDID-1"]
        )
    }
    func createDisposalPlan(udid: String, now: Date) throws -> LaneLifecyclePlan {
        lifecyclePlan(kind: .disposal, laneID: nil)
    }
    func applyDisposal(planID: String, udid: String, now: Date) throws -> LaneDisposalResult {
        LaneDisposalResult(planID: planID, udid: udid, deleted: true)
    }

    private func lifecyclePlan(
        kind: LaneLifecyclePlanKind,
        laneID: String?
    ) -> LaneLifecyclePlan {
        LaneLifecyclePlan(
            id: "ABC123",
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_600),
            laneID: laneID,
            reservationGeneration: kind == .recovery ? 1 : nil,
            lastActivityAt: kind == .recovery
                ? Date(timeIntervalSince1970: 500)
                : nil,
            fingerprint: ManagedSimulatorFingerprint(
                udid: "UDID-1",
                deviceTypeIdentifier: "TYPE-1",
                runtimeIdentifier: "RUNTIME-1",
                standardizedDataPath: "/tmp/Devices/UDID-1",
                state: "Shutdown"
            )
        )
    }
}

private extension LaneStatusReport {
    static var fixture: LaneStatusReport {
        LaneStatusReport(
            configuration: LaneConfiguration(maxActive: 2),
            reserved: [LaneStatusEntry(
                laneID: "lane-1",
                slot: 1,
                project: "ExplorerDex",
                threadID: "thread-1",
                threadTitle: "Simulator validation",
                udid: "UDID-1",
                runtimeName: "iOS 27.0",
                deviceTypeName: "iPhone 17 Pro",
                lastActivityAt: Date(timeIntervalSince1970: 1_000),
                expiresAt: Date(timeIntervalSince1970: 8_200),
                isCommandActive: false,
                recoveryRequired: false
            ), LaneStatusEntry(
                laneID: "lane-2",
                slot: 2,
                project: "Set",
                threadID: "thread-2",
                threadTitle: "Import validation",
                udid: "UDID-2",
                runtimeName: "iOS 27.0",
                deviceTypeName: "iPhone 17 Pro",
                lastActivityAt: Date(timeIntervalSince1970: 1_000),
                expiresAt: Date(timeIntervalSince1970: 8_200),
                isCommandActive: true,
                recoveryRequired: false
            )],
            availableSlots: []
        )
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func append(_ value: String) { lock.withLock { text += value } }
}

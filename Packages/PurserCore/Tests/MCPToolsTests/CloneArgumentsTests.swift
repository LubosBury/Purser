import Foundation
import Testing
import Domain
import Catalog
import Executor
import Planner
import MCPBridge
@testable import MCPTools
import PurserTestSupport

private func snapshot() -> CatalogSnapshot {
    var catalog = SyntheticCatalog()
    catalog.addSubscription("s", prices: ["USA": SyntheticCatalog.d("29.99")])
    catalog.addIAP("life", base: "USA", manual: ["USA": SyntheticCatalog.d("49.99")])
    return catalog.snapshot()
}

private func message(_ body: () throws -> Void) -> String? {
    do { try body() } catch let error as ToolArgumentError { return error.message } catch { return "other: \(error)" }
    return nil
}

@Suite struct CloneArgumentsTests {
    @Test func defaultsCloneEverythingIntoTheSourceGroupWithTheSuffix() throws {
        let request = try CloneArguments.request(["products": [["source": "com.example.s"], ["source": "life"]], "suffix": " _AB3 "],
                                                 snapshot: snapshot())
        #expect(request.items == [CloneItem(source: .subscription("s"), productId: "com.example.s_AB3", name: "Synthetic s_AB3"),
                                  CloneItem(source: .iap("life"), productId: "com.example.life_AB3", name: "Synthetic life_AB3")])
        #expect(request.group == .sourceGroup && request.level == .sameAsSource)
        #expect(request.copy == CloneCopy() && request.offerCodeSuffix == "_AB3")
    }

    @Test func explicitIdsANewGroupTheEndLevelAndACopyList() throws {
        let request = try CloneArguments.request(["products": [["source": "s", "product_id": "s.b", "name": "S B"]], "suffix": "_B",
                                                  "group": ["new": "Variant B"], "level": "end", "copy": ["localizations", "prices"]],
                                                 snapshot: snapshot())
        #expect(request.items == [CloneItem(source: .subscription("s"), productId: "s.b", name: "S B")])
        #expect(request.group == .newGroup(name: "Variant B") && request.level == .end)
        #expect(request.copy == CloneCopy(localizations: true, reviewScreenshot: false, prices: true, introOffers: false, promoOffers: false))
        let nothing = try CloneArguments.request(["products": [["source": "s"]], "suffix": "_B", "group": "source", "copy": []], snapshot: snapshot())
        #expect(nothing.copy == CloneCopy(localizations: false, reviewScreenshot: false, prices: false, introOffers: false, promoOffers: false))
    }

    @Test func wrongArgumentsAreNamed() {
        let s = snapshot()
        #expect(message { _ = try CloneArguments.request(["products": [["source": "s"]]], snapshot: s) }?.contains("suffix") == true)
        #expect(message { _ = try CloneArguments.request(["products": [], "suffix": "_B"], snapshot: s) }?.contains("products") == true)
        #expect(message { _ = try CloneArguments.request(["products": [["source": "nope"]], "suffix": "_B"], snapshot: s) }?
            .contains("No subscription or in-app purchase") == true)
        #expect(message { _ = try CloneArguments.request(["products": [["product_id": "x"]], "suffix": "_B"], snapshot: s) }?
            .contains("source") == true)
        #expect(message { _ = try CloneArguments.request(["products": [["source": "s"]], "suffix": "_B", "group": "other"], snapshot: s) }?
            .contains("group") == true)
        #expect(message { _ = try CloneArguments.request(["products": [["source": "s"]], "suffix": "_B", "level": "middle"], snapshot: s) }?
            .contains("level") == true)
        #expect(message { _ = try CloneArguments.request(["products": [["source": "s"]], "suffix": "_B", "copy": ["everything"]], snapshot: s) }?
            .contains("copy") == true)
    }

    @Test func onlyAMissingOrNullCopyMeansEverything() throws {
        let s = snapshot()
        #expect(try CloneArguments.request(["products": [["source": "s"]], "suffix": "_B", "copy": .null], snapshot: s).copy == CloneCopy())
        let wrongTypes: [JSONValue] = ["localizations", true, 3, ["x": "y"]]
        for wrong in wrongTypes {
            let problem = message { _ = try CloneArguments.request(["products": [["source": "s"]], "suffix": "_B", "copy": wrong], snapshot: s) }
            #expect(problem?.contains("“copy” must be a list") == true)
            #expect(problem?.contains("omit it to copy everything") == true)
        }
    }

    @Test func theCopyNamesAreTheOnesTheSchemaOffers() throws {
        for name in ["clone_products", "preview_clone"] {
            let schema = try #require(ToolCatalog.definition(named: name)?.inputSchema)
            let offered = schema["properties"]?["copy"]?["items"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
            #expect(offered == CloneArguments.copyNames, "\(name)")
        }
    }

    @Test func aPreviewWhileARunIsInProgressSaysSoAndListsNoSteps() {
        let clone = MCPRender.productRunInProgress(.clone)
        #expect(clone["running"]?.stringValue == "clone")
        #expect(clone["note"]?.stringValue == "A clone is running in Purser; wait until it finishes.")
        #expect(clone["steps"] == nil)
        let creation = MCPRender.productRunInProgress(.creation)
        #expect(creation["running"]?.stringValue == "creation")
        #expect(creation["note"]?.stringValue == "New products are being created in Purser; wait until that finishes.")
    }

    @Test func aBlockedStepIsListedApartWithItsReason() {
        let s = snapshot()
        let item = CloneItem(source: .subscription("s"), productId: "com.example.s_AB3", name: "Synthetic s_AB3")
        let screenshot = CloneStep.reviewScreenshot(productId: item.productId)
        let mixed = MCPRender.cloneSteps(ClonePreview(steps: [screenshot, .availability(productId: item.productId)],
                                                      blocked: [screenshot: "Remove it first."]), snapshot: s)
        #expect(mixed["steps"]?.arrayValue?.map(\.stringValue) == ["make com.example.s_AB3 available where its source is"])
        #expect(mixed["blocked"]?.arrayValue?.first?["step"]?.stringValue == "copy the review screenshot to com.example.s_AB3")
        #expect(mixed["blocked"]?.arrayValue?.first?["reason"]?.stringValue == "Remove it first.")
        let onlyBlocked = MCPRender.cloneSteps(ClonePreview(steps: [screenshot], blocked: [screenshot: "Remove it first."]), snapshot: s)
        #expect(onlyBlocked["steps"]?.arrayValue?.isEmpty == true)
        #expect(onlyBlocked["note"]?.stringValue?.contains("blocked") == true)
    }

    @Test func thePreviewAndTheResultAreRendered() {
        let s = snapshot()
        let item = CloneItem(source: .subscription("s"), productId: "com.example.s_AB3", name: "Synthetic s_AB3")
        let preview = MCPRender.cloneSteps(ClonePreview(steps: [.product(item), .availability(productId: item.productId),
                                                                .localization(productId: item.productId, locale: "cs"),
                                                                .reviewScreenshot(productId: item.productId)], blocked: [:]), snapshot: s)
        #expect(preview["blocked"] == nil)
        #expect(preview["steps"]?.arrayValue?.map(\.stringValue) == [
            "create the subscription com.example.s_AB3 (Synthetic s_AB3) as a copy of com.example.s",
            "make com.example.s_AB3 available where its source is",
            "add the cs text of com.example.s_AB3",
            "copy the review screenshot to com.example.s_AB3",
        ])
        let report = CloneReport(steps: [CloneStepReport(step: .product(item), outcome: .created(ascId: "c-1")),
                                         CloneStepReport(step: .reviewScreenshot(productId: item.productId), outcome: .failed("HTTP 500"))],
                                 created: ["s": "c-1"])
        let drafts = CloneDraftOutcome(drafts: [CloneDraftOutcome.Line(title: "Clone com.example.s_AB3 of com.example.s: regular prices (apply first)",
                                                                      planId: "plan-1", error: nil)],
                                       notes: ["Synthetic note"])
        let result = MCPRender.cloneResult(report, drafts: drafts, snapshot: s)
        #expect(result["steps"]?.arrayValue?.map { $0["outcome"] } == ["created", "failed"])
        #expect(result["steps"]?.arrayValue?.last?["message"] == "HTTP 500")
        #expect(result["clones"]?.arrayValue?.first?["source"] == "com.example.s")
        #expect(result["clones"]?.arrayValue?.first?["clone_asc_id"] == "c-1")
        #expect(result["drafts"]?.arrayValue?.first?["plan_id"] == "plan-1")
        #expect(result["not_copied"] == ["Synthetic note"])
        #expect(MCPRender.cloneResult(report, drafts: nil, snapshot: s)["drafts"] == "preparing")
        #expect(MCPRender.cloneResult(report, drafts: CloneDraftOutcome(syncProblem: "Sync failed"), snapshot: s)["sync_problem"] == "Sync failed")
    }

    @Test func aDraftThatAlreadyExistsKeepsItsNoteAndItsPlan() {
        let line = CloneDraftOutcome.Line(title: "Clone x: regular prices (apply first)", planId: "plan-1", error: nil, note: "Draft already exists")
        let failed = CloneDraftOutcome.Line(title: "Clone x: intro offers", planId: nil, error: "No offer to copy")
        let report = CloneReport(steps: [], created: ["s": "c-1"])
        let drafts = MCPRender.cloneResult(report, drafts: CloneDraftOutcome(drafts: [line, failed]), snapshot: snapshot())["drafts"]?.arrayValue
        #expect(drafts?.first?["plan_id"] == "plan-1" && drafts?.first?["note"] == "Draft already exists")
        #expect(drafts?.last?["plan_id"] == nil && drafts?.last?["note"] == nil && drafts?.last?["error"] == "No offer to copy")
    }

    @Test func theAnswerAlwaysCarriesNotCopied() {
        let s = snapshot()
        let report = CloneReport(steps: [], created: ["s": "c-1"])
        // Prepared and nothing left out: an empty list, and the answer says so.
        let complete = MCPRender.cloneResult(report, drafts: CloneDraftOutcome(drafts: []), snapshot: s)
        #expect(complete["not_copied"] == [])
        #expect(complete["note"]?.stringValue?.contains("Nothing of the sources' prices and offers was left out.") == true)
        // Not prepared: the list is not known yet, so it names the standing exclusions instead of claiming there are none.
        let preparing = MCPRender.cloneResult(report, drafts: nil, snapshot: s)
        let syncFailed = MCPRender.cloneResult(report, drafts: CloneDraftOutcome(syncProblem: "Sync failed"), snapshot: s)
        let unknowns: [JSONValue] = [preparing, syncFailed]
        for unknown in unknowns {
            let entries = unknown["not_copied"]?.arrayValue
            #expect(entries?.count == 1)
            #expect(entries?.first?.stringValue?.contains("Not worked out yet") == true)
            #expect(entries?.first?.stringValue?.contains("MONTHLY") == true)
        }
    }

    @Test func aRunThatClonedNothingPreparesNoDraftsAndDoesNotClaimThatNothingWasLeftOut() {
        let item = CloneItem(source: .subscription("s"), productId: "com.example.s_AB3", name: "Synthetic s_AB3")
        let report = CloneReport(steps: [CloneStepReport(step: .product(item), outcome: .failed("HTTP 409"))], created: [:])
        let result = MCPRender.cloneResult(report, drafts: CloneDraftOutcome(), snapshot: snapshot())
        #expect(result["clones"] == [])
        #expect(result["drafts"] == [])
        #expect(result["note"]?.stringValue?.contains("No clone exists") == true)
        #expect(result["note"]?.stringValue?.contains("Nothing of the sources' prices") == false)
        #expect(result["not_copied"]?.arrayValue?.count == 1)
    }
}

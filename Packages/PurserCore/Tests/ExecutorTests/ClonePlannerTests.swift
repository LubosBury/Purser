import Foundation
import Testing
import Catalog
import Domain
import Executor
import PurserTestSupport

@Suite struct ClonePlannerTests {
    private func catalog(_ change: (inout SyntheticCatalog) -> Void = { _ in }) -> CatalogSnapshot {
        var catalog = SyntheticCatalog()
        catalog.addSubscription("s", prices: ["USA": Decimal(string: "29.99")!])
        catalog.addSubscription("t", prices: ["USA": Decimal(string: "9.99")!], period: .oneMonth)
        catalog.subscriptions["t"]?.groupId = "group-2"
        // A clone an earlier run created: same Product ID and reference name as the request below.
        catalog.addSubscription("s2", prices: [:], state: .missingMetadata, available: ["USA"])
        catalog.subscriptions["s2"]?.productId = "com.example.s_AB3"
        catalog.subscriptions["s2"]?.name = "Synthetic s_AB3"
        catalog.addIAP("life", base: "USA", manual: ["USA": Decimal(string: "49.99")!])
        change(&catalog)
        return catalog.snapshot()
    }

    private func request(_ items: [CloneItem], group: CloneGroupTarget = .sourceGroup, suffix: String = "_AB4",
                         copy: CloneCopy = CloneCopy()) -> CloneRequest {
        CloneRequest(items: items, group: group, level: .sameAsSource, copy: copy, offerCodeSuffix: suffix)
    }

    private func problems(_ request: CloneRequest) -> [String] { ClonePlanner.problems(request, snapshot: catalog()) }

    @Test func aValidRequestHasNoProblems() {
        #expect(problems(request([CloneItem(source: .subscription("s"), productId: "com.example.s_AB4", name: "Synthetic s_AB4"),
                                  CloneItem(source: .iap("life"), productId: "com.example.life_AB4", name: "Synthetic life_AB4")])).isEmpty)
    }

    @Test func aCloneOfAnEarlierRunWithTheSameNameIsResumed() {
        #expect(problems(request([CloneItem(source: .subscription("s"), productId: "com.example.s_AB3", name: "Synthetic s_AB3")],
                                 suffix: "_AB3")).isEmpty)
    }

    @Test func productIdsTheAppUsesAreRefused() {
        let cases: [(CloneItem, String)] = [
            (CloneItem(source: .subscription("s"), productId: "com.example.s", name: "Copy"), "must differ from its source"),
            (CloneItem(source: .subscription("s"), productId: "com.example.t", name: "Copy"), "already used by “Synthetic t”"),
            (CloneItem(source: .subscription("s"), productId: "com.example.s_AB3", name: "Other name"), "already used by “Synthetic s_AB3”"),
            (CloneItem(source: .iap("life"), productId: "com.example.s_AB3", name: "Synthetic s_AB3"), "already used by “Synthetic s_AB3”"),
            (CloneItem(source: .subscription("s"), productId: "bad id", name: "Copy"), "may contain only letters"),
        ]
        for (item, message) in cases {
            #expect(problems(request([item])).contains { $0.contains(message) }, "\(item)")
        }
    }

    @Test func aNewGroupMayNotTakeTheNameOfAGroupWithOtherSubscriptions() {
        // "Clones" holds only s2, the clone of s that an earlier run of the "_AB3" request made.
        let snapshot = catalog { catalog in
            catalog.addGroup("group-1", name: "Synthetic group")
            catalog.addGroup("group-3", name: "Clones")
            catalog.subscriptions["s2"]?.groupId = "group-3"
            catalog.subscriptions["s2"]?.groupName = "Clones"
        }
        func problems(_ productId: String, _ group: String, suffix: String) -> [String] {
            ClonePlanner.problems(request([CloneItem(source: .subscription("s"), productId: productId, name: "Synthetic s\(suffix)")],
                                         group: .newGroup(name: group), suffix: suffix), snapshot: snapshot)
        }
        #expect(problems("com.example.s_AB3", "Clones", suffix: "_AB3").isEmpty)
        #expect(problems("com.example.s_AB4", "Clones", suffix: "_AB4") == [
            "A group named “Clones” already exists with other subscriptions; choose a name no group has."])
        #expect(problems("com.example.s_AB4", " Synthetic group ", suffix: "_AB4").contains { $0.contains("“Synthetic group” already exists") })
        #expect(problems("com.example.s_AB4", "Fresh", suffix: "_AB4").isEmpty)
    }

    @Test func groupSuffixAndSourceRules() {
        let s = CloneItem(source: .subscription("s"), productId: "com.example.s_AB4", name: "S")
        let t = CloneItem(source: .subscription("t"), productId: "com.example.t_AB4", name: "T")
        #expect(problems(request([s, t], group: .newGroup(name: "B"))).contains { $0.contains("one group only") })
        #expect(problems(request([s], group: .newGroup(name: " "))).contains { $0.contains("group name") })
        #expect(problems(request([s], suffix: "")).contains { $0.contains("suffix") })
        #expect(problems(request([s], suffix: "-b")).contains { $0.contains("suffix") })
        #expect(!problems(request([s], suffix: "", copy: CloneCopy(promoOffers: false))).contains { $0.contains("suffix") })
        #expect(problems(request([])) == ["There is nothing to clone."])
        #expect(problems(request([CloneItem(source: .subscription("nope"), productId: "x_AB4", name: "X")])).contains { $0.contains("not in the catalog") })
        #expect(problems(request([CloneItem(source: .group("group-1"), productId: "g_AB4", name: "G")])).contains { $0.contains("cannot be cloned") })
    }

    @Test func aPromoCodeThatTheSuffixMakesTooLongIsRefusedBeforeAnythingIsWritten() {
        let long = String(repeating: "x", count: 62)        // 62 + "_AB4" = 66 characters, the advisor allows 64
        let snapshot = catalog { catalog in
            catalog.addPromo("s", code: "winback", prices: ["USA": Decimal(string: "14.99")!])
            catalog.addPromo("s", code: long, prices: ["USA": Decimal(string: "14.99")!])
        }
        let s = CloneItem(source: .subscription("s"), productId: "com.example.s_AB4", name: "S")
        let refused = ClonePlanner.problems(request([s]), snapshot: snapshot)
        #expect(refused == ["The code “\(long)” of a promotional offer of com.example.s would be too long or invalid with the suffix “_AB4”; use a shorter suffix or do not copy promotional offers."])
        // Said once however often the source is listed; a short suffix, or leaving the offers out, makes the request valid.
        #expect(ClonePlanner.problems(request([s, s]), snapshot: snapshot).filter { $0.contains(long) }.count == 1)
        #expect(ClonePlanner.problems(request([s], suffix: "_1"), snapshot: snapshot).isEmpty)
        #expect(ClonePlanner.problems(request([s], copy: CloneCopy(promoOffers: false)), snapshot: snapshot).isEmpty)
        // Offers of a subscription that is not cloned do not count.
        let t = CloneItem(source: .subscription("t"), productId: "com.example.t_AB4", name: "T")
        #expect(ClonePlanner.problems(request([t]), snapshot: snapshot).isEmpty)
    }
}

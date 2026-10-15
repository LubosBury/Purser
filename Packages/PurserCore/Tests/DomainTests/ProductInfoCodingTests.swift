import Foundation
import Testing
import Domain

@Suite struct ProductInfoCodingTests {
    @Test func infoStoredBeforeCloningDecodesWithoutTheNewFields() throws {
        let subscription = Data(#"{"ascId":"6500000001","productId":"fruit.yearly","name":"Fruit Yearly","period":"ONE_YEAR","state":"APPROVED","groupId":"7000000001","groupName":"Fruit Premium","availableTerritories":["USA"],"monthlyPlanAvailable":false}"#.utf8)
        let info = try JSONDecoder().decode(SubscriptionInfo.self, from: subscription)
        #expect(info.familySharable == nil)
        #expect(info.reviewNote == nil)
        #expect(info.groupLevel == nil)
        let iap = Data(#"{"ascId":"6600000001","productId":"fruit.lifetime","name":"Fruit Lifetime","iapType":"NON_CONSUMABLE","state":"APPROVED"}"#.utf8)
        let purchase = try JSONDecoder().decode(IAPInfo.self, from: iap)
        #expect(purchase.familySharable == nil)
        #expect(purchase.reviewNote == nil)
    }

    @Test func cloneAttributesSurviveARoundTrip() throws {
        let info = SubscriptionInfo(ascId: "6500000001", productId: "fruit.yearly", name: "Fruit Yearly", period: .oneYear, state: .approved,
                                    groupId: "7000000001", groupName: "Fruit Premium", availableTerritories: ["USA"], monthlyPlanAvailable: false,
                                    familySharable: true, reviewNote: "Synthetic note", groupLevel: 2)
        #expect(try JSONDecoder().decode(SubscriptionInfo.self, from: JSONEncoder().encode(info)) == info)
        let iap = IAPInfo(ascId: "6600000001", productId: "fruit.lifetime", name: "Fruit Lifetime", iapType: "NON_CONSUMABLE",
                          state: .approved, familySharable: false, reviewNote: "Synthetic note")
        #expect(try JSONDecoder().decode(IAPInfo.self, from: JSONEncoder().encode(iap)) == iap)
    }

    @Test func screenshotStatesTellWhatAClonesNeeds() {
        func shot(_ state: String?, template: String? = "https://is1-ssl.mzstatic.com/x/{w}x{h}bb.{f}") -> ReviewScreenshot {
            ReviewScreenshot(ascId: "shot-1", fileName: "a.png", fileSize: 70, templateURL: template, width: 1, height: 1, deliveryState: state)
        }
        #expect(shot("COMPLETE").isCommitted && shot("COMPLETE").isDownloadable)
        #expect(shot("UPLOAD_COMPLETE").isCommitted && !shot("UPLOAD_COMPLETE").isDownloadable)
        #expect(!shot("AWAITING_UPLOAD").isCommitted)
        #expect(!shot("FAILED").isCommitted)
        #expect(!shot(nil).isCommitted)
        #expect(!shot("COMPLETE", template: nil).isDownloadable)
    }
}

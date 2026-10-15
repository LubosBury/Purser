import CryptoKit
import Foundation
import Domain
import ASCClient

// Cloning (spec "Localizations and cloning" §6): groups, subscriptions, in-app purchases and their availability, the review
// screenshot cycle (reservation, upload on Apple's upload host, commit with the MD5) and the image CDN. Assumptions until
// spike SL10n (Q5, Q6) confirms them: a created product or group has version 1 in PREPARE_FOR_SUBMISSION without texts;
// a product holds one screenshot at most; the commit makes it COMPLETE at once.
extension FakeASC {
    public static let apiHost = "api.appstoreconnect.apple.com"
    public static let uploadHost = "upload.fake.apple.com"
    public static let imageHost = "is1-ssl.mzstatic.com"
    /// A 1 x 1 PNG (70 bytes): what the image CDN serves for every screenshot.
    public static let samplePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") ?? Data()

    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func imageTemplate(screenshotId: String) -> String {
        "https://\(imageHost)/image/thumb/fake/\(screenshotId)/{w}x{h}bb.{f}"
    }

    // MARK: Apple's upload and image hosts

    func assetExchange(_ record: inout FakeRequestRecord, url: URL, body: Data?) throws -> (Data, HTTPURLResponse) {
        switch takeFault(method: record.method, path: url.path) {
        case .networkBeforeSend?:
            log.append(record)
            throw URLError(.notConnectedToInternet)
        case let .serverError(status, _)?:
            return assetResponse(&record, url: url, status: status, data: Data(), applied: false)
        default:
            break
        }
        if record.method == "GET", record.host == Self.imageHost, url.path.hasPrefix("/image/thumb/fake/") {
            return assetResponse(&record, url: url, status: 200, data: Self.samplePNG, applied: false)
        }
        if record.method == "PUT", record.host == Self.uploadHost {
            let stored = uploadPart(path: url.path, body: body)
            return assetResponse(&record, url: url, status: stored ? 200 : 400, data: Data(), applied: stored)
        }
        return assetResponse(&record, url: url, status: 404, data: Data(), applied: false)
    }

    func assetResponse(_ record: inout FakeRequestRecord, url: URL, status: Int, data: Data, applied: Bool) -> (Data, HTTPURLResponse) {
        record.status = status
        record.applied = applied
        log.append(record)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    /// The parts of an upload: `uploadPartSize` bytes each, the last one shorter.
    func uploadParts(fileSize: Int) -> [(offset: Int, length: Int)] {
        let size = max(uploadPartSize, 1)
        return stride(from: 0, to: fileSize, by: size).map { (offset: $0, length: min(size, fileSize - $0)) }
    }

    /// PUT /screenshot/<id>/part-<n>: stores the bytes of one part of a reservation that awaits its upload.
    func uploadPart(path: String, body: Data?) -> Bool {
        let c = components(path)
        guard c.count == 3, c[0] == "screenshot", c[2].hasPrefix("part-"), let n = Int(c[2].dropFirst("part-".count)), let body,
              let index = model.screenshots.firstIndex(where: { $0.id == c[1] }),
              model.screenshots[index].state == "AWAITING_UPLOAD" else { return false }
        let parts = uploadParts(fileSize: model.screenshots[index].fileSize)
        guard n >= 1, n <= parts.count, body.count == parts[n - 1].length else { return false }
        let offset = parts[n - 1].offset
        model.screenshots[index].received.replaceSubrange(offset..<(offset + body.count), with: body)
        model.screenshots[index].receivedParts.insert(n)
        return true
    }

    // MARK: Resources

    func subscriptionResource(_ sub: FakeSubscription, level: Int) -> JSONBody {
        var attributes: [String: JSONBody] = [
            "name": .string(sub.name), "productId": .string(sub.productId), "state": .string(sub.state.rawValue),
            "subscriptionPeriod": .string(sub.period.rawValue), "groupLevel": .int(level), "familySharable": .bool(sub.familySharable),
        ]
        if let note = sub.reviewNote { attributes["reviewNote"] = .string(note) }
        return resource("subscriptions", sub.id, attributes: attributes)
    }

    func iapResource(_ iap: FakeIAP) -> JSONBody {
        var attributes: [String: JSONBody] = [
            "name": .string(iap.name), "productId": .string(iap.productId), "inAppPurchaseType": .string(iap.type),
            "state": .string(iap.state.rawValue), "familySharable": .bool(iap.familySharable),
        ]
        if let note = iap.reviewNote { attributes["reviewNote"] = .string(note) }
        return resource("inAppPurchases", iap.id, attributes: attributes)
    }

    func screenshotResource(_ shot: FakeScreenshot, withOperations: Bool) -> JSONBody {
        var attributes: [String: JSONBody] = [
            "fileName": .string(shot.fileName), "fileSize": .int(shot.fileSize),
            "sourceFileChecksum": shot.checksum.map(JSONBody.string) ?? .null,
            "assetDeliveryState": .object(["state": .string(shot.state), "errors": .array([]), "warnings": .array([])]),
            "imageAsset": .null, "uploadOperations": .null,
        ]
        if let template = shot.templateURL, let width = shot.width, let height = shot.height {
            attributes["imageAsset"] = .object(["templateUrl": .string(template), "width": .int(width), "height": .int(height)])
        }
        if withOperations {
            attributes["uploadOperations"] = .array(uploadParts(fileSize: shot.fileSize).enumerated().map { index, part in
                .object([
                    "method": .string("PUT"),
                    "url": .string("https://\(Self.uploadHost)/screenshot/\(shot.id)/part-\(index + 1)?token=synthetic-upload-token"),
                    "offset": .int(part.offset), "length": .int(part.length),
                    "requestHeaders": .array([.object(["name": .string("Content-Type"), "value": .string("image/png")])]),
                ])
            })
        }
        let type = shot.owner.kind == .iap ? "inAppPurchaseAppStoreReviewScreenshots" : "subscriptionAppStoreReviewScreenshots"
        return resource(type, shot.id, attributes: attributes)
    }

    // MARK: Reads

    func productAssetRead(_ c: [String], url: URL, query: [String: String]) throws -> FakeReply? {
        let ok = { (body: JSONBody) in FakeReply(status: 200, body: body, applied: false) }
        if let id = capture(c, ["v2", "inAppPurchases", "*", "inAppPurchaseAvailability"]) {
            guard model.iaps.first(where: { $0.id == id })?.availableTerritories != nil else { throw notFound() }
            return ok(single(resource("inAppPurchaseAvailabilities", "avail-\(id)",
                                      attributes: ["availableInNewTerritories": .bool(model.availabilityInNew[id] ?? false)]),
                             url: url.absoluteString))
        }
        if let id = capture(c, ["v1", "inAppPurchaseAvailabilities", "*", "availableTerritories"]) {
            let iapId = String(id.dropFirst("avail-".count))
            guard let territories = model.iaps.first(where: { $0.id == iapId })?.availableTerritories else { throw notFound() }
            return ok(page(territories.sorted().map { (territoryResource($0), [:]) }, url: url, query: query))
        }
        let screenshotReads: [([String], LocalizationOwnerKind)] = [
            (["v1", "subscriptions", "*", "appStoreReviewScreenshot"], .subscription),
            (["v2", "inAppPurchases", "*", "appStoreReviewScreenshot"], .iap),
        ]
        for (pattern, kind) in screenshotReads {
            guard let id = capture(c, pattern) else { continue }
            guard let shot = model.screenshots.first(where: { $0.owner == LocalizationOwner(kind, id) }) else {
                return ok(.object(["data": .null, "links": .object(["self": .string(url.absoluteString)])]))
            }
            return ok(single(screenshotResource(shot, withOperations: false), url: url.absoluteString))
        }
        return nil
    }

    // MARK: Writes

    func handleProductWrite(method: String, components c: [String], body: Data?) throws -> FakeReply? {
        switch method {
        case "POST":
            if capture(c, ["v1", "subscriptionGroups"]) != nil { return try postGroup(body) }
            if capture(c, ["v1", "subscriptions"]) != nil { return try postSubscription(body) }
            if capture(c, ["v2", "inAppPurchases"]) != nil { return try postInAppPurchase(body) }
            if capture(c, ["v1", "subscriptionAvailabilities"]) != nil { return try postAvailability(.subscription, body) }
            if capture(c, ["v1", "inAppPurchaseAvailabilities"]) != nil { return try postAvailability(.iap, body) }
            if capture(c, ["v1", "subscriptionAppStoreReviewScreenshots"]) != nil { return try postScreenshot(.subscription, body) }
            if capture(c, ["v1", "inAppPurchaseAppStoreReviewScreenshots"]) != nil { return try postScreenshot(.iap, body) }
        case "PATCH":
            for collection in ["subscriptionAppStoreReviewScreenshots", "inAppPurchaseAppStoreReviewScreenshots"] {
                if let id = capture(c, ["v1", collection, "*"]) { return try patchScreenshot(id, body) }
            }
        case "DELETE":
            for collection in ["subscriptionAppStoreReviewScreenshots", "inAppPurchaseAppStoreReviewScreenshots"] {
                if let id = capture(c, ["v1", collection, "*"]) { return try deleteScreenshot(id) }
            }
        default:
            break
        }
        return nil
    }

    func newProductId(_ value: Any?) throws -> String {
        guard let productId = value as? String, !productId.isEmpty else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.REQUIRED", "productId is required")
        }
        if model.subscriptions.contains(where: { $0.productId == productId }) || model.iaps.contains(where: { $0.productId == productId }) {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE", "The product ID \(productId) has already been used")
        }
        return productId
    }

    func postGroup(_ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        guard relId(data, "app") == model.app.id else { throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The app does not exist") }
        guard let name = attributes(data)["referenceName"] as? String, !name.isEmpty else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.REQUIRED", "referenceName is required")
        }
        let group = FakeGroup(id: nextId("grp"), name: name)
        model.groups.append(group)
        model.versions.append(FakeVersion(id: nextId("gver"), owner: .group(group.id), number: 1, state: .prepareForSubmission))
        return FakeReply(status: 201, body: single(resource("subscriptionGroups", group.id, attributes: ["referenceName": .string(name)])),
                         applied: true)
    }

    func postSubscription(_ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        let a = attributes(data)
        guard let groupId = relId(data, "group"), model.groups.contains(where: { $0.id == groupId }) else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The subscription group does not exist")
        }
        let productId = try newProductId(a["productId"])
        guard let name = a["name"] as? String, !name.isEmpty,
              let period = (a["subscriptionPeriod"] as? String).flatMap(SubscriptionPeriod.init(rawValue:)) else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "name and subscriptionPeriod are required")
        }
        let levels = model.subscriptions.filter { $0.groupId == groupId }.enumerated().map { $0.element.groupLevel ?? $0.offset + 1 }
        let sub = FakeSubscription(id: nextId("sub"), productId: productId, name: name, period: period, state: .missingMetadata,
                                   groupId: groupId, availableTerritories: [], familySharable: a["familySharable"] as? Bool ?? false,
                                   reviewNote: a["reviewNote"] as? String, groupLevel: a["groupLevel"] as? Int ?? ((levels.max() ?? 0) + 1))
        model.subscriptions.append(sub)
        for territory in model.territories.keys.sorted() {
            for i in 0..<40 { model.pricePoints.append(FakeSeed.point(product: sub.id, territory: territory, index: i, planType: .upfront)) }
        }
        model.versions.append(FakeVersion(id: nextId("sver"), owner: .subscription(sub.id), number: 1, state: .prepareForSubmission))
        return FakeReply(status: 201, body: single(subscriptionResource(sub, level: sub.groupLevel ?? 1)), applied: true)
    }

    func postInAppPurchase(_ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        let a = attributes(data)
        guard relId(data, "app") == model.app.id else { throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The app does not exist") }
        let productId = try newProductId(a["productId"])
        guard let name = a["name"] as? String, !name.isEmpty, let type = a["inAppPurchaseType"] as? String,
              ["CONSUMABLE", "NON_CONSUMABLE", "NON_RENEWING_SUBSCRIPTION"].contains(type) else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "name and inAppPurchaseType are required")
        }
        let iap = FakeIAP(id: nextId("iap"), productId: productId, name: name, type: type, state: .missingMetadata,
                          familySharable: a["familySharable"] as? Bool ?? false, reviewNote: a["reviewNote"] as? String)
        model.iaps.append(iap)
        for territory in model.territories.keys.sorted() {
            for i in 0..<60 { model.pricePoints.append(FakeSeed.point(product: iap.id, territory: territory, index: i, planType: nil)) }
        }
        model.versions.append(FakeVersion(id: nextId("iver"), owner: .iap(iap.id), number: 1, state: .prepareForSubmission))
        return FakeReply(status: 201, body: single(iapResource(iap)), applied: true)
    }

    func postAvailability(_ kind: LocalizationOwnerKind, _ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        guard let inNew = attributes(data)["availableInNewTerritories"] as? Bool else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.REQUIRED", "availableInNewTerritories is required")
        }
        let territories = Set(relIds(data, "availableTerritories").map { TerritoryCode($0) })
        guard territories.allSatisfy({ model.territories[$0] != nil }) else {
            throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "Unknown territory")
        }
        switch kind {
        case .subscription:
            guard let id = relId(data, "subscription"), let index = model.subscriptions.firstIndex(where: { $0.id == id }) else {
                throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The subscription does not exist")
            }
            guard model.availabilityInNew[id] == nil else { throw conflict("ENTITY_ERROR", "The subscription already has an availability") }
            model.subscriptions[index].availableTerritories = territories
            model.availabilityInNew[id] = inNew
            return FakeReply(status: 201, body: single(resource("subscriptionAvailabilities", "avail-\(id)",
                                                                attributes: ["availableInNewTerritories": .bool(inNew)])), applied: true)
        case .iap:
            guard let id = relId(data, "inAppPurchase"), let index = model.iaps.firstIndex(where: { $0.id == id }) else {
                throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The in-app purchase does not exist")
            }
            guard model.iaps[index].availableTerritories == nil else {
                throw conflict("ENTITY_ERROR", "The in-app purchase already has an availability")
            }
            model.iaps[index].availableTerritories = territories
            model.availabilityInNew[id] = inNew
            return FakeReply(status: 201, body: single(resource("inAppPurchaseAvailabilities", "avail-\(id)",
                                                                attributes: ["availableInNewTerritories": .bool(inNew)])), applied: true)
        case .group:
            throw notFound()
        }
    }

    func postScreenshot(_ kind: LocalizationOwnerKind, _ body: Data?) throws -> FakeReply {
        let (data, _) = try parse(body)
        let a = attributes(data)
        let productId: String?
        switch kind {
        case .subscription: productId = relId(data, "subscription").flatMap { id in model.subscriptions.contains { $0.id == id } ? id : nil }
        case .iap: productId = relId(data, "inAppPurchaseV2").flatMap { id in model.iaps.contains { $0.id == id } ? id : nil }
        case .group: productId = nil
        }
        guard let productId else { throw conflict("ENTITY_ERROR.RELATIONSHIP.INVALID", "The product does not exist") }
        guard let fileName = a["fileName"] as? String, !fileName.isEmpty, let fileSize = a["fileSize"] as? Int, fileSize > 0 else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "fileName and fileSize are required")
        }
        let owner = LocalizationOwner(kind, productId)
        guard !model.screenshots.contains(where: { $0.owner == owner }) else {
            throw conflict("ENTITY_ERROR", "The product already has an App Store review screenshot")
        }
        let shot = FakeScreenshot(id: nextId("shot"), owner: owner, fileName: fileName, fileSize: fileSize, state: "AWAITING_UPLOAD")
        model.screenshots.append(shot)
        return FakeReply(status: 201, body: single(screenshotResource(shot, withOperations: true)), applied: true)
    }

    func patchScreenshot(_ id: String, _ body: Data?) throws -> FakeReply {
        guard let index = model.screenshots.firstIndex(where: { $0.id == id }) else { throw notFound() }
        let (data, _) = try parse(body)
        let a = attributes(data)
        guard a["uploaded"] as? Bool == true, let checksum = a["sourceFileChecksum"] as? String else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "uploaded and sourceFileChecksum are required")
        }
        var shot = model.screenshots[index]
        guard shot.receivedParts.count == uploadParts(fileSize: shot.fileSize).count else {
            throw conflict("ENTITY_ERROR", "Not every upload operation was completed")
        }
        guard Self.md5(shot.received) == checksum else {
            throw conflict("ENTITY_ERROR.ATTRIBUTE.INVALID", "sourceFileChecksum does not match the uploaded file")
        }
        shot.checksum = checksum
        shot.state = "COMPLETE"
        shot.templateURL = Self.imageTemplate(screenshotId: id)
        shot.width = 1
        shot.height = 1
        model.screenshots[index] = shot
        return FakeReply(status: 200, body: single(screenshotResource(shot, withOperations: false)), applied: true)
    }

    func deleteScreenshot(_ id: String) throws -> FakeReply {
        guard let index = model.screenshots.firstIndex(where: { $0.id == id }) else { throw notFound() }
        model.screenshots.remove(at: index)
        return FakeReply(status: 204, body: nil, applied: true)
    }
}

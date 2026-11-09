import Foundation

/// Builds the `/m/v1/ad` request body (pure; unit tested).
enum AdRequestBuilder {
    static func build(appKey: String, placement: String, format: AdFormat, sizes: [String],
                      device: DeviceSnapshot, identity: ResolvedIdentity, sdkId: String,
                      consent: ConsentSnapshot, config: ConfigSnapshot,
                      userId: String?, custom: String?) -> AdRequest {
        var user: AdRequest.User?
        // The publisher user id/custom string only matter for rewarded SSV; never send them otherwise.
        if format == .rewarded, (userId?.isEmpty == false) || (custom?.isEmpty == false) {
            user = AdRequest.User(id: userId.map { String($0.prefix(256)) },
                                  custom: custom.map { String($0.prefix(256)) })
        }
        return AdRequest(
            appKey: appKey,
            placement: placement,
            format: format,
            sizes: sizes,
            device: .init(
                osv: device.osVersion,
                model: device.model,
                ifa: identity.ifa,
                ifaType: identity.ifaType,
                lmt: identity.lmt,
                sdkId: sdkId,
                lang: device.language,
                w: device.widthPx,
                h: device.heightPx,
                pxratio: (device.scale * 100).rounded() / 100,
                connection: device.connection,
                tzOffsetMin: device.tzOffsetMin
            ),
            app: .init(bundle: device.bundleId, version: device.appVersion, sdkVersion: Adfacten.sdkVersion),
            regs: .init(coppa: config.childDirected, gdpr: consent.gdprApplies, tcf: consent.tcString,
                        gpp: consent.gppString, usPrivacy: consent.usPrivacy),
            user: user,
            test: config.testMode
        )
    }
}

/// HTTP client for `POST /m/v1/ad`.
final class AdClient: Sendable {
    let session: URLSession
    let endpoint: URL

    static let requestTimeout: TimeInterval = 10

    init(session: URLSession, baseURL: URL) {
        self.session = session
        self.endpoint = baseURL.appendingPathComponent("m/v1/ad")
    }

    struct Fetched: Sendable {
        var payload: AdPayload
        var serverDate: Date?
    }

    func fetch(_ body: AdRequest, userAgent: String) async -> Result<Fetched, AdfactenError> {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("ios/\(Adfacten.sdkVersion)", forHTTPHeaderField: "X-Adfacten-SDK")
        do {
            req.httpBody = try AdRequest.encoder().encode(body)
        } catch {
            return .failure(AdfactenError(.invalidResponse, "could not encode the ad request"))
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await session.adfData(for: req)
        } catch let err as URLError where err.code == .timedOut {
            return .failure(AdfactenError(.network, "ad request timed out"))
        } catch {
            return .failure(AdfactenError(.network, "ad request failed: \(error.localizedDescription)"))
        }
        return Self.interpret(status: http.statusCode, data: data,
                              dateHeader: http.value(forHTTPHeaderField: "Date"))
    }

    static func interpret(status: Int, data: Data, dateHeader: String?) -> Result<Fetched, AdfactenError> {
        switch status {
        case 200:
            do {
                let env = try AdPayload.decoder().decode(AdEnvelope.self, from: data)
                return .success(Fetched(payload: env.ad, serverDate: Expiry.parseHTTPDate(dateHeader)))
            } catch {
                Log.error("could not decode ad response: \(error)")
                return .failure(AdfactenError(.invalidResponse, "invalid ad response"))
            }
        case 204:
            return .failure(AdfactenError(.noFill, "no fill"))
        case 400, 403:
            let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
            let code = body?.code ?? (status == 400 ? "invalid_request" : "forbidden")
            let message = body?.message ?? "request rejected (\(status))"
            if code == "coppa" {
                return .failure(AdfactenError(.childDirected, message, serverCode: code))
            }
            return .failure(AdfactenError(.serverRejected, message, serverCode: code))
        default:
            return .failure(AdfactenError(.network, "server error (HTTP \(status))"))
        }
    }
}

/// Checks that the payload is usable for the requested format and pre-parses VAST.
enum AdValidator {
    static func validate(_ p: AdPayload, requested: AdFormat) -> Result<VASTAd?, AdfactenError> {
        guard !p.id.isEmpty else { return .failure(AdfactenError(.invalidResponse, "ad has no id")) }
        guard p.format == requested else {
            return .failure(AdfactenError(.invalidResponse, "ad format \(p.format.rawValue) does not match \(requested.rawValue)"))
        }
        let allowed: Set<AdPayload.Kind>
        switch requested {
        case .banner: allowed = [.image, .html]
        case .native: allowed = [.native]
        case .interstitial, .rewarded, .appOpen: allowed = [.image, .html, .video]
        case .unknown: allowed = []
        }
        guard allowed.contains(p.kind) else {
            return .failure(AdfactenError(.invalidResponse, "kind \(p.kind.rawValue) not supported for \(requested.rawValue)"))
        }
        switch p.kind {
        case .unknown:
            return .failure(AdfactenError(.invalidResponse, "unknown creative kind"))
        case .image:
            guard p.image?.url ?? p.image?.fallback ?? p.image?.url2x != nil else {
                return .failure(AdfactenError(.invalidResponse, "image ad without an image url"))
            }
        case .html:
            guard let html = p.html, !html.isEmpty else {
                return .failure(AdfactenError(.invalidResponse, "html ad without markup"))
            }
        case .native:
            guard let n = p.native, (n.title?.isEmpty == false) || n.image?.url != nil else {
                return .failure(AdfactenError(.invalidResponse, "native ad without assets"))
            }
        case .video:
            guard let xml = p.vast, !xml.isEmpty else {
                return .failure(AdfactenError(.invalidResponse, "video ad without VAST"))
            }
            do {
                return .success(try VASTParser.parse(xml))
            } catch {
                return .failure(AdfactenError(.invalidResponse, "unusable VAST: \(error)"))
            }
        }
        return .success(nil)
    }
}

@_spi(GraineRTC) import GraineInApp
import Foundation

/*
 * THE DIRECT MINT — a call's credential from the telephony gateway itself,
 * with a grant the web route signed: the voice bar's lib/rtc-direct.ts, for
 * every call in this process (Android's RtcDirect.kt is the same).
 *
 * The web route (`/api/embed/rtc-session`) runs in Washington and the gateway
 * in Mumbai, so a mint from a phone in India crossed the ocean twice: 1.3 s
 * median on production, measured with calls placed the SDK's way, against
 * 0.19 s for the voice bar's direct mint — the whole tap-to-media path 1.8 s
 * against 0.67 s. No check moves off the server: the web route makes them all
 * when it signs a grant, and the call servers verify the signature and set
 * the call up next to the media servers
 * through the same function, credit gate and agent status included.
 *
 * A GRANT IS FOR ITS REQUEST, EXACTLY. The web route signs into it who the
 * customer is — the identity, the install, the memory choice, the time zone —
 * and the call's id, which the gateway hands the conversation as its
 * `graine_call_id` (Call History's link, and the context a ring Graine sent
 * left for it). So a grant is used only for the agent, the customer and the
 * call it was asked for: another customer's is let go — by the app's own
 * warm-ups alone, never by what a call or a ring asks, which may be older than
 * who the customer is — and another call's is never used: that call is minted
 * on the web route.
 *
 *   warm     the session arrived, the customer changed, the app came back: a
 *            grant for the agent's NEXT call, its id chosen now — only when
 *            none is usable for this customer or the one in hand is half spent
 *            (renewed for the same id), so the app coming back costs nothing
 *   take     the call the customer places takes that id (`takeCallId`), and
 *            its mint at the gateway carries exactly what a web-route mint
 *            would; once its mint is done, the next call's grant is fetched
 *   ring     a call Graine rang comes with its own id: a grant for exactly
 *            that id is asked for as it rings (`warm` with a body naming it),
 *            and again when who the customer is changes while it rings
 *   mint     a usable grant for exactly this call and a gateway that said
 *            yes: the credential from the gateway within 4 s, else the web
 *            route — whose answer's grant is kept for that call's own redials
 *
 * EVERYTHING HERE IS OPTIONAL. A direct mint answers a credential, a gate's
 * refusal of the call, or "the web route": no grant for this call, a lapsed
 * one, a gateway without the route, a refused or spent grant, a host that did
 * not answer. Each costs at most one short request, and the call is minted the
 * old way. A grant request the web route refuses holds the next one back for
 * the Retry-After it names (a 429), else a minute. Two direct requests in a
 * row that never answered, two grants refused in a row, or a gateway that
 * answers anything but yes, and the direct mint RESTS: ten minutes on the web
 * route, asking nobody anything, then the gateway is asked again. A process
 * lives for days on a phone; a gateway out of reach this morning is not one
 * for the rest of the week.
 *
 * TIME IS THE DEVICE'S WALL CLOCK, as in the voice bar: a grant's life and a
 * rest are counted from their start by it, so a phone that slept through a
 * grant's life sees it lapsed. The clock this object runs on only schedules.
 */

/// What the web route hands out as `direct`: the grant, when it lapses, and where to take it.
struct RtcDirectOffer: Equatable {
    var grant: String
    /// Epoch milliseconds, by the server's clock.
    var expiresAtMs: Double
    /// The grant's life in milliseconds, so a phone whose clock is wrong still knows when it lapses.
    var ttlMs: Double?
    /// The call servers' direct route, as the grant's offer names it.
    var url: URL

    /// The voice bar's isDirectOffer: anything malformed is no offer.
    static func parse(_ value: Any?) -> RtcDirectOffer? {
        guard let o = value as? [String: Any],
              let grant = o["grant"] as? String, grant.hasPrefix("v1."),
              let expires = DirectJSON.number(o["expires_at"]), expires.isFinite,
              let text = o["url"] as? String, text.lowercased().hasPrefix("https://"),
              let url = URL(string: text), url.host?.isEmpty == false else { return nil }
        var ttl: Double?
        if let raw = o["ttl_ms"] {
            guard let value = DirectJSON.number(raw), value.isFinite, value > 0 else { return nil }
            ttl = value
        }
        return RtcDirectOffer(grant: grant, expiresAtMs: expires, ttlMs: ttl, url: url)
    }
}

/**
 * A call's mint body, read back. The core writes it (RtcMintBody): the
 * publishable key, the session id, the variables, who the customer is and the
 * call's id. The grant requests and the direct mint are built from it, so the
 * core hands this module nothing new for them.
 */
struct RtcMintBodyParts {
    /// The publishable key and who the customer is: everything but the call's own.
    let identityFields: [String: Any]
    let publishableKey: String
    let sessionId: String?
    let variables: [String: Any]?
    /// The call's id: what its grant names, and what it is looked up by.
    let callId: String?

    /// The call's own fields. Everything else is who the customer is.
    static let callFields: Set<String> = ["session_id", "variables", "callId"]

    init?(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = (object["publishableKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        publishableKey = key
        sessionId = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        variables = object["variables"] as? [String: Any]
        callId = (object["callId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        identityFields = object.filter { !Self.callFields.contains($0.key) }
    }

    /// Changes exactly when who a grant is for changes: the key and every identity field.
    var identityKey: String {
        DirectJSON.text(identityFields) ?? publishableKey
    }

    /// The web route's grant-only request: the same key and customer, and the call the grant is to name.
    func grantOnlyBody(callId: String?) -> Data {
        var body = identityFields
        body["grant_only"] = true
        if let id = callId { body["callId"] = id }
        return DirectJSON.data(body)
    }

    /// The direct mint's body: the grant, this call's session id and its variables. Who the customer is, and the call's id, ride in the grant.
    func directBody(grant: String) -> Data {
        var body: [String: Any] = ["grant": grant]
        if let id = sessionId { body["session_id"] = id }
        if let variables = variables { body["variables"] = variables }
        return DirectJSON.data(body)
    }
}

/// What a direct mint came to.
enum RtcDirectAnswer: Equatable {
    /// The gateway answered as the web route would have: a credential, or a gate's refusal of the call.
    case minted(RtcMintOutcome)
    /// Mint on the web route — and why not here, for the log.
    case webRoute(String)
}

final class RtcDirectMint {
    /// One for the process: what it learns — the gateway's answer, each agent's grants — serves every call.
    /// Its queue is the tap's, as the engine's is: a direct mint is on the way to the call's first word.
    static let shared = RtcDirectMint(
        clock: DispatchRtcClock(queue: DispatchQueue(label: "ai.graine.calls.rtc.direct", qos: .userInitiated)),
        http: URLSessionRtcHTTP()
    )

    /// A direct mint answers in ~0.2 s from India; one that has not answered in four is not about to, and the web route is still there.
    static let timeout = 4.0
    /// A grant request crosses the ocean to the web route, in the background.
    static let refreshTimeout = 10.0
    /// A grant with less life left than this is not used: the gateway allows 30 s of clock disagreement.
    static let minLife = 30.0
    /// Direct requests in a row (the probe's or a mint's) that never answered before the direct mint rests.
    static let maxFailures = 2
    /// Grants refused in a row before it rests: the gateway and the web route disagree on the secret.
    static let maxRefusedGrants = 2
    /// How long a rest lasts: the web route alone, nothing asked of anyone, then the gateway asked again.
    static let restSeconds = 600.0
    /// Grants held at once: each agent's next call's, a ringing call's, and the calls in progress's own.
    static let maxHeld = 8
    /// How long grant requests wait after the web route refused one without saying for how long (Android's QUIET_MS).
    static let quietSeconds = 60.0

    /// A new id for a call this app places, as the core names them: `call_` and a lowercase UUID.
    static func freshCallId() -> String {
        "call_" + UUID().uuidString.lowercased()
    }

    /// The gateway's answer to "do you take grants?", per direct route. No entry: never asked, no answer, or ask again.
    enum Probe: Equatable {
        case probing
        case ready
    }

    /// What a grant was asked for — the agent (deployment and key), who the customer is, which call — and so what it serves.
    struct GrantKey: Hashable {
        let slot: String
        let identity: String
        let callId: String?
    }

    /// A grant in hand: when it lapses and when it is due for renewal, on the device's wall clock (seconds since 1970).
    private struct Held {
        let offer: RtcDirectOffer
        let lapsesAt: Double
        let renewAt: Double
        /// Arrival order, for letting the oldest go.
        let seq: Int

        func usable(at now: Double) -> Bool { now < lapsesAt - RtcDirectMint.minLife }
        /// Time to ask for the next: half spent, or within `minLife` of lapsing.
        func due(at now: Double) -> Bool { now >= renewAt || !usable(at: now) }
    }

    private let clock: RtcClock
    private let http: RtcHTTP
    private let wallNow: () -> Date
    private let newCallId: () -> String

    // Everything below is touched on the clock only.
    private var held: [GrantKey: Held] = [:]
    private var seq = 0
    /// Each agent's next call: what its grant was asked for, and so the id the next call placed with it takes.
    private var next: [String: GrantKey] = [:]
    /// Grants on their way: each agent's next call's (one at a time), and ringing calls'.
    private var askingNext: [String: GrantKey] = [:]
    private var askingCalls: Set<GrantKey> = []
    /// Agents whose web route signs no grants (it answered `direct: null`): not asked again until a mint brings one.
    private var unoffered: Set<String> = []
    /// No grant request for an agent before this (wall clock): the web route refused the last one.
    private var quietUntil: [String: Double] = [:]
    private var probes: [String: Probe] = [:]
    /// Every direct route an offer has named: what is asked again when a rest is over.
    private var routes: [String: URL] = [:]
    /// Mints waiting for a probe already on its way: nil for "ready", else why not.
    private var probeWaiters: [String: [(String?) -> Void]] = [:]
    private var failures = 0
    private var refusedGrants = 0
    /// While the direct mint rests: until when (wall clock), and why.
    private var restUntil: Double?
    private(set) var restReason: String?
    private var restTimer: RtcTimer?

    init(clock: RtcClock, http: RtcHTTP, wallNow: @escaping () -> Date = Date.init, newCallId: @escaping () -> String = RtcDirectMint.freshCallId) {
        self.clock = clock
        self.http = http
        self.wallNow = wallNow
        self.newCallId = newCallId
    }

    private var now: Double { wallNow().timeIntervalSince1970 }

    // MARK: - Ahead of a call

    /**
     * Ahead of a call. A body that names no call: a grant for the agent's
     * next call — asked for only when none is usable for this customer, or
     * the one in hand is past half its life or within 30 s of lapsing;
     * otherwise nothing at all is sent, however often the app comes back. A
     * body that names a call (one ringing): a grant for exactly that call,
     * unless one is in hand or on its way. The gateway is asked whether it
     * takes grants when a grant arrives (and again after an answer that never
     * came). `body` is a mint body (RtcMintBody). Any thread; nothing waits.
     */
    func warm(baseUrl: String, body: Data, log: ((String) -> Void)? = nil) {
        clock.run { [self] in
            guard let parts = RtcMintBodyParts(body) else { return }
            let slot = Self.slotKey(baseUrl, parts.publishableKey)
            if let callId = parts.callId {
                // A ringing call's: asked for under whoever its request names — perhaps nobody yet, an app a push
                // woke before its session said who the customer is — and forgetting nobody's.
                if restingNow() != nil { return }
                askFor(GrantKey(slot: slot, identity: parts.identityKey, callId: callId), baseUrl: baseUrl, parts: parts, log: log)
            } else {
                // The app's own warm-up (the session, identify, setMemory, the foreground): who the customer is now.
                // Only here do another customer's grants go.
                forgetOthers(slot, identity: parts.identityKey, log: log)
                // Resting: nobody is asked anything until the rest is over.
                if restingNow() != nil { return }
                warmNext(slot, baseUrl: baseUrl, parts: parts, log: log)
            }
        }
    }

    /**
     * The agent's next call's grant: renewed for the same id when it is due,
     * asked for under a new id when there is none. Also behind every call's
     * mint, where the request may be older than the customer — a call a push
     * prepared before the session said who they are — so it never forgets
     * anyone's grants (the caller has made sure it is not another customer's
     * next call it would renew).
     */
    private func warmNext(_ slot: String, baseUrl: String, parts: RtcMintBodyParts, log: ((String) -> Void)?) {
        let kept = next[slot]
        if let kept = kept, let h = held[kept], !h.due(at: now) {
            // A usable grant, not half spent: nothing for the web route; the gateway only if its answer never came.
            if probes[h.offer.url.absoluteString] == nil { probe(h.offer.url, log: log) }
            return
        }
        guard askingNext[slot] == nil, !unoffered.contains(slot), !quiet(slot) else { return }
        // Renewed, a grant keeps its call's id: it is for the same next call.
        let key = GrantKey(slot: slot, identity: parts.identityKey, callId: kept?.callId ?? newCallId())
        askingNext[slot] = key
        fetch(key, baseUrl: baseUrl, parts: parts, log: log)
    }

    /// A named call's grant — a ringing call's: asked for unless a usable one is in hand or on its way.
    private func askFor(_ key: GrantKey, baseUrl: String, parts: RtcMintBodyParts, log: ((String) -> Void)?) {
        if let h = held[key], h.usable(at: now) { return }
        guard !askingCalls.contains(key), !unoffered.contains(key.slot), !quiet(key.slot) else { return }
        askingCalls.insert(key)
        fetch(key, baseUrl: baseUrl, parts: parts, log: log)
    }

    /// The web route refused this agent's last grant request, and its wait is not over.
    private func quiet(_ slot: String) -> Bool {
        (quietUntil[slot] ?? 0) > now
    }

    /**
     * The id the call about to be placed takes: the one its agent's
     * next-call grant was asked for, while that grant is this customer's and
     * usable. Taken, the grant is that call's alone; the next call's is
     * fetched once this call's mint is done. Nil: the call takes an id of its
     * own and is minted on the web route, as before. Answers at once; any
     * thread but this object's clock.
     */
    func takeCallId(baseUrl: String, body: Data) -> String? {
        clock.sync { [self] in
            guard let parts = RtcMintBodyParts(body) else { return nil }
            let slot = Self.slotKey(baseUrl, parts.publishableKey)
            forgetOthers(slot, identity: parts.identityKey, log: nil)
            guard restingNow() == nil, let kept = next[slot], let h = held[kept], h.usable(at: now) else { return nil }
            next[slot] = nil
            return kept.callId
        }
    }

    // MARK: - A call's mint

    /// The call's credential from the gateway, or the web route. `done` runs on this object's clock. Any thread.
    func mint(baseUrl: String, body: Data, done: @escaping (RtcDirectAnswer) -> Void) {
        clock.run { [self] in attempt(baseUrl: baseUrl, body: body, done: done) }
    }

    private func attempt(baseUrl: String, body: Data, done: @escaping (RtcDirectAnswer) -> Void) {
        guard let parts = RtcMintBodyParts(body) else { return done(.webRoute("the mint's body names no publishable key")) }
        let slot = Self.slotKey(baseUrl, parts.publishableKey)
        // Whatever this call's mint comes to, the next call's grant follows it, under the same rules as a warm-up —
        // for this call's customer, unless the app has already moved on to another.
        let finish: (RtcDirectAnswer) -> Void = { [self] answer in
            done(answer)
            guard restingNow() == nil, next[slot].map({ $0.identity == parts.identityKey }) ?? true else { return }
            warmNext(slot, baseUrl: baseUrl, parts: parts, log: nil)
        }
        if let why = restingNow() { return finish(.webRoute("resting (\(why))")) }
        let key = GrantKey(slot: slot, identity: parts.identityKey, callId: parts.callId)
        // A grant asked for any other call, or any other customer, never carries this one.
        guard let h = held[key] else { return finish(.webRoute("no grant for this call")) }
        guard h.usable(at: now) else {
            held[key] = nil
            return finish(.webRoute("the grant in hand has lapsed"))
        }
        let offer = h.offer
        let route = offer.url.absoluteString
        switch probes[route] {
        case .ready?:
            break
        case .probing?:
            // A probe on its way is waited for, as in the voice bar: it opens the connection this mint rides.
            probeWaiters[route, default: []].append { [self] notReady in
                if let why = notReady { return finish(.webRoute(why)) }
                attempt(baseUrl: baseUrl, body: body, done: done)
            }
            return
        case nil:
            // Its answer never came: asked again now, behind this call, which does not wait for it.
            probe(offer.url, log: nil)
            return finish(.webRoute("the gateway has not said whether it takes grants"))
        }
        request(offer.url, json: parts.directBody(grant: offer.grant), timeout: Self.timeout) { [self] answer in
            answered(answer, key: key, offer: offer, done: finish)
        }
    }

    private func answered(_ answer: RtcHTTPAnswer, key: GrantKey, offer: RtcDirectOffer, done: (RtcDirectAnswer) -> Void) {
        let status: Int
        let data: Data?
        switch answer {
        case .failed(let why):
            let rests = failed(log: nil)
            return done(.webRoute("the gateway did not answer (\(why))\(rests ? " — the web route alone for \(Self.restMinutes) minutes" : "")"))
        case let .answered(code, body, _):
            status = code
            data = body
        }
        let outcome = URLSessionRtcMinting.outcome(status: status, data: data)
        guard case let .refused(_, code, _) = outcome else {
            failures = 0
            refusedGrants = 0
            return done(.minted(outcome))
        }
        let named = code.map { " \($0)" } ?? ""
        if status == 200 {
            return done(.webRoute("the gateway's answer was not a credential"))
        }
        if status == 402 || status == 409 || code.map({ GraineRtcRefusal.codes.contains($0) }) == true {
            // A gate said no to the call itself, exactly as the web route's mint would have: no second road.
            return done(.minted(outcome))
        }
        if code == "grant_invalid" || status == 401 || status == 403 {
            // Refused: let go, and the call minted on the web route, which hands out a grant that works.
            drop(offer, key: key)
            refusedGrants += 1
            if refusedGrants >= Self.maxRefusedGrants { rest("the gateway refused \(refusedGrants) grants in a row", log: nil) }
            return done(.webRoute("the gateway refused the grant (\(status)\(named))"))
        }
        if code == "grant_budget" || status == 429 {
            // Spent: one grant is not an unlimited supply of calls.
            drop(offer, key: key)
            return done(.webRoute("the grant is spent (\(status)\(named))"))
        }
        if status == 404 {
            // The grant names an agent the gateway does not have (a call twin that moved); the web route mints for the new one.
            drop(offer, key: key)
            return done(.webRoute("the gateway does not know the grant's agent (404)"))
        }
        done(.webRoute("the gateway answered \(status)\(named)"))
    }

    // MARK: - Grants

    /// A web-route mint's grant (its credential's `direct`): exactly that call's, for its own later mints — a redial's. Any thread.
    func accept(_ offer: RtcDirectOffer, baseUrl: String, body: Data) {
        clock.run { [self] in
            guard let parts = RtcMintBodyParts(body) else { return }
            let slot = Self.slotKey(baseUrl, parts.publishableKey)
            keep(offer, for: GrantKey(slot: slot, identity: parts.identityKey, callId: parts.callId), log: nil)
        }
    }

    private func keep(_ offer: RtcDirectOffer, for key: GrantKey, log: ((String) -> Void)?) {
        let now = self.now
        // Timed from its arrival, by this device: a phone set five minutes wrong would otherwise use a lapsed grant,
        // or never a good one. Only an offer without its life is read against the server's clock.
        let life = offer.ttlMs.map { $0 / 1000 } ?? max(0, offer.expiresAtMs / 1000 - now)
        seq += 1
        held[key] = Held(offer: offer, lapsesAt: now + life, renewAt: now + life / 2, seq: seq)
        unoffered.remove(key.slot)
        letGoOfOld(now: now)
        let route = offer.url.absoluteString
        routes[route] = offer.url
        if probes[route] == nil, restingNow() == nil { probe(offer.url, log: log) }
    }

    /// Lapsed grants go; past `maxHeld`, the oldest — never an agent's next call's.
    private func letGoOfOld(now: Double) {
        let nextKeys = Set(next.values)
        for (key, h) in held where !h.usable(at: now) && !nextKeys.contains(key) { held[key] = nil }
        while held.count > Self.maxHeld, let oldest = held.filter({ !nextKeys.contains($0.key) }).min(by: { $0.value.seq < $1.value.seq }) {
            held[oldest.key] = nil
        }
    }

    private func drop(_ offer: RtcDirectOffer, key: GrantKey) {
        if held[key]?.offer == offer { held[key] = nil }
    }

    /// Another customer's grants for this agent go — held, kept for the next call, or on their way.
    private func forgetOthers(_ slot: String, identity: String, log: ((String) -> Void)?) {
        let theirs = held.keys.filter { $0.slot == slot && $0.identity != identity }
        for key in theirs { held[key] = nil }
        if let kept = next[slot], kept.identity != identity { next[slot] = nil }
        if let asking = askingNext[slot], asking.identity != identity { askingNext[slot] = nil }
        askingCalls = askingCalls.filter { $0.slot != slot || $0.identity == identity }
        if !theirs.isEmpty { log?("direct mint: the customer changed — the grants asked for the one before are let go") }
    }

    /// The web route's grant-only mode, in the background, for exactly `key`.
    private func fetch(_ key: GrantKey, baseUrl: String, parts: RtcMintBodyParts, log: ((String) -> Void)?) {
        guard let url = Self.sessionURL(baseUrl) else {
            if askingNext[key.slot] == key { askingNext[key.slot] = nil }
            askingCalls.remove(key)
            return
        }
        request(url, json: parts.grantOnlyBody(callId: key.callId), timeout: Self.refreshTimeout) { [self] answer in
            fetched(answer, key: key, log: log)
        }
    }

    private func fetched(_ answer: RtcHTTPAnswer, key: GrantKey, log: ((String) -> Void)?) {
        // Still wanted? A request made for another customer while it was on its way is nobody's now.
        let forNext = askingNext[key.slot] == key
        if forNext { askingNext[key.slot] = nil }
        let forCall = askingCalls.remove(key) != nil
        guard forNext || forCall else { return }
        switch answer {
        case .answered(200, let data, _):
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            if let offer = RtcDirectOffer.parse(object?["direct"]) {
                keep(offer, for: key, log: log)
                if forNext { next[key.slot] = key }
                log?(forNext ? "direct mint: a grant for the next call" : "direct mint: a grant for the ringing call")
            } else if object?["direct"] is NSNull {
                unoffered.insert(key.slot)
                log?("direct mint: the web route signs no grants for this agent — its route only")
            } else {
                log?("direct mint: the grant-only answer carried no grant")
            }
        case let .answered(status, _, retryAfter):
            // A WARM-UP NEVER BECOMES LOAD. The web route's limits are every device's on this key, real mints among
            // them: refused (a 429, a setting such as an agent without app://), grants are not asked for again for a
            // while — the Retry-After a 429 names, else a minute.
            let wait = (status == 429 ? retryAfter : nil) ?? Self.quietSeconds
            quietUntil[key.slot] = now + wait
            log?("direct mint: no grant (the web route answered \(status)) — none asked for again for \(Int(wait)) s")
        case .failed(let why):
            log?("direct mint: no grant (\(why))")
        }
    }

    // MARK: - The gateway

    /**
     * Is the gateway's direct route there? Asked before any grant is taken to
     * it: the gateway and the web route deploy separately, in either order.
     * Yes is kept until a rest; any other answer rests the direct mint; no
     * answer at all is asked again by the next warm-up or tap — and counts
     * toward the two that rest it.
     */
    private func probe(_ url: URL, log: ((String) -> Void)?) {
        let route = url.absoluteString
        guard probes[route] == nil, restingNow() == nil else { return }
        probes[route] = .probing
        request(url, json: nil, timeout: Self.timeout) { [self] answer in
            var notReady: String?
            switch answer {
            case let .answered(status, data, _):
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                if status == 200, DirectJSON.isTrue(object?["direct"]) {
                    // Yes — kept before the rest is looked at, so a rest ending now does not ask this route twice.
                    probes[route] = .ready
                    if let why = restingNow() {
                        probes[route] = nil
                        notReady = "resting (\(why))"
                    } else {
                        failures = 0
                        log?("direct mint: the gateway takes grants")
                    }
                } else {
                    // Not here (yet): the web route alone for a while, then asked again.
                    probes[route] = nil
                    notReady = "the gateway takes no grants (\(status))"
                    rest("the gateway takes no grants (\(status))", log: log)
                }
            case .failed(let why):
                probes[route] = nil
                notReady = "the gateway did not answer (\(why))"
                log?("direct mint: the gateway did not answer (\(why))")
                failed(log: log)
            }
            for wake in probeWaiters.removeValue(forKey: route) ?? [] { wake(notReady) }
        }
    }

    /// A direct request that never answered. Whether the direct mint rests because of it.
    @discardableResult
    private func failed(log: ((String) -> Void)?) -> Bool {
        failures += 1
        guard failures >= Self.maxFailures else { return false }
        rest("\(failures) direct requests in a row never answered", log: log)
        return true
    }

    // MARK: - Resting

    static var restMinutes: Int { Int(restSeconds / 60) }

    /**
     * The web route alone for `restSeconds`: no direct mint, no probe, no
     * grant asked for. Then every route seen is asked again, with the
     * failures forgotten. The grants in hand are kept — still good after the
     * rest if their life allows.
     */
    private func rest(_ why: String, log: ((String) -> Void)?) {
        guard restingNow() == nil else { return }
        let until = now + Self.restSeconds
        restUntil = until
        restReason = why
        failures = 0
        refusedGrants = 0
        // Every answer is asked for again afterwards; a probe on its way finishes on its own.
        probes = probes.filter { $0.value == .probing }
        restTimer = clock.after(Self.restSeconds) { [weak self] in
            guard let self = self, self.restUntil == until else { return }
            self.resume()
        }
        log?("direct mint: \(why) — the web route alone for \(Self.restMinutes) minutes, then the gateway asked again")
    }

    /// Why the direct mint rests, while it does. A rest the wall clock says is over (a phone that slept through it) ends here.
    private func restingNow() -> String? {
        guard let until = restUntil else { return nil }
        if now < until { return restReason }
        resume()
        return nil
    }

    /// The rest is over: the gateway is asked again on every route seen.
    private func resume() {
        guard restUntil != nil else { return }
        restUntil = nil
        restReason = nil
        restTimer?.cancel()
        restTimer = nil
        for url in routes.values where probes[url.absoluteString] == nil { probe(url, log: nil) }
    }

    /// One request with a deadline of its own: an answer after it is no answer. `done` runs on the clock.
    private func request(_ url: URL, json: Data?, timeout: Double, done: @escaping (RtcHTTPAnswer) -> Void) {
        var settled = false
        let deadline = clock.after(timeout) {
            guard !settled else { return }
            settled = true
            done(.failed("timed out after \(Int(timeout)) s"))
        }
        http.send(url, json: json, timeout: timeout) { [weak self] answer in
            self?.clock.run {
                guard !settled else { return }
                settled = true
                deadline.cancel()
                done(answer)
            }
        }
    }

    // MARK: - Addresses

    private static func base(_ baseUrl: String) -> String {
        var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// One agent: the deployment and the publishable key.
    static func slotKey(_ baseUrl: String, _ publishableKey: String) -> String {
        base(baseUrl) + " " + publishableKey
    }

    /// The web route, where grants come from.
    static func sessionURL(_ baseUrl: String) -> URL? {
        URL(string: base(baseUrl) + "/api/embed/rtc-session")
    }

    // MARK: - Tests (their clock runs inline)

    /// The agent's next call's id and grant, whoever it is for.
    func nextGrant(baseUrl: String, publishableKey: String) -> (callId: String?, grant: String)? {
        guard let key = next[Self.slotKey(baseUrl, publishableKey)], let h = held[key] else { return nil }
        return (key.callId, h.offer.grant)
    }

    /// The grant held for a call of this agent — for whoever, or for exactly `identity` (`RtcMintBodyParts.identityKey`).
    func grant(baseUrl: String, publishableKey: String, callId: String?, identity: String? = nil) -> String? {
        let slot = Self.slotKey(baseUrl, publishableKey)
        return held.first { $0.key.slot == slot && $0.key.callId == callId && (identity == nil || $0.key.identity == identity) }?.value.offer.grant
    }

    func probeState(_ url: URL) -> Probe? {
        probes[url.absoluteString]
    }
}

// MARK: - The network

/// One exchange with a host: its status, body and `Retry-After` (seconds), or why there was none.
enum RtcHTTPAnswer {
    case answered(status: Int, data: Data?, retryAfter: Double? = nil)
    case failed(String)
}

protocol RtcHTTP: AnyObject {
    /// A GET when `json` is nil, else a POST of it. `done` may run on any thread.
    func send(_ url: URL, json: Data?, timeout: Double, done: @escaping (RtcHTTPAnswer) -> Void)
}

/// One session for every request here: the probe's connection to the gateway is the one the first direct mint rides.
final class URLSessionRtcHTTP: RtcHTTP {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = RtcDirectMint.refreshTimeout
        configuration.timeoutIntervalForResource = RtcDirectMint.refreshTimeout + 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func send(_ url: URL, json: Data?, timeout: Double, done: @escaping (RtcHTTPAnswer) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let json = json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        } else {
            request.httpMethod = "GET"
        }
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                done(.failed(error.localizedDescription))
                return
            }
            let http = response as? HTTPURLResponse
            done(.answered(status: http?.statusCode ?? 0, data: data, retryAfter: Self.retryAfter(http)))
        }.resume()
    }

    /// `Retry-After` in seconds — the form the web route sends; nil without one, or in the date form.
    static func retryAfter(_ response: HTTPURLResponse?) -> Double? {
        guard let text = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(text), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

/// JSON as JSONSerialization reads it, where its NSNumbers blur booleans and numbers.
enum DirectJSON {
    /// A number, never a boolean.
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// `true` itself, not something that converts to it.
    static func isTrue(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }

    /// Keys sorted, so the same object always reads the same.
    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func text(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}

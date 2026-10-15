import Foundation
import Testing
@testable import GraineInAppRTC

/*
 * THE SIP THE SBC SEES, BYTE FOR BYTE — the voice bar's own messages, from a
 * recorded production trace (inapp-wt/rtc-shared/TRACE.md), with the realm and
 * the addresses replaced by documentation ones. Then the parser, fed what a
 * server sends and what it should never send.
 */

private let identity = SipIdentity(
    username: "web-XXXX",
    realm: "sbc.example.test",
    password: "pw",
    viaHost: "cdh6l13lka9h.invalid",
    contactUser: "e7q9tikf",
    instanceId: "c30c2118-f5c4-4dd6-898c-3d8485be8150",
    userAgent: "jambonz-webrtc-0.1.4 graine-inapp-ios/0.7.0"
)

private func lines(_ text: String) -> [String] { text.components(separatedBy: "\r\n") }

@Suite struct SipWriterGoldenTests {
    @Test func registerIsTheVoiceBars() {
        let request = SipWriter.register(identity: identity, callId: "5jl5ol93rs8bq7uj2ivsf1", cseq: 1, fromTag: "4kj2mue2i7", branch: "z9hG4bK7801448", expires: 300)
        #expect(request.text == [
            "REGISTER sip:sbc.example.test SIP/2.0",
            "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK7801448",
            "Max-Forwards: 69",
            "To: <sip:web-XXXX@sbc.example.test>",
            "From: <sip:web-XXXX@sbc.example.test>;tag=4kj2mue2i7",
            "Call-ID: 5jl5ol93rs8bq7uj2ivsf1",
            "CSeq: 1 REGISTER",
            "Expires: 300",
            "Contact: <sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws>;+sip.ice;reg-id=1;+sip.instance=\"<urn:uuid:c30c2118-f5c4-4dd6-898c-3d8485be8150>\";expires=300",
            "Allow: INVITE,ACK,CANCEL,BYE,UPDATE,MESSAGE,OPTIONS,REFER,INFO,NOTIFY,SUBSCRIBE",
            "Supported: path,gruu,outbound",
            "User-Agent: jambonz-webrtc-0.1.4 graine-inapp-ios/0.7.0",
            "Content-Length: 0",
            "", "",
        ].joined(separator: "\r\n"))
    }

    @Test func theCredentialsGoAfterCSeqAndBeforeTheCallersHeaders() {
        var request = SipWriter.register(identity: identity, callId: "c", cseq: 1, fromTag: "f", branch: "z9hG4bK1", expires: 300)
        request.set("CSeq", "2 REGISTER")
        request.set("Via", "SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK7956117")
        request.set("Authorization", "Digest algorithm=MD5, username=\"web-XXXX\"")
        let text = lines(request.text)
        #expect(text[1] == "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK7956117", "the Via keeps its place")
        #expect(text[6] == "CSeq: 2 REGISTER")
        #expect(text[7] == "Authorization: Digest algorithm=MD5, username=\"web-XXXX\"")
        #expect(text[8] == "Expires: 300")
    }

    @Test func unRegisterWritesContactThenExpires() {
        let text = lines(SipWriter.register(identity: identity, callId: "5jl5ol93rs8bq7uj2ivsf1", cseq: 3, fromTag: "i0st9kgb1j", branch: "z9hG4bK5354503", expires: 0).text)
        #expect(text[7] == "Contact: <sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws>;+sip.ice;reg-id=1;+sip.instance=\"<urn:uuid:c30c2118-f5c4-4dd6-898c-3d8485be8150>\";expires=0")
        #expect(text[8] == "Expires: 0")
        #expect(text[6] == "CSeq: 3 REGISTER")
    }

    @Test func inviteCarriesTheThreeHeadersInTheBarsOrder() {
        let target = "sip:app-817361cd-2a13-4937-b465-686d3f58eddd@sbc.example.test"
        let request = SipWriter.invite(
            identity: identity, target: target, callId: "8bfb0ntka5aua320artv", cseq: 367, fromTag: "qdq9n426ik",
            branch: "z9hG4bK8311767",
            headers: ["X-Graine-Session-Id: 0123456789abcdef0123456789abcdef", "X-Graine-Agent-Id: agent-1", "X-Application-Sid: 817361cd-2a13-4937-b465-686d3f58eddd"],
            sdp: "v=0\r\n"
        )
        #expect(request.text == [
            "INVITE \(target) SIP/2.0",
            "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK8311767",
            "Max-Forwards: 69",
            "To: <\(target)>",
            "From: <sip:web-XXXX@sbc.example.test>;tag=qdq9n426ik",
            "Call-ID: 8bfb0ntka5aua320artv",
            "CSeq: 367 INVITE",
            "X-Graine-Session-Id: 0123456789abcdef0123456789abcdef",
            "X-Graine-Agent-Id: agent-1",
            "X-Application-Sid: 817361cd-2a13-4937-b465-686d3f58eddd",
            "Contact: <sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws;ob>",
            "Content-Type: application/sdp",
            "Session-Expires: 90",
            "Allow: INVITE,ACK,CANCEL,BYE,UPDATE,MESSAGE,OPTIONS,REFER,INFO,NOTIFY,SUBSCRIBE",
            "Supported: timer,ice,replaces,outbound",
            "User-Agent: jambonz-webrtc-0.1.4 graine-inapp-ios/0.7.0",
            "Content-Length: 5",
            "",
            "v=0",
            "",
        ].joined(separator: "\r\n"))
    }

    @Test func theAckForAChallengeKeepsTheInvitesBranchAndTakesTheAnswersTo() throws {
        let target = "sip:app-1@sbc.example.test"
        let invite = SipWriter.invite(identity: identity, target: target, callId: "cid", cseq: 367, fromTag: "qdq9n426ik", branch: "z9hG4bK8311767", headers: [], sdp: "v=0\r\n")
        let ack = SipWriter.ackFailure(invite: invite, responseTo: "<\(target)>;tag=aSBtgypQaZ95a")
        #expect(ack.text == [
            "ACK \(target) SIP/2.0",
            "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK8311767",
            "Max-Forwards: 69",
            "To: <\(target)>;tag=aSBtgypQaZ95a",
            "From: <sip:web-XXXX@sbc.example.test>;tag=qdq9n426ik",
            "Call-ID: cid",
            "CSeq: 367 ACK",
            "Allow: INVITE,ACK,CANCEL,BYE,UPDATE,MESSAGE,OPTIONS,REFER,INFO,NOTIFY,SUBSCRIBE",
            "Supported: outbound",
            "User-Agent: jambonz-webrtc-0.1.4 graine-inapp-ios/0.7.0",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
    }

    private var dialog: SipDialog {
        SipDialog(
            callId: "8bfb0ntka5aua320artv", localTag: "qdq9n426ik", remoteTag: "cByBmmry4gpBj",
            localUri: identity.aor, remoteUri: "sip:app-1@sbc.example.test",
            remoteTarget: "sip:198.51.100.7:5060;transport=tcp", routeSet: [], localSeq: 368, inviteSeq: 368
        )
    }

    @Test func inDialogRequestsGoToTheContactWithNoRoute() {
        let ack = SipWriter.inDialog(method: "ACK", dialog: dialog, identity: identity, branch: "z9hG4bK9229009", cseq: 368)
        #expect(ack.text == [
            "ACK sip:198.51.100.7:5060;transport=tcp SIP/2.0",
            "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK9229009",
            "Max-Forwards: 69",
            "To: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj",
            "From: <sip:web-XXXX@sbc.example.test>;tag=qdq9n426ik",
            "Call-ID: 8bfb0ntka5aua320artv",
            "CSeq: 368 ACK",
            "Allow: INVITE,ACK,CANCEL,BYE,UPDATE,MESSAGE,OPTIONS,REFER,INFO,NOTIFY,SUBSCRIBE",
            "Supported: outbound",
            "User-Agent: jambonz-webrtc-0.1.4 graine-inapp-ios/0.7.0",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
        let bye = lines(SipWriter.inDialog(method: "BYE", dialog: dialog, identity: identity, branch: "z9hG4bK2423643", cseq: 369).text)
        #expect(bye[0] == "BYE sip:198.51.100.7:5060;transport=tcp SIP/2.0")
        #expect(bye[6] == "CSeq: 369 BYE")
        #expect(!bye.contains { $0.hasPrefix("Route:") })
    }

    @Test func theRefreshIsAnUpdateWithNoBody() {
        let update = SipWriter.inDialog(
            method: "UPDATE", dialog: dialog, identity: identity, branch: "z9hG4bK2457755", cseq: 9691,
            extra: ["Contact: \(identity.dialogContact)", "Session-Expires: 90;refresher=uac"]
        )
        #expect(update.text == [
            "UPDATE sip:198.51.100.7:5060;transport=tcp SIP/2.0",
            "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK2457755",
            "Max-Forwards: 69",
            "To: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj",
            "From: <sip:web-XXXX@sbc.example.test>;tag=qdq9n426ik",
            "Call-ID: 8bfb0ntka5aua320artv",
            "CSeq: 9691 UPDATE",
            "Contact: <sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws;ob>",
            "Session-Expires: 90;refresher=uac",
            "Allow: INVITE,ACK,CANCEL,BYE,UPDATE,MESSAGE,OPTIONS,REFER,INFO,NOTIFY,SUBSCRIBE",
            "Supported: timer,ice,outbound",
            "User-Agent: jambonz-webrtc-0.1.4 graine-inapp-ios/0.7.0",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
    }

    @Test func aRecordRouteBecomesTheRouteSetReversed() {
        var d = dialog
        d.routeSet = ["<sip:b.example.test;lr>", "<sip:a.example.test;lr>"]
        let text = lines(SipWriter.inDialog(method: "BYE", dialog: d, identity: identity, branch: "z9hG4bK1", cseq: 369).text)
        #expect(text[1] == "Route: <sip:b.example.test;lr>")
        #expect(text[2] == "Route: <sip:a.example.test;lr>")
        #expect(text[3].hasPrefix("Via: "))
    }

    @Test func cancelKeepsTheInvitesBranchAndHasNoToTag() {
        let invite = SipWriter.invite(identity: identity, target: "sip:app-1@sbc.example.test", callId: "cid", cseq: 9689, fromTag: "f1", branch: "z9hG4bK42", headers: [], sdp: "v=0\r\n")
        let text = lines(SipWriter.cancel(invite: invite).text)
        #expect(text[0] == "CANCEL sip:app-1@sbc.example.test SIP/2.0")
        #expect(text[1] == "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK42")
        #expect(text[3] == "To: <sip:app-1@sbc.example.test>")
        #expect(text[6] == "CSeq: 9689 CANCEL")
    }

    @Test func answersCopyTheRequestAndTagTheTo() throws {
        let options = try #require(SipParser.parse([
            "OPTIONS sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws SIP/2.0",
            "Via: SIP/2.0/WSS 198.51.100.7:8443;branch=z9hG4bKsrv1",
            "Via: SIP/2.0/TCP 198.51.100.8:5060;branch=z9hG4bKsrv0",
            "From: <sip:sbc@sbc.example.test>;tag=s1",
            "To: <sip:web-XXXX@sbc.example.test>",
            "Call-ID: opt1",
            "CSeq: 7 OPTIONS",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n")))
        let reply = SipWriter.response(to: options, code: 200, newTag: { "ourtag" })
        #expect(reply == [
            "SIP/2.0 200 OK",
            "Via: SIP/2.0/WSS 198.51.100.7:8443;branch=z9hG4bKsrv1",
            "Via: SIP/2.0/TCP 198.51.100.8:5060;branch=z9hG4bKsrv0",
            "To: <sip:web-XXXX@sbc.example.test>;tag=ourtag",
            "From: <sip:sbc@sbc.example.test>;tag=s1",
            "Call-ID: opt1",
            "CSeq: 7 OPTIONS",
            "Allow: INVITE,ACK,CANCEL,BYE,UPDATE,MESSAGE,OPTIONS,REFER,INFO,NOTIFY,SUBSCRIBE",
            "Accept: application/sdp, application/dtmf-relay",
            "Supported: outbound",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
        let notAllowed = SipWriter.response(to: options, code: 405, newTag: { "t" })
        #expect(notAllowed.contains("SIP/2.0 405 Method Not Allowed\r\n"))
    }

    @Test func anAnsweredReInviteCarriesItsSdpAndContact() throws {
        let reinvite = try #require(SipParser.parse([
            "INVITE sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws SIP/2.0",
            "Via: SIP/2.0/WSS 198.51.100.7:8443;branch=z9hG4bKre1",
            "Record-Route: <sip:198.51.100.7;lr>",
            "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj",
            "To: <sip:web-XXXX@sbc.example.test>;tag=qdq9n426ik",
            "Call-ID: 8bfb0ntka5aua320artv",
            "CSeq: 2 INVITE",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n")))
        let reply = lines(SipWriter.response(to: reinvite, code: 200, extra: ["Contact: \(identity.dialogContact)", "Session-Expires: 90;refresher=uas"], body: "v=0\r\n", newTag: { "x" }))
        #expect(reply[1] == "Record-Route: <sip:198.51.100.7;lr>")
        #expect(reply[3] == "To: <sip:web-XXXX@sbc.example.test>;tag=qdq9n426ik", "the dialog's tag, not a new one")
        #expect(reply.contains("Contact: <sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws;ob>"))
        #expect(reply.contains("Supported: timer,ice,replaces,outbound"))
        #expect(reply.contains("Content-Type: application/sdp"))
        #expect(reply.contains("Content-Length: 5"))
    }

    @Test func theUserAgentNamesTheSdk() {
        #expect(SipShape.userAgent(sdkVersion: "0.7.0") == "jambonz-webrtc-0.1.4 graine-inapp-ios/0.7.0")
    }
}

@Suite struct SipParserTests {
    /// The SBC's 200 OK to the authorised INVITE, from the trace (addresses documentation ones).
    static let ok200 = [
        "SIP/2.0 200 OK",
        "Via: SIP/2.0/WSS cdh6l13lka9h.invalid;branch=z9hG4bK7810508;received=192.0.2.1;rport=65005",
        "From: <sip:web-XXXX@sbc.example.test>;tag=qdq9n426ik",
        "To: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj",
        "Call-ID: 8bfb0ntka5aua320artv",
        "CSeq: 368 INVITE",
        "Contact: <sip:198.51.100.7:5060;transport=tcp>",
        "Content-Type: application/sdp",
        "Content-Length: 4",
        "X-Trace-ID: 1c9f7360d77b48c102207393e121ea68",
        "X-Call-Sid: 208fd2fd-4b9c-4732-bc61-5ab3819b1c21",
        "",
        "v=0\n",
    ].joined(separator: "\r\n")

    @Test func readsTheSbcsAnswer() throws {
        let m = try #require(SipParser.parse(Self.ok200))
        #expect(m.statusCode == 200)
        #expect(m.callId == "8bfb0ntka5aua320artv")
        #expect(m.cseq?.number == 368)
        #expect(m.cseq?.method == "INVITE")
        #expect(m.toTag == "cByBmmry4gpBj")
        #expect(m.fromTag == "qdq9n426ik")
        #expect(m.topViaBranch == "z9hG4bK7810508")
        #expect(SipNameAddr.parse(m.header("Contact")!)?.uri == "sip:198.51.100.7:5060;transport=tcp")
        #expect(m.header("x-call-sid") == "208fd2fd-4b9c-4732-bc61-5ab3819b1c21", "header names in any case")
        #expect(m.body == "v=0\n", "exactly Content-Length bytes")
        #expect(m.hasSdp)
        #expect(m.sessionExpires == nil)
    }

    @Test func readsAChallengeAndTheBareTrying() throws {
        let challenge = try #require(SipParser.parse([
            "SIP/2.0 401 Unauthorized",
            "Via: SIP/2.0/WSS h.invalid;branch=z9hG4bK1;received=192.0.2.1;rport=65005",
            "From: <sip:web-XXXX@sbc.example.test>;tag=f",
            "To: <sip:web-XXXX@sbc.example.test>;tag=7XZFBD4cK46Dr",
            "Call-ID: c", "CSeq: 1 REGISTER",
            "WWW-Authenticate: Digest realm=\"sbc.example.test\", algorithm=MD5, qop=\"auth\", nonce=\"n1\"",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n")))
        #expect(challenge.statusCode == 401)
        let parsed = try #require(SipChallenge.parse(challenge.header("WWW-Authenticate")!))
        #expect(parsed == SipChallenge(realm: "sbc.example.test", nonce: "n1", opaque: nil, algorithm: "MD5", qop: ["auth"], stale: false))
        let trying = try #require(SipParser.parse("SIP/2.0 100 Trying\r\nVia: SIP/2.0/WSS h.invalid;branch=z9hG4bK1\r\nFrom: <sip:a@b>;tag=1\r\nTo: <sip:c@d>\r\nCall-ID: c\r\nCSeq: 5 INVITE\r\nContent-Length: 0\r\n\r\n"))
        #expect(trying.statusCode == 100)
        #expect(trying.toTag == nil)
    }

    @Test func foldedLinesCompactNamesAndListedValues() throws {
        let m = try #require(SipParser.parse([
            "BYE sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws SIP/2.0",
            "v: SIP/2.0/WSS 198.51.100.7:8443;branch=z9hG4bKa, SIP/2.0/TCP 198.51.100.8;branch=z9hG4bKb",
            "Record-Route: <sip:p1.example.test;lr>,<sip:p2.example.test;lr>",
            "f: \"The, Agent\" <sip:app-1@sbc.example.test>",
            "  ;tag=remote1",
            "t: <sip:web-XXXX@sbc.example.test>;tag=local1",
            "i: call-1",
            "CSeq: 9 BYE",
            "l: 0", "", "",
        ].joined(separator: "\r\n")))
        #expect(m.method == "BYE")
        #expect(m.headerValues("Via").count == 2)
        #expect(m.topViaBranch == "z9hG4bKa")
        #expect(m.headerValues("Record-Route") == ["<sip:p1.example.test;lr>", "<sip:p2.example.test;lr>"])
        #expect(m.fromTag == "remote1", "the folded line is the From's")
        #expect(SipNameAddr.parse(m.header("From")!)?.display == "The, Agent", "a comma inside quotes is not a separator")
        #expect(m.toTag == "local1")
        #expect(m.callId == "call-1")
    }

    @Test func lfOnlyAndNoContentLengthAreRead() throws {
        let m = try #require(SipParser.parse("SIP/2.0 200 OK\nVia: SIP/2.0/WSS h.invalid;branch=z9hG4bK1\nFrom: <sip:a@b>;tag=1\nTo: <sip:c@d>;tag=2\nCall-ID: c\nCSeq: 2 BYE\n\nbody"))
        #expect(m.body == "body")
    }

    @Test func sessionExpiresIsRead() throws {
        let m = try #require(SipParser.parse("UPDATE sip:x@h.invalid SIP/2.0\r\nVia: SIP/2.0/WSS h;branch=z9hG4bK1\r\nFrom: <sip:a@b>;tag=1\r\nTo: <sip:c@d>;tag=2\r\nCall-ID: c\r\nCSeq: 3 UPDATE\r\nx: 120;refresher=uas\r\n\r\n"))
        #expect(m.sessionExpires?.seconds == 120)
        #expect(m.sessionExpires?.refresher == "uas")
    }

    @Test func malformedInputIsDroppedNeverACrash() {
        let good = "Via: SIP/2.0/WSS h;branch=z9hG4bK1\r\nFrom: <sip:a@b>;tag=1\r\nTo: <sip:c@d>\r\nCall-ID: c\r\nCSeq: 1 INVITE\r\n"
        let bad: [String] = [
            "",
            "\r\n\r\n",
            "garbage",
            "SIP/2.0 200 OK\r\n" + good,                                   // no blank line
            "SIP/2.0 99 Low\r\n" + good + "\r\n",                          // a status out of range
            "SIP/2.0 2000 OK\r\n" + good + "\r\n",
            "INVITE sip:x SIP/3.0\r\n" + good + "\r\n",                    // another version
            "INVITE\r\n" + good + "\r\n",
            "invite sip:x@y SIP/2.0\r\n" + good + "\r\n",                  // a method is upper case
            "SIP/2.0 200 OK\r\n no header above\r\n" + good + "\r\n",      // a fold with nothing to fold into
            "SIP/2.0 200 OK\r\nNo colon here\r\n" + good + "\r\n",
            "SIP/2.0 200 OK\r\nBad Name: x\r\n" + good + "\r\n",
            "SIP/2.0 200 OK\r\n" + good + "Content-Length: 10\r\n\r\nshort",  // a body shorter than promised
            "SIP/2.0 200 OK\r\n" + good + "Content-Length: -1\r\n\r\n",
            "SIP/2.0 200 OK\r\nFrom: <sip:a@b>\r\nTo: <sip:c@d>\r\nCall-ID: c\r\nCSeq: 1 INVITE\r\n\r\n",   // no Via
            "SIP/2.0 200 OK\r\nVia: v;branch=1\r\nFrom: <sip:a@b>\r\nTo: <sip:c@d>\r\nCSeq: 1 INVITE\r\n\r\n", // no Call-ID
            "SIP/2.0 200 OK\r\nVia: v;branch=1\r\nFrom: <sip:a@b>\r\nTo: <sip:c@d>\r\nCall-ID: c\r\nCSeq: one INVITE\r\n\r\n",
            "BYE sip:x@y SIP/2.0\r\n" + good + "\r\n",                     // a BYE whose CSeq names INVITE
        ]
        for text in bad {
            #expect(SipParser.parse(text) == nil, "\(text.prefix(40).debugDescription)")
        }
    }

    @Test func sizeAndCountAreCapped() {
        let head = "SIP/2.0 200 OK\r\nVia: v;branch=z9hG4bK1\r\nFrom: <sip:a@b>;tag=1\r\nTo: <sip:c@d>\r\nCall-ID: c\r\nCSeq: 1 INVITE\r\n"
        let huge = head + "\r\n" + String(repeating: "a", count: SipParser.maxBytes)
        #expect(SipParser.parse(huge) == nil, "over the size cap")
        let many = head + (0...SipParser.maxHeaders).map { "X-H\($0): v" }.joined(separator: "\r\n") + "\r\n\r\n"
        #expect(SipParser.parse(many) == nil, "over the header cap")
        let longLine = head + "X-Long: " + String(repeating: "b", count: SipParser.maxLineBytes) + "\r\n\r\n"
        #expect(SipParser.parse(longLine) == nil, "over the line cap")
        // Random bytes: dropped, quickly, whatever they are.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 1...600, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = SipParser.parse(bytes: bytes)
            _ = SipParser.parse(bytes: Array(head.utf8) + bytes)
        }
    }

    @Test func nameAddrAndParams() {
        let a = SipNameAddr.parse("\"Agent \\\"One\\\"\" <sip:app@h;transport=tcp>;tag=abc;lr")
        #expect(a?.display == "Agent \\\"One\\\"")
        #expect(a?.uri == "sip:app@h;transport=tcp")
        #expect(a?.param("tag") == "abc")
        #expect(a?.param("lr") == "")
        let bare = SipNameAddr.parse("sip:web@realm;tag=xyz")
        #expect(bare?.uri == "sip:web@realm")
        #expect(bare?.param("tag") == "xyz")
        #expect(SipNameAddr.parse("<sip:no-close") == nil)
        #expect(SipNameAddr.parse("") == nil)
    }
}

@Suite struct SipDigestTests {
    /// RFC 2617 §3.5's own example, qop=auth (the password is written apart from its label on purpose).
    @Test func rfc2617Vector() throws {
        let phrase = "Circle Of Life"
        let challenge = SipChallenge(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque: "5ccc069c403ebaf9f0171e9517f40e41", algorithm: nil, qop: ["auth", "auth-int"], stale: false)
        var authOnly = challenge
        authOnly.qop = ["auth"]
        let header = try #require(SipDigest.authorization(username: "Mufasa", password: phrase, method: "GET", uri: "/dir/index.html", challenge: authOnly, cnonce: "0a4f113b"))
        #expect(header.contains("response=\"6629fae49393a05397450978507c4ef1\""))
        #expect(header == "Digest algorithm=MD5, username=\"Mufasa\", realm=\"testrealm@host.com\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", uri=\"/dir/index.html\", response=\"6629fae49393a05397450978507c4ef1\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\", qop=auth, cnonce=\"0a4f113b\", nc=00000001")
        // JsSIP prefers auth-int when both are offered.
        let both = try #require(SipDigest.authorization(username: "Mufasa", password: phrase, method: "GET", uri: "/dir/index.html", challenge: challenge, cnonce: "0a4f113b"))
        #expect(both.contains("qop=auth-int"))
    }

    @Test func withoutQopItIsRfc2069() throws {
        let challenge = SipChallenge(realm: "r", nonce: "n", opaque: nil, algorithm: "MD5", qop: [], stale: false)
        let header = try #require(SipDigest.authorization(username: "u", password: "p", method: "REGISTER", uri: "sip:r", challenge: challenge, cnonce: "c"))
        let expected = SipDigest.md5Hex("\(SipDigest.md5Hex("u:r:p")):n:\(SipDigest.md5Hex("REGISTER:sip:r"))")
        #expect(header == "Digest algorithm=MD5, username=\"u\", realm=\"r\", nonce=\"n\", uri=\"sip:r\", response=\"\(expected)\"")
    }

    @Test func onlyMd5AndKnownQopsAreAnswered() {
        let sha = SipChallenge(realm: "r", nonce: "n", opaque: nil, algorithm: "SHA-256", qop: ["auth"], stale: false)
        #expect(SipDigest.authorization(username: "u", password: "p", method: "INVITE", uri: "sip:x", challenge: sha, cnonce: "c") == nil)
        let odd = SipChallenge(realm: "r", nonce: "n", opaque: nil, algorithm: nil, qop: ["auth-conf"], stale: false)
        #expect(SipDigest.authorization(username: "u", password: "p", method: "INVITE", uri: "sip:x", challenge: odd, cnonce: "c") == nil)
    }

    @Test func challengesAreReadLeniently() {
        #expect(SipChallenge.parse("Digest realm=\"r\",nonce=\"n\",stale=TRUE,qop=\"auth, auth-int\"")?.qop == ["auth", "auth-int"])
        #expect(SipChallenge.parse("Digest realm=\"r\", nonce=\"n\", stale=true")?.stale == true)
        #expect(SipChallenge.parse("Basic realm=\"r\"") == nil)
        #expect(SipChallenge.parse("Digest realm=\"r\"") == nil, "no nonce")
        #expect(SipChallenge.parse("Digestrealm=\"r\", nonce=\"n\"") == nil)
    }
}

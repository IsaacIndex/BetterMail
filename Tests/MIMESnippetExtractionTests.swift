import CoreData
import XCTest
@testable import BetterMail

@MainActor
final class MIMESnippetExtractionTests: XCTestCase {

    private let decoder = HeaderDecoder()

    // MARK: - extractBoundary

    func test_extractBoundary_quotedValue_returnsBoundary() {
        let ct = "multipart/alternative; boundary=\"_000_ABC123\""
        XCTAssertEqual(decoder.extractBoundary(from: ct), "_000_ABC123")
    }

    func test_extractBoundary_unquotedValue_returnsBoundary() {
        let ct = "multipart/mixed; boundary=_007_XYZ789"
        XCTAssertEqual(decoder.extractBoundary(from: ct), "_007_XYZ789")
    }

    func test_extractBoundary_noBoundary_returnsNil() {
        let ct = "text/plain; charset=utf-8"
        XCTAssertNil(decoder.extractBoundary(from: ct))
    }

    func test_extractBoundary_boundaryWithSpacesAroundEquals_returnsBoundary() {
        let ct = "multipart/alternative; boundary = \"spacey_boundary\""
        XCTAssertEqual(decoder.extractBoundary(from: ct), "spacey_boundary")
    }

    func test_headers_foldedRecipientHeader_insertsReadableSeparator() {
        let source = "To: \"Cheung, Simon\" <simon@example.com>,\r\n \"Chen, Rachel Q\" <rachel@example.com>\r\nSubject: Review\r\n\r\nBody"

        XCTAssertEqual(decoder.headers(from: source)["to"],
                       "\"Cheung, Simon\" <simon@example.com>, \"Chen, Rachel Q\" <rachel@example.com>")
    }

    // MARK: - calendar RSVP classification

    func test_calendarRSVPClassifier_calendarReplyWithFoldedContentType_returnsTrue() {
        let source = """
        Content-Type: text/calendar;
            charset=\"utf-8\";
            method=\"REPLY\"

        BEGIN:VCALENDAR
        METHOD:REPLY
        END:VCALENDAR
        """

        XCTAssertTrue(CalendarRSVPClassifier.isCalendarRSVP(in: source))
    }

    func test_calendarRSVPClassifier_calendarReplyPayloadWithoutMethodParameter_returnsTrue() {
        let source = """
        Content-Type: text/calendar; charset=utf-8

        BEGIN:VCALENDAR
        METHOD:REPLY
        END:VCALENDAR
        """

        XCTAssertTrue(CalendarRSVPClassifier.isCalendarRSVP(in: source))
    }

    func test_calendarRSVPClassifier_calendarReplyInMultipartBody_returnsTrue() {
        let source = """
        Content-Type: multipart/alternative; boundary="calendar-part"

        --calendar-part
        Content-Type: text/plain; charset=utf-8

        Thanks.
        --calendar-part
        Content-Type: text/calendar; charset=utf-8; method=REPLY

        BEGIN:VCALENDAR
        METHOD:REPLY
        END:VCALENDAR
        --calendar-part--
        """

        XCTAssertTrue(CalendarRSVPClassifier.isCalendarRSVP(in: source))
    }

    func test_calendarRSVPClassifier_calendarReplyInCachedBoundaryFragment_returnsTrue() {
        let fragment = """
        --calendar-part
        Content-Type: text/plain; charset=utf-8

        Thanks.
        --calendar-part
        Content-Type: text/calendar; charset=utf-8; method=REPLY

        BEGIN:VCALENDAR
        METHOD:REPLY
        END:VCALENDAR
        --calendar-part--
        """

        XCTAssertTrue(CalendarRSVPClassifier.isCalendarRSVP(in: fragment))
    }

    func test_calendarRSVPClassifier_replyWithGeneratedPlainAlternative_staysAttendanceOnly() {
        let source = """
        Content-Type: multipart/alternative; boundary="response"

        --response
        Content-Type: text/plain; charset=utf-8

        Accepted: Planning
        --response
        Content-Type: text/calendar; method=REPLY

        BEGIN:VCALENDAR
        METHOD:REPLY
        END:VCALENDAR
        --response--
        """

        XCTAssertEqual(CalendarRSVPClassifier.classify(source).kind, .attendanceOnlyResponse)
    }

    func test_calendarRSVPClassifier_replyWithEscapedFoldedComment_isVisibleSupplement() {
        let source = #"""
        Content-Type: text/calendar; method=REPLY

        BEGIN:VCALENDAR
        METHOD:REPLY
        COMMENT:I can join\, but will arrive\n
         ten minutes late\; please start.
        END:VCALENDAR
        """#

        let result = CalendarRSVPClassifier.classify(source)
        XCTAssertEqual(result.kind, .supplementedResponse)
        XCTAssertEqual(result.supplementText, "I can join, but will arrive\nten minutes late; please start.")
        XCTAssertFalse(result.shouldSuppress)
    }

    func test_calendarRSVPClassifier_emptyComment_staysAttendanceOnly() {
        let source = """
        Content-Type: text/calendar; method=REPLY

        BEGIN:VCALENDAR
        METHOD:REPLY
        COMMENT:\(String(repeating: " ", count: 3))
        END:VCALENDAR
        """

        XCTAssertEqual(CalendarRSVPClassifier.classify(source).kind, .attendanceOnlyResponse)
    }

    func test_calendarRSVPClassifier_encodedComments_areDecoded() {
        let payload = "BEGIN:VCALENDAR\nMETHOD:REPLY\nCOMMENT:Joining by phone\nEND:VCALENDAR"
        let base64 = Data(payload.utf8).base64EncodedString()
        let base64Source = "Content-Type: text/calendar; method=REPLY\nContent-Transfer-Encoding: base64\n\n\(base64)"
        let quotedPrintableSource = "Content-Type: text/calendar; method=REPLY\nContent-Transfer-Encoding: quoted-printable\n\nBEGIN:VCALENDAR\nMETHOD:REPLY\nCOMMENT:Joining=20by=20video\nEND:VCALENDAR"

        XCTAssertEqual(CalendarRSVPClassifier.classify(base64Source).supplementText, "Joining by phone")
        XCTAssertEqual(CalendarRSVPClassifier.classify(quotedPrintableSource).supplementText, "Joining by video")
    }

    func test_calendarRSVPClassifier_payloadMethodWinsOverConflictingHeader() {
        let reply = "Content-Type: text/calendar; method=REQUEST\n\nBEGIN:VCALENDAR\nMETHOD:REPLY\nEND:VCALENDAR"
        let invitation = "Content-Type: text/calendar; method=REPLY\n\nBEGIN:VCALENDAR\nMETHOD:REQUEST\nEND:VCALENDAR"

        XCTAssertEqual(CalendarRSVPClassifier.classify(reply).kind, .attendanceOnlyResponse)
        XCTAssertEqual(CalendarRSVPClassifier.classify(invitation).kind, .invitation)
    }

    func test_calendarRSVPClassifier_otherSchedulingMethodsAndOrdinaryReplyAll_remainVisible() {
        for method in ["CANCEL", "COUNTER", "PUBLISH"] {
            let source = "Content-Type: text/calendar; method=\(method)\n\nBEGIN:VCALENDAR\nMETHOD:\(method)\nEND:VCALENDAR"
            XCTAssertEqual(CalendarRSVPClassifier.classify(source).kind, .otherSchedulingMessage)
        }
        let replyAll = "Content-Type: text/plain; charset=utf-8\n\nReplying all with the slides and next steps."
        XCTAssertEqual(CalendarRSVPClassifier.classify(replyAll).kind, .ordinaryMessage)
    }

    func test_calendarRSVPClassifier_secondaryICSAttachment_isIgnored() {
        let source = """
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: text/plain

        Here are the meeting notes.
        --mixed
        Content-Type: text/calendar; name="invite.ics"; method=REPLY
        Content-Disposition: attachment; filename="invite.ics"

        BEGIN:VCALENDAR
        METHOD:REPLY
        END:VCALENDAR
        --mixed--
        """

        XCTAssertEqual(CalendarRSVPClassifier.classify(source).kind, .ordinaryMessage)
    }

    func test_calendarRSVPClassifier_malformedAndOversizedInput_failOpen() {
        let malformed = "Content-Type: multipart/alternative; boundary=missing-close\n\n--missing-close\nContent-Type: text/calendar; method=REPLY\n\nBEGIN:VCALENDAR\nMETHOD:REPLY"
        let oversized = "Content-Type: text/calendar; method=REPLY\n\n" + String(repeating: "X", count: 512 * 1024 + 1)

        XCTAssertEqual(CalendarRSVPClassifier.classify(malformed).kind, .indeterminate)
        XCTAssertEqual(CalendarRSVPClassifier.classify(oversized).kind, .indeterminate)
        XCTAssertFalse(CalendarRSVPClassifier.isCalendarRSVP(in: malformed))
        XCTAssertFalse(CalendarRSVPClassifier.isCalendarRSVP(in: oversized))
    }

    func test_calendarRSVPClassifier_invitationAndNonCalendarMessages_remainVisible() {
        let invitation = """
        Content-Type: text/calendar; charset=utf-8; method=REQUEST

        BEGIN:VCALENDAR
        METHOD:REQUEST
        END:VCALENDAR
        """
        let plainEmail = "Content-Type: text/plain\n\nAccepted: project proposal"

        XCTAssertFalse(CalendarRSVPClassifier.isCalendarRSVP(in: invitation))
        XCTAssertFalse(CalendarRSVPClassifier.isCalendarRSVP(in: plainEmail))
    }

    func test_calendarRSVPClassifier_quotedCalendarReplyInPlainText_returnsFalse() {
        let forwardedEmail = """
        Content-Type: text/plain; charset=utf-8

        FYI, the previous response included:
        Content-Type: text/calendar; method=REPLY
        METHOD:REPLY
        """

        XCTAssertFalse(CalendarRSVPClassifier.isCalendarRSVP(in: forwardedEmail))
    }

    func test_calendarRSVPVisibility_hidesReplyButKeepsItForReconciliation() async throws {
        let defaults = UserDefaults(suiteName: "CalendarRSVPVisibilityTests-\(UUID().uuidString)")!
        let store = MessageStore(userDefaults: defaults, storeType: NSInMemoryStoreType)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rsvp = EmailMessage(messageID: "rsvp",
                                mailboxID: "Inbox",
                                accountName: "work",
                                subject: "Accepted: Planning",
                                from: "organizer@example.com",
                                to: "me@example.com",
                                date: date,
                                snippet: "Content-Type: text/calendar; method=REPLY",
                                isUnread: false,
                                calendarMessageKind: .attendanceOnlyResponse,
                                inReplyTo: nil,
                                references: [])
        let message = EmailMessage(messageID: "message",
                                   mailboxID: "Inbox",
                                   accountName: "work",
                                   subject: "Planning notes",
                                   from: "organizer@example.com",
                                   to: "me@example.com",
                                   date: date,
                                   snippet: "Please review the notes.",
                                   isUnread: false,
                                   inReplyTo: nil,
                                   references: [])
        let supplement = EmailMessage(messageID: "supplement",
                                      mailboxID: "Inbox",
                                      accountName: "work",
                                      subject: "Accepted: Planning",
                                      from: "organizer@example.com",
                                      to: "me@example.com",
                                      date: date,
                                      snippet: "I will bring the updated deck.",
                                      isUnread: false,
                                      calendarMessageKind: .supplementedResponse,
                                      inReplyTo: rsvp.messageID,
                                      references: [rsvp.messageID])
        try await store.upsert(messages: [rsvp, message, supplement])
        await store.addActionItem(for: rsvp, folderID: nil, tags: [])
        await store.addActionItem(for: supplement, folderID: nil, tags: [])

        let visible = try await store.fetchMessages()
        let actionItems = await store.fetchActionItems()
        let scope = DayFetchScope(mailbox: "Inbox", account: "work", displayName: "Work / Inbox")
        let reconciled = try await store.fetchMessagesForReconciliation(
            in: DateInterval(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1)),
            scope: scope
        )

        XCTAssertEqual(visible.map(\.messageID), ["message", "supplement"])
        XCTAssertEqual(actionItems.map(\.id), [ActionItem.scopedID(for: supplement)])
        XCTAssertEqual(Set(reconciled.map(\.messageID)), ["rsvp", "message", "supplement"])
    }

    func test_calendarRSVPVisibility_excludesReplyFromThread() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = EmailMessage(messageID: "conversation",
                                        mailboxID: "inbox",
                                        accountName: "",
                                        subject: "Planning",
                                        from: "organizer@example.com",
                                        to: "me@example.com",
                                        date: date,
                                        snippet: "Agenda attached.",
                                        isUnread: false,
                                        inReplyTo: nil,
                                        references: [])
        let rsvp = EmailMessage(messageID: "rsvp",
                                mailboxID: "inbox",
                                accountName: "",
                                subject: "Accepted: Planning",
                                from: "me@example.com",
                                to: "organizer@example.com",
                                date: date.addingTimeInterval(60),
                                snippet: "Content-Type: text/calendar; method=REPLY",
                                isUnread: false,
                                calendarMessageKind: .attendanceOnlyResponse,
                                inReplyTo: conversation.messageID,
                                references: [conversation.messageID])

        let result = JWZThreader().buildThreads(from: [conversation, rsvp])

        XCTAssertEqual(result.roots.map(\.message.messageID), [conversation.messageID])
        XCTAssertTrue(result.roots[0].children.isEmpty)
        XCTAssertEqual(result.messageThreadMap[rsvp.threadKey], conversation.threadKey)
    }

    func test_calendarThreading_hiddenRSVPPromotesVisibleSupplementToInvitation() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let invitation = EmailMessage(messageID: "invite",
                                      mailboxID: "inbox",
                                      accountName: "work",
                                      subject: "Planning",
                                      from: "organizer@example.com",
                                      to: "team@example.com",
                                      date: date,
                                      snippet: "Agenda",
                                      isUnread: false,
                                      calendarMessageKind: .invitation,
                                      inReplyTo: nil,
                                      references: [])
        let hiddenRSVP = EmailMessage(messageID: "rsvp",
                                      mailboxID: "sent",
                                      accountName: "work",
                                      subject: "Accepted: Planning",
                                      from: "me@example.com",
                                      to: "organizer@example.com",
                                      date: date.addingTimeInterval(60),
                                      snippet: "Accepted",
                                      isUnread: false,
                                      calendarMessageKind: .attendanceOnlyResponse,
                                      inReplyTo: invitation.messageID,
                                      references: [invitation.messageID])
        let supplement = EmailMessage(messageID: "supplement",
                                      mailboxID: "sent",
                                      accountName: "work",
                                      subject: "Re: Planning",
                                      from: "me@example.com",
                                      to: "team@example.com",
                                      date: date.addingTimeInterval(120),
                                      snippet: "I attached the revised agenda.",
                                      isUnread: false,
                                      calendarMessageKind: .ordinaryMessage,
                                      inReplyTo: hiddenRSVP.messageID,
                                      references: [invitation.messageID, hiddenRSVP.messageID])
        let secondSupplement = EmailMessage(messageID: "supplement-two",
                                            mailboxID: "sent",
                                            accountName: "work",
                                            subject: "Re: Planning",
                                            from: "teammate@example.com",
                                            to: "team@example.com",
                                            date: date.addingTimeInterval(180),
                                            snippet: "I added the final figures.",
                                            isUnread: false,
                                            calendarMessageKind: .ordinaryMessage,
                                            inReplyTo: hiddenRSVP.messageID,
                                            references: [invitation.messageID, hiddenRSVP.messageID])

        let result = JWZThreader().buildThreads(from: [invitation, hiddenRSVP, supplement, secondSupplement])

        XCTAssertEqual(result.roots.map(\.message.messageID), [invitation.messageID])
        XCTAssertEqual(result.roots.first?.children.map(\.message.messageID),
                       [supplement.messageID, secondSupplement.messageID])
        XCTAssertEqual(result.threads.first?.messageCount, 3)
        XCTAssertEqual(result.messageThreadMap[hiddenRSVP.threadKey], invitation.threadKey)
        XCTAssertEqual(result.messageThreadMap[supplement.threadKey], invitation.threadKey)
        XCTAssertEqual(result.messageThreadMap[secondSupplement.threadKey], invitation.threadKey)

        let graph = GraphData.make(roots: result.roots,
                                   messageLimitPerBranch: 2,
                                   now: date.addingTimeInterval(240))
        let graphThreadID = GraphData.threadNodeID(for: invitation.messageID)
        XCTAssertEqual(graph.visibleEmailNodeCount, 2)
        XCTAssertEqual(graph.threads.first?.messageIDs,
                       [invitation.messageID, supplement.messageID, secondSupplement.messageID])
        XCTAssertEqual(graph.remainingEmails(forThreadID: graphThreadID)?.hiddenCount, 1,
                       "The hidden RSVP must not consume the configured email-node page budget")
    }

    func test_calendarThreading_missingInvitation_keepsSupplementAsTemporaryRoot() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let hiddenRSVP = EmailMessage(messageID: "rsvp",
                                      mailboxID: "sent",
                                      accountName: "work",
                                      subject: "Accepted: Planning",
                                      from: "me@example.com",
                                      to: "organizer@example.com",
                                      date: date,
                                      snippet: "Accepted",
                                      isUnread: false,
                                      calendarMessageKind: .attendanceOnlyResponse,
                                      inReplyTo: "missing-invite",
                                      references: ["missing-invite"])
        let supplement = EmailMessage(messageID: "supplement",
                                      mailboxID: "sent",
                                      accountName: "work",
                                      subject: "Re: Planning",
                                      from: "me@example.com",
                                      to: "team@example.com",
                                      date: date.addingTimeInterval(60),
                                      snippet: "One more detail.",
                                      isUnread: false,
                                      calendarMessageKind: .ordinaryMessage,
                                      inReplyTo: hiddenRSVP.messageID,
                                      references: ["missing-invite", hiddenRSVP.messageID])

        let result = JWZThreader().buildThreads(from: [hiddenRSVP, supplement])

        XCTAssertEqual(result.roots.map(\.message.messageID), [supplement.messageID])
        XCTAssertEqual(result.threads.first?.messageCount, 1)
        XCTAssertEqual(result.messageThreadMap[hiddenRSVP.threadKey], supplement.threadKey)
    }

    // MARK: - decodeMIMEBody

    func test_decodeMIMEBody_quotedPrintable_decodesHexAndSoftBreaks() {
        // =\n is a QP soft line break (continuation) — it should be removed, joining the lines
        let input = "Hello=20World=\nThis is a test"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain")
        XCTAssertEqual(result, "Hello WorldThis is a test")
        // =0A encodes a literal newline
        let input2 = "Line one=0ALine two"
        let result2 = decoder.decodeMIMEBody(input2, transferEncoding: "quoted-printable", contentType: "text/plain")
        XCTAssertEqual(result2, "Line one\nLine two")
    }

    func test_decodeMIMEBody_quotedPrintable_utf8MultiByteSequence() {
        let input = "Excel =E2=80=93 Push Rules"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain; charset=utf-8")
        XCTAssertEqual(result, "Excel \u{2013} Push Rules")
    }

    func test_decodeMIMEBody_base64_decodesCorrectly() {
        let original = "Hello, this is a test message."
        let encoded = Data(original.utf8).base64EncodedString()
        let result = decoder.decodeMIMEBody(encoded, transferEncoding: "base64", contentType: "text/plain")
        XCTAssertEqual(result, original)
    }

    func test_decodeMIMEBody_caseInsensitive_works() {
        let original = "Test message"
        let encoded = Data(original.utf8).base64EncodedString()
        XCTAssertEqual(decoder.decodeMIMEBody(encoded, transferEncoding: "Base64", contentType: "text/plain"), original)
        XCTAssertEqual(decoder.decodeMIMEBody(encoded, transferEncoding: "BASE64", contentType: "text/plain"), original)
        let qp = "Hello=20World"
        XCTAssertEqual(decoder.decodeMIMEBody(qp, transferEncoding: "QUOTED-PRINTABLE", contentType: "text/plain"), "Hello World")
    }

    func test_decodeMIMEBody_7bit_passthrough() {
        let input = "Plain text content"
        XCTAssertEqual(decoder.decodeMIMEBody(input, transferEncoding: "7bit", contentType: "text/plain"), input)
        XCTAssertEqual(decoder.decodeMIMEBody(input, transferEncoding: "8bit", contentType: "text/plain"), input)
        XCTAssertEqual(decoder.decodeMIMEBody(input, transferEncoding: "", contentType: "text/plain"), input)
    }

    func test_decodeMIMEBody_latin1Charset_decodesCorrectly() {
        let input = "caf=E9"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "quoted-printable", contentType: "text/plain; charset=iso-8859-1")
        XCTAssertEqual(result, "café")
    }

    func test_decodeMIMEBody_unknownCharset_fallsBackToUTF8() {
        let input = "hello"
        let result = decoder.decodeMIMEBody(input, transferEncoding: "7bit", contentType: "text/plain; charset=iso-2022-jp")
        XCTAssertEqual(result, "hello")
    }

    // MARK: - extractPlainTextFromMIME

    func test_extractPlainTextFromMIME_simpleMultipartAlternative_extractsPlainText() {
        let source = "Content-Type: multipart/alternative; boundary=\"boundary1\"\n\n--boundary1\nContent-Type: text/plain; charset=utf-8\n\nHello from the plain text part.\n--boundary1\nContent-Type: text/html; charset=utf-8\n\n<html><body>Hello from HTML</body></html>\n--boundary1--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Hello from the plain text part.")
    }

    func test_extractPlainTextFromMIME_nestedMultipart_walksToPlainText() {
        let source = "Content-Type: multipart/mixed; boundary=\"outer\"\n\n--outer\nContent-Type: multipart/related; boundary=\"middle\"\n\n--middle\nContent-Type: multipart/alternative; boundary=\"inner\"\n\n--inner\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nDear team,=0APlease review.\n--inner\nContent-Type: text/html\n\n<html><body>Dear team</body></html>\n--inner--\n--middle--\n--outer--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertTrue(result?.contains("Dear team,") == true)
        XCTAssertTrue(result?.contains("Please review.") == true)
    }

    func test_extractPlainTextFromMIME_base64PlainText_decodes() {
        let body = "This is a base64 encoded message."
        let encoded = Data(body.utf8).base64EncodedString()
        let source = "Content-Type: multipart/alternative; boundary=\"b64bound\"\n\n--b64bound\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n\(encoded)\n--b64bound--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), body)
    }

    func test_extractPlainTextFromMIME_nonMultipart_returnsNil() {
        let source = "Content-Type: text/plain; charset=utf-8\n\nJust a simple email.\n"
        XCTAssertNil(decoder.extractPlainTextFromMIME(source))
    }

    func test_extractPlainTextFromMIME_htmlOnly_stripsTagsAsFallback() {
        let source = "Content-Type: multipart/alternative; boundary=\"htmlonly\"\n\n--htmlonly\nContent-Type: text/html; charset=utf-8\n\n<html><head><style>body{color:red}</style></head><body><p>Important message</p></body></html>\n--htmlonly--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("Important message") == true)
        XCTAssertFalse(result?.contains("<p>") == true)
        XCTAssertFalse(result?.contains("color:red") == true)
    }

    func test_extractPlainTextFromMIME_closingDelimiter_ignoresEpilogue() {
        let source = "Content-Type: multipart/alternative; boundary=\"epilogue\"\n\n--epilogue\nContent-Type: text/plain\n\nReal content.\n--epilogue--\nThis is epilogue junk that should be ignored.\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "Real content.")
    }

    func test_extractPlainTextFromMIME_depthLimit_returnsNil() {
        // Use zero-padded names so no boundary is a prefix of another
        var source = ""
        for i in 0..<12 {
            let boundary = String(format: "depth_%02d", i)
            source += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\n\n--\(boundary)\n"
        }
        source += "Content-Type: text/plain\n\nShould not be reached.\n"
        for i in stride(from: 11, through: 0, by: -1) {
            let boundary = String(format: "depth_%02d", i)
            source += "--\(boundary)--\n"
        }
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertNil(result)
    }

    func test_extractPlainTextFromMIME_emptySource_returnsNil() {
        XCTAssertNil(decoder.extractPlainTextFromMIME(""))
    }

    func test_extractPlainTextFromMIME_oversizedSource_returnsNil() {
        let padding = String(repeating: "X", count: 512 * 1024 + 1)
        let source = "Content-Type: multipart/mixed; boundary=\"big\"\n\n--big\nContent-Type: text/plain\n\n\(padding)\n--big--"
        XCTAssertNil(decoder.extractPlainTextFromMIME(source))
    }

    func test_extractPlainTextFromMIME_latin1Part_decodesCorrectly() {
        let source = "Content-Type: multipart/alternative; boundary=\"latin\"\n\n--latin\nContent-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: quoted-printable\n\ncaf=E9\n--latin--\n"
        let result = decoder.extractPlainTextFromMIME(source)
        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines), "café")
    }

    // MARK: - bodySnippet integration

    func test_bodySnippet_emptyBodyWithMultipartSource_extractsFromMIME() {
        let source = "Content-Type: multipart/alternative; boundary=\"inttest\"\nSubject: Test\n\n--inttest\nContent-Type: text/plain; charset=utf-8\n\nThis is the real email body from MIME.\n--inttest\nContent-Type: text/html\n\n<html><body>HTML version</body></html>\n--inttest--\n"
        let result = decoder.bodySnippet(fromBody: "", fallbackSource: source)
        XCTAssertTrue(result.contains("This is the real email body from MIME."))
    }

    func test_bodySnippet_nonEmptyBody_usesPrimaryBody() {
        let result = decoder.bodySnippet(fromBody: "Primary body text", fallbackSource: "irrelevant")
        XCTAssertEqual(result, "Primary body text")
    }

    func test_bodySnippet_emptyBodyNonMultipartSource_usesNaiveFallback() {
        let source = "Subject: Test\n\nSimple body after headers.\n"
        let result = decoder.bodySnippet(fromBody: "", fallbackSource: source)
        XCTAssertTrue(result.contains("Simple body after headers."))
    }

    func test_bodySnippet_nonEmptyBoundaryLedNestedMIME_extractsOnlyEmailContent() {
        let body = """
        --_005_CH5PR15MB6969
        Content-Type: multipart/alternative;
         boundary="_000_CH5PR15MB6969"

        --_000_CH5PR15MB6969
        Content-Type: text/plain; charset="us-ascii"

        Hi all,

        Scheduling this follow-up meeting to continue our walkthrough.
        --_000_CH5PR15MB6969
        Content-Type: text/html; charset="us-ascii"

        <html><body><p>Hi all,</p><p>Scheduling this follow-up meeting.</p></body></html>
        --_000_CH5PR15MB6969--
        --_005_CH5PR15MB6969--
        """

        let result = decoder.bodySnippet(fromBody: body, fallbackSource: "")

        XCTAssertEqual(result,
                       "Hi all,\n\nScheduling this follow-up meeting to continue our walkthrough.")
        XCTAssertFalse(result.contains("_005_CH5PR15MB6969"))
        XCTAssertFalse(result.contains("Content-Type"))
        XCTAssertFalse(result.contains("boundary="))
    }

    func test_extractPlainTextFromMIME_textAttachmentBeforeBody_skipsAttachment() {
        let source = """
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: text/plain; charset=utf-8
        Content-Disposition: attachment; filename="notes.txt"

        Attachment text that must not be shown.
        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/html; charset=utf-8

        <p>HTML fallback</p>
        --inner
        Content-Type: text/plain; charset=utf-8

        Real email body.
        --inner--
        --outer--
        """

        let result = decoder.extractPlainTextFromMIME(source)

        XCTAssertEqual(result?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Real email body.")
        XCTAssertFalse(result?.contains("Attachment text") == true)
    }

    func test_extractPlainTextFromMIME_boundaryTextInsideContent_isNotDelimiter() {
        let source = """
        Content-Type: multipart/alternative; boundary="safe-boundary"

        --safe-boundary
        Content-Type: text/plain; charset=utf-8

        Keep --safe-boundary inside this sentence.
        --safe-boundary--
        """

        XCTAssertEqual(decoder.extractPlainTextFromMIME(source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                       "Keep --safe-boundary inside this sentence.")
    }

    func test_bodySnippet_htmlOnly_preservesParagraphAndListFormatting() {
        let source = """
        Content-Type: text/html; charset=utf-8

        <html><body><p>Hello <strong>team</strong>.</p><p>Next steps:</p><ul><li>Review</li><li>Reply</li></ul></body></html>
        """

        let result = decoder.bodySnippet(fromBody: "", fallbackSource: source)

        XCTAssertTrue(result.contains("Hello team."))
        XCTAssertTrue(result.contains("Next steps:"))
        XCTAssertTrue(result.contains("• Review\n• Reply"))
        XCTAssertFalse(result.contains("<strong>"))
    }

    func test_snippetFormatter_cachedBoundaryFragment_preservesParagraphsAndRemovesMIMEFraming() {
        let cachedSnippet = """
        --cached-outer
        Content-Type: multipart/alternative; boundary="cached-inner"

        --cached-inner
        Content-Type: text/plain; charset=utf-8

        First paragraph.

        Second paragraph.
        --cached-inner--
        --cached-outer--
        """
        let formatter = SnippetFormatter(lineLimit: 10, stopPhrases: [])

        let result = formatter.format(cachedSnippet)

        XCTAssertEqual(result, "First paragraph.\n\nSecond paragraph.")
        XCTAssertFalse(result.contains("cached-outer"))
        XCTAssertFalse(result.contains("Content-Type"))
    }

    func test_snippetFormatter_truncatedCachedBoundaryFragment_extractsOnlyAvailableContent() {
        let cachedSnippet = """
        --_005_CH5PR15MB6969
        Content-Type: multipart/alternative;
         boundary="_000_CH5PR15MB6969"

        --_000_CH5PR15MB6969
        Content-Type: text/plain; charset="us-ascii"

        Hi all,

        Scheduling this follow-up meeting to continue our walkthrough.
        """
        let formatter = SnippetFormatter(lineLimit: 10, stopPhrases: [])

        let result = formatter.format(cachedSnippet)

        XCTAssertEqual(result,
                       "Hi all,\n\nScheduling this follow-up meeting to continue our walkthrough.")
        XCTAssertFalse(result.contains("_005_CH5PR15MB6969"))
        XCTAssertFalse(result.contains("Content-Type"))
        XCTAssertFalse(result.contains("boundary="))
    }

    func test_snippetFormatter_stopPhraseRemoval_keepsParagraphBreaks() {
        let formatter = SnippetFormatter(lineLimit: 10, stopPhrases: ["confidential"])

        XCTAssertEqual(formatter.format("First paragraph.\n\nCONFIDENTIAL\n\nSecond paragraph."),
                       "First paragraph.\n\nSecond paragraph.")
    }

    // MARK: - collapsed email history

    func test_collapsedHistory_headerOnlyForwardChain_extractsEachPriorEmailInSourceOrder() {
        let body = """
        FYI on CCB process for your reference.

        From: VIVIAN CHOW <vchow@hk1.ibm.com>
        Date: Wednesday, 19 August 2026 at 4:23 PM
        To: Noel Feng <noel@example.com>
        Subject: FW: CR/CL for Day 2 release

        FYI

        -----Original Message-----
        From: Ho, Kevin K W <kevin@example.com>
        Sent: Thursday, 30 July, 2026 09:11
        To: Elie <elie@example.com>
        Subject: [EXTERNAL] RE: CR/CL for Day 2 release

        CCB ToR attached for reference.

        寄件者: HADAYA, Elie <elie@example.com>
        寄件日期: Wednesday, 29 July 2026 09:00
        收件者: Ronald Lee <ronald@example.com>
        主旨: RE: CR/CL for Day 2 release

        IT CCB already has an approved ToR.
        """

        let result = CollapsedEmailHistoryParser().parse(source: "",
                                                         body: body,
                                                         parentMessageID: "outer@example.com",
                                                         parentSubject: "FW: CR/CL for Day 2 release")

        XCTAssertEqual(result.map(\.subject), [
            "FW: CR/CL for Day 2 release",
            "[EXTERNAL] RE: CR/CL for Day 2 release",
            "RE: CR/CL for Day 2 release"
        ])
        XCTAssertEqual(result.map(\.sourceOrder), [0, 1, 2])
        XCTAssertTrue(result[0].snippet.contains("FYI"))
        XCTAssertTrue(result[1].snippet.contains("CCB ToR"))
        XCTAssertTrue(result[2].snippet.contains("approved ToR"))
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
    }

    func test_collapsedHistory_outlookAndGmailSeparators_extractStrongHeaderBlocks() {
        let body = """
        ---------- Forwarded message ---------
        From: Alice Example <alice@example.com>
        Date: Tue, 18 Aug 2026 14:30:00 +0800
        To: Team <team@example.com>
        Subject: Launch plan

        Please review the plan.

        -----Original Message-----
        From: Bob Example <bob@example.com>
        Sent: Monday, 17 August 2026 at 9:15 AM
        To: Alice Example <alice@example.com>
        Subject: Draft launch plan

        Initial draft attached.
        """

        let parser = CollapsedEmailHistoryParser()
        let first = parser.parse(source: "",
                                 body: body,
                                 parentMessageID: "forward@example.com",
                                 parentSubject: "Fwd: Launch plan")
        let second = parser.parse(source: "",
                                  body: body,
                                  parentMessageID: "forward@example.com",
                                  parentSubject: "Fwd: Launch plan")

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertNotNil(first[0].date)
        XCTAssertNotNil(first[1].date)
    }

    func test_collapsedHistory_quotedReplyMarker_extractsQuotedMessage() {
        let body = """
        Thanks, adding Isaac.

        On August 19, 2026 at 4:23 PM, Vivian Chow <vchow@example.com> wrote:
        > The CCB process is confirmed.
        > Please use the approved ToR.
        """

        let result = CollapsedEmailHistoryParser().parse(source: "",
                                                         body: body,
                                                         parentMessageID: "reply@example.com",
                                                         parentSubject: "Re: CCB process")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].subject, "CCB process")
        XCTAssertEqual(result[0].from, "Vivian Chow <vchow@example.com>")
        XCTAssertEqual(result[0].snippet,
                       "The CCB process is confirmed.\nPlease use the approved ToR.")
    }

    func test_collapsedHistory_markerWithoutStrongHeaders_failsClosed() {
        let body = """
        We discussed the phrase forwarded message in the meeting.
        -----Original Message-----
        This is ordinary prose without a From, Date, and Subject header block.
        """

        let result = CollapsedEmailHistoryParser().parse(source: "",
                                                         body: body,
                                                         parentMessageID: "plain@example.com",
                                                         parentSubject: "Meeting notes")

        XCTAssertTrue(result.isEmpty)
    }

    func test_collapsedHistory_headerLabelsAcrossBodyBoundary_failClosed() {
        let body = """
        From: the project owner
        This is ordinary prose describing the owner field.

        Date: Wednesday, 19 August 2026 at 4:23 PM
        Subject: These labels belong to a later section
        """

        let result = CollapsedEmailHistoryParser().parse(source: "",
                                                         body: body,
                                                         parentMessageID: "plain@example.com",
                                                         parentSubject: "Project notes")

        XCTAssertTrue(result.isEmpty)
    }

    func test_collapsedHistory_noIDMessagesWithSameLongPrefix_remainDistinct() {
        let sharedPrefix = String(repeating: "A", count: 1_600)
        let body = """
        From: Alice Example <alice@example.com>
        Date: Wednesday, 19 August 2026 at 4:23 PM
        Subject: Repeated subject

        \(sharedPrefix) first ending

        -----Original Message-----
        From: Alice Example <alice@example.com>
        Date: Wednesday, 19 August 2026 at 4:23 PM
        Subject: Repeated subject

        \(sharedPrefix) second ending
        """

        let result = CollapsedEmailHistoryParser().parse(source: "",
                                                         body: body,
                                                         parentMessageID: "long-prefix@example.com",
                                                         parentSubject: "Fwd: Repeated subject")

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
        XCTAssertEqual(result[0].snippet, result[1].snippet,
                       "The visible snippets may match; full content must still preserve both emails")
    }

    func test_collapsedHistory_sameParentIDAcrossAccounts_usesDifferentLogicalIDs() {
        let body = """
        From: Alice Example <alice@example.com>
        Date: Wednesday, 19 August 2026 at 4:23 PM
        Subject: Prior decision

        The prior decision remains approved.
        """
        let parser = CollapsedEmailHistoryParser()

        let work = parser.parse(source: "",
                                body: body,
                                parentMessageID: "shared-parent@example.com",
                                parentAccountName: "Work",
                                parentSubject: "Fwd: Prior decision")
        let personal = parser.parse(source: "",
                                    body: body,
                                    parentMessageID: "shared-parent@example.com",
                                    parentAccountName: "Personal",
                                    parentSubject: "Fwd: Prior decision")

        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(personal.count, 1)
        XCTAssertNotEqual(work[0].id, personal[0].id)
    }

    func test_collapsedHistory_messageRFC822Part_extractsNestedEmail() {
        let nested = """
        Message-ID: <nested@example.com>
        From: Alice <alice@example.com>
        To: Team <team@example.com>
        Date: Tue, 18 Aug 2026 14:30:00 +0800
        Subject: Nested source
        Content-Type: text/plain; charset=utf-8

        Nested body text.
        """
        let encoded = Data(nested.utf8).base64EncodedString()
        let source = """
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: text/plain; charset=utf-8

        See attached message.
        --outer
        Content-Type: message/rfc822
        Content-Transfer-Encoding: base64

        \(encoded)
        --outer--
        """

        let result = CollapsedEmailHistoryParser().parse(source: source,
                                                         body: "",
                                                         parentMessageID: "container@example.com",
                                                         parentSubject: "Fwd: Nested source")

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].originalMessageID, "nested@example.com")
        XCTAssertEqual(result[0].subject, "Nested source")
        XCTAssertEqual(result[0].snippet, "Nested body text.")
    }

    func test_collapsedHistory_oversizedAttachmentAfterText_extractsBoundedConversation() {
        let source = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="oversized-boundary"

        --oversized-boundary
        Content-Type: text/plain; charset=utf-8

        FYI

        From: Alice Example <alice@example.com>
        Date: Tuesday, 18 August 2026 at 9:30 AM
        To: Team <team@example.com>
        Subject: Prior approval

        The prior approval remains valid.
        --oversized-boundary
        Content-Type: application/pdf
        Content-Transfer-Encoding: base64

        \(String(repeating: "A", count: 600_000))
        --oversized-boundary--
        """

        let messages = CollapsedEmailHistoryParser(decoder: decoder).parse(
            source: source,
            body: "",
            parentMessageID: "large-parent@example.com",
            parentSubject: "FW: Prior approval"
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.from, "Alice Example <alice@example.com>")
        XCTAssertEqual(messages.first?.subject, "Prior approval")
        XCTAssertEqual(messages.first?.snippet, "The prior approval remains valid.")
    }
}

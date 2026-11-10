import Foundation
import Testing
@testable import EmberRichText

@Suite("Link policy")
struct LinkPolicyTests {
    private func opens(_ string: String) -> Bool { LinkPolicy.opens(URL(string: string)!) }

    @Test func webMailAndPhoneAddressesOpen() {
        #expect(opens("https://example.com/a?b=1"))
        #expect(opens("http://example.com"))
        #expect(opens("mailto:ann@example.com"))
        #expect(opens("tel:+15551234567"))
    }

    @Test func theSchemeIsComparedWithoutCase() {
        #expect(opens("HTTPS://example.com/"))
        #expect(opens("MailTo:ann@example.com"))
    }

    @Test func otherSchemesAreRefused() {
        for address in ["ssh://host/x", "sftp://host/x", "sms:+15551234567", "file:///etc/hosts", "javascript:alert(1)", "data:text/plain,hi"] {
            #expect(!opens(address), "\(address)")
        }
    }

    @Test func aWebAddressWithoutAHostIsRefused() {
        #expect(!opens("http:///path"))
        #expect(!opens("https:"))
        #expect(!opens("https:/path"))
    }

    @Test func aRelativeAddressIsRefused() {
        #expect(!opens("/rooms/1"))
    }
}

import Foundation
import Testing
import EmberCore

/// Which scheme a bare address gets, which hosts count as local, and which need https.
@Suite struct ServerAddressDefaultsTests {
    @Test(arguments: [
        ("10.0.0.5:8787", "http://10.0.0.5:8787"),
        ("172.16.4.2", "http://172.16.4.2"),
        ("172.31.255.1:3000", "http://172.31.255.1:3000"),
        ("192.168.1.20:8787", "http://192.168.1.20:8787"),
        ("169.254.10.1", "http://169.254.10.1"),
        ("127.8.0.1", "http://127.8.0.1"),
        ("ember.local:8787", "http://ember.local:8787"),
        ("Ember.LOCAL", "http://ember.local"),
        ("172.32.0.1", "https://172.32.0.1"),
        ("172.15.0.1", "https://172.15.0.1"),
        ("8.8.8.8", "https://8.8.8.8"),
        ("10.example.com", "https://10.example.com"),
        ("192.168.1.example.com", "https://192.168.1.example.com"),
        ("local.example.com", "https://local.example.com"),
    ])
    func aBareAddressGetsTheSchemeItsNetworkUses(_ typed: String, _ expected: String) {
        #expect(ServerAddress.origin(from: typed)?.absoluteString == expected)
    }

    @Test(arguments: ["+10.0.0.1", "10.+0.0.1", "192.168.-0.1", "127.0.0.+1"])
    func aSignedPartIsNoIPv4Address(_ host: String) {
        #expect(!ServerAddress.isLocal(host))
    }

    @Test(arguments: [
        ("https://ember.example.com:443", "https://ember.example.com"),
        ("http://ember.example.com:80/", "http://ember.example.com"),
        ("192.168.1.20:80", "http://192.168.1.20"),
        ("ember.example.com:443", "https://ember.example.com"),
    ])
    func theSchemesOwnPortIsLeftOut(_ typed: String, _ expected: String) {
        #expect(ServerAddress.origin(from: typed)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("https://Chat.Example.COM:443/ember/?x=1#y", "https://chat.example.com"),
        ("HTTP://LocalHost:8787", "http://localhost:8787"),
        ("http://user:secret@chat.example.com:80", "http://chat.example.com"),
        ("https://chat.example.com:8443/", "https://chat.example.com:8443"),
    ])
    func anOriginNormalizesAsABrowserWritesIt(_ url: String, _ expected: String) throws {
        #expect(ServerAddress.normalizedOrigin(try #require(URL(string: url))).absoluteString == expected)
    }

    @Test(arguments: [
        ("http://ember.example.com", true),
        ("http://8.8.8.8:8787", true),
        ("https://ember.example.com", false),
        ("http://localhost:8787", false),
        ("http://192.168.1.20:8787", false),
        ("http://ember.local", false),
        ("http://nas", false),
        ("http://[::1]:8787", false),
    ])
    func plainHTTPToAPublicHostNeedsHTTPS(_ origin: String, _ needs: Bool) throws {
        #expect(ServerAddress.needsHTTPS(try #require(URL(string: origin))) == needs)
    }
}

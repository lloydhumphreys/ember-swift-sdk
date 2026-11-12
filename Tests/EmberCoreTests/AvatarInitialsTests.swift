import Testing
@testable import EmberCore

@Suite struct AvatarInitialsTests {
    @Test(arguments: [
        ("David Heinemeier Hansson", "DH"),
        ("Dirk van den Berg", "DB"),
        ("Auto User 7", "A7"),
        ("Gerrit Van den Berg 1", "G1"),
        ("Ada Lovelace", "AL"),
        ("grace", "g"),
        ("Élodie Ünal-Smith o'Brien 3po _x ñ", "S_"),
        ("日本 Tokyo", "T"),
        ("", ""),
    ])
    func atMostTwoAreTheFirstAndTheLast(_ name: String, _ expected: String) {
        #expect(AvatarStyle.initials(of: name, atMost: 2) == expected)
    }

    @Test func aNameWithNoneOfCampfiresHasItsFirstLetter() {
        #expect(AvatarStyle.initials(of: "Élodie", atMost: 2) == "É")
        #expect(AvatarStyle.initials(of: "日本", atMost: 2) == "日")
        #expect(AvatarStyle.initials(of: "🎉 !", atMost: 2) == "")
    }

    @Test func oneIsTheFirst() {
        #expect(AvatarStyle.initials(of: "David Heinemeier Hansson", atMost: 1) == "D")
        #expect(AvatarStyle.initials(of: "Ada", atMost: 0) == "")
    }
}

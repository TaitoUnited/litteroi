import Testing
@testable import LitteroiCore

private let names = NameList(parsing: """
    # Henkilöt ensin
    Matti Meikäläinen, Masa
    Pekka

    [asiakkaat]
    Esimerkki Oy
    """)

@Test func readsPeopleAndClientsFromTheNameList() {
    #expect(names.entries == [
        .init(kind: .person, forms: ["Matti Meikäläinen", "Masa"]),
        .init(kind: .person, forms: ["Pekka"]),
        .init(kind: .client, forms: ["Esimerkki Oy"]),
    ])
}

@Test func hidesInflectedNamesInOrderOfFirstMention() {
    let (text, key) = Pseudonymizer(names: names).pseudonymize(
        "Pekan mukaan Matti Meikäläisen tiimi vie Esimerkki Oy:lle demon. Kysy Matilta tai Masalta."
    )
    #expect(text == "Henkilö A:n mukaan Henkilö B:n tiimi vie Asiakas 1 Oy:lle demon. Kysy Henkilö B:lta tai Henkilö B:lta.")
    #expect(key.names == ["Henkilö A": "Pekka", "Henkilö B": "Matti Meikäläinen", "Asiakas 1": "Esimerkki Oy"])
}

@Test func leavesLowerCaseWordsAndOtherCapitalisedWordsAlone() {
    let text = "Matkalla pekka sanoi, että Pekkarinen ja Mattila tulevat."
    #expect(Pseudonymizer(names: names).pseudonymize(text).text == "Matkalla pekka sanoi, että Pekkarinen ja Henkilö A:la tulevat.")
}

@Test func restoresTheWordsAsWrittenAndNamesNewForms() {
    let original = "Kysy Matilta, Matti tietää."
    let (hidden, key) = Pseudonymizer(names: names).pseudonymize(original)
    #expect(Pseudonymizer.restore(hidden, with: key) == original)
    #expect(Pseudonymizer.restore("Henkilö A:lle ja Henkilö Z.", with: key) == "Matti Meikäläinen:lle ja Henkilö Z.")
}

@Test func namesPeopleWithLettersPastZ() {
    #expect(Pseudonymizer.letters(0) == "A")
    #expect(Pseudonymizer.letters(25) == "Z")
    #expect(Pseudonymizer.letters(26) == "AA")
}

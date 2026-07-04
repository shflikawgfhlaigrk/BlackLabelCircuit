class User {
    var thing: Thing?
    func load() {
        let t = try! JSONDecoder().decode(Thing.self, from: Data())
        thing = t
    }
}

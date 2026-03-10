import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output machine-readable JSON when supported")
    var json = false

    @Flag(name: .long, help: "Disable colors and emoji output")
    var noColor = false
}

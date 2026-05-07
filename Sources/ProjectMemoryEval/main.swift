import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

func printHelp() {
    print(
        """
        ProjectMemoryEval

        Usage:
          swift run ProjectMemoryEval --help
          swift run ProjectMemoryEval --fixture <path>     # Phase 2
          swift run ProjectMemoryEval --dev-set            # Phase 2
          swift run ProjectMemoryEval --diff <a> <b>       # Phase 2

        Phase 1 only provides the CLI skeleton and shared mechanical assertions.
        """
    )
}

if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    printHelp()
} else if arguments.contains("--fixture")
    || arguments.contains("--dev-set")
    || arguments.contains("--diff") {
    print("ProjectMemoryEval runner is Phase 2.")
    exit(2)
} else {
    print("Unknown arguments: \(arguments.joined(separator: " "))")
    printHelp()
    exit(64)
}

import Foundation
import RashunCore

let args = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    Usage: rashun [source] [--json]

    Commands:
      rashun                List all available sources
      rashun <source>       Show usage for a specific source
      rashun --json         Show usage for all sources in JSON format
      rashun <source> --json
                            Show usage for a specific source in JSON format
      rashun --help         Show this help message
    """)
}

func findSource(named name: String) -> (any AISource)? {
    allSources.first { $0.name.lowercased() == name.lowercased() }
}

func fetchAndPrintHuman(_ source: any AISource) async {
    let metrics = source.metrics
    if metrics.count == 1 {
        let metric = metrics[0]
        do {
            let result = try await source.fetchUsage(for: metric.id)
            let pct = Int(result.percentRemaining.rounded())
            print("\(source.name): \(pct)% remaining")
        } catch {
            FileHandle.standardError.write(Data("Error fetching \(source.name): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    } else {
        print("\(source.name):")
        for metric in metrics {
            do {
                let result = try await source.fetchUsage(for: metric.id)
                let pct = Int(result.percentRemaining.rounded())
                print("  \(metric.title): \(pct)% remaining")
            } catch {
                FileHandle.standardError.write(Data("Error fetching \(source.name) \(metric.title): \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}

struct MetricJSON: Encodable {
    let id: String
    let title: String
    let percentRemaining: Double
    let remaining: Double
    let limit: Double
}

struct SourceJSON: Encodable {
    let source: String
    let metrics: [MetricJSON]
}

func fetchJSON(_ source: any AISource) async -> SourceJSON {
    var metricResults: [MetricJSON] = []
    for metric in source.metrics {
        do {
            let result = try await source.fetchUsage(for: metric.id)
            metricResults.append(MetricJSON(
                id: metric.id,
                title: metric.title,
                percentRemaining: (result.percentRemaining * 10).rounded() / 10,
                remaining: result.remaining,
                limit: result.limit
            ))
        } catch {
            FileHandle.standardError.write(Data("Error fetching \(source.name) \(metric.title): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    return SourceJSON(source: source.name, metrics: metricResults)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("Failed to encode JSON\n".utf8))
        exit(1)
    }
    print(str)
}

// -- Main logic --

if args.contains("--help") || args.contains("-h") {
    printUsage()
    exit(0)
}

let jsonFlag = args.contains("--json")
let positional = args.filter { $0 != "--json" }

if positional.isEmpty && !jsonFlag {
    // List all sources
    print("Available sources:")
    for source in allSources {
        let metricNames = source.metrics.map { $0.title }.joined(separator: ", ")
        print("  \(source.name) (\(metricNames))")
    }
    exit(0)
}

if positional.isEmpty && jsonFlag {
    // JSON for all sources
    var results: [SourceJSON] = []
    for source in allSources {
        let result = await fetchJSON(source)
        results.append(result)
    }
    printJSON(results)
    exit(0)
}

if let sourceName = positional.first {
    guard let source = findSource(named: sourceName) else {
        FileHandle.standardError.write(Data("Unknown source: \(sourceName)\n".utf8))
        FileHandle.standardError.write(Data("Available sources: \(allSources.map { $0.name }.joined(separator: ", "))\n".utf8))
        exit(1)
    }

    if jsonFlag {
        let result = await fetchJSON(source)
        printJSON(result)
    } else {
        await fetchAndPrintHuman(source)
    }
    exit(0)
}

import Foundation
import SDImportCore

@main
struct SDImportCLI {
    static func main() throws {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("sdimport: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            return
        }

        let command = arguments.removeFirst()
        if command == "-h" || command == "--help" || command == "help" {
            printUsage()
            return
        }

        let databaseURL = try optionURL("--db", in: arguments)
            ?? DatabasePoolFactory.defaultDatabaseURL()
        let pool = try DatabasePoolFactory(databaseURL: databaseURL).makeMigratedPool()
        let jobRepository = JobRepository(pool: pool)
        let dedupeRepository = DedupeRepository(pool: pool)

        switch command {
        case "scan":
            let inputURL = try requiredURL("--input", in: arguments)
            let photosURL = try requiredURL("--photos-root", in: arguments)
            let videosURL = try requiredURL("--videos-root", in: arguments)
            let location = option("--location", in: arguments) ?? "TODO"
            let reportsURL = try optionURL("--reports-dir", in: arguments)
            let jobID = option("--job-id", in: arguments) ?? JobID.make()
            let scanner = MediaScanner(
                jobRepository: jobRepository,
                dedupeRepository: dedupeRepository
            )
            let summary = try scanner.scan(
                ScanRequest(
                    mountURL: inputURL,
                    volumeName: inputURL.lastPathComponent,
                    location: location,
                    roots: DestinationRoots(photosURL: photosURL, videosURL: videosURL),
                    reportsDirectoryURL: reportsURL,
                    jobID: jobID
                )
            )
            try printJSON(summary)

        case "import", "retry":
            let jobID = try required("--job-id", in: arguments)
            let engine = ImportEngine(
                jobRepository: jobRepository,
                dedupeRepository: dedupeRepository
            )
            let result = try engine.importFiles(jobID: jobID)
            try printJSON(result)

        case "list-jobs":
            let limit = Int(option("--limit", in: arguments) ?? "50") ?? 50
            let jobs = try jobRepository.listJobs(limit: limit)
            try printJSON(jobs)

        case "show-job":
            let jobID = try required("--job-id", in: arguments)
            guard let job = try jobRepository.fetchJob(id: jobID) else {
                throw SDImportError.jobNotFound(jobID)
            }
            let files = try jobRepository.fetchJobFiles(jobID: jobID)
            try printJSON(JobDetail(job: job, files: files))

        case "prune":
            let retention = try retentionPolicy(from: required("--retention", in: arguments))
            let dryRun = arguments.contains("--dry-run")
            let summary = try HistoryRetentionService(pool: pool).prune(policy: retention, dryRun: dryRun)
            try printJSON(summary)

        default:
            throw SDImportError.invalidArgument("unknown command: \(command)")
        }
    }

    private static func printUsage() {
        print(
            """
            Usage:
              sdimport scan --input PATH --photos-root PATH --videos-root PATH [--location LABEL] [--reports-dir PATH] [--db PATH]
              sdimport import --job-id JOB_ID [--db PATH]
              sdimport retry --job-id JOB_ID [--db PATH]
              sdimport list-jobs [--limit N] [--db PATH]
              sdimport show-job --job-id JOB_ID [--db PATH]
              sdimport prune --retention 30|90|365|forever [--dry-run] [--db PATH]
            """
        )
    }

    private static func required(_ flag: String, in arguments: [String]) throws -> String {
        guard let value = option(flag, in: arguments) else {
            throw SDImportError.invalidArgument("missing \(flag)")
        }
        return value
    }

    private static func option(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }

    private static func requiredURL(_ flag: String, in arguments: [String]) throws -> URL {
        URL(fileURLWithPath: try required(flag, in: arguments).expandingTildeInPath)
    }

    private static func optionURL(_ flag: String, in arguments: [String]) throws -> URL? {
        guard let value = option(flag, in: arguments) else {
            return nil
        }
        return URL(fileURLWithPath: value.expandingTildeInPath)
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func retentionPolicy(from value: String) throws -> RetentionPolicy {
        switch value.lowercased() {
        case "30":
            return .days(30)
        case "90":
            return .days(90)
        case "365":
            return .days(365)
        case "forever":
            return .forever
        default:
            throw SDImportError.invalidArgument("invalid retention: \(value)")
        }
    }
}

private struct JobDetail: Encodable {
    let job: ImportJob
    let files: [JobFileRecord]
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

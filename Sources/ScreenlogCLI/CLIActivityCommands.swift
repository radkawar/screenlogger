import Foundation
import ScreenlogCore

extension ScreenlogCLIMain {
    static let usageHelp = """
        Usage:
          screenlog usage time [--since DATE|30d] [--before DATE] [--json]
          screenlog usage coverage [--since DATE|30d] [--before DATE] [--gap MIN] [--json]
          screenlog usage top-applications [--since DATE|30d] [--before DATE] [--limit N] [--json]
          screenlog usage top-domains [--since DATE|30d] [--before DATE] [--limit N] [--json]
          screenlog usage sessions [--since DATE|30d] [--before DATE] [--gap MIN] [--json]

        Date bounds are half-open: since is included and before is excluded.
        Relative bounds such as 30d, 12h, and 2w are measured back from now.
        """

    static let digestHelp = """
        Usage:
          screenlog digest [--since DATE|30d] [--before DATE] [--gap MIN]
                           [--limit N] [--sample-limit N] [--json]

        Produces coverage, active days, approximate recorded time, top apps and
        domains, sessions, and bounded representative OCR snippets. Use --json
        when an assistant will synthesize the narrative.

        Example:
          screenlog digest --since 30d --before now --json
        """

    static func usageHelp(for subcommand: String?) -> String {
        switch subcommand {
        case "time":
            return """
                Usage: screenlog usage time [--since DATE|30d] [--before DATE] [--json]

                Reports observed coverage, capture span, moment count, and active days.
                Example: screenlog usage time --since 7d --json
                """
        case "coverage":
            return """
                Usage: screenlog usage coverage [--since DATE|30d] [--before DATE]
                                                [--gap MIN] [--json]

                Reports the observed range and threshold-defined session breaks.
                Example: screenlog usage coverage --since 2026-08-01 --before 2026-09-01 --json
                """
        case "top-applications", "top-apps":
            return """
                Usage: screenlog usage top-applications [--since DATE|30d] [--before DATE]
                                                        [--limit N] [--json]

                Counts captured moments per application. Shares may overlap across displays.
                Example: screenlog usage top-applications --since 30d --limit 20 --json
                """
        case "top-domains":
            return """
                Usage: screenlog usage top-domains [--since DATE|30d] [--before DATE]
                                                   [--limit N] [--json]

                Counts captured browser moments per domain.
                Example: screenlog usage top-domains --since 30d --json
                """
        case "sessions":
            return """
                Usage: screenlog usage sessions [--since DATE|30d] [--before DATE]
                                                [--gap MIN] [--json]

                Lists local timestamps, wall-clock duration, and captured moment count.
                Example: screenlog usage sessions --since 7d --gap 10 --json
                """
        default:
            return usageHelp
        }
    }

    static func usage(_ args: [String], client: ScreenlogXPCClient) throws {
        guard let sub = args.first else {
            print(usageHelp)
            return
        }
        if isHelpArgument(sub) {
            print(usageHelp)
            return
        }
        let rest = Array(args.dropFirst())
        if rest.contains(where: isHelpArgument) {
            print(usageHelp(for: sub))
            return
        }
        let bounds = try activityBounds(rest)
        let json = rest.contains("--json")

        switch sub {
        case "time":
            let stats = try client.stats(
                fromTimestampMs: bounds.sinceMs,
                toTimestampMs: bounds.beforeMs
            )
            let sessions = try client.sessions(
                fromTimestampMs: bounds.sinceMs,
                toTimestampMs: bounds.beforeMs
            )
            let document = usageTimeDocument(bounds: bounds, stats: stats, sessions: sessions)
            if json {
                print(try CLIOutputFormat.json(document))
            } else {
                printCoverage(document.range)
                print("capture_span: \(CLIOutputFormat.duration(seconds: document.captureSpanSeconds))")
                print("moments: \(document.momentCount)")
                print("physical_frames: \(document.physicalFrameCount)")
                print("active_days: \(document.range.activeDays)")
            }
        case "coverage":
            let gap = try intFlag(rest, name: "--gap", allowed: 1...10_080) ?? 5
            let stats = try client.stats(
                fromTimestampMs: bounds.sinceMs,
                toTimestampMs: bounds.beforeMs
            )
            let sessions = try client.sessions(
                gapMinutes: gap,
                fromTimestampMs: bounds.sinceMs,
                toTimestampMs: bounds.beforeMs
            )
            let document = usageTimeDocument(bounds: bounds, stats: stats, sessions: sessions)
            if json {
                print(try CLIOutputFormat.json(document))
            } else {
                printCoverage(document.range)
                print("active_days: \(document.range.activeDays)")
                print("sessions: \(document.range.sessionCount)")
                print("session_breaks: \(document.range.sessionBreakCount)")
                print("capture_span: \(CLIOutputFormat.duration(seconds: document.captureSpanSeconds))")
            }
        case "top-applications", "top-apps":
            try printTopUsage(rest, bounds: bounds, kind: .applications, json: json, client: client)
        case "top-domains":
            try printTopUsage(rest, bounds: bounds, kind: .domains, json: json, client: client)
        case "sessions":
            let gap = try intFlag(rest, name: "--gap", allowed: 1...10_080) ?? 5
            let sessions = try client.sessions(
                gapMinutes: gap,
                fromTimestampMs: bounds.sinceMs,
                toTimestampMs: bounds.beforeMs
            )
            let documents = sessions.map(CLISessionDocument.init)
            if json {
                print(try CLIOutputFormat.json(documents))
            } else if documents.isEmpty {
                print("No sessions in the requested range.")
            } else {
                for session in documents {
                    let app = session.startingDisplayName ?? session.startingBundleID ?? "Unknown app"
                    print(
                        "\(session.start)  \(CLIOutputFormat.duration(seconds: session.durationSeconds))"
                            + "  \(session.momentCount) moments  \(app)"
                    )
                }
            }
        default:
            throw CLIError.unknown("usage \(sub)")
        }
    }

    static func digest(_ args: [String], client: ScreenlogXPCClient) throws {
        if args.contains(where: isHelpArgument) {
            print(digestHelp)
            return
        }
        let bounds = try activityBounds(args)
        let gap = try intFlag(args, name: "--gap", allowed: 1...10_080) ?? 5
        let limit = try intFlag(args, name: "--limit", allowed: 1...100) ?? 10
        let sampleLimit = try intFlag(args, name: "--sample-limit", allowed: 1...100) ?? 24
        let stats = try client.stats(
            fromTimestampMs: bounds.sinceMs,
            toTimestampMs: bounds.beforeMs
        )
        let sessions = try client.sessions(
            gapMinutes: gap,
            fromTimestampMs: bounds.sinceMs,
            toTimestampMs: bounds.beforeMs
        )
        let applications = try client.topApplications(
            limit: limit,
            fromTimestampMs: bounds.sinceMs,
            toTimestampMs: bounds.beforeMs
        )
        let domains = try client.topDomains(
            limit: limit,
            fromTimestampMs: bounds.sinceMs,
            toTimestampMs: bounds.beforeMs
        )
        let samples = try client.sample(
            limit: sampleLimit,
            minSegLen: 10,
            fromTimestampMs: bounds.sinceMs,
            toTimestampMs: bounds.beforeMs,
            order: .oldest
        )
        let range = CLIActivityRangeDocument(bounds: bounds, stats: stats, sessions: sessions)
        let document = CLIDigestDocument(
            range: range,
            momentCount: stats.momentCount,
            captureSpanSeconds: captureSpanSeconds(sessions),
            topApplications: applications.map {
                CLIUsageItemDocument(item: $0, totalMoments: stats.momentCount)
            },
            topDomains: domains.map {
                CLIUsageItemDocument(item: $0, totalMoments: stats.momentCount)
            },
            sessions: sessions.map(CLISessionDocument.init),
            representativeFrames: samples.map {
                CLIFrameDocument(frame: $0, maximumOCRCharacters: 240)
            },
            interpretationNotes: [
                "Capture span is the sum of session wall-clock spans, not active attention or project time.",
                "Application and domain shares can overlap when several displays are captured at once.",
                "Visible or audible content is evidence of exposure, not proof that the user authored it.",
            ]
        )

        if args.contains("--json") {
            print(try CLIOutputFormat.json(document))
        } else {
            printCoverage(range)
            print("capture_span: \(CLIOutputFormat.duration(seconds: document.captureSpanSeconds))")
            print("active_days: \(range.activeDays)  sessions: \(range.sessionCount)")
            print("top applications:")
            for item in document.topApplications {
                print("  \(percentage(item.shareOfRecordedMoments))  \(item.displayName ?? item.identifier)")
            }
            if !document.topDomains.isEmpty {
                print("top domains:")
                for item in document.topDomains {
                    print("  \(percentage(item.shareOfRecordedMoments))  \(item.identifier)")
                }
            }
            print("representative frame ids: \(document.representativeFrames.map { String($0.id) }.joined(separator: ","))")
            print("hint: rerun with --json for bounded evidence and machine-readable timestamps")
        }
    }

    static func list(_ args: [String], client: ScreenlogXPCClient) throws {
        if args.contains(where: isHelpArgument) || args.isEmpty {
            print("Usage: screenlog list applications|domains")
            return
        }
        switch args.first {
        case "applications", "apps":
            for a in try client.listApplications() {
                print("\(a.bundleID)\t\(a.displayName ?? "")")
            }
        case "domains":
            for d in try client.listDomains() {
                print(d.normalizedDomain)
            }
        default:
            throw CLIError.usage("list applications|domains")
        }
    }

    static func record(_ args: [String], client: ScreenlogXPCClient) throws {
        if args.contains(where: isHelpArgument) || args.isEmpty {
            print("Usage: screenlog record start|stop|once")
            return
        }
        switch args.first {
        case "start":
            try client.startRecording()
            print("recording started")
        case "stop":
            try client.stopRecording()
            print("recording stopped")
        case "once":
            let id = try client.captureOnce()
            print("frame_id=\(id)")
        default:
            throw CLIError.usage("record start|stop|once")
        }
    }

    private enum TopUsageKind {
        case applications
        case domains
    }

    private static func printTopUsage(
        _ args: [String],
        bounds: ActivityBounds,
        kind: TopUsageKind,
        json: Bool,
        client: ScreenlogXPCClient
    ) throws {
        let limit = try intFlag(args, name: "--limit", allowed: 1...500) ?? 20
        let stats = try client.stats(
            fromTimestampMs: bounds.sinceMs,
            toTimestampMs: bounds.beforeMs
        )
        let sessions = try client.sessions(
            fromTimestampMs: bounds.sinceMs,
            toTimestampMs: bounds.beforeMs
        )
        let items =
            switch kind {
            case .applications:
                try client.topApplications(
                    limit: limit,
                    fromTimestampMs: bounds.sinceMs,
                    toTimestampMs: bounds.beforeMs
                )
            case .domains:
                try client.topDomains(
                    limit: limit,
                    fromTimestampMs: bounds.sinceMs,
                    toTimestampMs: bounds.beforeMs
                )
            }
        let document = CLIUsageTopDocument(
            range: CLIActivityRangeDocument(bounds: bounds, stats: stats, sessions: sessions),
            items: items.map { CLIUsageItemDocument(item: $0, totalMoments: stats.momentCount) }
        )
        if json {
            print(try CLIOutputFormat.json(document))
        } else if document.items.isEmpty {
            print("No activity in the requested range.")
        } else {
            for item in document.items {
                let label = item.displayName ?? item.identifier
                print(
                    "\(percentage(item.shareOfRecordedMoments))  "
                        + "\(item.momentCount) moments  \(label)  \(item.identifier)"
                )
            }
            print("note: shares can overlap when several displays are captured at once")
        }
    }

    private static func usageTimeDocument(
        bounds: ActivityBounds,
        stats: RecordingStats,
        sessions: [SessionRow]
    ) -> CLIUsageTimeDocument {
        CLIUsageTimeDocument(
            range: CLIActivityRangeDocument(bounds: bounds, stats: stats, sessions: sessions),
            physicalFrameCount: stats.totalFrames,
            momentCount: stats.momentCount,
            captureSpanSeconds: captureSpanSeconds(sessions),
            unfinalizedMomentCount: stats.unfinalizedMomentCount
        )
    }

    private static func printCoverage(_ range: CLIActivityRangeDocument) {
        guard let first = range.firstRecordedMs, let last = range.lastRecordedMs else {
            print("coverage: no recorded activity in the requested range")
            return
        }
        print("coverage: \(CLIOutputFormat.localISO(first)) to \(CLIOutputFormat.localISO(last))")
    }

    private static func captureSpanSeconds(_ sessions: [SessionRow]) -> Int64 {
        sessions.reduce(0) { total, session in
            total + max(session.frameCount > 0 ? 1 : 0, session.durationMs / 1000)
        }
    }

    private static func percentage(_ fraction: Double) -> String {
        String(format: "%5.1f%%", fraction * 100)
    }

    static func isHelpArgument(_ argument: String) -> Bool {
        argument == "--help" || argument == "-h"
    }
}

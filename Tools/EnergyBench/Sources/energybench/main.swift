import Foundation
import StrandAnalytics

// energybench — replay local days through the previous and the new energy estimator and compare.
//
//   energybench --days DIR [--only 2026-10-01,2026-10-02] [--rmr 1850]
//               [--report out.md] [--json out.json]
//               [--timeline 2026-10-02@21:30-22:55] [--csv-day 2026-10-02 --csv out.csv]
//               [--min-bout 10] [--cadence 80] [--dyn 0.15] [--light-pal 1.55]
//
// DIR holds `energy-bench-day-v1` bundles (README.md). It is never inside this repository, and nothing
// is written back to it. Exit status: 0 = every applicable check passed, 1 = a check failed, 2 = usage / IO.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: energybench --days DIR [--only DAY[,DAY…]] [--rmr KCAL_PER_DAY]
                       [--report FILE.md] [--json FILE.json]
                       [--timeline DAY@HH:MM-HH:MM] [--csv-day DAY --csv FILE.csv]
                       [--min-bout MIN] [--cadence TICKS_PER_MIN] [--dyn G] [--light-pal X]

    """.utf8))
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("energybench: \(message)\n".utf8))
    exit(2)
}

var daysDir: String?
var only: Set<String> = []
var reportPath: String?
var jsonPath: String?
var timelineSpec: String?
var csvDay: String?
var csvPath: String?
var options = BenchOptions()

var args = Array(CommandLine.arguments.dropFirst())
func next(_ flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) needs a value") }
    return args.removeFirst()
}
func number(_ flag: String) -> Double {
    guard let v = Double(next(flag)) else { fail("\(flag) needs a number") }
    return v
}
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--days": daysDir = next(flag)
    case "--only": only = Set(next(flag).split(separator: ",").map(String.init))
    case "--rmr": options.measuredRmr = number(flag)
    case "--report": reportPath = next(flag)
    case "--json": jsonPath = next(flag)
    case "--timeline": timelineSpec = next(flag)
    case "--csv-day": csvDay = next(flag)
    case "--csv": csvPath = next(flag)
    case "--min-bout": options.minBoutMinutes = Int(number(flag))
    case "--cadence": options.cadenceMoving = number(flag)
    case "--dyn": options.dynMoving = number(flag)
    case "--light-pal": options.lightDayMaxPAL = number(flag)
    case "-h", "--help": usage()
    default: fail("unknown argument \(flag)")
    }
}
guard let daysDir else { usage() }

let dirURL = URL(fileURLWithPath: daysDir, isDirectory: true)
let files: [URL]
do {
    files = try FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} catch {
    fail("cannot read \(daysDir): \(error.localizedDescription)")
}

var runs: [DayRun] = []
for url in files {
    let bundle: DayBundle
    do { bundle = try DayBundle.load(url) } catch {
        FileHandle.standardError.write(Data("energybench: skipping \(url.lastPathComponent): \(error)\n".utf8))
        continue
    }
    if !only.isEmpty && !only.contains(bundle.day) { continue }
    do {
        runs.append(try Bench.run(bundle, options: options))
    } catch {
        FileHandle.standardError.write(Data("energybench: \(bundle.day): \(error)\n".utf8))
    }
}
guard !runs.isEmpty else { fail("no usable day bundles in \(daysDir)") }

let checks = Checks.evaluate(runs, options: options)
let markdown = Report.markdown(runs: runs, checks: checks, options: options)
print(markdown)

if let reportPath {
    do { try markdown.write(toFile: reportPath, atomically: true, encoding: .utf8) } catch { fail("cannot write \(reportPath)") }
}
if let jsonPath {
    do { try Report.json(runs: runs, checks: checks, options: options).write(to: URL(fileURLWithPath: jsonPath)) }
    catch { fail("cannot write \(jsonPath): \(error)") }
}
if let timelineSpec {
    let parts = timelineSpec.split(separator: "@", maxSplits: 1).map(String.init)
    guard let run = runs.first(where: { $0.day == parts[0] }) else { fail("--timeline: no such day \(parts[0])") }
    var from = 0, to = run.signals.count
    if parts.count == 2 {
        let span = parts[1].split(separator: "-").map(String.init)
        func minutes(_ hhmm: String) -> Int? {
            let p = hhmm.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? p[0] * 60 + p[1] : nil
        }
        guard span.count == 2, let a = minutes(span[0]), let b = minutes(span[1]) else {
            fail("--timeline wants DAY@HH:MM-HH:MM")
        }
        from = a; to = b
    }
    print("\n## Timeline \(run.day)\n")
    print(Report.timeline(run: run, fromMinute: from, toMinute: to))
}
if let csvDay {
    guard let csvPath else { fail("--csv-day needs --csv FILE") }
    guard let run = runs.first(where: { $0.day == csvDay }) else { fail("--csv-day: no such day \(csvDay)") }
    do { try Report.timelineCSV(run: run).write(toFile: csvPath, atomically: true, encoding: .utf8) } catch { fail("cannot write \(csvPath)") }
}

exit(Checks.allPassed(checks) ? 0 : 1)

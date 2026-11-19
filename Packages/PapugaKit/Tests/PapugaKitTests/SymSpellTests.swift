import XCTest
@testable import PapugaKit

final class SymSpellTests: XCTestCase {

    private func bench(_ s: String) { print("BENCH| \(s)") }

    private func sample() -> SymSpell {
        let s = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 7)
        s.load([
            ("hello", 100), ("help", 80), ("hell", 50), ("shell", 30),
            ("world", 90), ("word", 40), ("work", 20), ("привіт", 70), ("привид", 25),
        ])
        return s
    }

    func test_damerauLevenshtein_handlesTranspositionAndEdits() {
        func dl(_ a: String, _ b: String) -> Int {
            SymSpell.damerauLevenshtein(Array(a), Array(b))
        }
        XCTAssertEqual(dl("hello", "hello"), 0)
        XCTAssertEqual(dl("helo", "hello"), 1)   // one insertion
        XCTAssertEqual(dl("wrold", "world"), 1)  // adjacent transposition (Damerau)
        XCTAssertEqual(dl("abc", "abd"), 1)      // one substitution
        XCTAssertEqual(dl("", "abc"), 3)
    }

    func test_lookup_ranksByDistanceThenFrequency() {
        let s = sample()
        let r = s.lookup("helo", maxEditDistance: 2, max: 5)
        XCTAssertFalse(r.isEmpty)
        // hello (d1, freq100) beats hell (d1, freq50); both beat the d2 options.
        XCTAssertEqual(r.first?.term, "hello")
        XCTAssertEqual(r.first?.distance, 1)
        XCTAssertTrue(r.contains { $0.term == "hell" && $0.distance == 1 })
    }

    func test_lookup_catchesTransposition() {
        let r = sample().lookup("wrold", maxEditDistance: 2, max: 3)
        XCTAssertEqual(r.first?.term, "world")
        XCTAssertEqual(r.first?.distance, 1)
    }

    func test_lookup_exactMatchIsDistanceZero() {
        let r = sample().lookup("hello", maxEditDistance: 2)
        XCTAssertEqual(r.first, SymSpell.Suggestion(term: "hello", distance: 0, count: 100))
    }

    func test_lookup_worksForCyrillic() {
        let r = sample().lookup("привт", maxEditDistance: 2, max: 3) // missing и
        XCTAssertTrue(r.contains { $0.term == "привіт" }, "got \(r.map(\.term))")
    }

    func test_lookup_returnsEmptyForFarInput() {
        XCTAssertTrue(sample().lookup("xyzzyx", maxEditDistance: 2).isEmpty)
    }

    // MARK: - Perf (gated): the ~µs/word promise

    func test_bench_lookupThroughput() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PAPUGA_BENCH"] == "1",
                          "set PAPUGA_BENCH=1 to run perf benchmarks")
        let s = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 7)
        // 20k varied deterministic pseudo-words (LCG → realistic spread, not the
        // pathological base-26-sequential collisions).
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
        var entries: [(String, Int)] = []
        var seen = Set<String>()
        while entries.count < 20_000 {
            let len = 4 + Int(next() % 6) // 4…9
            var w = ""
            for _ in 0..<len { w.append(alphabet[Int(next() % 26)]) }
            if seen.insert(w).inserted { entries.append((w, Int(next() % 50) + 1)) }
        }
        let t0 = DispatchTime.now()
        s.load(entries)
        let buildMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        bench("SymSpell build: \(s.wordCount) words, \(s.deleteEntryCount) delete keys, \(Int(buildMs)) ms")

        // Lookup typos of known words (substitute the last character).
        let probes = entries.prefix(2000).map { word -> String in
            let chars = Array(word.0)
            guard let last = chars.last else { return word.0 }
            let replacement = alphabet[(Int(last.asciiValue ?? 97) + 1) % 26]
            return String(chars.dropLast()) + String(replacement)
        }
        let t1 = DispatchTime.now()
        var hits = 0
        for p in probes { if !s.lookup(p, maxEditDistance: 2, max: 3).isEmpty { hits += 1 } }
        let totalUs = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1_000
        bench(String(format: "SymSpell lookup: %d probes, %.1f µs/word avg, %d hits",
                     probes.count, totalUs / Double(probes.count), hits))
        XCTAssertLessThan(totalUs / Double(probes.count), 1500) // well under NSSpellChecker's ~5000 µs
    }
}

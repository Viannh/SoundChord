import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import CSoundChordDSP
import Foundation
import os

// MARK: - Chord Models

public enum ChordQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case major
    case minor
    case dominant7
    case major7
    case minor7

    public var symbol: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .dominant7: return "7"
        case .major7: return "maj7"
        case .minor7: return "m7"
        }
    }

    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        }
    }
}

public struct GuitarChordDiagram: Sendable, Hashable {
    /// 6 strings from low E (index 0) to high e (index 5):
    /// `-1` = muted (`x`), `0` = open (`o`), `>= 1` = absolute fret number.
    public let frets: [Int]
    /// 6 finger assignments (`0` = open/muted, `1...4` = index..pinky).
    public let fingers: [Int]
    /// First displayed fret on the fretboard window (`>= 1`).
    public let baseFret: Int
    /// Optional absolute fret number where finger 1 forms a barre.
    public let barreFret: Int?

    public init(
        frets: [Int],
        fingers: [Int],
        baseFret: Int = 1,
        barreFret: Int? = nil
    ) {
        self.frets = frets
        self.fingers = fingers
        self.baseFret = max(1, baseFret)
        self.barreFret = barreFret
    }
}

public struct DetectedChord: Codable, Sendable, Hashable {
    public let root: Int
    public let quality: ChordQuality
    public let confidence: Double
    public let timestamp: TimeInterval

    public static let noteNames: [String] = [
        "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"
    ]

    public init(
        root: Int,
        quality: ChordQuality,
        confidence: Double,
        timestamp: TimeInterval = 0
    ) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
        self.confidence = max(0.0, min(1.0, confidence))
        self.timestamp = timestamp
    }

    public func transposed(by semitones: Int) -> DetectedChord {
        let shifted = ((root + semitones) % 12 + 12) % 12
        return DetectedChord(
            root: shifted,
            quality: quality,
            confidence: confidence,
            timestamp: timestamp
        )
    }

    public var rootName: String {
        Self.noteNames[((root % 12) + 12) % 12]
    }

    public var displayName: String {
        rootName + quality.symbol
    }

    public var noteIndices: [Int] {
        let r = ((root % 12) + 12) % 12
        return quality.intervals.map { (r + $0) % 12 }
    }

    public var noteNamesList: [String] {
        noteIndices.map { Self.noteNames[$0] }
    }

    public var guitarDiagram: GuitarChordDiagram {
        GuitarChordLibrary.diagram(root: root, quality: quality)
    }
}

public struct ChordHistoryEntry: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let chord: DetectedChord
    public let timestamp: TimeInterval

    public init(id: UUID = UUID(), chord: DetectedChord, timestamp: TimeInterval) {
        self.id = id
        self.chord = chord
        self.timestamp = timestamp
    }
}

public struct ChordAnalysisSnapshot: Sendable, Hashable {
    public let chord: DetectedChord?
    public let chroma: [Float]
    public let detectedKey: String?
    public let rms: Float
    public let isSilent: Bool

    public init(
        chord: DetectedChord?,
        chroma: [Float],
        detectedKey: String?,
        rms: Float = 0,
        isSilent: Bool = false
    ) {
        self.chord = chord
        self.chroma = chroma
        self.detectedKey = detectedKey
        self.rms = rms
        self.isSilent = isSilent
    }
}

// MARK: - Offline Chord Timeline & Lyrics-Chord Alignment Models

public struct TimedChordSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let chord: DetectedChord
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public var duration: TimeInterval {
        max(0, endTime - startTime)
    }

    public init(
        id: UUID = UUID(),
        chord: DetectedChord,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.chord = chord
        let safeStart = max(0, startTime)
        self.startTime = safeStart
        self.endTime = max(safeStart, endTime)
    }
}

public struct BeatChordCell: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let barIndex: Int
    public let beatIndex: Int
    public let chord: DetectedChord?
    public let isChordChange: Bool
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(
        id: UUID = UUID(),
        barIndex: Int,
        beatIndex: Int,
        chord: DetectedChord?,
        isChordChange: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.barIndex = barIndex
        self.beatIndex = beatIndex
        self.chord = chord
        self.isChordChange = isChordChange
        let safeStart = max(0, startTime)
        self.startTime = safeStart
        self.endTime = max(safeStart, endTime)
    }
}

public enum SongSectionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case intro
    case verse
    case preChorus
    case chorus
    case bridge
    case outro

    public var displayTitle: String {
        switch self {
        case .intro: return "Intro"
        case .verse: return "Verse"
        case .preChorus: return "Pre-Chorus"
        case .chorus: return "Chorus"
        case .bridge: return "Bridge"
        case .outro: return "Outro"
        }
    }
}

public struct SongSection: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: SongSectionKind
    public let label: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(
        id: UUID = UUID(),
        kind: SongSectionKind,
        label: String? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.kind = kind
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = (trimmed?.isEmpty == false) ? trimmed! : kind.displayTitle
        let safeStart = max(0, startTime)
        self.startTime = safeStart
        self.endTime = max(safeStart, endTime)
    }
}

public struct TrackChordTimeline: Codable, Hashable, Sendable {
    public let trackId: String
    public let key: String?
    public let bpm: Double?
    public let simpleMode: Bool
    public let duration: TimeInterval
    public let segments: [TimedChordSegment]
    public let beats: [BeatChordCell]
    public let beatsPerBar: Int
    public let sections: [SongSection]
    public let isPartial: Bool
    public let analyzedAt: Date

    private enum CodingKeys: String, CodingKey {
        case trackId
        case key
        case bpm
        case simpleMode
        case duration
        case segments
        case beats
        case beatsPerBar
        case sections
        case isPartial
        case analyzedAt
    }

    public init(
        trackId: String,
        key: String?,
        bpm: Double?,
        simpleMode: Bool,
        duration: TimeInterval,
        segments: [TimedChordSegment],
        beats: [BeatChordCell] = [],
        beatsPerBar: Int = 4,
        sections: [SongSection] = [],
        isPartial: Bool = false,
        analyzedAt: Date = Date()
    ) {
        self.trackId = trackId
        self.key = key
        self.bpm = bpm
        self.simpleMode = simpleMode
        self.duration = max(0, duration)
        self.segments = segments
        self.beats = beats
        self.beatsPerBar = max(1, beatsPerBar)
        self.sections = sections
        self.isPartial = isPartial
        self.analyzedAt = analyzedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.trackId = try container.decode(String.self, forKey: .trackId)
        self.key = try container.decodeIfPresent(String.self, forKey: .key)
        self.bpm = try container.decodeIfPresent(Double.self, forKey: .bpm)
        self.simpleMode = try container.decodeIfPresent(Bool.self, forKey: .simpleMode) ?? true
        self.duration = max(0, try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0)
        self.segments = try container.decodeIfPresent([TimedChordSegment].self, forKey: .segments) ?? []
        self.beats = try container.decodeIfPresent([BeatChordCell].self, forKey: .beats) ?? []
        self.beatsPerBar = max(1, try container.decodeIfPresent(Int.self, forKey: .beatsPerBar) ?? 4)
        self.sections = try container.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
        self.isPartial = try container.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
        self.analyzedAt = try container.decodeIfPresent(Date.self, forKey: .analyzedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackId, forKey: .trackId)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(bpm, forKey: .bpm)
        try container.encode(simpleMode, forKey: .simpleMode)
        try container.encode(duration, forKey: .duration)
        try container.encode(segments, forKey: .segments)
        try container.encode(beats, forKey: .beats)
        try container.encode(beatsPerBar, forKey: .beatsPerBar)
        try container.encode(sections, forKey: .sections)
        try container.encode(isPartial, forKey: .isPartial)
        try container.encode(analyzedAt, forKey: .analyzedAt)
    }

    public func index(at time: TimeInterval) -> Int? {
        guard !segments.isEmpty, time.isFinite else { return nil }
        let t = max(0, time)
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let seg = segments[mid]
            if t < seg.startTime {
                high = mid - 1
            } else if t >= seg.endTime {
                if mid == segments.count - 1 && t <= seg.endTime + 0.05 {
                    return mid
                }
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    public func segment(at time: TimeInterval) -> TimedChordSegment? {
        guard let idx = index(at: time) else { return nil }
        return segments[idx]
    }

    public func nextSegment(after time: TimeInterval) -> TimedChordSegment? {
        guard !segments.isEmpty, time.isFinite else { return nil }
        let t = max(0, time)
        if let idx = index(at: t) {
            let nextIdx = idx + 1
            return nextIdx < segments.count ? segments[nextIdx] : nil
        }
        return segments.first(where: { $0.startTime > t })
    }

    public func beatIndex(at time: TimeInterval) -> Int? {
        guard !beats.isEmpty, time.isFinite else { return nil }
        let t = max(0, time)
        var low = 0
        var high = beats.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let beat = beats[mid]
            if t < beat.startTime {
                high = mid - 1
            } else if t >= beat.endTime {
                if mid == beats.count - 1 && t <= beat.endTime + 0.05 {
                    return mid
                }
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    public func section(at time: TimeInterval) -> SongSection? {
        guard !sections.isEmpty, time.isFinite else { return nil }
        let t = max(0, time)
        if let exact = sections.first(where: { t >= $0.startTime && t < $0.endTime }) {
            return exact
        }
        if let last = sections.last, t >= last.startTime && t <= last.endTime + 0.05 {
            return last
        }
        return nil
    }

    public var uniqueChords: [DetectedChord] {
        var seen = Set<String>()
        var result: [DetectedChord] = []
        let sourceChords: [DetectedChord] = !segments.isEmpty
            ? segments.map(\.chord)
            : beats.compactMap(\.chord)
        for chord in sourceChords {
            let key = "\(chord.root):\(chord.quality.rawValue)"
            if seen.insert(key).inserted {
                result.append(chord)
            }
        }
        return result
    }

    public var chordChangeSegments: [TimedChordSegment] {
        if !segments.isEmpty {
            var merged: [TimedChordSegment] = []
            merged.reserveCapacity(segments.count)
            for seg in segments {
                if let last = merged.last,
                   last.chord.root == seg.chord.root,
                   last.chord.quality == seg.chord.quality,
                   (seg.startTime - last.endTime) <= 0.6 {
                    merged[merged.count - 1] = TimedChordSegment(
                        id: last.id,
                        chord: last.chord,
                        startTime: last.startTime,
                        endTime: seg.endTime
                    )
                } else {
                    merged.append(seg)
                }
            }
            return merged
        }

        var derived: [TimedChordSegment] = []
        var activeChord: DetectedChord?
        var activeStart: TimeInterval = 0
        var activeEnd: TimeInterval = 0
        for beat in beats {
            guard let chord = beat.chord else {
                if let cur = activeChord {
                    derived.append(TimedChordSegment(chord: cur, startTime: activeStart, endTime: activeEnd))
                    activeChord = nil
                }
                continue
            }
            if let cur = activeChord,
               cur.root == chord.root,
               cur.quality == chord.quality,
               !beat.isChordChange {
                activeEnd = beat.endTime
            } else {
                if let cur = activeChord {
                    derived.append(TimedChordSegment(chord: cur, startTime: activeStart, endTime: activeEnd))
                }
                activeChord = chord
                activeStart = beat.startTime
                activeEnd = beat.endTime
            }
        }
        if let cur = activeChord {
            derived.append(TimedChordSegment(chord: cur, startTime: activeStart, endTime: activeEnd))
        }
        return derived
    }
}

public struct ChordLyricToken: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let chord: DetectedChord?
    public let chordSegmentId: UUID?
    public let chordStartTime: TimeInterval?

    public init(
        id: String,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        chord: DetectedChord? = nil,
        chordSegmentId: UUID? = nil,
        chordStartTime: TimeInterval? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.chord = chord
        self.chordSegmentId = chordSegmentId
        self.chordStartTime = chordStartTime
    }
}

public enum ChordLyricRow: Identifiable, Hashable, Sendable {
    case lyric(
        id: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isBackgroundVocal: Bool,
        tokens: [ChordLyricToken],
        translatedText: String?
    )
    case instrumental(
        id: String,
        label: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        segments: [TimedChordSegment]
    )

    public var id: String {
        switch self {
        case .lyric(let id, _, _, _, _, _):
            return id
        case .instrumental(let id, _, _, _, _):
            return id
        }
    }

    public var startTime: TimeInterval {
        switch self {
        case .lyric(_, let startTime, _, _, _, _):
            return startTime
        case .instrumental(_, _, let startTime, _, _):
            return startTime
        }
    }

    public var endTime: TimeInterval {
        switch self {
        case .lyric(_, _, let endTime, _, _, _):
            return endTime
        case .instrumental(_, _, _, let endTime, _):
            return endTime
        }
    }
}

// MARK: - Complete 60-Chord Standard Guitar Diagram Library (12 Roots × 5 Qualities)

private enum GuitarChordLibrary {
    /// Returns an accurate, playable standard guitar voicing for every (root 0...11, quality) pair.
    /// Every fretted note fits inside `baseFret...(baseFret + 3)` and uses exact chord tones.
    static func diagram(root: Int, quality: ChordQuality) -> GuitarChordDiagram {
        let r = ((root % 12) + 12) % 12
        switch (r, quality) {
        // MARK: 0 - C
        case (0, .major):
            return GuitarChordDiagram(frets: [-1, 3, 2, 0, 1, 0], fingers: [0, 3, 2, 0, 1, 0], baseFret: 1, barreFret: nil)
        case (0, .minor):
            return GuitarChordDiagram(frets: [-1, 3, 5, 5, 4, 3], fingers: [0, 1, 3, 4, 2, 1], baseFret: 3, barreFret: 3)
        case (0, .dominant7):
            return GuitarChordDiagram(frets: [-1, 3, 2, 3, 1, 0], fingers: [0, 3, 2, 4, 1, 0], baseFret: 1, barreFret: nil)
        case (0, .major7):
            return GuitarChordDiagram(frets: [-1, 3, 2, 0, 0, 0], fingers: [0, 3, 2, 0, 0, 0], baseFret: 1, barreFret: nil)
        case (0, .minor7):
            return GuitarChordDiagram(frets: [-1, 3, 5, 3, 4, 3], fingers: [0, 1, 3, 1, 2, 1], baseFret: 3, barreFret: 3)

        // MARK: 1 - C# / Db
        case (1, .major):
            return GuitarChordDiagram(frets: [-1, 4, 6, 6, 6, 4], fingers: [0, 1, 2, 3, 4, 1], baseFret: 4, barreFret: 4)
        case (1, .minor):
            return GuitarChordDiagram(frets: [-1, 4, 6, 6, 5, 4], fingers: [0, 1, 3, 4, 2, 1], baseFret: 4, barreFret: 4)
        case (1, .dominant7):
            return GuitarChordDiagram(frets: [-1, 4, 6, 4, 6, 4], fingers: [0, 1, 3, 1, 4, 1], baseFret: 4, barreFret: 4)
        case (1, .major7):
            return GuitarChordDiagram(frets: [-1, 4, 6, 5, 6, 4], fingers: [0, 1, 3, 2, 4, 1], baseFret: 4, barreFret: 4)
        case (1, .minor7):
            return GuitarChordDiagram(frets: [-1, 4, 6, 4, 5, 4], fingers: [0, 1, 3, 1, 2, 1], baseFret: 4, barreFret: 4)

        // MARK: 2 - D
        case (2, .major):
            return GuitarChordDiagram(frets: [-1, -1, 0, 2, 3, 2], fingers: [0, 0, 0, 1, 3, 2], baseFret: 1, barreFret: nil)
        case (2, .minor):
            return GuitarChordDiagram(frets: [-1, -1, 0, 2, 3, 1], fingers: [0, 0, 0, 2, 3, 1], baseFret: 1, barreFret: nil)
        case (2, .dominant7):
            return GuitarChordDiagram(frets: [-1, -1, 0, 2, 1, 2], fingers: [0, 0, 0, 2, 1, 3], baseFret: 1, barreFret: nil)
        case (2, .major7):
            return GuitarChordDiagram(frets: [-1, -1, 0, 2, 2, 2], fingers: [0, 0, 0, 1, 2, 3], baseFret: 1, barreFret: nil)
        case (2, .minor7):
            return GuitarChordDiagram(frets: [-1, -1, 0, 2, 1, 1], fingers: [0, 0, 0, 2, 1, 1], baseFret: 1, barreFret: nil)

        // MARK: 3 - Eb / D#
        case (3, .major):
            return GuitarChordDiagram(frets: [-1, 6, 8, 8, 8, 6], fingers: [0, 1, 2, 3, 4, 1], baseFret: 6, barreFret: 6)
        case (3, .minor):
            return GuitarChordDiagram(frets: [-1, 6, 8, 8, 7, 6], fingers: [0, 1, 3, 4, 2, 1], baseFret: 6, barreFret: 6)
        case (3, .dominant7):
            return GuitarChordDiagram(frets: [-1, 6, 8, 6, 8, 6], fingers: [0, 1, 3, 1, 4, 1], baseFret: 6, barreFret: 6)
        case (3, .major7):
            return GuitarChordDiagram(frets: [-1, 6, 8, 7, 8, 6], fingers: [0, 1, 3, 2, 4, 1], baseFret: 6, barreFret: 6)
        case (3, .minor7):
            return GuitarChordDiagram(frets: [-1, 6, 8, 6, 7, 6], fingers: [0, 1, 3, 1, 2, 1], baseFret: 6, barreFret: 6)

        // MARK: 4 - E
        case (4, .major):
            return GuitarChordDiagram(frets: [0, 2, 2, 1, 0, 0], fingers: [0, 2, 3, 1, 0, 0], baseFret: 1, barreFret: nil)
        case (4, .minor):
            return GuitarChordDiagram(frets: [0, 2, 2, 0, 0, 0], fingers: [0, 2, 3, 0, 0, 0], baseFret: 1, barreFret: nil)
        case (4, .dominant7):
            return GuitarChordDiagram(frets: [0, 2, 0, 1, 0, 0], fingers: [0, 2, 0, 1, 0, 0], baseFret: 1, barreFret: nil)
        case (4, .major7):
            return GuitarChordDiagram(frets: [0, 2, 1, 1, 0, 0], fingers: [0, 3, 1, 2, 0, 0], baseFret: 1, barreFret: nil)
        case (4, .minor7):
            return GuitarChordDiagram(frets: [0, 2, 0, 0, 0, 0], fingers: [0, 2, 0, 0, 0, 0], baseFret: 1, barreFret: nil)

        // MARK: 5 - F
        case (5, .major):
            return GuitarChordDiagram(frets: [1, 3, 3, 2, 1, 1], fingers: [1, 3, 4, 2, 1, 1], baseFret: 1, barreFret: 1)
        case (5, .minor):
            return GuitarChordDiagram(frets: [1, 3, 3, 1, 1, 1], fingers: [1, 3, 4, 1, 1, 1], baseFret: 1, barreFret: 1)
        case (5, .dominant7):
            return GuitarChordDiagram(frets: [1, 3, 1, 2, 1, 1], fingers: [1, 3, 1, 2, 1, 1], baseFret: 1, barreFret: 1)
        case (5, .major7):
            return GuitarChordDiagram(frets: [-1, -1, 3, 2, 1, 0], fingers: [0, 0, 3, 2, 1, 0], baseFret: 1, barreFret: nil)
        case (5, .minor7):
            return GuitarChordDiagram(frets: [1, 3, 1, 1, 1, 1], fingers: [1, 3, 1, 1, 1, 1], baseFret: 1, barreFret: 1)

        // MARK: 6 - F# / Gb
        case (6, .major):
            return GuitarChordDiagram(frets: [2, 4, 4, 3, 2, 2], fingers: [1, 3, 4, 2, 1, 1], baseFret: 2, barreFret: 2)
        case (6, .minor):
            return GuitarChordDiagram(frets: [2, 4, 4, 2, 2, 2], fingers: [1, 3, 4, 1, 1, 1], baseFret: 2, barreFret: 2)
        case (6, .dominant7):
            return GuitarChordDiagram(frets: [2, 4, 2, 3, 2, 2], fingers: [1, 3, 1, 2, 1, 1], baseFret: 2, barreFret: 2)
        case (6, .major7):
            return GuitarChordDiagram(frets: [2, -1, 3, 3, 2, -1], fingers: [1, 0, 3, 4, 2, 0], baseFret: 2, barreFret: nil)
        case (6, .minor7):
            return GuitarChordDiagram(frets: [2, 4, 2, 2, 2, 2], fingers: [1, 3, 1, 1, 1, 1], baseFret: 2, barreFret: 2)

        // MARK: 7 - G
        case (7, .major):
            return GuitarChordDiagram(frets: [3, 2, 0, 0, 0, 3], fingers: [2, 1, 0, 0, 0, 3], baseFret: 1, barreFret: nil)
        case (7, .minor):
            return GuitarChordDiagram(frets: [3, 5, 5, 3, 3, 3], fingers: [1, 3, 4, 1, 1, 1], baseFret: 3, barreFret: 3)
        case (7, .dominant7):
            return GuitarChordDiagram(frets: [3, 2, 0, 0, 0, 1], fingers: [3, 2, 0, 0, 0, 1], baseFret: 1, barreFret: nil)
        case (7, .major7):
            return GuitarChordDiagram(frets: [3, 2, 0, 0, 0, 2], fingers: [3, 1, 0, 0, 0, 2], baseFret: 1, barreFret: nil)
        case (7, .minor7):
            return GuitarChordDiagram(frets: [3, 5, 3, 3, 3, 3], fingers: [1, 3, 1, 1, 1, 1], baseFret: 3, barreFret: 3)

        // MARK: 8 - Ab / G#
        case (8, .major):
            return GuitarChordDiagram(frets: [4, 6, 6, 5, 4, 4], fingers: [1, 3, 4, 2, 1, 1], baseFret: 4, barreFret: 4)
        case (8, .minor):
            return GuitarChordDiagram(frets: [4, 6, 6, 4, 4, 4], fingers: [1, 3, 4, 1, 1, 1], baseFret: 4, barreFret: 4)
        case (8, .dominant7):
            return GuitarChordDiagram(frets: [4, 6, 4, 5, 4, 4], fingers: [1, 3, 1, 2, 1, 1], baseFret: 4, barreFret: 4)
        case (8, .major7):
            return GuitarChordDiagram(frets: [4, -1, 5, 5, 4, -1], fingers: [1, 0, 3, 4, 2, 0], baseFret: 4, barreFret: nil)
        case (8, .minor7):
            return GuitarChordDiagram(frets: [4, 6, 4, 4, 4, 4], fingers: [1, 3, 1, 1, 1, 1], baseFret: 4, barreFret: 4)

        // MARK: 9 - A
        case (9, .major):
            return GuitarChordDiagram(frets: [-1, 0, 2, 2, 2, 0], fingers: [0, 0, 1, 2, 3, 0], baseFret: 1, barreFret: nil)
        case (9, .minor):
            return GuitarChordDiagram(frets: [-1, 0, 2, 2, 1, 0], fingers: [0, 0, 2, 3, 1, 0], baseFret: 1, barreFret: nil)
        case (9, .dominant7):
            return GuitarChordDiagram(frets: [-1, 0, 2, 0, 2, 0], fingers: [0, 0, 2, 0, 3, 0], baseFret: 1, barreFret: nil)
        case (9, .major7):
            return GuitarChordDiagram(frets: [-1, 0, 2, 1, 2, 0], fingers: [0, 0, 2, 1, 3, 0], baseFret: 1, barreFret: nil)
        case (9, .minor7):
            return GuitarChordDiagram(frets: [-1, 0, 2, 0, 1, 0], fingers: [0, 0, 2, 0, 1, 0], baseFret: 1, barreFret: nil)

        // MARK: 10 - Bb / A#
        case (10, .major):
            return GuitarChordDiagram(frets: [-1, 1, 3, 3, 3, 1], fingers: [0, 1, 2, 3, 4, 1], baseFret: 1, barreFret: 1)
        case (10, .minor):
            return GuitarChordDiagram(frets: [-1, 1, 3, 3, 2, 1], fingers: [0, 1, 3, 4, 2, 1], baseFret: 1, barreFret: 1)
        case (10, .dominant7):
            return GuitarChordDiagram(frets: [-1, 1, 3, 1, 3, 1], fingers: [0, 1, 3, 1, 4, 1], baseFret: 1, barreFret: 1)
        case (10, .major7):
            return GuitarChordDiagram(frets: [-1, 1, 3, 2, 3, 1], fingers: [0, 1, 3, 2, 4, 1], baseFret: 1, barreFret: 1)
        case (10, .minor7):
            return GuitarChordDiagram(frets: [-1, 1, 3, 1, 2, 1], fingers: [0, 1, 3, 1, 2, 1], baseFret: 1, barreFret: 1)

        // MARK: 11 - B
        case (11, .major):
            return GuitarChordDiagram(frets: [-1, 2, 4, 4, 4, 2], fingers: [0, 1, 2, 3, 4, 1], baseFret: 2, barreFret: 2)
        case (11, .minor):
            return GuitarChordDiagram(frets: [-1, 2, 4, 4, 3, 2], fingers: [0, 1, 3, 4, 2, 1], baseFret: 2, barreFret: 2)
        case (11, .dominant7):
            return GuitarChordDiagram(frets: [-1, 2, 1, 2, 0, 2], fingers: [0, 2, 1, 3, 0, 4], baseFret: 1, barreFret: nil)
        case (11, .major7):
            return GuitarChordDiagram(frets: [-1, 2, 4, 3, 4, 2], fingers: [0, 1, 3, 2, 4, 1], baseFret: 2, barreFret: 2)
        case (11, .minor7):
            return GuitarChordDiagram(frets: [-1, 2, 4, 2, 3, 2], fingers: [0, 1, 3, 1, 2, 1], baseFret: 2, barreFret: 2)

        default:
            return GuitarChordDiagram(frets: [-1, 3, 2, 0, 1, 0], fingers: [0, 3, 2, 0, 1, 0], baseFret: 1, barreFret: nil)
        }
    }
}

// MARK: - Real-Time On-Device Chord Detector (Rust DSP FFI)

public final class ChordDetector: @unchecked Sendable {
    private static let scratchCapacity: Int = 32_768
    private static let rmsCapacity: Int = 16_384 // Power of 2 for bitmask wrap
    private static let rmsMask: Int = 16_383
    private static let minSamplesForAnalysis: UInt64 = 1_024

    private let rustHandle: UnsafeMutableRawPointer?
    private let ringLock: UnsafeMutablePointer<os_unfair_lock>
    private let analysisLock: UnsafeMutablePointer<os_unfair_lock>
    private let monoScratch: UnsafeMutablePointer<Float>
    private let rmsRing: UnsafeMutablePointer<Float>

    private var rmsWriteIndex: Int = 0
    private var rmsFilled: Int = 0
    private var totalSamplesWritten: UInt64 = 0
    private var ringSampleRate: Double = 44_100
    private var activeSourceId: UInt64 = 0

    private var rmsEvalBuffer: [Float]

    // MARK: - Init & Deinit

    public init() {
        rustHandle = sc_realtime_new()

        ringLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        ringLock.initialize(to: os_unfair_lock())

        analysisLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        analysisLock.initialize(to: os_unfair_lock())

        monoScratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchCapacity)
        monoScratch.initialize(repeating: 0, count: Self.scratchCapacity)

        rmsRing = UnsafeMutablePointer<Float>.allocate(capacity: Self.rmsCapacity)
        rmsRing.initialize(repeating: 0, count: Self.rmsCapacity)

        rmsEvalBuffer = Array(repeating: 0, count: Self.rmsCapacity)
    }

    deinit {
        if let rustHandle {
            sc_realtime_free(rustHandle)
        }
        monoScratch.deinitialize(count: Self.scratchCapacity)
        monoScratch.deallocate()
        rmsRing.deinitialize(count: Self.rmsCapacity)
        rmsRing.deallocate()
        ringLock.deinitialize(count: 1)
        ringLock.deallocate()
        analysisLock.deinitialize(count: 1)
        analysisLock.deallocate()
    }

    // MARK: - Source Gating (Prevents Crossfade Bleed Between Decks)

    /// Pins ingestion from `ingestBuffers(..., sourceId:)` to the active player item's tap.
    /// Pass `0` to accept any source.
    public func setActiveSource(_ sourceId: UInt64) {
        os_unfair_lock_lock(ringLock)
        activeSourceId = sourceId
        os_unfair_lock_unlock(ringLock)
    }

    // MARK: - Real-Time Audio Ingestion (Zero Heap Allocations)

    /// Ingests mono Float32 PCM samples into the Rust DSP ring buffer.
    public func ingest(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0 else { return }

        os_unfair_lock_lock(ringLock)
        appendMonoSamplesLocked(samples: samples, count: count, sampleRate: sampleRate)
        os_unfair_lock_unlock(ringLock)
    }

    /// Ingests interleaved multi-channel Float32 PCM samples, mono-summing into the Rust DSP ring buffer.
    public func ingestInterleaved(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        channels: Int,
        sampleRate: Double
    ) {
        guard frameCount > 0, channels > 0 else { return }
        if channels == 1 {
            ingest(samples: samples, count: frameCount, sampleRate: sampleRate)
            return
        }

        os_unfair_lock_lock(ringLock)
        let effectiveSR = sampleRate > 0 ? sampleRate : ringSampleRate
        var frameOffset = 0
        while frameOffset < frameCount {
            let chunk = min(Self.scratchCapacity, frameCount - frameOffset)
            if channels == 2 {
                for i in 0..<chunk {
                    let base = (frameOffset &+ i) &* 2
                    monoScratch[i] = 0.5 * (samples[base] + samples[base &+ 1])
                }
            } else {
                let invChannels = 1.0 / Float(channels)
                for i in 0..<chunk {
                    let base = (frameOffset &+ i) &* channels
                    var sum: Float = 0
                    for ch in 0..<channels {
                        sum += samples[base &+ ch]
                    }
                    monoScratch[i] = sum * invChannels
                }
            }
            appendMonoSamplesLocked(samples: monoScratch, count: chunk, sampleRate: effectiveSR)
            frameOffset &+= chunk
        }
        os_unfair_lock_unlock(ringLock)
    }

    /// Zero-allocation ingestion directly from an `MTAudioProcessingTap`'s Float32 `AudioBufferList`.
    public func ingestBuffers(
        _ bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        isNonInterleaved: Bool,
        sampleRate: Double,
        sourceId: UInt64 = 0
    ) {
        guard frameCount > 0 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard !buffers.isEmpty else { return }

        os_unfair_lock_lock(ringLock)
        if sourceId != 0 && activeSourceId != 0 && sourceId != activeSourceId {
            os_unfair_lock_unlock(ringLock)
            return
        }
        let effectiveSR = sampleRate > 0 ? sampleRate : ringSampleRate

        if isNonInterleaved {
            let numChannels = buffers.count
            if numChannels == 1 {
                if let ptr = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    let available = min(frameCount, Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size)
                    if available > 0 {
                        appendMonoSamplesLocked(samples: ptr, count: available, sampleRate: effectiveSR)
                    }
                }
            } else if numChannels == 2 {
                if let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                   let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    let countL = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                    let countR = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
                    let available = min(frameCount, min(countL, countR))
                    var offset = 0
                    while offset < available {
                        let chunk = min(Self.scratchCapacity, available - offset)
                        for i in 0..<chunk {
                            let idx = offset &+ i
                            monoScratch[i] = 0.5 * (left[idx] + right[idx])
                        }
                        appendMonoSamplesLocked(samples: monoScratch, count: chunk, sampleRate: effectiveSR)
                        offset &+= chunk
                    }
                }
            } else {
                var minAvailable = frameCount
                var validChannels = 0
                for ch in 0..<numChannels {
                    if buffers[ch].mData != nil {
                        let chSamples = Int(buffers[ch].mDataByteSize) / MemoryLayout<Float>.size
                        minAvailable = min(minAvailable, chSamples)
                        validChannels += 1
                    }
                }
                if validChannels > 0 && minAvailable > 0 {
                    let invChannels = 1.0 / Float(validChannels)
                    var offset = 0
                    while offset < minAvailable {
                        let chunk = min(Self.scratchCapacity, minAvailable - offset)
                        for i in 0..<chunk {
                            let idx = offset &+ i
                            var sum: Float = 0
                            for ch in 0..<numChannels {
                                if let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) {
                                    sum += ptr[idx]
                                }
                            }
                            monoScratch[i] = sum * invChannels
                        }
                        appendMonoSamplesLocked(samples: monoScratch, count: chunk, sampleRate: effectiveSR)
                        offset &+= chunk
                    }
                }
            }
        } else if let first = buffers.first,
                  let ptr = first.mData?.assumingMemoryBound(to: Float.self) {
            let channels = max(1, Int(first.mNumberChannels))
            let totalFloats = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let availableFrames = min(frameCount, totalFloats / channels)
            if channels == 1 {
                if availableFrames > 0 {
                    appendMonoSamplesLocked(samples: ptr, count: availableFrames, sampleRate: effectiveSR)
                }
            } else if channels == 2 {
                var offset = 0
                while offset < availableFrames {
                    let chunk = min(Self.scratchCapacity, availableFrames - offset)
                    for i in 0..<chunk {
                        let base = (offset &+ i) &* 2
                        monoScratch[i] = 0.5 * (ptr[base] + ptr[base &+ 1])
                    }
                    appendMonoSamplesLocked(samples: monoScratch, count: chunk, sampleRate: effectiveSR)
                    offset &+= chunk
                }
            } else {
                let invChannels = 1.0 / Float(channels)
                var offset = 0
                while offset < availableFrames {
                    let chunk = min(Self.scratchCapacity, availableFrames - offset)
                    for i in 0..<chunk {
                        let base = (offset &+ i) &* channels
                        var sum: Float = 0
                        for ch in 0..<channels {
                            sum += ptr[base &+ ch]
                        }
                        monoScratch[i] = sum * invChannels
                    }
                    appendMonoSamplesLocked(samples: monoScratch, count: chunk, sampleRate: effectiveSR)
                    offset &+= chunk
                }
            }
        }

        os_unfair_lock_unlock(ringLock)
    }

    private func appendMonoSamplesLocked(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0 else { return }
        if sampleRate > 0 {
            ringSampleRate = sampleRate
        }
        let effectiveSR = ringSampleRate > 0 ? ringSampleRate : 44_100

        let capacity = Self.rmsCapacity
        if count >= capacity {
            let startOffset = count - capacity
            rmsRing.update(from: samples.advanced(by: startOffset), count: capacity)
            rmsWriteIndex = 0
            rmsFilled = capacity
        } else {
            let firstChunk = min(count, capacity - rmsWriteIndex)
            rmsRing.advanced(by: rmsWriteIndex).update(from: samples, count: firstChunk)
            let remaining = count - firstChunk
            if remaining > 0 {
                rmsRing.update(from: samples.advanced(by: firstChunk), count: remaining)
            }
            rmsWriteIndex = (rmsWriteIndex + count) & Self.rmsMask
            rmsFilled = min(capacity, rmsFilled + count)
        }
        totalSamplesWritten &+= UInt64(count)

        if let rustHandle {
            sc_realtime_ingest(rustHandle, samples, count, effectiveSR)
        }
    }

    // MARK: - Reset

    public func reset() {
        os_unfair_lock_lock(ringLock)
        rmsRing.initialize(repeating: 0, count: Self.rmsCapacity)
        rmsWriteIndex = 0
        rmsFilled = 0
        totalSamplesWritten = 0
        os_unfair_lock_unlock(ringLock)

        os_unfair_lock_lock(analysisLock)
        if let rustHandle {
            sc_realtime_reset(rustHandle)
        }
        os_unfair_lock_unlock(analysisLock)
    }

    // MARK: - Real-Time Chord & Key Analysis

    public func analyze(currentTime: TimeInterval, simpleMode: Bool) -> ChordAnalysisSnapshot {
        os_unfair_lock_lock(analysisLock)
        defer { os_unfair_lock_unlock(analysisLock) }

        var written: UInt64 = 0
        var rmsCount = 0

        os_unfair_lock_lock(ringLock)
        written = totalSamplesWritten
        rmsCount = min(Self.rmsCapacity, rmsFilled)
        if rmsCount > 0 {
            let startIdx = (rmsWriteIndex - rmsCount) & Self.rmsMask
            let firstChunk = min(rmsCount, Self.rmsCapacity - startIdx)
            rmsEvalBuffer.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                dstBase.update(from: rmsRing.advanced(by: startIdx), count: firstChunk)
                let rem = rmsCount - firstChunk
                if rem > 0 {
                    dstBase.advanced(by: firstChunk).update(from: rmsRing, count: rem)
                }
            }
        }
        os_unfair_lock_unlock(ringLock)

        var rms: Float = 0
        if rmsCount > 0 {
            vDSP_rmsqv(rmsEvalBuffer, 1, &rms, vDSP_Length(rmsCount))
            if !rms.isFinite { rms = 0 }
        }

        guard written >= Self.minSamplesForAnalysis, let rustHandle else {
            return ChordAnalysisSnapshot(
                chord: nil,
                chroma: Array(repeating: 0, count: 12),
                detectedKey: nil,
                rms: rms,
                isSilent: true
            )
        }

        let snap = sc_realtime_analyze(rustHandle, simpleMode ? 1 : 0)
        let chroma: [Float] = [
            snap.chroma.0, snap.chroma.1, snap.chroma.2, snap.chroma.3,
            snap.chroma.4, snap.chroma.5, snap.chroma.6, snap.chroma.7,
            snap.chroma.8, snap.chroma.9, snap.chroma.10, snap.chroma.11
        ]

        let detectedKey: String?
        if snap.has_key != 0 {
            let rootIdx = ((Int(snap.key_root) % 12) + 12) % 12
            let note = DetectedChord.noteNames[rootIdx]
            detectedKey = snap.key_is_minor != 0 ? "\(note) Minor" : "\(note) Major"
        } else {
            detectedKey = nil
        }

        let isSilent = snap.has_chord == 0
        let chord: DetectedChord?
        if !isSilent {
            chord = DetectedChord(
                root: Int(snap.root),
                quality: ChordTimelineAnalyzer.chordQuality(fromCValue: snap.quality),
                confidence: snap.confidence,
                timestamp: currentTime
            )
        } else {
            chord = nil
        }

        return ChordAnalysisSnapshot(
            chord: chord,
            chroma: chroma,
            detectedKey: detectedKey,
            rms: rms,
            isSilent: isSilent
        )
    }
}

// MARK: - Timeline-Synced Lyrics + Chords Aligner

public enum LyricsChordAligner {
    private struct WordSlot {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    public static func align(
        lyrics: LyricsDocument,
        timeline: TrackChordTimeline,
        lyricsOffsetSeconds: TimeInterval = 0
    ) -> [ChordLyricRow] {
        let segments = timeline.segments
        let totalDuration = max(timeline.duration, segments.last?.endTime ?? 0)

        let validLines = lyrics.lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.words.isEmpty
        }

        // Case 1: Synced Lyrics (Word-Synced or Line-Synced)
        if lyrics.isSynced && !validLines.isEmpty {
            var rows: [ChordLyricRow] = []
            rows.reserveCapacity(validLines.count + 4)

            // Compute effective start & end timestamps for every line with offset applied
            var lineRanges: [(start: TimeInterval, end: TimeInterval)] = []
            lineRanges.reserveCapacity(validLines.count)

            for i in 0..<validLines.count {
                let line = validLines[i]
                var start = max(0, line.startTime + lyricsOffsetSeconds)
                if !line.words.isEmpty, let firstWord = line.words.first {
                    start = min(start, max(0, firstWord.startTime + lyricsOffsetSeconds))
                }

                let nextStart: TimeInterval? = (i + 1 < validLines.count)
                    ? max(start, validLines[i + 1].startTime + lyricsOffsetSeconds)
                    : nil

                var end: TimeInterval
                if !line.words.isEmpty, let lastWord = line.words.last {
                    let wordEnd = max(start, lastWord.endTime + lyricsOffsetSeconds)
                    let lineEnd = line.endTime > line.startTime
                        ? max(start, line.endTime + lyricsOffsetSeconds)
                        : wordEnd
                    end = max(wordEnd, lineEnd)
                    if let nextStart {
                        end = min(end, nextStart)
                    }
                } else if line.endTime > line.startTime {
                    let rawEnd = max(start, line.endTime + lyricsOffsetSeconds)
                    if let nextStart {
                        // In standard LRC where endTime was synthesized as nextStart, cap vocal duration
                        // when there is a large instrumental gap (>= 8.5s) before the next line.
                        let wordCount = max(1, line.text.split(whereSeparator: { $0.isWhitespace }).count)
                        if abs(rawEnd - nextStart) < 0.05 && (nextStart - start) >= 8.5 {
                            let estimatedVocalSpan = min(5.5, max(2.5, Double(wordCount) * 0.55))
                            end = min(nextStart, start + estimatedVocalSpan)
                        } else {
                            end = min(rawEnd, nextStart)
                        }
                    } else {
                        end = rawEnd
                    }
                } else if let nextStart {
                    let wordCount = max(1, line.text.split(whereSeparator: { $0.isWhitespace }).count)
                    if (nextStart - start) >= 8.5 {
                        let estimatedVocalSpan = min(5.5, max(2.5, Double(wordCount) * 0.55))
                        end = min(nextStart, start + estimatedVocalSpan)
                    } else {
                        end = nextStart
                    }
                } else {
                    end = max(start + 3.0, totalDuration)
                }

                if end <= start {
                    end = nextStart.map { max(start + 0.1, $0) } ?? (start + 2.5)
                }
                lineRanges.append((start: start, end: end))
            }

            // 1. Optional "Intro" instrumental row before the first lyric line
            if let firstRange = lineRanges.first, firstRange.start >= 2.5 {
                let introSegments = overlappingSegments(in: segments, from: 0, to: firstRange.start)
                if !introSegments.isEmpty {
                    rows.append(
                        .instrumental(
                            id: "intro",
                            label: "Intro",
                            startTime: 0,
                            endTime: firstRange.start,
                            segments: introSegments
                        )
                    )
                }
            }

            // 2. Lyric lines + optional inter-line "Instrumental" rows
            for i in 0..<validLines.count {
                let line = validLines[i]
                let range = lineRanges[i]
                let tokens = buildTokens(
                    for: line,
                    lineIndex: i,
                    lineStart: range.start,
                    lineEnd: range.end,
                    lyricsOffsetSeconds: lyricsOffsetSeconds,
                    timeline: timeline
                )

                rows.append(
                    .lyric(
                        id: line.id,
                        startTime: range.start,
                        endTime: range.end,
                        isBackgroundVocal: line.isBackgroundVocal,
                        tokens: tokens,
                        translatedText: line.translatedText
                    )
                )

                if i + 1 < validLines.count {
                    let gapStart = range.end
                    let gapEnd = lineRanges[i + 1].start
                    if gapEnd - gapStart >= 3.0 {
                        let gapSegments = overlappingSegments(in: segments, from: gapStart, to: gapEnd)
                        if !gapSegments.isEmpty {
                            rows.append(
                                .instrumental(
                                    id: "inst_\(i)",
                                    label: "Instrumental",
                                    startTime: gapStart,
                                    endTime: gapEnd,
                                    segments: gapSegments
                                )
                            )
                        }
                    }
                }
            }

            // 3. Optional "Outro" instrumental row after the last lyric line
            if let lastRange = lineRanges.last, totalDuration - lastRange.end >= 3.0 {
                let outroSegments = overlappingSegments(in: segments, from: lastRange.end, to: totalDuration)
                if !outroSegments.isEmpty {
                    rows.append(
                        .instrumental(
                            id: "outro",
                            label: "Outro",
                            startTime: lastRange.end,
                            endTime: totalDuration,
                            segments: outroSegments
                        )
                    )
                }
            }

            return rows
        }

        // Case 2: Unsynced / Plain Lyrics - map chords proportionally across lines
        let plainLines: [LyricLine]
        if !validLines.isEmpty {
            plainLines = validLines
        } else {
            plainLines = lyrics.plainText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { idx, text in
                    LyricLine(id: "plain_\(idx)", startTime: 0, endTime: 0, text: text)
                }
        }

        guard !plainLines.isEmpty else {
            if !segments.isEmpty {
                return [
                    .instrumental(
                        id: "instrumental_full",
                        label: "Instrumental",
                        startTime: 0,
                        endTime: max(totalDuration, segments.last?.endTime ?? 0),
                        segments: segments
                    )
                ]
            }
            return []
        }

        let firstChordStart = segments.first?.startTime ?? 0
        let lastChordEnd = max(totalDuration, segments.last?.endTime ?? 1.0)
        let activeSpan = max(1.0, lastChordEnd - firstChordStart)
        let lineDuration = activeSpan / Double(plainLines.count)

        var rows: [ChordLyricRow] = []
        rows.reserveCapacity(plainLines.count)

        for (i, line) in plainLines.enumerated() {
            let lineStart = firstChordStart + Double(i) * lineDuration
            let lineEnd = firstChordStart + Double(i + 1) * lineDuration
            let tokens = buildTokens(
                for: line,
                lineIndex: i,
                lineStart: lineStart,
                lineEnd: lineEnd,
                lyricsOffsetSeconds: 0,
                timeline: timeline
            )
            rows.append(
                .lyric(
                    id: line.id,
                    startTime: lineStart,
                    endTime: lineEnd,
                    isBackgroundVocal: line.isBackgroundVocal,
                    tokens: tokens,
                    translatedText: line.translatedText
                )
            )
        }

        return rows
    }

    private static func overlappingSegments(
        in segments: [TimedChordSegment],
        from startTime: TimeInterval,
        to endTime: TimeInterval
    ) -> [TimedChordSegment] {
        guard endTime > startTime else { return [] }
        return segments.filter { seg in
            let overlapStart = max(startTime, seg.startTime)
            let overlapEnd = min(endTime, seg.endTime)
            let overlap = overlapEnd - overlapStart
            return overlap >= 0.18 || (seg.startTime >= startTime && seg.startTime < endTime)
        }
    }

    private static func buildTokens(
        for line: LyricLine,
        lineIndex: Int,
        lineStart: TimeInterval,
        lineEnd: TimeInterval,
        lyricsOffsetSeconds: TimeInterval,
        timeline: TrackChordTimeline
    ) -> [ChordLyricToken] {
        var wordSlots: [WordSlot] = []

        if !line.words.isEmpty {
            wordSlots.reserveCapacity(line.words.count)
            for (idx, word) in line.words.enumerated() {
                let cleaned = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let rawStart = max(0, word.startTime + lyricsOffsetSeconds)
                let rawEnd = max(rawStart, word.endTime + lyricsOffsetSeconds)
                let nextWordStart: TimeInterval? = (idx + 1 < line.words.count)
                    ? max(rawStart, line.words[idx + 1].startTime + lyricsOffsetSeconds)
                    : nil
                let effectiveEnd = rawEnd > rawStart ? rawEnd : (nextWordStart ?? max(rawStart + 0.15, lineEnd))
                wordSlots.append(WordSlot(text: cleaned, startTime: rawStart, endTime: effectiveEnd))
            }
        }

        if wordSlots.isEmpty {
            let pieces = line.text
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            let words = pieces.isEmpty ? [line.text] : pieces
            let span = max(0.05, lineEnd - lineStart)
            let step = span / Double(max(1, words.count))
            wordSlots.reserveCapacity(words.count)
            for (wIdx, text) in words.enumerated() {
                let wStart = lineStart + Double(wIdx) * step
                let wEnd = lineStart + Double(wIdx + 1) * step
                wordSlots.append(WordSlot(text: text, startTime: wStart, endTime: wEnd))
            }
        }

        guard !wordSlots.isEmpty else { return [] }

        var assignedSegments = Array<TimedChordSegment?>(repeating: nil, count: wordSlots.count)

        // 1. Place every chord segment starting within [lineStart, lineEnd) onto its matching word token
        let lineSegments = timeline.segments.filter { seg in
            seg.startTime >= lineStart - 0.05 && seg.startTime < lineEnd - 0.02
        }

        for seg in lineSegments {
            let targetIdx = matchingWordIndex(for: seg.startTime, in: wordSlots)
            if assignedSegments[targetIdx] == nil {
                assignedSegments[targetIdx] = seg
            } else if let existing = assignedSegments[targetIdx] {
                // If two chord changes happen within one long held word, spill the later chord to next free word if available
                if existing.chord.displayName == seg.chord.displayName {
                    continue
                }
                if targetIdx + 1 < wordSlots.count && assignedSegments[targetIdx + 1] == nil {
                    assignedSegments[targetIdx + 1] = seg
                } else {
                    let existingDist = abs(wordSlots[targetIdx].startTime - existing.startTime)
                    let candidateDist = abs(wordSlots[targetIdx].startTime - seg.startTime)
                    if candidateDist < existingDist {
                        assignedSegments[targetIdx] = seg
                    }
                }
            }
        }

        // 2. Attach the carrying chord active at `lineStart` to word 0 if no chord starts on word 0
        if assignedSegments[0] == nil,
           let carrying = timeline.segment(at: lineStart) {
            let alreadyOnWord1WithSameChord = (wordSlots.count > 1)
                && (assignedSegments[1]?.id == carrying.id)
            if !alreadyOnWord1WithSameChord {
                assignedSegments[0] = carrying
            }
        }

        // 3. Emit ChordLyricTokens
        var tokens: [ChordLyricToken] = []
        tokens.reserveCapacity(wordSlots.count)
        for (wIdx, slot) in wordSlots.enumerated() {
            let seg = assignedSegments[wIdx]
            tokens.append(
                ChordLyricToken(
                    id: "\(line.id)_l\(lineIndex)_w\(wIdx)",
                    text: slot.text,
                    startTime: slot.startTime,
                    endTime: slot.endTime,
                    chord: seg?.chord,
                    chordSegmentId: seg?.id,
                    chordStartTime: seg?.startTime
                )
            )
        }
        return tokens
    }

    private static func matchingWordIndex(for timestamp: TimeInterval, in slots: [WordSlot]) -> Int {
        guard !slots.isEmpty else { return 0 }
        // First check direct interval containment `[slot.startTime, slot.endTime)`
        for (idx, slot) in slots.enumerated() {
            if timestamp >= slot.startTime && timestamp < slot.endTime {
                return idx
            }
        }
        // Otherwise pick the nearest word slot
        var bestIdx = 0
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        for (idx, slot) in slots.enumerated() {
            let dist: TimeInterval
            if timestamp < slot.startTime {
                dist = slot.startTime - timestamp
            } else if timestamp > slot.endTime {
                dist = timestamp - slot.endTime
            } else {
                dist = 0
            }
            if dist < bestDistance {
                bestDistance = dist
                bestIdx = idx
            }
        }
        return bestIdx
    }
}

// MARK: - Full-Track Offline Chord Timeline Analyzer (Rust DSP FFI)

public enum ChordTimelineAnalyzer {
    private static let analysisSampleRate: Double = 22_050
    private static let fftSize: Int = 8_192

    internal static func chordQuality(fromCValue value: Int32) -> ChordQuality {
        switch value {
        case 0: return .major
        case 1: return .minor
        case 2: return .dominant7
        case 3: return .major7
        case 4: return .minor7
        default: return .major
        }
    }

    internal static func sectionKind(fromCValue value: Int32) -> SongSectionKind {
        switch value {
        case 0: return .intro
        case 1: return .verse
        case 2: return .preChorus
        case 3: return .chorus
        case 4: return .bridge
        case 5: return .outro
        default: return .verse
        }
    }

    // MARK: - Decode Audio File & Analyze

    public static func analyzeAudioFile(
        at fileURL: URL,
        trackId: String,
        simpleMode: Bool,
        knownDuration: TimeInterval? = nil,
        isPartial: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TrackChordTimeline {
        let asset = AVURLAsset(url: fileURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw BitChordError.parseError("No audio track found in \(fileURL.lastPathComponent).")
        }

        var assetDuration: TimeInterval?
        if let cmDuration = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(cmDuration)
            if secs.isFinite && secs > 0 {
                assetDuration = secs
            }
        }

        let authoritativeDuration: TimeInterval? = {
            if let knownDuration, knownDuration.isFinite && knownDuration > 0 {
                return knownDuration
            }
            return assetDuration
        }()

        let targetRate = Self.analysisSampleRate
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            onProgress?(0.02)

            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: targetRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]

            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw BitChordError.parseError("Unable to attach audio reader output.")
            }
            reader.add(output)

            guard reader.startReading() else {
                throw BitChordError.parseError(reader.error?.localizedDescription ?? "Failed to start audio reader.")
            }

            let expectedSamples: Int = {
                if let dur = authoritativeDuration, dur > 0 {
                    return max(Self.fftSize, Int(ceil(dur * targetRate)))
                }
                return Int(targetRate * 180)
            }()

            // Cap maximum decoded samples if knownDuration is provided so doubled fMP4 edit-lists stop early
            let maxSamplesToRead: Int? = {
                if let known = knownDuration, known.isFinite && known > 0 {
                    return Int(ceil(known * targetRate * 1.05))
                }
                return nil
            }()

            var pcmSamples: [Float] = []
            pcmSamples.reserveCapacity(min(expectedSamples + Self.fftSize, Int(targetRate * 1_200)))

            var buffersRead = 0
            var lastReportedDecodeProgress = 0.0

            while reader.status == .reading {
                if (buffersRead & 31) == 0 {
                    try Task.checkCancellation()
                }
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    break
                }
                defer { CMSampleBufferInvalidate(sampleBuffer) }

                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    let byteLength = CMBlockBufferGetDataLength(blockBuffer)
                    var offset = 0
                    while offset < byteLength {
                        var lengthAtOffset: Int = 0
                        var rawPtr: UnsafeMutablePointer<CChar>?
                        let status = CMBlockBufferGetDataPointer(
                            blockBuffer,
                            atOffset: offset,
                            lengthAtOffsetOut: &lengthAtOffset,
                            totalLengthOut: nil,
                            dataPointerOut: &rawPtr
                        )
                        guard status == kCMBlockBufferNoErr, let rawPtr, lengthAtOffset > 0 else {
                            break
                        }
                        let floatCount = lengthAtOffset / MemoryLayout<Float>.size
                        if floatCount > 0 {
                            rawPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
                                pcmSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: floatCount))
                            }
                        }
                        offset += lengthAtOffset
                    }
                }

                buffersRead += 1
                if let maxSamplesToRead, pcmSamples.count >= maxSamplesToRead {
                    reader.cancelReading()
                    break
                }

                if let onProgress, expectedSamples > 0 {
                    let fraction = min(1.0, Double(pcmSamples.count) / Double(expectedSamples))
                    if fraction - lastReportedDecodeProgress >= 0.04 {
                        lastReportedDecodeProgress = fraction
                        onProgress(0.02 + 0.38 * fraction)
                    }
                }
            }

            let minPartialSamples = Int(targetRate * 2.0)
            if reader.status == .failed {
                if !(isPartial && pcmSamples.count >= minPartialSamples) {
                    throw BitChordError.parseError(reader.error?.localizedDescription ?? "Failed while decoding audio file.")
                }
            }

            try Task.checkCancellation()
            guard !pcmSamples.isEmpty else {
                throw BitChordError.parseError("Decoded audio track contained no PCM samples.")
            }
            if isPartial && pcmSamples.count < minPartialSamples {
                throw BitChordError.parseError("Partial prefix contained insufficient audio samples.")
            }

            let rawDecodedDuration = Double(pcmSamples.count) / targetRate
            let effectiveKnownForBuffer: TimeInterval?
            if isPartial {
                if let auth = authoritativeDuration, auth.isFinite && auth > 0 {
                    effectiveKnownForBuffer = min(rawDecodedDuration, auth)
                } else {
                    effectiveKnownForBuffer = rawDecodedDuration
                }
            } else {
                effectiveKnownForBuffer = authoritativeDuration
            }

            onProgress?(0.40)
            return Self.analyzePCMBuffer(
                pcmSamples,
                sampleRate: targetRate,
                trackId: trackId,
                simpleMode: simpleMode,
                knownDuration: effectiveKnownForBuffer,
                isPartial: isPartial,
                onProgress: { p in
                    onProgress?(0.40 + 0.60 * p)
                }
            )
        }.value
    }

    // MARK: - Analyze Linear PCM Buffer

    public static func analyzePCMBuffer(
        _ samples: [Float],
        sampleRate: Double,
        trackId: String,
        simpleMode: Bool,
        knownDuration: TimeInterval? = nil,
        isPartial: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> TrackChordTimeline {
        let effectiveRate = sampleRate > 0 ? sampleRate : Self.analysisSampleRate
        let rawDuration = Double(samples.count) / effectiveRate

        // Guard against CoreMedia duration doubling when knownDuration is provided
        let timelineDuration: TimeInterval
        let analysisSampleLimit: Int
        if isPartial {
            if let known = knownDuration, known.isFinite && known > 0, rawDuration > known * 1.15 {
                timelineDuration = known
                analysisSampleLimit = min(samples.count, Int(ceil(known * effectiveRate)))
            } else {
                timelineDuration = rawDuration
                analysisSampleLimit = samples.count
            }
        } else if let known = knownDuration, known.isFinite && known > 0 {
            if rawDuration > known * 1.15 {
                timelineDuration = known
                analysisSampleLimit = min(samples.count, Int(ceil(known * effectiveRate)))
            } else {
                timelineDuration = max(rawDuration, known)
                analysisSampleLimit = samples.count
            }
        } else {
            timelineDuration = rawDuration
            analysisSampleLimit = samples.count
        }

        guard analysisSampleLimit > 0 else {
            onProgress?(1.0)
            return TrackChordTimeline(
                trackId: trackId,
                key: nil,
                bpm: nil,
                simpleMode: simpleMode,
                duration: max(0, timelineDuration),
                segments: [],
                beats: [],
                beatsPerBar: 4,
                sections: [],
                isPartial: isPartial
            )
        }

        onProgress?(0.15)
        let resultPtr: UnsafeMutablePointer<ScTimelineResult>? = samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return sc_analyze_pcm(
                base,
                analysisSampleLimit,
                effectiveRate,
                simpleMode ? 1 : 0,
                max(0, timelineDuration)
            )
        }

        guard let resultPtr else {
            onProgress?(1.0)
            return TrackChordTimeline(
                trackId: trackId,
                key: nil,
                bpm: nil,
                simpleMode: simpleMode,
                duration: max(0, timelineDuration),
                segments: [],
                beats: [],
                beatsPerBar: 4,
                sections: [],
                isPartial: isPartial
            )
        }
        defer { sc_free_timeline(resultPtr) }
        onProgress?(0.85)

        let res = resultPtr.pointee

        var segments: [TimedChordSegment] = []
        if let rawSegs = res.segments, res.segment_count > 0 {
            segments.reserveCapacity(res.segment_count)
            for i in 0..<res.segment_count {
                let cSeg = rawSegs[i]
                let start = max(0, cSeg.start_time.isFinite ? cSeg.start_time : 0)
                let end = max(start, cSeg.end_time.isFinite ? cSeg.end_time : start)
                guard end > start + 1e-4 else { continue }
                let chord = DetectedChord(
                    root: Int(cSeg.root),
                    quality: chordQuality(fromCValue: cSeg.quality),
                    confidence: cSeg.confidence.isFinite ? cSeg.confidence : 0.85,
                    timestamp: start
                )
                segments.append(
                    TimedChordSegment(
                        chord: chord,
                        startTime: start,
                        endTime: end
                    )
                )
            }
        }

        var beats: [BeatChordCell] = []
        if let rawBeats = res.beats, res.beat_count > 0 {
            beats.reserveCapacity(res.beat_count)
            var segCursor = 0
            for i in 0..<res.beat_count {
                let cBeat = rawBeats[i]
                let start = max(0, cBeat.start_time.isFinite ? cBeat.start_time : 0)
                let end = max(start, cBeat.end_time.isFinite ? cBeat.end_time : start)

                let beatChord: DetectedChord?
                if cBeat.root >= 0 {
                    let quality = chordQuality(fromCValue: cBeat.quality)
                    let midTime = 0.5 * (start + end)
                    while segCursor + 1 < segments.count && segments[segCursor].endTime <= midTime {
                        segCursor += 1
                    }
                    let confidence: Double
                    if segCursor < segments.count,
                       midTime >= segments[segCursor].startTime - 0.05,
                       midTime <= segments[segCursor].endTime + 0.05 {
                        confidence = segments[segCursor].chord.confidence
                    } else {
                        confidence = 0.90
                    }
                    beatChord = DetectedChord(
                        root: Int(cBeat.root),
                        quality: quality,
                        confidence: confidence,
                        timestamp: start
                    )
                } else {
                    beatChord = nil
                }

                beats.append(
                    BeatChordCell(
                        barIndex: max(0, Int(cBeat.bar_index)),
                        beatIndex: max(0, Int(cBeat.beat_index)),
                        chord: beatChord,
                        isChordChange: cBeat.is_chord_change != 0,
                        startTime: start,
                        endTime: end
                    )
                )
            }
        }

        var sections: [SongSection] = []
        if let rawSections = res.sections, res.section_count > 0 {
            sections.reserveCapacity(res.section_count)
            for i in 0..<res.section_count {
                let cSec = rawSections[i]
                let kind = sectionKind(fromCValue: cSec.kind)
                let start = max(0, cSec.start_time.isFinite ? cSec.start_time : 0)
                let end = max(start, cSec.end_time.isFinite ? cSec.end_time : start)
                sections.append(
                    SongSection(
                        kind: kind,
                        label: kind.displayTitle,
                        startTime: start,
                        endTime: end
                    )
                )
            }
        }

        let formattedKey: String?
        if res.has_key != 0 {
            let rootIdx = ((Int(res.key_root) % 12) + 12) % 12
            let note = DetectedChord.noteNames[rootIdx]
            formattedKey = res.key_is_minor != 0 ? "\(note) Minor" : "\(note) Major"
        } else {
            formattedKey = nil
        }

        let finalDuration = (res.duration.isFinite && res.duration >= 0) ? res.duration : max(0, timelineDuration)
        let finalBPM = (res.bpm.isFinite && res.bpm > 0) ? res.bpm : nil
        let finalBeatsPerBar = max(1, Int(res.beats_per_bar))

        onProgress?(1.0)
        return TrackChordTimeline(
            trackId: trackId,
            key: formattedKey,
            bpm: finalBPM,
            simpleMode: simpleMode,
            duration: finalDuration,
            segments: segments,
            beats: beats,
            beatsPerBar: finalBeatsPerBar,
            sections: sections,
            isPartial: isPartial
        )
    }
}

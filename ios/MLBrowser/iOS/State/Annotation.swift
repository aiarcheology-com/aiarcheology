//
//  Annotation.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 17.12.23.
//

@preconcurrency import AVFoundation
import Foundation

/// The shape drawn around a detection.
///
/// **The raw values are persisted, so they are not free to rename** (AIA-0620).
/// `DeepConfiguration.selectedSymbol` reads them straight out of the Core Data attribute
/// `selectedSymbol_` and falls back to `.circle` on any value it does not recognise. Renaming
/// `"Square"` would therefore not fail loudly — it would silently reset every existing user's
/// annotation shape to a circle, on a preference they chose deliberately.
///
/// `.square` is consequently a **storage name, not a label**: it has always drawn
/// `ObservationRectangleView` — a bounding rectangle, never a square — and since AIA-0620 it says
/// so. Only the user-facing string changed; the stored value is untouched.
public enum AnnotationSymbol: String, CaseIterable, Identifiable {
	case point = "Point"
	case square = "Square"
	case circle = "Circle"

	public var id: String { self.rawValue }

	/// Localized display name for the symbol type
	public var localizedName: String {
		switch self {
		case .point: return L10n.Symbol.point
		case .square: return L10n.Symbol.rectangle
		case .circle: return L10n.Symbol.circle
		}
	}
}

// Custom symbol crosses tasks via params; assert it is safe in this app.
extension AnnotationSymbol: @unchecked Sendable {}

// MARK: - Annotation sounds (AIA-0716)

/// The app-provided sounds available for painted annotations.
///
/// These are deliberately not references to iOS alert tones: iOS does not expose its alert-tone
/// catalog or a per-tone volume control. The audio is generated from the original waveforms below,
/// which keeps the catalog self-contained and avoids bundling third-party audio assets.
public enum AnnotationSound: String, CaseIterable, Identifiable, Sendable {
	case bell
	case bloom
	case chime
	case click
	case croak
	case drop
	case echo
	case ping
	case pulse
	case sonar
	case tap

	public var id: String { rawValue }

	var localizedName: String {
		switch self {
		case .bell: L10n.Configuration.soundBell
		case .bloom: L10n.Configuration.soundBloom
		case .chime: L10n.Configuration.soundChime
		case .click: L10n.Configuration.soundClick
		case .croak: L10n.Configuration.soundCroak
		case .drop: L10n.Configuration.soundDrop
		case .echo: L10n.Configuration.soundEcho
		case .ping: L10n.Configuration.soundPing
		case .pulse: L10n.Configuration.soundPulse
		case .sonar: L10n.Configuration.soundSonar
		case .tap: L10n.Configuration.soundTap
		}
	}
}

/// A model's persisted sound preference, made value-only before it crosses into driver actors.
public struct AnnotationSoundConfiguration: Equatable, Sendable {
	static let defaultVolume = 0.2
	static let volumeRange: ClosedRange<Double> = 0...1

	let isEnabled: Bool
	let sound: AnnotationSound
	let volume: Double

	init(isEnabled: Bool = false, sound: AnnotationSound = .chime, volume: Double = defaultVolume) {
		self.isEnabled = isEnabled
		self.sound = sound
		self.volume = min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound)
	}
}

/// A bounded request to play one app-provided annotation sound.
struct AnnotationSoundPlaybackRequest: Equatable, Sendable {
	let sound: AnnotationSound
	let volume: Float

	init(sound: AnnotationSound, volume: Double) {
		self.sound = sound
		self.volume = Float(min(max(volume, AnnotationSoundConfiguration.volumeRange.lowerBound), AnnotationSoundConfiguration.volumeRange.upperBound))
	}

	init?(configuration: AnnotationSoundConfiguration) {
		guard configuration.isEnabled else { return nil }
		self.init(sound: configuration.sound, volume: configuration.volume)
	}
}

/// Small boundary that lets the presentation path be tested without invoking AVFoundation.
protocol AnnotationSoundPlaying: Sendable {
	func play(_ request: AnnotationSoundPlaybackRequest) async
	func play(_ requests: [AnnotationSoundPlaybackRequest]) async
}

extension AnnotationSoundPlaying {
	func play(_ requests: [AnnotationSoundPlaybackRequest]) async {
		for request in requests {
			await play(request)
		}
	}
}

/// Plays every annotation sound through a bounded two-voice queue. `volume` is AVAudioPlayer-local
/// and never changes system volume. Two model sounds can be heard together; a dense batch queues
/// its remaining annotations instead of allocating an unbounded number of players.
actor AnnotationSoundPlayer: AnnotationSoundPlaying {
	private static let releaseDelayNanoseconds: UInt64 = 350_000_000
	private static let maximumActivePlayers = 2
	private var activePlayers: [UUID: AVAudioPlayer] = [:]
	private var queuedRequests: [AnnotationSoundPlaybackRequest] = []

	func play(_ request: AnnotationSoundPlaybackRequest) async {
		queuedRequests.append(request)
		startQueuedRequests()
	}

	func play(_ requests: [AnnotationSoundPlaybackRequest]) async {
		queuedRequests.append(contentsOf: requests)
		startQueuedRequests()
	}

	private func startQueuedRequests() {
		while activePlayers.count < Self.maximumActivePlayers, queuedRequests.isEmpty.not {
			start(queuedRequests.removeFirst())
		}
	}

	private func start(_ request: AnnotationSoundPlaybackRequest) {
		do {
			// Ambient audio respects Silent mode and mixes with an already-playing app, rather than
			// changing the device's output level or interrupting another source.
			try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
			let player = try AVAudioPlayer(data: AnnotationSoundCatalog.audioData(for: request.sound))
			player.volume = request.volume
			player.prepareToPlay()
			player.play()
			let id = UUID()
			activePlayers[id] = player
			Task { [weak self] in
				try? await Task.sleep(nanoseconds: Self.releaseDelayNanoseconds)
				await self?.releasePlayer(id)
			}
		} catch {
			LoggingPolicy.error("Unable to play an annotation sound", error: error, logger: .ui)
		}
	}

	private func releasePlayer(_ id: UUID) {
		activePlayers.removeValue(forKey: id)
		startQueuedRequests()
	}
}

/// Original, synthesized PCM/WAVE data for the app-provided sound catalog.
///
/// Keeping the synthesis here makes provenance explicit: all eleven tones are authored in code,
/// require no external asset license, and resolve identically in previews, tests, and release builds.
enum AnnotationSoundCatalog {
	private static let sampleRate = 44_100
	private static let duration = 0.24
	private static let dataBySound = Dictionary(uniqueKeysWithValues: AnnotationSound.allCases.map {
		($0, makeWAV(for: $0))
	})

	static func audioData(for sound: AnnotationSound) -> Data {
		// Every `AnnotationSound` is populated above. The fallback maintains a valid request if a
		// future enum case is temporarily omitted from the catalog implementation.
		dataBySound[sound] ?? makeWAV(for: .chime)
	}

	private static func makeWAV(for sound: AnnotationSound) -> Data {
		let frameCount = Int(Double(sampleRate) * duration)
		let samples = (0..<frameCount).map { frame -> Int16 in
			let time = Double(frame) / Double(sampleRate)
			let normalizedTime = time / duration
			let envelope = pow(1 - normalizedTime, 2.2)
			let waveform: Double
			switch sound {
			case .bell:
				waveform = sin(2 * .pi * 880 * time) + 0.48 * sin(2 * .pi * 1_322 * time)
			case .bloom:
				let frequency = 420 + 380 * normalizedTime
				waveform = sin(2 * .pi * frequency * time) + 0.32 * sin(2 * .pi * frequency * 1.5 * time)
			case .chime:
				waveform = sin(2 * .pi * 1_318 * time) + 0.45 * sin(2 * .pi * 1_760 * time)
			case .click:
				waveform = sin(2 * .pi * 1_920 * time) * pow(1 - normalizedTime, 5)
			case .croak:
				let frequency = 210 + 60 * sin(2 * .pi * 13 * time)
				waveform = sin(2 * .pi * frequency * time) + 0.22 * sin(2 * .pi * frequency * 2 * time)
			case .drop:
				let frequency = 1_480 - 900 * normalizedTime
				waveform = sin(2 * .pi * frequency * time)
			case .echo:
				let echo = normalizedTime > 0.38 ? 0.38 : 1
				waveform = echo * sin(2 * .pi * 640 * time)
			case .ping:
				waveform = sin(2 * .pi * 1_040 * time) + 0.18 * sin(2 * .pi * 2_080 * time)
			case .pulse:
				waveform = sin(2 * .pi * 760 * time)
			case .sonar:
				let sweep = 330 + 1_070 * normalizedTime
				waveform = sin(2 * .pi * sweep * time) + 0.18 * sin(2 * .pi * sweep * 0.5 * time)
			case .tap:
				waveform = (sin(2 * .pi * 1_260 * time) + 0.4 * sin(2 * .pi * 2_520 * time)) * pow(1 - normalizedTime, 4)
			}
			return Int16((waveform * envelope * 0.42 * Double(Int16.max)).rounded())
		}

		let dataLength = samples.count * MemoryLayout<Int16>.size
		var data = Data()
		data.reserveCapacity(44 + dataLength)
		data.append(Data("RIFF".utf8))
		data.append(littleEndian: UInt32(36 + dataLength))
		data.append(Data("WAVEfmt ".utf8))
		data.append(littleEndian: UInt32(16))
		data.append(littleEndian: UInt16(1))
		data.append(littleEndian: UInt16(1))
		data.append(littleEndian: UInt32(sampleRate))
		data.append(littleEndian: UInt32(sampleRate * MemoryLayout<Int16>.size))
		data.append(littleEndian: UInt16(MemoryLayout<Int16>.size))
		data.append(littleEndian: UInt16(16))
		data.append(Data("data".utf8))
		data.append(littleEndian: UInt32(dataLength))
		for sample in samples {
			data.append(littleEndian: sample)
		}
		return data
	}
}

private extension Data {
	mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
		var value = value.littleEndian
		Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
	}
}

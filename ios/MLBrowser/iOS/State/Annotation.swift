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

	/// The device's current media output level, 0...1 (AIA-0720).
	///
	/// Exposed through this boundary so the sound settings screen can warn about a silenced device
	/// without importing AVFoundation. It reports **media** volume only: iOS offers no way to read
	/// the Silent mode switch, which is a separate condition and the one that actually caused #720.
	func deviceOutputVolume() async -> Float

	/// Ends every sounding voice and refuses new ones until ``resume()`` (#785).
	///
	/// Called when the app leaves the foreground. Nothing else guarantees a player is finished
	/// before the process is suspended and the system tears the shared session down underneath it.
	func suspend() async

	/// Admits playback again after ``suspend()``. Called when the app returns to the foreground.
	func resume() async
}

extension AnnotationSoundPlaying {
	func play(_ requests: [AnnotationSoundPlaybackRequest]) async {
		for request in requests {
			await play(request)
		}
	}
}

/// Decides which playback requests are allowed to start (AIA-0720).
///
/// This is a pure value type on purpose: the actor below is a thin AVFoundation shell, so the whole
/// admission policy stays testable without constructing an `AVAudioPlayer`.
///
/// A dense detection pass is thinned by **dropping**, never by queueing. The shipped AIA-0716
/// behaviour queued every surplus annotation behind a two-voice limit, so a five-object pass was
/// heard as a lock-stepped sequence trailing the detections that caused it.
struct AnnotationSoundAdmissionPolicy: Sendable {
	/// Simultaneous voices. Deliberately small: the catalog is generated at 0.42 of full scale, and
	/// near-phase-aligned copies of one tone sum, so a high cap clips instead of sounding louder.
	static let maximumActiveVoices = 3

	/// Gap between two onsets **of the same sound**. A concurrency cap alone is not a rate cap —
	/// voices free continuously, so three slots over a ~0.35 s hold still admit an unbroken wall of
	/// tone. This interval is what actually bounds the rate.
	static let minimumInterOnsetInterval: TimeInterval = 0.15

	/// How many objects one run may announce with the same sound. Beyond this the remaining
	/// detections are dropped rather than extending the run indefinitely.
	static let maximumStaggeredOnsets = 3

	/// A run of onsets for one sound: when the next may be heard, and how many have been granted.
	///
	/// The count is tracked explicitly rather than derived from the delay. Deriving it invited a
	/// float hazard: each delay is an accumulated sum of `minimumInterOnsetInterval`, so a fourth
	/// onset computed a delay of 0.4499999999825377 against a 0.45 horizon and was admitted — a cap
	/// that held or broke depending on the device's uptime. An integer cannot drift.
	private struct Run {
		var nextOnset: TimeInterval
		var grantedOnsets: Int
	}

	private var runBySound: [AnnotationSound: Run] = [:]

	init() {}

	/// Decides whether a request plays, and if so how long to wait first.
	///
	/// **Keyed per sound rather than globally**, and that distinction is load-bearing (AIA-0720):
	/// `AnnotationSoundEventCoordinator` emits requests in driver-registration order, so a single
	/// global gate would let the first-registered model win every slot under saturation and a second
	/// model's tone would never be heard — defeating the point of telling models apart by ear.
	///
	/// **Same-sound detections are staggered, not collapsed.** Firing N identical waveforms at one
	/// instant does not sound like N: phase-aligned copies sum into a single louder tone and clip.
	/// Spacing the onsets is the only way a listener can hear that three things were found rather
	/// than one, which is what "one sound per object" has to mean in practice.
	///
	/// **This is a rolling limiter, not a per-pass counter**, and the distinction is deliberate. A
	/// detection pass publishes partial results before its final ones, so "per pass" would be the
	/// wrong unit: two bursts arriving 80 ms apart would each be granted a full run and the density
	/// this exists to bound would return. A run therefore spans whatever arrives inside it and only
	/// resets once the sound has gone quiet — in practice every ordinary pass, which arrives seconds
	/// after the last, starts a fresh run.
	///
	/// - Parameter now: a monotonic timestamp; callers pass `ProcessInfo.processInfo.systemUptime`
	///   so the gate cannot be skewed by a wall-clock adjustment.
	/// - Returns: the delay to wait before starting playback, or `nil` if the request is dropped.
	mutating func admissionDelay(
		for sound: AnnotationSound,
		activeVoices: Int,
		now: TimeInterval
	) -> TimeInterval? {
		guard activeVoices < Self.maximumActiveVoices else { return nil }

		// A run that has already been heard out is over: the next detection starts a new one, which
		// is what lets a stationary object sound again on the following pass.
		var run = runBySound[sound] ?? Run(nextOnset: now, grantedOnsets: 0)
		if now >= run.nextOnset {
			run = Run(nextOnset: now, grantedOnsets: 0)
		}

		// Drop rather than extend: a dense burst shortens to a fixed-length run instead of trailing
		// the detections that caused it — the failure AIA-0716's FIFO produced.
		guard run.grantedOnsets < Self.maximumStaggeredOnsets else { return nil }

		let delay = max(run.nextOnset - now, 0)
		runBySound[sound] = Run(
			nextOnset: max(run.nextOnset, now) + Self.minimumInterOnsetInterval,
			grantedOnsets: run.grantedOnsets + 1
		)
		return delay
	}
}

/// Plays annotation sounds through a bounded, rate-limited set of voices. `volume` is
/// AVAudioPlayer-local and never changes system volume. Surplus requests are dropped rather than
/// queued, so what is heard always corresponds to detections happening now.
actor AnnotationSoundPlayer: AnnotationSoundPlaying {
	private static let playerRetentionBufferNanoseconds: UInt64 = 110_000_000

	/// The session category every annotation sound plays under.
	///
	/// Exposed rather than inlined because it is a **user-facing promise**, not just an audio
	/// setting: the Sound screen tells the user that detection sounds follow Silent mode
	/// (`L10n.Configuration.soundOutputNote`), which is true only while this stays `.ambient`.
	/// `AnnotationSoundCategoryTests` pins the two together so a future change to `.playback`
	/// cannot silently turn shipped copy into a lie (AIA-0720).
	static let sessionCategory: AVAudioSession.Category = .ambient

	private var activePlayers: [UUID: AVAudioPlayer] = [:]

	/// Set between ``suspend()`` and ``resume()``, i.e. while the app is not in the foreground.
	///
	/// A latch and not just a one-shot stop: `suspend()` is reached by an actor hop, so a detection
	/// pass already in flight when the app backgrounded can deliver its requests *after* it runs.
	/// Without this the burst would start a fresh voice into a process about to be suspended, which
	/// is precisely the state `suspend()` exists to leave behind (#785).
	private var isSuspended = false

	private var admissionPolicy = AnnotationSoundAdmissionPolicy()
	/// Last environment reported by `logPlaybackEnvironment`, so continuous detection logs
	/// transitions rather than one line per pass.
	private var lastLoggedEnvironment: String?

	/// Holds each player until its actual audio stream has finished, plus a short scheduling buffer.
	/// Using `AVAudioPlayer.duration` means a future longer catalog tone cannot be truncated by a
	/// disconnected retention constant.
	static func playerRetentionNanoseconds(for playbackDuration: TimeInterval) -> UInt64 {
		let durationNanoseconds = UInt64((max(playbackDuration, 0) * 1_000_000_000).rounded(.up))
		return durationNanoseconds + Self.playerRetentionBufferNanoseconds
	}

	func play(_ request: AnnotationSoundPlaybackRequest) async {
		startBurst([request])
	}

	func play(_ requests: [AnnotationSoundPlaybackRequest]) async {
		startBurst(requests)
	}

	/// One burst = one `play(_:)` call. The session is asserted once per burst rather than once per
	/// request, so a dense pass does not re-enter AVAudioSession for every annotation.
	private func startBurst(_ requests: [AnnotationSoundPlaybackRequest]) {
		guard requests.isEmpty.not else { return }
		// Nothing may start while the app is on its way out of the foreground; see `isSuspended`.
		guard isSuspended.not else { return }
		// Fail closed, as AIA-0716 did. If the category could not be established, the shared session
		// may still be whatever WebKit left behind — possibly `.playback`, which plays straight
		// through Silent mode. Staying silent is the only outcome consistent with what the Sound
		// screen promises the user.
		guard prepareSession() else { return }
		for request in requests {
			start(request)
		}
	}

	private func start(_ request: AnnotationSoundPlaybackRequest) {
		guard let delay = admissionPolicy.admissionDelay(
			for: request.sound,
			activeVoices: activePlayers.count,
			now: ProcessInfo.processInfo.systemUptime
		) else { return }

		guard delay <= 0 else {
			// A later object in the same pass: hold it briefly so the run is countable by ear
			// instead of summing into one louder tone.
			Task { [weak self] in
				do {
					try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
				} catch {
					return
				}
				await self?.startImmediately(request)
			}
			return
		}

		startImmediately(request)
	}

	private func startImmediately(_ request: AnnotationSoundPlaybackRequest) {
		// Re-checked here and not only in `startBurst`: a staggered onset is a detached task that
		// `suspend()` neither retains nor cancels, so it can wake *after* the app has gone to the
		// background, find `activePlayers` empty, and start a fresh voice into a process about to be
		// suspended — the latch defeated by the one path that does not go through the gate (#785).
		guard isSuspended.not else { return }

		// Re-checked here, not only at admission. A staggered onset was admitted against the voice
		// count at *scheduling* time — typically near zero, since nothing in the pass had started
		// yet — so without this the cap could be exceeded by the time the delay elapses. Dropping is
		// the right outcome: the reserved onset slot has already moved on, and this path never queues.
		guard activePlayers.count < AnnotationSoundAdmissionPolicy.maximumActiveVoices else { return }

		do {
			let player = try AVAudioPlayer(data: AnnotationSoundCatalog.audioData(for: request.sound))
			player.volume = request.volume
			// Both of these report failure by returning `false`, not by throwing. Discarding them —
			// as this path did before AIA-0720 — is how a device can produce no sound at all while
			// leaving a completely clean log, which is exactly what happened in #720.
			guard player.prepareToPlay() else {
				LoggingPolicy.error("Annotation sound refused to prepare", logger: .ui)
				return
			}
			guard player.play() else {
				LoggingPolicy.error("Annotation sound refused to start", logger: .ui)
				return
			}
			let id = UUID()
			let retentionNanoseconds = Self.playerRetentionNanoseconds(for: player.duration)
			activePlayers[id] = player
			Task { [weak self] in
				// `try?` would swallow cancellation and fall straight through to `releasePlayer`,
				// dropping the last strong reference to a still-playing player and truncating it
				// audibly. Nothing cancels this task today; the guard keeps that true by accident
				// from becoming true by luck.
				do {
					try await Task.sleep(nanoseconds: retentionNanoseconds)
				} catch {
					return
				}
				await self?.releasePlayer(id)
			}
		} catch {
			LoggingPolicy.error("Unable to play an annotation sound", error: error, logger: .ui)
		}
	}

	/// Re-asserted on **every** burst rather than latched once per process (AIA-0720).
	///
	/// This app is a web browser: WebKit manipulates the shared `AVAudioSession` when page media
	/// plays, and any interruption — a call, Siri, an alarm, a media-services reset — deactivates it.
	/// A once-per-process latch left the category stale for the rest of the run with nothing to
	/// re-establish it.
	/// - Returns: whether the session is safe to play through.
	@discardableResult
	private func prepareSession() -> Bool {
		let session = AVAudioSession.sharedInstance()
		do {
			// `.ambient` respects Silent mode and mixes with an already-playing app, rather than
			// changing the device's output level or interrupting another source. See
			// `sessionCategory` for why this is a promise rather than a preference.
			//
			// Establishing the category is what makes activation safe: activating whatever category
			// happens to be current could interrupt another app, because the process default
			// (`.soloAmbient`) does not mix.
			try session.setCategory(Self.sessionCategory, options: [.mixWithOthers])
		} catch {
			LoggingPolicy.error("Unable to configure the annotation audio session", error: error, logger: .ui)
			logPlaybackEnvironment(session)
			return false
		}

		do {
			try session.setActive(true)
		} catch {
			// Not fatal: the category is correct, so playback still respects Silent mode and mixes.
			// Only the route/volume diagnostic below is less trustworthy.
			LoggingPolicy.error("Unable to activate the annotation audio session", error: error, logger: .ui)
		}

		logPlaybackEnvironment(session)
		return true
	}

	/// Everything a future "no sound on my device" report needs, in one line.
	///
	/// iOS exposes **no** API for the Silent mode switch, so this deliberately cannot report the one
	/// condition that caused #720. It reports every neighbouring condition instead, so that ruling
	/// them out leaves Silent mode as the remaining explanation rather than a guess.
	///
	/// **Logged on change, not per burst.** Detection passes run continuously, so a line per burst
	/// would add tens of entries a minute to a size-capped, rotating support log — evicting the very
	/// evidence this exists to preserve. Emitting only when the environment actually differs keeps
	/// the first state and every transition (a volume change, a route change) and drops the rest.
	private func logPlaybackEnvironment(_ session: AVAudioSession) {
		let route = session.currentRoute.outputs
			.map { "\($0.portType.rawValue)" }
			.joined(separator: ",")
		let environment = """
			category=\(session.category.rawValue) \
			outputVolume=\(String(format: "%.2f", session.outputVolume)) \
			route=\(route.isEmpty ? "none" : route) \
			otherAudioPlaying=\(session.isOtherAudioPlaying) \
			secondaryAudioSilenced=\(session.secondaryAudioShouldBeSilencedHint)
			"""

		guard environment != lastLoggedEnvironment else { return }
		lastLoggedEnvironment = environment
		LoggingPolicy.debug("Annotation sound environment: \(environment)", logger: .ui)
	}

	func deviceOutputVolume() async -> Float {
		// Deliberately does **not** activate the session. Merely opening the Sound screen must not
		// interrupt music playing in another app, and activating the process-default `.soloAmbient`
		// category — which does not mix — would do exactly that. `outputVolume` is readable without
		// activation, so the polite read is also the correct one.
		AVAudioSession.sharedInstance().outputVolume
	}

	/// Stops a player **before** the last strong reference to it goes (#785).
	///
	/// The retention window is wall-clock — `duration` plus `playerRetentionBufferNanoseconds` — so
	/// it is a prediction about when the stream ends, not an observation of it. Whenever CoreAudio
	/// misses render cycles (`HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload`) the
	/// stream outlives the prediction, and deallocating then tore the audio queue down underneath
	/// the render thread: `EXC_BAD_ACCESS` inside `AVAudioPlayerCpp`, reported from a Mac running
	/// continuous detection with overlapping annotation sounds.
	///
	/// `stop()` is synchronous and undoes `prepareToPlay()`, so after it returns the deallocation
	/// has nothing left to race.
	private func releasePlayer(_ id: UUID) {
		activePlayers.removeValue(forKey: id)?.stop()
	}

	/// Ends every voice and drops the players, so none survives into a suspended process.
	///
	/// The retention tasks still fire on their own schedule; `releasePlayer` is a no-op for an id
	/// already removed here, and calling `stop()` twice on one player is well defined.
	func suspend() {
		isSuspended = true
		for player in activePlayers.values {
			player.stop()
		}
		activePlayers.removeAll()
	}

	func resume() {
		isSuspended = false
	}
}

/// Original, synthesized PCM/WAVE data for the app-provided sound catalog.
///
/// Keeping the synthesis here makes provenance explicit: all eleven tones are authored in code,
/// require no external asset license, and resolve identically in previews, tests, and release builds.
enum AnnotationSoundCatalog {
	private static let sampleRate = 44_100
	static let duration = 0.24
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

//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.


import Accelerate
import AVFAudio
import CoreML
import Hub
import NaturalLanguage
import Tokenizers

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
public typealias FloatType = Float16
#else
public typealias FloatType = Float
#endif

#if (os(macOS) || targetEnvironment(macCatalyst)) && arch(arm64) && compiler(<6)
extension Float16: BNNSScalar {}
extension Float16: MLShapedArrayScalar {}
#endif

// MARK: - CoreML

public protocol WhisperMLModel: AnyObject {
    var model: MLModel? { get set }
    func loadModel(at modelPath: URL, computeUnits: MLComputeUnits, prewarmMode: Bool) async throws
    func unloadModel()
}

public extension WhisperMLModel {
    func loadModel(at modelPath: URL, computeUnits: MLComputeUnits, prewarmMode: Bool = false) async throws {
        let loadedModel = try await Task {
            let modelConfig = MLModelConfiguration()
            modelConfig.computeUnits = computeUnits
            return try await MLModel.load(contentsOf: modelPath, configuration: modelConfig)
        }.value

        model = prewarmMode ? nil : loadedModel
    }

    func unloadModel() {
        model = nil
    }

    var modelState: ModelState {
        return model == nil ? .unloaded : .loaded
    }
}

// MARK: - Whisper Models

public enum ModelVariant: CustomStringConvertible, CaseIterable {
    case tiny
    case tinyEn
    case base
    case baseEn
    case small
    case smallEn
    case medium
    case mediumEn
    case large
    case largev2
    case largev3

    // TODO: implement config.json and generation_config.json parsing for models
    public var isMultilingual: Bool {
        switch self {
            case .tiny, .base, .small, .medium, .large, .largev2, .largev3:
                return true
            case .tinyEn, .baseEn, .smallEn, .mediumEn:
                return false
        }
    }

    public var description: String {
        switch self {
            case .tiny:
                return "tiny"
            case .tinyEn:
                return "tiny.en"
            case .base:
                return "base"
            case .baseEn:
                return "base.en"
            case .small:
                return "small"
            case .smallEn:
                return "small.en"
            case .medium:
                return "medium"
            case .mediumEn:
                return "medium.en"
            case .large:
                return "large"
            case .largev2:
                return "large-v2"
            case .largev3:
                return "large-v3"
        }
    }
}

public enum ModelState: CustomStringConvertible {
    case unloading
    case unloaded
    case loading
    case loaded
    case prewarming
    case prewarmed
    case downloading
    case downloaded

    public var description: String {
        switch self {
            case .unloading:
                return "Unloading"
            case .unloaded:
                return "Unloaded"
            case .loading:
                return "Loading"
            case .loaded:
                return "Loaded"
            case .prewarming:
                return "Specializing"
            case .prewarmed:
                return "Specialized"
            case .downloading:
                return "Downloading"
            case .downloaded:
                return "Downloading"
        }
    }
}

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public struct ModelComputeOptions {
    public var melCompute: MLComputeUnits
    public var audioEncoderCompute: MLComputeUnits
    public var textDecoderCompute: MLComputeUnits
    public var prefillCompute: MLComputeUnits

    public init(
        melCompute: MLComputeUnits = .cpuAndGPU,
        audioEncoderCompute: MLComputeUnits? = nil,
        textDecoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
        prefillCompute: MLComputeUnits = .cpuOnly
    ) {
        if WhisperKit.isRunningOnSimulator {
            self.melCompute = .cpuOnly
            self.audioEncoderCompute = .cpuOnly
            self.textDecoderCompute = .cpuOnly
            self.prefillCompute = .cpuOnly
            return
        }

        self.melCompute = melCompute
        self.prefillCompute = prefillCompute
        self.textDecoderCompute = textDecoderCompute

        if #available(macOS 14.0, iOS 17.0, *) {
            self.audioEncoderCompute = audioEncoderCompute ?? .cpuAndNeuralEngine
        } else {
            self.audioEncoderCompute = audioEncoderCompute ?? .cpuAndGPU
        }
    }
}

public struct ModelSupport: Codable, Equatable {
    public let `default`: String
    public let supported: [String]
    /// Computed on init of ModelRepoConfig
    public var disabled: [String] = []

    private enum CodingKeys: String, CodingKey {
        case `default`, supported
    }
}

public struct DeviceSupport: Codable {
    public let identifiers: [String]
    public var models: ModelSupport
}

public struct ModelSupportConfig: Codable {
    public let repoName: String
    public let repoVersion: String
    public var deviceSupports: [DeviceSupport]
    /// Computed on init
    public private(set) var knownModels: [String]
    public private(set) var defaultSupport: DeviceSupport

    enum CodingKeys: String, CodingKey {
        case repoName = "name"
        case repoVersion = "version"
        case deviceSupports = "device_support"
    }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repoName = try container.decode(String.self, forKey: .repoName)
        let repoVersion = try container.decode(String.self, forKey: .repoVersion)
        let deviceSupports = try container.decode([DeviceSupport].self, forKey: .deviceSupports)

        self.init(repoName: repoName, repoVersion: repoVersion, deviceSupports: deviceSupports)
    }

    public init(repoName: String, repoVersion: String, deviceSupports: [DeviceSupport], includeFallback: Bool = true) {
        self.repoName = repoName
        self.repoVersion = repoVersion

        if includeFallback {
            self.deviceSupports = Self.mergeDeviceSupport(remote: deviceSupports, fallback: Constants.fallbackModelSupportConfig.deviceSupports)
            self.knownModels = self.deviceSupports.flatMap { $0.models.supported }.orderedSet
        } else {
            self.deviceSupports = deviceSupports
            self.knownModels = deviceSupports.flatMap { $0.models.supported }.orderedSet
        }

        // Add default device support with all models supported for unknown devices
        self.defaultSupport = DeviceSupport(
            identifiers: [],
            models: ModelSupport(
                default: "openai_whisper-base",
                supported: self.knownModels
            )
        )

        computeDisabledModels()
    }

    @available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
    public func modelSupport(for deviceIdentifier: String = WhisperKit.deviceName()) -> ModelSupport {
        for support in deviceSupports {
            if support.identifiers.contains(where: { deviceIdentifier.hasPrefix($0) }) {
                return support.models
            }
        }

        Logging.info("No device support found for \(deviceIdentifier), using default")
        return defaultSupport.models
    }

    private mutating func computeDisabledModels() {
        for i in 0..<deviceSupports.count {
            let disabledModels = Set(knownModels).subtracting(deviceSupports[i].models.supported)
            self.deviceSupports[i].models.disabled = Array(disabledModels)
        }
    }

    private static func mergeDeviceSupport(remote: [DeviceSupport], fallback: [DeviceSupport]) -> [DeviceSupport] {
        var mergedSupports: [DeviceSupport] = []
        let remoteIdentifiers = Set(remote.flatMap { $0.identifiers })

        // Add remote device supports, merging with fallback if identifiers overlap
        for remoteSupport in remote {
            if let fallbackSupport = fallback.first(where: { $0.identifiers.contains(where: remoteSupport.identifiers.contains) }) {
                let mergedModels = ModelSupport(
                    default: remoteSupport.models.default,
                    supported: (remoteSupport.models.supported + fallbackSupport.models.supported).orderedSet
                )
                mergedSupports.append(DeviceSupport(identifiers: remoteSupport.identifiers, models: mergedModels))
            } else {
                mergedSupports.append(remoteSupport)
            }
        }

        // Add fallback device supports that don't overlap with remote
        for fallbackSupport in fallback where !fallbackSupport.identifiers.contains(where: remoteIdentifiers.contains) {
            mergedSupports.append(fallbackSupport)
        }

        return mergedSupports
    }
}

// MARK: - Chunking

public struct AudioChunk {
    public var seekOffsetIndex: Int
    public var audioSamples: [Float]
}

// MARK: - Decoding

public enum DecodingTask: Codable, CustomStringConvertible, CaseIterable {
    case transcribe
    case translate

    public var description: String {
        switch self {
            case .transcribe:
                return "transcribe"
            case .translate:
                return "translate"
        }
    }
}

public struct DecodingInputs {
    public var initialPrompt: [Int]
    public var inputIds: MLMultiArray
    public var cacheLength: MLMultiArray
    public var keyCache: MLMultiArray
    public var valueCache: MLMultiArray
    public var alignmentWeights: MLMultiArray
    public var kvCacheUpdateMask: MLMultiArray
    public var decoderKeyPaddingMask: MLMultiArray
    public var prefillKeyCache: MLMultiArray
    public var prefillValueCache: MLMultiArray

    public init(initialPrompt: [Int], inputIds: MLMultiArray, cacheLength: MLMultiArray, keyCache: MLMultiArray, valueCache: MLMultiArray, alignmentWeights: MLMultiArray, kvCacheUpdateMask: MLMultiArray, decoderKeyPaddingMask: MLMultiArray, prefillKeyCache: MLMultiArray, prefillValueCache: MLMultiArray) {
        self.initialPrompt = initialPrompt
        self.inputIds = inputIds
        self.cacheLength = cacheLength
        self.keyCache = keyCache
        self.valueCache = valueCache
        self.alignmentWeights = alignmentWeights
        self.kvCacheUpdateMask = kvCacheUpdateMask
        self.decoderKeyPaddingMask = decoderKeyPaddingMask
        self.prefillKeyCache = prefillKeyCache
        self.prefillValueCache = prefillValueCache
    }

    func reset(prefilledCacheSize: Int, maxTokenContext: Int) {
        // NOTE: Because we have a mask on the kvcache,
        // we can simply shift the masks without touching the data,
        // it will be overwritten by the new data without impact on the output
        cacheLength[0] = NSNumber(value: prefilledCacheSize - 1)

        // Store token history and
        // Reset masks to prepare for next window
        for i in 0..<maxTokenContext {
            if i <= prefilledCacheSize - 1 {
                // Inside overlap window
                decoderKeyPaddingMask[i] = 0
                kvCacheUpdateMask[i - 1] = 0
                kvCacheUpdateMask[i] = 1
            } else {
                // Padding
                decoderKeyPaddingMask[i] = -10000
                kvCacheUpdateMask[i] = 0
            }
        }
    }
}

public struct DecodingCache {
    public var keyCache: MLMultiArray?
    public var valueCache: MLMultiArray?
    public var alignmentWeights: MLMultiArray?
    public init(keyCache: MLMultiArray? = nil, valueCache: MLMultiArray? = nil, alignmentWeights: MLMultiArray? = nil) {
        self.keyCache = keyCache
        self.valueCache = valueCache
        self.alignmentWeights = alignmentWeights
    }
}

public enum ChunkingStrategy: String, Codable, CaseIterable {
    case none
    case vad
}

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public struct DecodingFallback {
    public var needsFallback: Bool
    public var fallbackReason: String

    public init(needsFallback: Bool, fallbackReason: String) {
        self.needsFallback = needsFallback
        self.fallbackReason = fallbackReason
    }
}

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public extension DecodingFallback {
    init?(
        options: DecodingOptions,
        isFirstTokenLogProbTooLow: Bool,
        noSpeechProb: Float,
        compressionRatio: Float,
        avgLogProb: Float
    ) {
        // NOTE: order matters here
        if isFirstTokenLogProbTooLow {
            self.init(needsFallback: true, fallbackReason: "firstTokenLogProbThreshold")
        } else if let threshold = options.noSpeechThreshold, noSpeechProb > threshold {
            // silence detected
            self.init(needsFallback: false, fallbackReason: "silence")
        } else if let threshold = options.compressionRatioThreshold, compressionRatio > threshold {
            // too repetitive
            self.init(needsFallback: true, fallbackReason: "compressionRatioThreshold")
        } else if let threshold = options.logProbThreshold, avgLogProb < threshold {
            // average log probablity too low (model is not confident enough)
            self.init(needsFallback: true, fallbackReason: "logProbThreshold")
        } else {
            return nil
        }
    }
}

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public struct DecodingResult {
    public var language: String
    public var languageProbs: [String: Float]
    public var tokens: [Int]
    public var tokenLogProbs: [[Int: Float]]
    public var text: String
    public var avgLogProb: Float
    public var noSpeechProb: Float
    public var temperature: Float
    public var compressionRatio: Float
    public var cache: DecodingCache?
    public var timings: TranscriptionTimings?
    public var fallback: DecodingFallback?

    public static var emptyResults: DecodingResult {
        return DecodingResult(language: "",
                              languageProbs: [:],
                              tokens: [],
                              tokenLogProbs: [],
                              text: "",
                              avgLogProb: 0.0,
                              noSpeechProb: 0.0,
                              temperature: 0.0,
                              compressionRatio: 0.0,
                              cache: nil,
                              timings: nil,
                              fallback: nil)
    }

    public init(language: String, languageProbs: [String: Float], tokens: [Int], tokenLogProbs: [[Int: Float]], text: String, avgLogProb: Float, noSpeechProb: Float, temperature: Float, compressionRatio: Float, cache: DecodingCache? = nil, timings: TranscriptionTimings? = nil, fallback: DecodingFallback? = nil) {
        self.language = language
        self.languageProbs = languageProbs
        self.tokens = tokens
        self.tokenLogProbs = tokenLogProbs
        self.text = text
        self.avgLogProb = avgLogProb
        self.noSpeechProb = noSpeechProb
        self.temperature = temperature
        self.compressionRatio = compressionRatio
        self.cache = cache
        self.timings = timings
        self.fallback = fallback
    }
}

public enum WhisperError: Error, LocalizedError, Equatable {
    case tokenizerUnavailable(String = "Tokenizer is unavailable")
    case modelsUnavailable(String = "Models are unavailable")
    case prefillFailed(String = "Prefill failed")
    case audioProcessingFailed(String = "Audio processing failed")
    case decodingLogitsFailed(String = "Unable to decode logits from the model output")
    case segmentingFailed(String = "Creating segments failed")
    case loadAudioFailed(String = "Load audio failed")
    case prepareDecoderInputsFailed(String = "Prepare decoder inputs failed")
    case transcriptionFailed(String = "Transcription failed")
    case decodingFailed(String = "Decoding failed")
    case microphoneUnavailable(String = "No available microphone to record or stream")

    public var errorDescription: String? {
        switch self {
            case let .tokenizerUnavailable(message):
                Logging.error(message)
                return message
            case let .modelsUnavailable(message):
                Logging.error(message)
                return message
            case let .prefillFailed(message):
                Logging.error(message)
                return message
            case let .audioProcessingFailed(message):
                Logging.error(message)
                return message
            case let .decodingLogitsFailed(message):
                Logging.error(message)
                return message
            case let .segmentingFailed(message):
                Logging.error(message)
                return message
            case let .loadAudioFailed(message):
                Logging.error(message)
                return message
            case let .prepareDecoderInputsFailed(message):
                Logging.error(message)
                return message
            case let .transcriptionFailed(message):
                Logging.error(message)
                return message
            case let .decodingFailed(message):
                Logging.error(message)
                return message
            case let .microphoneUnavailable(message):
                Logging.error(message)
                return message
        }
    }
}

// Structs

public struct TranscriptionResult: Codable {
    public var text: String
    public var segments: [TranscriptionSegment]
    public var language: String
    public var timings: TranscriptionTimings
    public var seekTime: Float?

    public func logSegments() {
        for (i, segment) in segments.enumerated() {
            let start = segment.start
            let end = segment.end
            let text = segment.text
            let line = "[Segment \(i)] [\(formatTimestamp(start)) --> \(formatTimestamp(end))] \(text)"
            Logging.debug(line)
        }
    }

    public func logTimings() {
        // Calculate the full pipeline duration in milliseconds
        let decodeLoopTime = timings.decodingLoop
        let totalLoops = timings.totalDecodingLoops
        let decodeTimePerWindow = decodeLoopTime / timings.totalAudioProcessingRuns
        let timeToFirstToken = timings.firstTokenTime - timings.pipelineStart
        let tokensPerSecond = timings.tokensPerSecond
        let rtf = timings.realTimeFactor
        let totalTokens = segments.reduce(0) { $0 + $1.tokens.count }

        // NOTE: this is a relative value for percentage calculations
        let fullDecodingDuration = max(timings.decodingLoop, timings.fullPipeline) * 1000 // Convert to milliseconds

        let audioLoadTime = formatTimeWithPercentage(timings.audioLoading, 1, fullDecodingDuration)
        let audioProcTime = formatTimeWithPercentage(timings.audioProcessing, timings.totalAudioProcessingRuns, fullDecodingDuration)
        let logmelsTime = formatTimeWithPercentage(timings.logmels, timings.totalLogmelRuns, fullDecodingDuration)
        let encodingTime = formatTimeWithPercentage(timings.encoding, timings.totalEncodingRuns, fullDecodingDuration)
        let decodingInitTime = formatTimeWithPercentage(timings.decodingInit, 1, fullDecodingDuration)
        let prefillInfo = formatTimeWithPercentage(timings.prefill, 1, fullDecodingDuration)
        let predictionsInfo = formatTimeWithPercentage(timings.decodingPredictions, totalLoops, fullDecodingDuration)
        let filteringInfo = formatTimeWithPercentage(timings.decodingFiltering, totalLoops, fullDecodingDuration)
        let samplingInfo = formatTimeWithPercentage(timings.decodingSampling, totalLoops, fullDecodingDuration)
        let kvCachingInfo = formatTimeWithPercentage(timings.decodingKvCaching, timings.totalKVUpdateRuns, fullDecodingDuration)
        let wordTimestampInfo = formatTimeWithPercentage(timings.decodingWordTimestamps, timings.totalTimestampAlignmentRuns, fullDecodingDuration)
        let nonPredTimeInfo = formatTimeWithPercentage(timings.decodingNonPrediction, totalLoops, fullDecodingDuration)
        let windowingInfo = formatTimeWithPercentage(timings.decodingWindowing - timings.decodingWordTimestamps, timings.totalDecodingWindows, fullDecodingDuration)
        let fallbackInfo = formatTimeWithPercentage(timings.decodingFallback, timings.totalDecodingFallbacks, fullDecodingDuration)
        let decodingLoopInfo = formatTimeWithPercentage(timings.decodingLoop, totalLoops, fullDecodingDuration)

        // Logging
        Logging.info("""
        ---- Transcription Timings ----
        Audio Load:          \(audioLoadTime)
        Audio Processing:    \(audioProcTime)
        Mels:                \(logmelsTime)
        Encoding:            \(encodingTime)
        Matrices Init:       \(decodingInitTime)
        Prefill:             \(prefillInfo)
        Decoding:            \(predictionsInfo)
        Non-inference:       \(nonPredTimeInfo)
        - Logit Filtering:   \(filteringInfo)
        - Sampling:          \(samplingInfo)
        - Kv Caching:        \(kvCachingInfo)
        - Word Timestamps:   \(wordTimestampInfo)
        - Windowing:         \(windowingInfo)
        Fallbacks:           \(fallbackInfo)
        Decoding Full Loop:  \(decodingLoopInfo)
        -------------------------------
        Model Load Time:               \(String(format: "%.2f", timings.modelLoading)) seconds
        - Prewarm:                     \(String(format: "%.2f", timings.prewarmLoadTime)) seconds
        - Encoder:                     \(String(format: "%.2f", timings.encoderLoadTime)) seconds
        - Decoder:                     \(String(format: "%.2f", timings.decoderLoadTime)) seconds
        - Tokenizer:                   \(String(format: "%.2f", timings.tokenizerLoadTime)) seconds
        Inference Duration (Global):   \(String(format: "%.2f", timings.fullPipeline)) seconds
        - Decoding Loop (Avg/window):  \(String(format: "%.2f", decodeTimePerWindow)) seconds
        - Audio Windows:               \(String(format: "%.2f", timings.totalAudioProcessingRuns))
        Time to first token:           \(String(format: "%.2f", timeToFirstToken)) seconds
        Total Tokens:                  \(totalTokens)
        Tokens per Second:             \(String(format: "%.2f", tokensPerSecond)) tok/s
        Real Time Factor:              \(String(format: "%.3f", rtf))
        Fallbacks:                     \(timings.totalDecodingFallbacks)
        """)
    }
}

public extension TranscriptionResult {
    var allWords: [WordTiming] {
        return segments.compactMap { $0.words }.flatMap { $0 }
    }
}

public struct TranscriptionSegment: Hashable, Codable {
    public var id: Int = 0
    public var seek: Int = 0
    public var start: Float = 0.0
    public var end: Float = 0.0
    public var text: String = ""
    public var tokens: [Int] = []
    public var tokenLogProbs: [[Int: Float]] = [[:]]
    public var temperature: Float = 1.0
    public var avgLogprob: Float = 0.0
    public var compressionRatio: Float = 1.0
    public var noSpeechProb: Float = 0.0
    public var words: [WordTiming]? = nil
}

public struct WordTiming: Hashable, Codable {
    public var word: String
    public var tokens: [Int]
    public var start: Float
    public var end: Float
    public var probability: Float
}

public struct TranscriptionProgress {
    public var timings: TranscriptionTimings
    public var text: String
    public var tokens: [Int]
    public var temperature: Float?
    public var avgLogprob: Float?
    public var compressionRatio: Float?
    public var windowId: Int = 0

    public init(timings: TranscriptionTimings, text: String, tokens: [Int], temperature: Float? = nil, avgLogprob: Float? = nil, compressionRatio: Float? = nil, windowId: Int = 0) {
        self.timings = timings
        self.text = text
        self.tokens = tokens
        self.temperature = temperature
        self.avgLogprob = avgLogprob
        self.compressionRatio = compressionRatio
        self.windowId = windowId
    }
}

// Callbacks to receive state updates during transcription.

/// A callback that provides transcription segments as they are discovered.
/// - Parameters:
///   - segments: An array of `TranscriptionSegment` objects representing the transcribed segments
public typealias SegmentDiscoveryCallback = (_ segments: [TranscriptionSegment]) -> Void

/// A callback that reports changes in the model's state.
/// - Parameters:
///   - oldState: The previous state of the model, if any
///   - newState: The current state of the model
public typealias ModelStateCallback = (_ oldState: ModelState?, _ newState: ModelState) -> Void

/// A callback that reports changes in the transcription process.
/// - Parameter state: The current `TranscriptionState` of the transcription process
public typealias TranscriptionStateCallback = (_ state: TranscriptionState) -> Void

/// Represents the different states of the transcription process.
public enum TranscriptionState: CustomStringConvertible {
    /// The audio is being converted to the required format for transcription
    case convertingAudio

    /// The audio is actively being transcribed to text
    case transcribing

    /// The transcription process has completed
    case finished

    /// A human-readable description of the transcription state
    public var description: String {
        switch self {
            case .convertingAudio:
                return "Converting Audio"
            case .transcribing:
                return "Transcribing"
            case .finished:
                return "Finished"
        }
    }
}

/// Callback to receive progress updates during transcription.
///
/// - Parameters:
///   - progress: The current transcription progress, including the transcribed text, tokens, and other relevant information.
///
/// - Returns: A Boolean value indicating whether to continue the transcription process or stop early.
///   - `true`: Continue the transcription process.
///   - `false`: Stop the transcription process early.
///   - `nil`: Continue the transcription process (equivalent to returning `true`).
/// - Note: This callback should be lightweight and return as quickly as possible to avoid extra decoding loops
public typealias TranscriptionCallback = ((TranscriptionProgress) -> Bool?)?

public struct TranscriptionTimings: Codable {
    public var pipelineStart: CFAbsoluteTime
    public var firstTokenTime: CFAbsoluteTime
    public var inputAudioSeconds: TimeInterval
    public var modelLoading: TimeInterval
    public var prewarmLoadTime: TimeInterval
    public var encoderLoadTime: TimeInterval
    public var decoderLoadTime: TimeInterval
    public var encoderSpecializationTime: TimeInterval
    public var decoderSpecializationTime: TimeInterval
    public var tokenizerLoadTime: TimeInterval
    public var audioLoading: TimeInterval
    public var audioProcessing: TimeInterval
    public var logmels: TimeInterval
    public var encoding: TimeInterval
    public var prefill: TimeInterval
    public var decodingInit: TimeInterval
    public var decodingLoop: TimeInterval
    public var decodingPredictions: TimeInterval
    public var decodingFiltering: TimeInterval
    public var decodingSampling: TimeInterval
    public var decodingFallback: TimeInterval
    public var decodingWindowing: TimeInterval
    public var decodingKvCaching: TimeInterval
    public var decodingWordTimestamps: TimeInterval
    public var decodingNonPrediction: TimeInterval
    public var totalAudioProcessingRuns: Double
    public var totalLogmelRuns: Double
    public var totalEncodingRuns: Double
    public var totalDecodingLoops: Double
    public var totalKVUpdateRuns: Double
    public var totalTimestampAlignmentRuns: Double
    public var totalDecodingFallbacks: Double
    public var totalDecodingWindows: Double
    public var fullPipeline: TimeInterval

    /// Computed properties
    public var tokensPerSecond: Double {
        Double(totalDecodingLoops) / Double(fullPipeline)
    }

    public var realTimeFactor: Double {
        fullPipeline / inputAudioSeconds
    }

    public var speedFactor: Double {
        inputAudioSeconds / fullPipeline
    }

    /// Initialize with all time intervals set to zero.
    public init(modelLoading: TimeInterval = 0,
                prewarmLoadTime: TimeInterval = 0,
                encoderLoadTime: TimeInterval = 0,
                decoderLoadTime: TimeInterval = 0,
                encoderSpecializationTime: TimeInterval = 0,
                decoderSpecializationTime: TimeInterval = 0,
                tokenizerLoadTime: TimeInterval = 0,
                audioLoading: TimeInterval = 0,
                audioProcessing: TimeInterval = 0,
                logmels: TimeInterval = 0,
                encoding: TimeInterval = 0,
                prefill: TimeInterval = 0,
                decodingInit: TimeInterval = 0,
                decodingLoop: TimeInterval = 0,
                decodingPredictions: TimeInterval = 0,
                decodingFiltering: TimeInterval = 0,
                decodingSampling: TimeInterval = 0,
                decodingFallback: TimeInterval = 0,
                decodingWindowing: TimeInterval = 0,
                decodingKvCaching: TimeInterval = 0,
                decodingTimestampAlignment: TimeInterval = 0,
                decodingNonPrediction: TimeInterval = 0,
                totalAudioProcessingRuns: Double = 0,
                totalLogmelRuns: Double = 0,
                totalEncodingRuns: Double = 0,
                totalDecodingLoops: Double = 0,
                totalKVUpdateRuns: Double = 0,
                totalTimestampAlignmentRuns: Double = 0,
                totalDecodingFallbacks: Double = 0,
                totalDecodingWindows: Double = 0,
                fullPipeline: TimeInterval = 0)
    {
        self.pipelineStart = Double.greatestFiniteMagnitude
        self.firstTokenTime = Double.greatestFiniteMagnitude
        self.inputAudioSeconds = 0.001
        self.modelLoading = modelLoading
        self.prewarmLoadTime = prewarmLoadTime
        self.encoderLoadTime = encoderLoadTime
        self.decoderLoadTime = decoderLoadTime
        self.encoderSpecializationTime = encoderSpecializationTime
        self.decoderSpecializationTime = decoderSpecializationTime
        self.tokenizerLoadTime = tokenizerLoadTime
        self.audioLoading = audioLoading
        self.audioProcessing = audioProcessing
        self.logmels = logmels
        self.encoding = encoding
        self.prefill = prefill
        self.decodingInit = decodingInit
        self.decodingLoop = decodingLoop
        self.decodingPredictions = decodingPredictions
        self.decodingFiltering = decodingFiltering
        self.decodingSampling = decodingSampling
        self.decodingFallback = decodingFallback
        self.decodingWindowing = decodingWindowing
        self.decodingKvCaching = decodingKvCaching
        self.decodingWordTimestamps = decodingTimestampAlignment
        self.decodingNonPrediction = decodingNonPrediction
        self.totalAudioProcessingRuns = totalAudioProcessingRuns
        self.totalLogmelRuns = totalLogmelRuns
        self.totalEncodingRuns = totalEncodingRuns
        self.totalDecodingLoops = totalDecodingLoops
        self.totalKVUpdateRuns = totalKVUpdateRuns
        self.totalTimestampAlignmentRuns = totalTimestampAlignmentRuns
        self.totalDecodingFallbacks = totalDecodingFallbacks
        self.totalDecodingWindows = totalDecodingWindows
        self.fullPipeline = fullPipeline
    }
}

// MARK: MelSpectrogram

public class MelSpectrogramInput: MLFeatureProvider {
    /// audio as 480000 element vector of floats
    public var audio: MLMultiArray

    public var featureNames: Set<String> {
        return ["audio"]
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "audio" {
            return MLFeatureValue(multiArray: self.audio)
        }
        return nil
    }

    public init(audio: MLMultiArray) {
        self.audio = audio
    }

    public convenience init(audio: MLShapedArray<Float>) {
        self.init(audio: MLMultiArray(audio))
    }
}

/// Model Prediction Output Type
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public class MelSpectrogramOutput: MLFeatureProvider {
    /// Source provided by CoreML
    private let provider: MLFeatureProvider

    /// melspectrogram_features as 1 × 80 × 1 × 3000 4-dimensional array of 16-bit floats
    public var melspectrogramFeatures: MLMultiArray {
        return self.provider.featureValue(for: "melspectrogram_features")!.multiArrayValue!
    }

    /// melspectrogram_features as 1 × 80 × 1 × 3000 4-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var melspectrogram_featuresShapedArray: MLShapedArray<Float16> {
        return MLShapedArray<Float16>(self.melspectrogramFeatures)
    }

    public var featureNames: Set<String> {
        return self.provider.featureNames
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        return self.provider.featureValue(for: featureName)
    }

    public init(melspectrogram_features: MLMultiArray) {
        self.provider = try! MLDictionaryFeatureProvider(dictionary: ["melspectrogram_features": MLFeatureValue(multiArray: melspectrogram_features)])
    }

    public init(features: MLFeatureProvider) {
        self.provider = features
    }
}

// MARK: AudioEncoder

/// Model Prediction Input Type
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public class AudioEncoderInput: MLFeatureProvider {
    /// melspectrogram_features as 1 × {80,128} × 1 × 3000 4-dimensional array of floats
    public var melspectrogram_features: MLMultiArray

    public var featureNames: Set<String> {
        return ["melspectrogram_features"]
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "melspectrogram_features" {
            return MLFeatureValue(multiArray: self.melspectrogram_features)
        }
        return nil
    }

    public init(melspectrogram_features: MLMultiArray) {
        self.melspectrogram_features = melspectrogram_features
    }

    public convenience init(melspectrogram_features: MLShapedArray<Float>) {
        self.init(melspectrogram_features: MLMultiArray(melspectrogram_features))
    }
}

/// Model Prediction Output Type
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public class AudioEncoderOutput: MLFeatureProvider {
    /// Source provided by CoreML
    private let provider: MLFeatureProvider

    /// encoder_output_embeds as 1 × embedDim × 1 × sequenceLength 4-dimensional array of 16-bit floats
    public var encoder_output_embeds: MLMultiArray {
        return self.provider.featureValue(for: "encoder_output_embeds")!.multiArrayValue!
    }

    /// encoder_output_embeds as 1 × embedDim × 1 × sequenceLength 4-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var encoder_output_embedsShapedArray: MLShapedArray<Float16> {
        return MLShapedArray<Float16>(self.encoder_output_embeds)
    }

    public var featureNames: Set<String> {
        return self.provider.featureNames
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        return self.provider.featureValue(for: featureName)
    }

    public init(encoder_output_embeds: MLMultiArray) {
        self.provider = try! MLDictionaryFeatureProvider(dictionary: ["encoder_output_embeds": MLFeatureValue(multiArray: encoder_output_embeds)])
    }

    public init(features: MLFeatureProvider) {
        self.provider = features
    }
}

// MARK: TextDecoder

/// Model Prediction Input Type
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public class TextDecoderInput: MLFeatureProvider {
    /// input_ids as 1 element vector of 32-bit integers
    public var input_ids: MLMultiArray

    /// cache_length as 1 element vector of 32-bit integers
    public var cache_length: MLMultiArray

    /// key_cache as 1 × kvCacheEmbedDim × 1 × kvCacheMaxSequenceLength 4-dimensional array of floats
    public var key_cache: MLMultiArray

    /// value_cache as 1 × kvCacheEmbedDim × 1 × kvCacheMaxSequenceLength 4-dimensional array of floats
    public var value_cache: MLMultiArray

    /// kv_cache_update_mask as 1 by kvCacheMaxSequenceLength matrix of floats
    public var kv_cache_update_mask: MLMultiArray

    /// encoder_output_embeds as 1 × embedSize × 1 × sequenceLength 4-dimensional array of floats
    public var encoder_output_embeds: MLMultiArray

    /// decoder_key_padding_mask as 1 by kvCacheMaxSequenceLength matrix of floats
    public var decoder_key_padding_mask: MLMultiArray

    public var featureNames: Set<String> {
        return ["input_ids", "cache_length", "key_cache", "value_cache", "kv_cache_update_mask", "encoder_output_embeds", "decoder_key_padding_mask"]
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "input_ids" {
            return MLFeatureValue(multiArray: self.input_ids)
        }
        if featureName == "cache_length" {
            return MLFeatureValue(multiArray: self.cache_length)
        }
        if featureName == "key_cache" {
            return MLFeatureValue(multiArray: self.key_cache)
        }
        if featureName == "value_cache" {
            return MLFeatureValue(multiArray: self.value_cache)
        }
        if featureName == "kv_cache_update_mask" {
            return MLFeatureValue(multiArray: self.kv_cache_update_mask)
        }
        if featureName == "encoder_output_embeds" {
            return MLFeatureValue(multiArray: self.encoder_output_embeds)
        }
        if featureName == "decoder_key_padding_mask" {
            return MLFeatureValue(multiArray: self.decoder_key_padding_mask)
        }
        return nil
    }

    public init(input_ids: MLMultiArray, cache_length: MLMultiArray, key_cache: MLMultiArray, value_cache: MLMultiArray, kv_cache_update_mask: MLMultiArray, encoder_output_embeds: MLMultiArray, decoder_key_padding_mask: MLMultiArray) {
        self.input_ids = input_ids
        self.cache_length = cache_length
        self.key_cache = key_cache
        self.value_cache = value_cache
        self.kv_cache_update_mask = kv_cache_update_mask
        self.encoder_output_embeds = encoder_output_embeds
        self.decoder_key_padding_mask = decoder_key_padding_mask
    }

    public convenience init(input_ids: MLShapedArray<Int32>, cache_length: MLShapedArray<Int32>, key_cache: MLShapedArray<Float>, value_cache: MLShapedArray<Float>, kv_cache_update_mask: MLShapedArray<Float>, encoder_output_embeds: MLShapedArray<Float>, decoder_key_padding_mask: MLShapedArray<Float>) {
        self.init(input_ids: MLMultiArray(input_ids), cache_length: MLMultiArray(cache_length), key_cache: MLMultiArray(key_cache), value_cache: MLMultiArray(value_cache), kv_cache_update_mask: MLMultiArray(kv_cache_update_mask), encoder_output_embeds: MLMultiArray(encoder_output_embeds), decoder_key_padding_mask: MLMultiArray(decoder_key_padding_mask))
    }
}

/// Model Prediction Output Type
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public class TextDecoderOutput: MLFeatureProvider {
    /// Source provided by CoreML
    private let provider: MLFeatureProvider

    /// logits as 1 × vocab size × 1 × 1 4-dimensional array of 16-bit floats
    public var logits: MLMultiArray {
        return self.provider.featureValue(for: "logits")!.multiArrayValue!
    }

    /// logits as 1 × vocab size × 1 × 1 4-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var logitsShapedArray: MLShapedArray<Float16> {
        return MLShapedArray<Float16>(self.logits)
    }

    /// key_cache_updates as 1 × embed_dim * num_layers × 1 × 1 4-dimensional array of 16-bit floats
    public var key_cache_updates: MLMultiArray {
        return self.provider.featureValue(for: "key_cache_updates")!.multiArrayValue!
    }

    /// key_cache_updates as 1 × embed_dim * num_layers × 1 × 1 4-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var key_cache_updatesShapedArray: MLShapedArray<Float16> {
        return MLShapedArray<Float16>(self.key_cache_updates)
    }

    /// value_cache_updates as 1 × kvCacheEmbedDim × 1 × 1 4-dimensional array of 16-bit floats
    public var value_cache_updates: MLMultiArray {
        return self.provider.featureValue(for: "value_cache_updates")!.multiArrayValue!
    }

    /// value_cache_updates as 1 × kvCacheEmbedDim × 1 × 1 4-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var value_cache_updatesShapedArray: MLShapedArray<Float16> {
        return MLShapedArray<Float16>(self.value_cache_updates)
    }

    /// alignment_heads_weights as 1 × 1500 2-dimensional array of 16-bit floats
    public var alignment_heads_weights: MLMultiArray? {
        return self.provider.featureValue(for: "alignment_heads_weights")?.multiArrayValue
    }

    /// alignment_heads_weights as 1 × 1500 2-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var alignment_heads_weightsShapedArray: MLShapedArray<Float16>? {
        guard let alignment_heads_weights = self.alignment_heads_weights else {
            return nil
        }
        return MLShapedArray<Float16>(alignment_heads_weights)
    }

    public var featureNames: Set<String> {
        return self.provider.featureNames
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        return self.provider.featureValue(for: featureName)
    }

    public init(logits: MLMultiArray, key_cache_updates: MLMultiArray, value_cache_updates: MLMultiArray, logits_argmax _: MLMultiArray) {
        self.provider = try! MLDictionaryFeatureProvider(dictionary: ["logits": MLFeatureValue(multiArray: logits), "key_cache_updates": MLFeatureValue(multiArray: key_cache_updates), "value_cache_updates": MLFeatureValue(multiArray: value_cache_updates)])
    }

    public init(features: MLFeatureProvider) {
        self.provider = features
    }
}

// MARK: TextDecoderCachePrefill

public class TextDecoderCachePrefillInput: MLFeatureProvider {
    /// task as 1 element vector of 32-bit integers
    public var task: MLMultiArray

    /// language as 1 element vector of 32-bit integers
    public var language: MLMultiArray

    public var featureNames: Set<String> {
        return ["task", "language"]
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "task" {
            return MLFeatureValue(multiArray: self.task)
        }
        if featureName == "language" {
            return MLFeatureValue(multiArray: self.language)
        }
        return nil
    }

    public init(task: MLMultiArray, language: MLMultiArray) {
        self.task = task
        self.language = language
    }

    public convenience init(task: MLShapedArray<Int32>, language: MLShapedArray<Int32>) {
        self.init(task: MLMultiArray(task), language: MLMultiArray(language))
    }
}

/// Model Prediction Output Type
@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public class TextDecoderCachePrefillOutput: MLFeatureProvider {
    /// Source provided by CoreML
    private let provider: MLFeatureProvider

    /// key_cache_prefill as 1 × embed_dim * num_layers × 1 × 3 4-dimensional array of 16-bit floats
    public var key_cache_prefill: MLMultiArray {
        return self.provider.featureValue(for: "key_cache_prefill")!.multiArrayValue!
    }

    /// key_cache_prefill as 1 × embed_dim * num_layers × 1 × 3 4-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var key_cache_prefillShapedArray: MLShapedArray<Float16> {
        return MLShapedArray<Float16>(self.key_cache_prefill)
    }

    /// value_cache_prefill as 1 × embed_dim * num_layers × 1 × 3 4-dimensional array of 16-bit floats
    public var value_cache_prefill: MLMultiArray {
        return self.provider.featureValue(for: "value_cache_prefill")!.multiArrayValue!
    }

    /// value_cache_prefill as 1 × embed_dim * num_layers × 1 × 3 4-dimensional array of 16-bit floats
    @available(macOS, unavailable)
    @available(macCatalyst, unavailable)
    public var value_cache_prefillShapedArray: MLShapedArray<Float16> {
        return MLShapedArray<Float16>(self.value_cache_prefill)
    }

    public var featureNames: Set<String> {
        return self.provider.featureNames
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        return self.provider.featureValue(for: featureName)
    }

    public init(key_cache_prefill: MLMultiArray, value_cache_prefill: MLMultiArray) {
        self.provider = try! MLDictionaryFeatureProvider(dictionary: ["key_cache_prefill": MLFeatureValue(multiArray: key_cache_prefill), "value_cache_prefill": MLFeatureValue(multiArray: value_cache_prefill)])
    }

    public init(features: MLFeatureProvider) {
        self.provider = features
    }
}

// MARK: SpecialTokens

public struct SpecialTokens {
    public let endToken: Int
    public let englishToken: Int
    public let noSpeechToken: Int
    public let noTimestampsToken: Int
    public let specialTokenBegin: Int
    public let startOfPreviousToken: Int
    public let startOfTranscriptToken: Int
    public let timeTokenBegin: Int
    public let transcribeToken: Int
    public let translateToken: Int
    public let whitespaceToken: Int

    public init(
        endToken: Int,
        englishToken: Int,
        noSpeechToken: Int,
        noTimestampsToken: Int,
        specialTokenBegin: Int,
        startOfPreviousToken: Int,
        startOfTranscriptToken: Int,
        timeTokenBegin: Int,
        transcribeToken: Int,
        translateToken: Int,
        whitespaceToken: Int
    ) {
        self.endToken = endToken
        self.englishToken = englishToken
        self.noSpeechToken = noSpeechToken
        self.noTimestampsToken = noTimestampsToken
        self.specialTokenBegin = specialTokenBegin
        self.startOfPreviousToken = startOfPreviousToken
        self.startOfTranscriptToken = startOfTranscriptToken
        self.timeTokenBegin = timeTokenBegin
        self.transcribeToken = transcribeToken
        self.translateToken = translateToken
        self.whitespaceToken = whitespaceToken
    }
}

public protocol WhisperTokenizer: Tokenizer {
    var specialTokens: SpecialTokens { get }
    var allLanguageTokens: Set<Int> { get }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]])
}

struct WhisperTokenizerWrapper: WhisperTokenizer {
    let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: any Tokenizer) {
        let specialTokens = SpecialTokens(
            endToken: tokenizer.convertTokenToId("<|endoftext|>") ?? Self.defaultEndToken,
            englishToken: tokenizer.convertTokenToId("<|en|>") ?? Self.defaultEnglishToken,
            noSpeechToken: tokenizer.convertTokenToId("<|nospeech|>") ?? Self.defaultNoSpeechToken,
            noTimestampsToken: tokenizer.convertTokenToId("<|notimestamps|>") ?? Self.defaultNoTimestampsToken,
            specialTokenBegin: tokenizer.convertTokenToId("<|endoftext|>") ?? Self.defaultSpecialTokenBegin,
            startOfPreviousToken: tokenizer.convertTokenToId("<|startofprev|>") ?? Self.defaultStartOfPreviousToken,
            startOfTranscriptToken: tokenizer.convertTokenToId("<|startoftranscript|>") ?? Self.defaultStartOfTranscriptToken,
            timeTokenBegin: tokenizer.convertTokenToId("<|0.00|>") ?? Self.defaultTimeTokenBegin,
            transcribeToken: tokenizer.convertTokenToId("<|transcribe|>") ?? Self.defaultTranscribeToken,
            translateToken: tokenizer.convertTokenToId("<|translate|>") ?? Self.defaultTranslateToken,
            whitespaceToken: tokenizer.convertTokenToId(" ") ?? Self.defaultWhitespaceToken
        )
        self.tokenizer = tokenizer
        self.specialTokens = specialTokens
        self.allLanguageTokens = Set(
            Constants.languages
                .compactMap { tokenizer.convertTokenToId("<|\($0.value)|>") }
                .filter { $0 > specialTokens.specialTokenBegin }
        )
    }

    private func splitTokensOnUnicode(tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedFull = tokenizer.decode(tokens: tokens)
        let replacementString = "\u{fffd}"

        var words: [String] = []
        var wordTokens: [[Int]] = []
        var currentTokens: [Int] = []
        var unicodeOffset = 0

        for token in tokens {
            currentTokens.append(token)
            let decoded = tokenizer.decode(tokens: currentTokens)

            var hasUnicodeInFullString = false
            if let range = decoded.range(of: replacementString) {
                hasUnicodeInFullString = decodedFull[range] == replacementString
            }

            if !decoded.contains(replacementString) || hasUnicodeInFullString {
                words.append(decoded)
                wordTokens.append(currentTokens)
                currentTokens = []
                unicodeOffset += decoded.count
            }
        }

        return (words, wordTokens)
    }

    private func splitTokensOnSpaces(tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let (subwords, subwordTokensList) = splitTokensOnUnicode(tokens: tokens)
        var words: [String] = []
        var wordTokens: [[Int]] = []

        for (subword, subwordTokens) in zip(subwords, subwordTokensList) {
            let special = subwordTokens.first! >= specialTokens.specialTokenBegin
            let withSpace = subword.hasPrefix(" ")
            var punctuation = false
            if let strippedSubword = UnicodeScalar(subword.trimmingCharacters(in: .whitespaces)) {
                punctuation = CharacterSet.punctuationCharacters.contains(strippedSubword)
            }
            if special || withSpace || punctuation || words.isEmpty {
                words.append(subword)
                wordTokens.append(subwordTokens)
            } else {
                words[words.count - 1] += subword
                wordTokens[words.count - 1].append(contentsOf: subwordTokens)
            }
        }

        return (words, wordTokens)
    }

    private func isPunctuation(_ text: String, tokenRange: Range<String.Index>, tag: NLTag?) -> Bool {
        let punctuationCharacters = CharacterSet.punctuationCharacters
        let token = String(text[tokenRange])
        if let tag = tag, tag == .punctuation {
            return true
        } else if token.unicodeScalars.allSatisfy({ punctuationCharacters.contains($0) }) {
            return true
        }
        return false
    }

    /// Decodes token ids into individual words and per-word subtokens
    /// - Parameter tokenIds: Array of tokens to decode and then split
    /// - Returns: Tuple containing and array of the split words and all tokens for each word
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedWords = tokenizer.decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })

        // Detect language of input text
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decodedWords)
        let languageCode = recognizer.dominantLanguage?.rawValue

        if ["zh", "ja", "th", "lo", "my", "yue"].contains(languageCode) {
            return splitTokensOnUnicode(tokens: tokenIds)
        } else {
            return splitTokensOnSpaces(tokens: tokenIds)
        }
    }
}

extension WhisperTokenizerWrapper: Tokenizer {
    public func tokenize(text: String) -> [String] {
        tokenizer.tokenize(text: text)
    }

    public func encode(text: String) -> [Int] {
        tokenizer.encode(text: text)
    }

    public func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    public func callAsFunction(_ text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.callAsFunction(text, addSpecialTokens: addSpecialTokens)
    }

    public func decode(tokens: [Int]) -> String {
        tokenizer.decode(tokens: tokens)
    }
    
    public func decode(tokens: [Int], skipSpecialTokens: Bool) -> String {
        tokenizer.decode(tokens: tokens, skipSpecialTokens: skipSpecialTokens)
    }

    public func convertTokenToId(_ token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }

    public func convertTokensToIds(_ tokens: [String]) -> [Int?] {
        tokenizer.convertTokensToIds(tokens)
    }

    public func convertIdToToken(_ id: Int) -> String? {
        tokenizer.convertIdToToken(id)
    }

    public func convertIdsToTokens(_ ids: [Int]) -> [String?] {
        tokenizer.convertIdsToTokens(ids)
    }

    public var bosToken: String? { tokenizer.bosToken }
    public var bosTokenId: Int? { tokenizer.bosTokenId }
    public var eosToken: String? { tokenizer.eosToken }
    public var eosTokenId: Int? { tokenizer.eosTokenId }
    public var unknownToken: String? { tokenizer.unknownToken }
    public var unknownTokenId: Int? { tokenizer.unknownTokenId }

    public func applyChatTemplate(messages: [Message]) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: messages)
    }

    public func applyChatTemplate(messages: [Message], chatTemplate: Tokenizers.ChatTemplateArgument) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: messages, chatTemplate: chatTemplate)
    }
    
    public func applyChatTemplate(messages: [Message], tools: [ToolSpec]?) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: messages, tools: tools)
    }

    /// The appropriate chat template is selected from the tokenizer config
    public func applyChatTemplate(messages: [Message], tools: [ToolSpec]?, additionalContext: [String: Any]?) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }

    public func applyChatTemplate(messages: [Message], chatTemplate: String) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: messages, chatTemplate: chatTemplate)
    }

    public func applyChatTemplate(
        messages: [Message],
        chatTemplate: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt: Bool,
        truncation: Bool,
        maxLength: Int?,
        tools: [[String: Any]]?
    ) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: messages,
            chatTemplate: chatTemplate,
            addGenerationPrompt: addGenerationPrompt,
            truncation: truncation,
            maxLength: maxLength,
            tools: tools
        )
    }
    public func applyChatTemplate(
        messages: [Message],
        // A chat template can optionally be provided or specified by name when several templates are included in the tokenizer config. Normally this is not necessary.
        chatTemplate: ChatTemplateArgument?,
        addGenerationPrompt: Bool,
        truncation: Bool,
        maxLength: Int?,
        tools: [ToolSpec]?,
        additionalContext: [String: Any]?
    ) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: messages,
            chatTemplate: chatTemplate,
            addGenerationPrompt: addGenerationPrompt,
            truncation: truncation,
            maxLength: maxLength,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}

extension WhisperTokenizerWrapper {
    /// Default values for each token, using base vocab
    static var defaultWhitespaceToken: Int { 220 }
    static var defaultSpecialTokenBegin: Int { 50257 }
    static var defaultEndToken: Int { 50257 }
    static var defaultStartOfPreviousToken: Int { 50361 }
    static var defaultStartOfTranscriptToken: Int { 50258 }
    static var defaultEnglishToken: Int { 50259 }
    static var defaultTranscribeToken: Int { 50359 }
    static var defaultTranslateToken: Int { 50358 }
    static var defaultNoSpeechToken: Int { 50362 }
    static var defaultNoTimestampsToken: Int { 50363 }
    static var defaultTimeTokenBegin: Int { 50364 }
}

// MARK: Constants

public enum Constants {
    enum Logging {
        static let subsystem = "com.argmax.whisperkit"
    }

    static let specialTokenCharacters = CharacterSet(charactersIn: "<|>")

    public static let maxTokenContext = Int(448 / 2)
    public static let languages: [String: String] =
        [
            "english": "en",
            "chinese": "zh",
            "german": "de",
            "spanish": "es",
            "russian": "ru",
            "korean": "ko",
            "french": "fr",
            "japanese": "ja",
            "portuguese": "pt",
            "turkish": "tr",
            "polish": "pl",
            "catalan": "ca",
            "dutch": "nl",
            "arabic": "ar",
            "swedish": "sv",
            "italian": "it",
            "indonesian": "id",
            "hindi": "hi",
            "finnish": "fi",
            "vietnamese": "vi",
            "hebrew": "he",
            "ukrainian": "uk",
            "greek": "el",
            "malay": "ms",
            "czech": "cs",
            "romanian": "ro",
            "danish": "da",
            "hungarian": "hu",
            "tamil": "ta",
            "norwegian": "no",
            "thai": "th",
            "urdu": "ur",
            "croatian": "hr",
            "bulgarian": "bg",
            "lithuanian": "lt",
            "latin": "la",
            "maori": "mi",
            "malayalam": "ml",
            "welsh": "cy",
            "slovak": "sk",
            "telugu": "te",
            "persian": "fa",
            "latvian": "lv",
            "bengali": "bn",
            "serbian": "sr",
            "azerbaijani": "az",
            "slovenian": "sl",
            "kannada": "kn",
            "estonian": "et",
            "macedonian": "mk",
            "breton": "br",
            "basque": "eu",
            "icelandic": "is",
            "armenian": "hy",
            "nepali": "ne",
            "mongolian": "mn",
            "bosnian": "bs",
            "kazakh": "kk",
            "albanian": "sq",
            "swahili": "sw",
            "galician": "gl",
            "marathi": "mr",
            "punjabi": "pa",
            "sinhala": "si",
            "khmer": "km",
            "shona": "sn",
            "yoruba": "yo",
            "somali": "so",
            "afrikaans": "af",
            "occitan": "oc",
            "georgian": "ka",
            "belarusian": "be",
            "tajik": "tg",
            "sindhi": "sd",
            "gujarati": "gu",
            "amharic": "am",
            "yiddish": "yi",
            "lao": "lo",
            "uzbek": "uz",
            "faroese": "fo",
            "haitian creole": "ht",
            "pashto": "ps",
            "turkmen": "tk",
            "nynorsk": "nn",
            "maltese": "mt",
            "sanskrit": "sa",
            "luxembourgish": "lb",
            "myanmar": "my",
            "tibetan": "bo",
            "tagalog": "tl",
            "malagasy": "mg",
            "assamese": "as",
            "tatar": "tt",
            "hawaiian": "haw",
            "lingala": "ln",
            "hausa": "ha",
            "bashkir": "ba",
            "javanese": "jw",
            "sundanese": "su",
            "cantonese": "yue",
            "burmese": "my",
            "valencian": "ca",
            "flemish": "nl",
            "haitian": "ht",
            "letzeburgesch": "lb",
            "pushto": "ps",
            "panjabi": "pa",
            "moldavian": "ro",
            "moldovan": "ro",
            "sinhalese": "si",
            "castilian": "es",
            "mandarin": "zh",
        ]

    public static let languageCodes: Set<String> = Set(languages.values)

    public static let defaultLanguageCode: String = "en"

    public static let defaultAudioReadFrameSize: AVAudioFrameCount = 1_323_000 // 30s of audio at commonly found 44.1khz sample rate

    public static let fallbackModelSupportConfig: ModelSupportConfig = {
        var config = ModelSupportConfig(
            repoName: "whisperkit-coreml-fallback",
            repoVersion: "0.2",
            deviceSupports: [
                DeviceSupport(
                    identifiers: ["iPhone11", "iPhone12", "Watch7", "Watch8"],
                    models: ModelSupport(
                        default: "openai_whisper-tiny",
                        supported: [
                            "openai_whisper-base",
                            "openai_whisper-base.en",
                            "openai_whisper-tiny",
                            "openai_whisper-tiny.en",
                        ]
                    )
                ),
                DeviceSupport(
                    identifiers: ["iPhone13", "iPad13,18", "iPad13,1"],
                    models: ModelSupport(
                        default: "openai_whisper-base",
                        supported: [
                            "openai_whisper-tiny",
                            "openai_whisper-tiny.en",
                            "openai_whisper-base",
                            "openai_whisper-base.en",
                            "openai_whisper-small",
                            "openai_whisper-small.en",
                        ]
                    )
                ),
                DeviceSupport(
                    identifiers: ["iPhone14", "iPhone15", "iPhone16", "iPhone17", "iPad14,1", "iPad14,2"],
                    models: ModelSupport(
                        default: "openai_whisper-base",
                        supported: [
                            "openai_whisper-tiny",
                            "openai_whisper-tiny.en",
                            "openai_whisper-base",
                            "openai_whisper-base.en",
                            "openai_whisper-small",
                            "openai_whisper-small.en",
                            "openai_whisper-large-v2_949MB",
                            "openai_whisper-large-v2_turbo_955MB",
                            "openai_whisper-large-v3_947MB",
                            "openai_whisper-large-v3_turbo_954MB",
                            "distil-whisper_distil-large-v3_594MB",
                            "distil-whisper_distil-large-v3_turbo_600MB",
                            "openai_whisper-large-v3-v20240930_626MB",
                            "openai_whisper-large-v3-v20240930_turbo_632MB",
                        ]
                    )
                ),
                DeviceSupport(
                    identifiers: [
                        "Mac13",
                        "iMac21",
                        "MacBookAir10,1",
                        "MacBookPro17",
                        "MacBookPro18",
                        "Macmini9",
                        "iPad13,16",
                        "iPad13,4",
                        "iPad13,8",
                    ],
                    models: ModelSupport(
                        default: "openai_whisper-large-v3-v20240930",
                        supported: [
                            "openai_whisper-tiny",
                            "openai_whisper-tiny.en",
                            "openai_whisper-base",
                            "openai_whisper-base.en",
                            "openai_whisper-small",
                            "openai_whisper-small.en",
                            "openai_whisper-large-v2",
                            "openai_whisper-large-v2_949MB",
                            "openai_whisper-large-v3",
                            "openai_whisper-large-v3_947MB",
                            "distil-whisper_distil-large-v3",
                            "distil-whisper_distil-large-v3_594MB",
                            "openai_whisper-large-v3-v20240930",
                            "openai_whisper-large-v3-v20240930_626MB",
                        ]
                    )
                ),
                DeviceSupport(
                    identifiers: [
                        "Mac14",
                        "Mac15",
                        "Mac16",
                        "iPad14,3",
                        "iPad14,4",
                        "iPad14,5",
                        "iPad14,6",
                        "iPad14,8",
                        "iPad14,9",
                        "iPad14,10",
                        "iPad14,11",
                        "iPad16",
                    ],
                    models: ModelSupport(
                        default: "openai_whisper-large-v3-v20240930",
                        supported: [
                            "openai_whisper-tiny",
                            "openai_whisper-tiny.en",
                            "openai_whisper-base",
                            "openai_whisper-base.en",
                            "openai_whisper-small",
                            "openai_whisper-small.en",
                            "openai_whisper-large-v2",
                            "openai_whisper-large-v2_949MB",
                            "openai_whisper-large-v2_turbo",
                            "openai_whisper-large-v2_turbo_955MB",
                            "openai_whisper-large-v3",
                            "openai_whisper-large-v3_947MB",
                            "openai_whisper-large-v3_turbo",
                            "openai_whisper-large-v3_turbo_954MB",
                            "distil-whisper_distil-large-v3",
                            "distil-whisper_distil-large-v3_594MB",
                            "distil-whisper_distil-large-v3_turbo",
                            "distil-whisper_distil-large-v3_turbo_600MB",
                            "openai_whisper-large-v3-v20240930",
                            "openai_whisper-large-v3-v20240930_turbo",
                            "openai_whisper-large-v3-v20240930_626MB",
                            "openai_whisper-large-v3-v20240930_turbo_632MB",
                        ]
                    )
                ),
            ],
            includeFallback: false
        )

        return config
    }()

    public static let knownModels: [String] = fallbackModelSupportConfig.deviceSupports.flatMap { $0.models.supported }.orderedSet
}

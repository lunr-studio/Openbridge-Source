import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class AudioRecorderService: NSObject {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()

    private var input: AVCaptureDeviceInput?
    private var configuredDeviceID: String?
    private var activeRecordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL?, Never>?
    private var keepSessionRunningForDiagnostics = false
    private var recordingWasCancelled = false
    private var recordingMeterTimer: Timer?

    private(set) var lastRecordingPeakLevel: Double = 0

    func availableInputDevices() -> [MicrophoneDevice] {
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        let defaultDetail = defaultDevice?.localizedName ?? "macOS selected input"
        var devices = [
            MicrophoneDevice(
                id: MicrophoneDevice.systemDefaultID,
                displayName: "Default microphone",
                detail: defaultDetail,
                transportLabel: defaultDevice.map { transportLabel(for: $0.transportType) },
                isSystemDefault: true,
                isBluetooth: defaultDevice.map(isBluetoothDevice) ?? false
            ),
        ]

        let discoveredDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        devices.append(contentsOf: discoveredDevices.map { device in
            MicrophoneDevice(
                id: device.uniqueID,
                displayName: device.localizedName,
                detail: transportLabel(for: device.transportType),
                transportLabel: transportLabel(for: device.transportType),
                isSystemDefault: false,
                isBluetooth: isBluetoothDevice(device)
            )
        })

        return devices
    }

    func startDiagnostics(deviceID: String?) throws {
        keepSessionRunningForDiagnostics = true
        try configureSession(deviceID: physicalDeviceID(from: deviceID))
        startSessionIfNeeded()
    }

    func stopDiagnostics() {
        keepSessionRunningForDiagnostics = false
        stopSessionIfIdle()
    }

    func currentMeterSample() -> MicrophoneMeterSample {
        meterSampleFromConnection()
    }

    func startRecording(deviceID: String?) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openbridge-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        try configureSession(deviceID: physicalDeviceID(from: deviceID))
        startSessionIfNeeded()

        guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.wav) else {
            throw AudioRecorderError.unsupportedFileType
        }

        activeRecordingURL = fileURL
        recordingWasCancelled = false
        lastRecordingPeakLevel = 0
        output.startRecording(to: fileURL, outputFileType: .wav, recordingDelegate: self)
        startRecordingMeterTimer()
        return fileURL
    }

    func stopRecording() async -> URL? {
        guard output.isRecording else {
            let url = activeRecordingURL
            activeRecordingURL = nil
            stopRecordingMeterTimer()
            stopSessionIfIdle()
            return url
        }

        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
            output.stopRecording()
        }
    }

    func cancelRecording() -> URL? {
        let url = activeRecordingURL
        recordingWasCancelled = true
        stopRecordingMeterTimer()
        if output.isRecording {
            output.stopRecording()
        } else {
            activeRecordingURL = nil
            stopSessionIfIdle()
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return url
    }

    private func configureSession(deviceID: String?) throws {
        if configuredDeviceID == deviceID, input != nil, session.outputs.contains(output) {
            return
        }

        let wasRunning = session.isRunning
        if wasRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            if wasRunning {
                startSessionIfNeeded()
            }
        }

        if let input {
            session.removeInput(input)
            self.input = nil
        }

        if !session.outputs.contains(output) {
            if session.canAddOutput(output) {
                session.addOutput(output)
            } else {
                throw AudioRecorderError.outputUnavailable
            }
        }

        guard let device = selectedDevice(for: deviceID) else {
            configuredDeviceID = nil
            throw AudioRecorderError.noInputDevice
        }

        let nextInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(nextInput) else {
            throw AudioRecorderError.inputUnavailable(device.localizedName)
        }

        session.addInput(nextInput)
        input = nextInput
        configuredDeviceID = deviceID
    }

    private func selectedDevice(for deviceID: String?) -> AVCaptureDevice? {
        if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func physicalDeviceID(from deviceID: String?) -> String? {
        guard let deviceID, deviceID != MicrophoneDevice.systemDefaultID else {
            return nil
        }
        return deviceID
    }

    private func startSessionIfNeeded() {
        guard !session.isRunning else { return }
        session.startRunning()
    }

    private func stopSessionIfIdle() {
        guard !keepSessionRunningForDiagnostics, !output.isRecording, session.isRunning else {
            return
        }
        session.stopRunning()
    }

    private func startRecordingMeterTimer() {
        stopRecordingMeterTimer()
        recordingMeterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.recordRecordingLevel(self.meterSampleFromConnection())
            }
        }
        if let recordingMeterTimer {
            RunLoop.main.add(recordingMeterTimer, forMode: .common)
        }
    }

    private func stopRecordingMeterTimer() {
        recordingMeterTimer?.invalidate()
        recordingMeterTimer = nil
    }

    private func recordRecordingLevel(_ sample: MicrophoneMeterSample) {
        lastRecordingPeakLevel = max(lastRecordingPeakLevel, sample.normalizedLevel)
    }

    private func meterSampleFromConnection() -> MicrophoneMeterSample {
        guard let channel = output.connection(with: .audio)?.audioChannels.first else {
            return .silent
        }

        let sample = MicrophoneMeterSample(
            averagePowerDecibels: channel.averagePowerLevel,
            peakPowerDecibels: channel.peakHoldLevel,
            normalizedLevel: Self.normalizedLevel(from: channel.averagePowerLevel)
        )
        return sample
    }

    private func finishRecording(url: URL, error: Error?) {
        stopRecordingMeterTimer()
        let wasCancelled = recordingWasCancelled
        recordingWasCancelled = false
        activeRecordingURL = nil
        stopSessionIfIdle()

        if wasCancelled {
            try? FileManager.default.removeItem(at: url)
            stopContinuation?.resume(returning: nil)
        } else if error == nil {
            stopContinuation?.resume(returning: url)
        } else {
            stopContinuation?.resume(returning: nil)
        }
        stopContinuation = nil
    }

    private func transportLabel(for transportType: Int32) -> String {
        switch UInt32(bitPattern: transportType) {
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "Continuity"
        default:
            return "Audio input"
        }
    }

    private func isBluetoothDevice(_ device: AVCaptureDevice) -> Bool {
        let transportType = UInt32(bitPattern: device.transportType)
        if transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }

        let lowercasedName = device.localizedName.lowercased()
        return lowercasedName.contains("airpods")
            || lowercasedName.contains("bluetooth")
            || lowercasedName.contains("beats")
    }

    private static func normalizedLevel(from decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        let clamped = max(-60, min(0, decibels))
        return Double((clamped + 60) / 60)
    }
}

extension AudioRecorderService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.finishRecording(url: outputFileURL, error: error)
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case inputUnavailable(String)
    case outputUnavailable
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input was found. Check System Settings > Sound > Input and connect a microphone."
        case .inputUnavailable(let deviceName):
            return "\(deviceName) could not be used for recording. Choose another microphone or System Default."
        case .outputUnavailable:
            return "OpenBridge could not prepare audio capture. Quit and reopen the app, then try again."
        case .unsupportedFileType:
            return "This Mac cannot record WAV audio through the selected microphone."
        }
    }
}

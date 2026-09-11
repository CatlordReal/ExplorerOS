import SwiftUI
import MapKit
import CoreLocation
import Speech
import AVFoundation
import ExplorerLinkCore

@MainActor final class DirectionsModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var destination = ""
    @Published var walking = true
    @Published private(set) var location: CLLocation?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var mapDestination: MKMapItem?
    private let manager = CLLocationManager()
    private var directions: MKDirections?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters }
    func locate() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else { error = "Enable location for Explorer Link in Settings to calculate a route." }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { location = locations.last; error = nil }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { self.error = error.localizedDescription }
    func calculate() async throws -> RouteProgress {
        guard !busy, let location, abs(location.timestamp.timeIntervalSinceNow) < 300, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else {
            throw NSError(domain: "ExplorerDirections", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refresh your location before calculating a route."])
        }
        busy = true; defer { busy = false }
        let search = MKLocalSearch.Request(); search.naturalLanguageQuery = destination
        search.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 30000, longitudinalMeters: 30000)
        let result = try await MKLocalSearch(request: search).start()
        guard let target = result.mapItems.first else { throw NSError(domain: "ExplorerDirections", code: 2, userInfo: [NSLocalizedDescriptionKey: "No destination found. Try a more specific address."]) }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate)); request.destination = target
        request.transportType = walking ? .walking : .automobile; request.requestsAlternateRoutes = false
        let worker = MKDirections(request: request); directions = worker
        let response = try await worker.calculate(); directions = nil
        guard let route = response.routes.first else { throw NSError(domain: "ExplorerDirections", code: 3, userInfo: [NSLocalizedDescriptionKey: "No route is available."]) }
        mapDestination = target
        return RouteProgress(steps: route.steps.map { RouteStep(instruction: $0.instructions, distance: $0.distance) }, destination: target.name ?? destination)
    }
    func openInMaps() { mapDestination?.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: walking ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeDriving]) }
}

@MainActor final class DictationModel: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var transcript = ""
    @Published var error: String?
    private let audio = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var installedTap = false
    private var lastSend = Date.distantPast
    private var timeout: Task<Void, Never>?
    func start(companion: CompanionModel) async {
        guard !active else { return }
        guard companion.connected else { error = "Connect Glass before starting dictation."; return }
        let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic else { error = "Microphone and speech recognition permissions are required."; return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { error = "On-device dictation is unavailable for this device or language."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest(); request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = true
            self.request = request; transcript = ""; error = nil
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "ExplorerSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone route is available."]) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; installedTap = true
            task = recognizer.recognitionTask(with: request) { [weak self, weak companion] result, failure in
                Task { @MainActor in
                    guard let self, self.active else { return }
                    if let result {
                        self.transcript = String(result.bestTranscription.formattedString.prefix(900))
                        if result.isFinal || Date().timeIntervalSince(self.lastSend) > 0.6 {
                            do { try companion?.sendCard(title: "Dictation", body: self.transcript, source: "speech"); self.lastSend = Date() }
                            catch { self.error = error.localizedDescription; self.stop() }
                        }
                        if result.isFinal { self.stop() }
                    }
                    if let failure { self.error = failure.localizedDescription; self.stop() }
                }
            }
            audio.prepare(); try audio.start(); active = true
            timeout = Task { [weak self] in try? await Task.sleep(for: .seconds(60)); guard !Task.isCancelled else { return }; self?.stop() }
        } catch { self.error = error.localizedDescription; stop() }
    }
    func stop() {
        active = false; timeout?.cancel(); timeout = nil; audio.stop()
        if installedTap { audio.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

//
//  ViewController.swift
//  ScanCapture
//
//  Created by Paul-Edouard Sarlin on 26.04.21.
//

import UIKit
import SceneKit
import ARKit
import os.log
import Accelerate
import CoreMotion
import CoreBluetooth
import CoreLocation

class ViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate, CBCentralManagerDelegate, CLLocationManagerDelegate {

    @IBOutlet var sceneView: ARSCNView!

    // Overlay UI, built programmatically in setupOverlayUI()
    var timePill: UIView!
    var timeLabel: UILabel!
    var trackingDot: UIView!
    var trackingStatusLabel: UILabel!
    var mappingDot: UIView!
    var mappingStatusLabel: UILabel!
    var frameCounterLabel: UILabel!
    var fileSizeLabel: UILabel!
    var fpsLabel: UILabel!
    var fpsStepper: UIStepper!
    var timeWriteLabel: UILabel!
    var recordButton: UIButton!
    var recordShape: UIView!
    var sensorsButton: UIButton!
    var sensorsPanel: UIVisualEffectView!
    private var sensorsPanelOpen = false
    private var sensorRows: [String: (dot: UIView, value: UILabel)] = [:]
    private var sensorTimer: Timer!
    private var lastPanelUpdate: TimeInterval = 0
    private var prevCounts: [String: Int] = [:]

    var isRecording: Bool = false
    let queue: DispatchQueue = DispatchQueue(label: "com.scantoolscapture", attributes: .concurrent)
    var writerQueue: OperationQueue!
    var hasDepth: Bool = false

    var frameDrop: UInt = 6  // how many frames to skip at 60Hz
    var arFrameCounter: UInt = 0  // total number of ARFrames at 60Hz
    var captureFrameCounter: UInt = 0  // number of subsampled frames

    var outDirURL: URL!
    let imageDirName = "images"
    let depthDirName = "depth"
    var imageWriter: ImageStreamer!
    var poseWriter: PoseWriter!

    let captureDepth: Bool = true
    var depthWriter: ImageWriter!

    let captureIMU: Bool = true
    let imuFreq: Double = 100.0
    var motionManager: CMMotionManager!
    var motionWriter: MotionWriter!

    let captureBT: Bool = true
    var btManager: CBCentralManager!
    var btTimer: Timer!
    var btWriter: BluetoothWriter!
    let btQueue: DispatchQueue = DispatchQueue(label: "com.scantoolscapture.bluetooth")

    let captureLocation: Bool = true
    var locationManager: CLLocationManager!
    var locationWriter: LocationWriter!

    // UI
    var diskCapacity: String = "?"
    var startTime: Date!
    var recordingTimer: Timer!
    var previousPosition: SCNVector3?
    var timeWriteText: String = "? ms"

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.sceneView.debugOptions = [ARSCNDebugOptions.showFeaturePoints, ARSCNDebugOptions.showWorldOrigin]

        sceneView.delegate = self
        sceneView.session.delegate = self

        setupOverlayUI()
        updateDiskCapacity()
        initializeUI()

        sensorTimer = Timer.scheduledTimer(
            timeInterval: 1.0, target: self, selector: #selector(updateSensorPanel),
            userInfo: nil, repeats: true)

        writerQueue = OperationQueue()
        writerQueue.maxConcurrentOperationCount = 1

        if captureIMU {
            motionManager = CMMotionManager()
            if !motionManager.isDeviceMotionAvailable {os_log("Fused device motion not available.")}
            if !motionManager.isGyroAvailable {os_log("Gyroscope not available.")}
            if !motionManager.isAccelerometerAvailable {os_log("Accelerometer not available.")}
            if !motionManager.isMagnetometerAvailable {os_log("Magnetometer not available.")}
        }
        if captureBT {
            btManager = CBCentralManager(delegate: self, queue: btQueue)
        }
        if captureLocation {
            locationManager = CLLocationManager()
            locationManager!.delegate = self
            locationManager!.desiredAccuracy = kCLLocationAccuracyBest
            locationManager!.distanceFilter = kCLDistanceFilterNone
            locationManager!.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Overlay UI

    private enum UIStyle {
        static let chromeColor = UIColor(white: 0.0, alpha: 0.45)
        static let dimTextColor = UIColor(white: 1.0, alpha: 0.55)
        static let recordSize: CGFloat = 72
        static let recordInset: CGFloat = 6
    }

    private func setupOverlayUI() {
        // Recording time pill, top center
        timePill = UIView()
        timePill.backgroundColor = UIStyle.chromeColor
        timePill.layer.cornerRadius = 16
        timePill.translatesAutoresizingMaskIntoConstraints = false

        timeLabel = UILabel()
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timePill.addSubview(timeLabel)

        // Tracking / mapping status chips
        trackingDot = makeDot()
        trackingStatusLabel = makeChipLabel()
        let trackingChip = makeChip(dot: trackingDot, label: trackingStatusLabel)

        mappingDot = makeDot()
        mappingStatusLabel = makeChipLabel()
        let mappingChip = makeChip(dot: mappingDot, label: mappingStatusLabel)

        let chipsRow = UIStackView(arrangedSubviews: [trackingChip, mappingChip])
        chipsRow.axis = .horizontal
        chipsRow.spacing = 8
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        // Bottom control card
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        card.layer.cornerRadius = 28
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let (framesStat, framesValue) = makeStat(title: "FRAMES")
        frameCounterLabel = framesValue
        let (sizeStat, sizeValue) = makeStat(title: "SIZE")
        fileSizeLabel = sizeValue
        let (writeStat, writeValue) = makeStat(title: "WRITE")
        timeWriteLabel = writeValue

        let statsRow = UIStackView(arrangedSubviews: [framesStat, sizeStat, writeStat])
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.translatesAutoresizingMaskIntoConstraints = false

        // Record button: white ring + red shape that morphs to a square while recording
        recordButton = UIButton(type: .custom)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.layer.cornerRadius = UIStyle.recordSize / 2
        recordButton.layer.borderWidth = 4
        recordButton.layer.borderColor = UIColor.white.cgColor
        recordButton.addTarget(self, action: #selector(startStopButtonPressed(_:)), for: .touchUpInside)

        recordShape = UIView()
        recordShape.backgroundColor = .systemRed
        recordShape.isUserInteractionEnabled = false
        recordShape.translatesAutoresizingMaskIntoConstraints = false
        recordShape.layer.cornerRadius = (UIStyle.recordSize - 2 * UIStyle.recordInset) / 2
        recordButton.addSubview(recordShape)

        // FPS control, left of the record button
        fpsLabel = UILabel()
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        fpsLabel.textColor = .white
        fpsLabel.textAlignment = .center

        fpsStepper = UIStepper()
        fpsStepper.minimumValue = 1
        fpsStepper.maximumValue = 60
        fpsStepper.addTarget(self, action: #selector(fpsStepperChanged(_:)), for: .valueChanged)

        let fpsControl = UIStackView(arrangedSubviews: [fpsLabel, fpsStepper])
        fpsControl.axis = .vertical
        fpsControl.alignment = .center
        fpsControl.spacing = 6
        fpsControl.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(timePill)
        view.addSubview(chipsRow)
        view.addSubview(card)
        card.contentView.addSubview(statsRow)
        card.contentView.addSubview(fpsControl)
        card.contentView.addSubview(recordButton)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            timePill.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            timePill.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            timePill.heightAnchor.constraint(equalToConstant: 32),
            timeLabel.leadingAnchor.constraint(equalTo: timePill.leadingAnchor, constant: 14),
            timeLabel.trailingAnchor.constraint(equalTo: timePill.trailingAnchor, constant: -14),
            timeLabel.centerYAnchor.constraint(equalTo: timePill.centerYAnchor),

            chipsRow.topAnchor.constraint(equalTo: timePill.bottomAnchor, constant: 8),
            chipsRow.centerXAnchor.constraint(equalTo: safe.centerXAnchor),

            card.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),

            statsRow.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 14),
            statsRow.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            statsRow.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -16),

            recordButton.topAnchor.constraint(equalTo: statsRow.bottomAnchor, constant: 14),
            recordButton.centerXAnchor.constraint(equalTo: card.contentView.centerXAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: UIStyle.recordSize),
            recordButton.heightAnchor.constraint(equalToConstant: UIStyle.recordSize),
            recordButton.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -14),

            recordShape.centerXAnchor.constraint(equalTo: recordButton.centerXAnchor),
            recordShape.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            recordShape.widthAnchor.constraint(equalToConstant: UIStyle.recordSize - 2 * UIStyle.recordInset),
            recordShape.heightAnchor.constraint(equalToConstant: UIStyle.recordSize - 2 * UIStyle.recordInset),

            fpsControl.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            fpsControl.trailingAnchor.constraint(lessThanOrEqualTo: recordButton.leadingAnchor, constant: -12),
            fpsControl.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
        ])

        setupSensorPanel(safe: safe)
    }

    private func setupSensorPanel(safe: UILayoutGuide) {
        sensorsButton = UIButton(type: .system)
        sensorsButton.backgroundColor = UIStyle.chromeColor
        sensorsButton.layer.cornerRadius = 20
        sensorsButton.tintColor = .white
        sensorsButton.setImage(
            UIImage(systemName: "gauge", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)),
            for: .normal)
        sensorsButton.translatesAutoresizingMaskIntoConstraints = false
        sensorsButton.addTarget(self, action: #selector(toggleSensorsPanel), for: .touchUpInside)

        sensorsPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        sensorsPanel.layer.cornerRadius = 20
        sensorsPanel.clipsToBounds = true
        sensorsPanel.translatesAutoresizingMaskIntoConstraints = false
        sensorsPanel.alpha = 0
        sensorsPanel.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.97, y: 0.97)

        let title = UILabel()
        title.attributedText = NSAttributedString(string: "SENSORS", attributes: [
            .kern: 1.5,
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIStyle.dimTextColor,
        ])

        let stack = UIStackView(arrangedSubviews: [
            title,
            makeSensorRow(key: "camera", name: "Camera", symbol: "camera.fill"),
            makeSensorRow(key: "depth", name: "Depth (LiDAR)", symbol: "cube.transparent"),
            makeSensorRow(key: "accel", name: "Accelerometer", symbol: "waveform.path"),
            makeSensorRow(key: "gyro", name: "Gyroscope", symbol: "gyroscope"),
            makeSensorRow(key: "mag", name: "Magnetometer", symbol: "location.north"),
            makeSensorRow(key: "fused", name: "Fused IMU", symbol: "waveform.path.ecg"),
            makeSensorRow(key: "bt", name: "Bluetooth", symbol: "dot.radiowaves.left.and.right"),
            makeSensorRow(key: "loc", name: "Location", symbol: "location.fill"),
        ])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(10, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sensorsButton)
        view.addSubview(sensorsPanel)
        sensorsPanel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            sensorsButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            sensorsButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            sensorsButton.widthAnchor.constraint(equalToConstant: 40),
            sensorsButton.heightAnchor.constraint(equalToConstant: 40),

            sensorsPanel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 84),
            sensorsPanel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            sensorsPanel.widthAnchor.constraint(equalToConstant: 262),

            stack.topAnchor.constraint(equalTo: sensorsPanel.contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: sensorsPanel.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: sensorsPanel.contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: sensorsPanel.contentView.bottomAnchor, constant: -14),
        ])
    }

    private func makeSensorRow(key: String, name: String, symbol: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = UIStyle.dimTextColor
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ])

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let valueLabel = UILabel()
        valueLabel.text = "–"
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = UIStyle.dimTextColor
        valueLabel.textAlignment = .right

        let dot = makeDot()

        let row = UIStackView(arrangedSubviews: [icon, nameLabel, valueLabel, dot])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true

        sensorRows[key] = (dot, valueLabel)
        return row
    }

    private enum SensorState { case live, ready, warn, off }

    private func setSensor(_ key: String, _ state: SensorState, _ text: String) {
        guard let row = sensorRows[key] else { return }
        row.value.text = text
        switch state {
        case .live:  row.dot.backgroundColor = .systemGreen
        case .ready: row.dot.backgroundColor = UIColor(white: 1.0, alpha: 0.4)
        case .warn:  row.dot.backgroundColor = .systemYellow
        case .off:   row.dot.backgroundColor = UIColor(white: 1.0, alpha: 0.15)
        }
    }

    @objc private func toggleSensorsPanel() {
        sensorsPanelOpen.toggle()
        if sensorsPanelOpen {
            lastPanelUpdate = ProcessInfo.processInfo.systemUptime
            prevCounts.removeAll()
            updateSensorPanel()
        }
        let open = sensorsPanelOpen
        sensorsButton.tintColor = open ? UIColor(red: 0.5, green: 0.86, blue: 0.94, alpha: 1.0) : .white
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3,
                       options: [.allowUserInteraction]) {
            self.sensorsPanel.alpha = open ? 1 : 0
            self.sensorsPanel.transform = open
                ? .identity
                : CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.97, y: 0.97)
        }
    }

    @objc private func updateSensorPanel() {
        guard sensorsPanelOpen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(now - lastPanelUpdate, 0.05)
        lastPanelUpdate = now

        func rate(_ key: String, _ current: Int) -> Double {
            let prev = prevCounts[key] ?? current
            prevCounts[key] = current
            return max(Double(current - prev) / dt, 0)
        }

        if isRecording {
            setSensor("camera", .live, String(format: "%.1f fps", rate("camera", Int(captureFrameCounter))))
        } else {
            setSensor("camera", .ready, String(format: "set %.1f fps", 60/Double(frameDrop)))
        }

        if !hasDepth {
            setSensor("depth", .off, "unavailable")
        } else if isRecording && depthWriter != nil {
            setSensor("depth", .live, String(format: "%.1f fps", rate("depth", depthWriter.depthFrameCount)))
        } else {
            setSensor("depth", .ready, "ready")
        }

        func imu(_ key: String, _ available: Bool, _ count: Int?) {
            if !available {
                setSensor(key, .off, "unavailable")
            } else if isRecording, let count = count {
                setSensor(key, .live, String(format: "%.0f Hz", rate(key, count)))
            } else {
                setSensor(key, .ready, String(format: "%.0f Hz", imuFreq))
            }
        }
        imu("accel", motionManager?.isAccelerometerAvailable ?? false, motionWriter?.accelWriter.sampleCount)
        imu("gyro", motionManager?.isGyroAvailable ?? false, motionWriter?.gyroWriter.sampleCount)
        imu("mag", motionManager?.isMagnetometerAvailable ?? false, motionWriter?.magnetoWriter.sampleCount)
        imu("fused", motionManager?.isDeviceMotionAvailable ?? false, motionWriter?.fusedWriter.sampleCount)

        if isRecording && btWriter != nil {
            setSensor("bt", .live, String(format: "%d pkts", btWriter.sampleCount))
        } else if btManager?.state == .poweredOn {
            setSensor("bt", .ready, "powered on")
        } else if btManager?.state == .unauthorized {
            setSensor("bt", .warn, "no permission")
        } else {
            setSensor("bt", .off, "off")
        }

        let auth = locationManager?.authorizationStatus
        if isRecording && locationWriter != nil {
            setSensor("loc", .live, String(format: "%d fixes", locationWriter.sampleCount))
        } else if auth == .authorizedWhenInUse || auth == .authorizedAlways {
            setSensor("loc", .ready, "authorized")
        } else if auth == .notDetermined {
            setSensor("loc", .warn, "pending")
        } else {
            setSensor("loc", .warn, "denied")
        }
    }

    private func makeDot() -> UIView {
        let dot = UIView()
        dot.backgroundColor = .systemGray
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        return dot
    }

    private func makeChipLabel() -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        return label
    }

    private func makeChip(dot: UIView, label: UILabel) -> UIView {
        let content = UIStackView(arrangedSubviews: [dot, label])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false

        let chip = UIView()
        chip.backgroundColor = UIStyle.chromeColor
        chip.layer.cornerRadius = 12
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(content)
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 24),
            content.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            content.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        return chip
    }

    private func makeStat(title: String) -> (UIStackView, UILabel) {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = UIStyle.dimTextColor

        let valueLabel = UILabel()
        valueLabel.text = "?"
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6

        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        return (stack, valueLabel)
    }

    private static func indicatorColor(for state: ARCamera.TrackingState) -> UIColor {
        switch state {
        case .normal:
            return .systemGreen
        case .limited:
            return .systemYellow
        case .notAvailable:
            return .systemRed
        }
    }

    private static func indicatorColor(for status: ARFrame.WorldMappingStatus) -> UIColor {
        switch status {
        case .mapped:
            return .systemGreen
        case .extending:
            return .systemTeal
        case .limited:
            return .systemYellow
        case .notAvailable:
            return .systemGray
        @unknown default:
            return .systemGray
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = ARConfiguration.WorldAlignment.gravity
        if captureDepth && ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth]) {
            configuration.frameSemantics = [.sceneDepth]
            self.hasDepth = true
            os_log("Will also save depth data.")
        }

        sceneView.session.run(configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        sceneView.session.pause()
    }

    @objc func startStopButtonPressed(_ sender: UIButton) {
        if (self.isRecording == false) {
            os_log("Starting a new recording.")
            queue.async {
                if (self.createFiles()) {
                    DispatchQueue.main.async {
                        // reset timer
                        self.startTime = Date()
                        self.updateTime()
                        self.recordingTimer = Timer.scheduledTimer(
                            timeInterval: 1.0, target: self, selector: #selector(self.updateTime),
                            userInfo: nil, repeats: true)
                        self.arFrameCounter = 0
                        self.captureFrameCounter = 0
                        self.initializeUI()
                        self.toggleRecording(val: true)
                        if self.btWriter != nil {
                            self.btTimer = Timer.scheduledTimer(
                                timeInterval: 1.0, target: self, selector: #selector(self.refreshBluetooth),
                                userInfo: nil, repeats: true)
                        }
                        if self.locationWriter != nil {
                            self.locationManager!.startUpdatingLocation()
                        }
                    }
                    self.motionWriter?.start()
                } else {
                    self.showError(msg: "Failed to create the recording directory or files.")
                    return
                }
            }
        } else {
            os_log("Stopping the recording.")
            self.toggleRecording(val: false)
            if recordingTimer?.isValid == true {
                recordingTimer.invalidate()
            }
            if self.captureBT {
                if btTimer?.isValid == true {
                    btTimer.invalidate()
                }
                self.stopBluetoooth()
            }
            if self.captureLocation {
                self.locationManager!.stopUpdatingLocation()
            }
            self.writerQueue.addBarrierBlock({
                os_log("Finishing all writers")
                self.poseWriter.finish()
                self.imageWriter.finish()
                self.motionWriter?.finish()
                self.btWriter?.finish()
                self.locationWriter?.finish()
                os_log("Opening the capture directory.")
                var sharedURL = URLComponents(url: self.outDirURL!, resolvingAgainstBaseURL: false)!
                sharedURL.scheme = "shareddocuments"  // scheme of the Files app
                DispatchQueue.main.async {
                    UIApplication.shared.open(sharedURL.url!)
                }
            })
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        os_log("AR session failed: %@", type:.error, error.localizedDescription)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let mappingStatus = frame.worldMappingStatus
        let trackingState = frame.camera.trackingState

        if (self.arFrameCounter % 6) == 0 {  // only update the UI every 100ms
            DispatchQueue.main.async { [arFrameCounter = self.arFrameCounter] in
                self.trackingStatusLabel.text = trackingState.toString()
                self.trackingDot.backgroundColor = Self.indicatorColor(for: trackingState)
                self.mappingStatusLabel.text = mappingStatus.toString()
                self.mappingDot.backgroundColor = Self.indicatorColor(for: mappingStatus)
                self.timeWriteLabel.text = self.timeWriteText + String(format:" / %d", self.writerQueue.operationCount)
                if self.isRecording {
                    if (arFrameCounter % 30) == 0 {  // every half second
                        self.drawCamera(camera: frame.camera)
                        if (arFrameCounter % 1200) == 0 {  // every 20 seconds
                            self.updateSize()
                        }
                    }
                }
            }
        }

        if (self.isRecording) {
            let timestamp = frame.timestamp
            let camera = frame.camera
            let imageBuffer = frame.capturedImage

            if (arFrameCounter % frameDrop == 0) {
                captureFrameCounter += 1
                frameCounterLabel.text = String(format: "%u", captureFrameCounter)
                self.writerQueue.addOperation({
                    let enter = ProcessInfo.processInfo.systemUptime
                    self.poseWriter.write(camera: camera, timestamp: timestamp, state: trackingState.toString())
                    self.imageWriter.write(buffer: imageBuffer, timestamp: timestamp)
                    if (self.hasDepth && (frame.sceneDepth != nil)) {
                        self.depthWriter.writeDepth(sceneDepth: frame.sceneDepth!, timestamp: timestamp)
                    }
                    self.timeWriteText = String(format: "%.1f ms", (ProcessInfo.processInfo.systemUptime - enter)*1000)
                })
            }
            arFrameCounter += 1
        }
    }

    private func drawCamera(camera: ARCamera) {
        let tvec = camera.transform.columns.3
        let position = SCNVector3Make(tvec.x, tvec.y, tvec.z)

        if previousPosition != nil {
            let dist = (position - previousPosition!).length()
            if dist < 1.0 {  // every meter
                return
            }
        }

        let node = SCNNode(geometry: SCNSphere(radius: 0.005))
        node.geometry?.firstMaterial?.diffuse.contents = UIColor.red
        node.simdPosition = simd_make_float3(tvec)
        sceneView.scene.rootNode.addChildNode(node)

        if previousPosition != nil {
            let indices: [Int32] = [0, 1]
            let source = SCNGeometrySource(vertices: [previousPosition!, position])
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let line = SCNGeometry(sources: [source], elements: [element])
            let lineNode = SCNNode(geometry: line)
            lineNode.geometry?.firstMaterial?.diffuse.contents = UIColor.white
            sceneView.scene.rootNode.addChildNode(lineNode)
        }
        previousPosition = position
    }

    private func toggleRecording(val: Bool) {
        self.isRecording = val
        if val {
            prevCounts.removeAll()
        }
        self.fpsStepper.isEnabled = !val
        // prevent screen lock while recording
        UIApplication.shared.isIdleTimerDisabled = val
        UIView.animate(withDuration: 0.25) {
            if val {
                self.recordShape.layer.cornerRadius = 12
                self.recordShape.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
                self.timePill.backgroundColor = .systemRed
            } else {
                self.recordShape.layer.cornerRadius = (UIStyle.recordSize - 2 * UIStyle.recordInset) / 2
                self.recordShape.transform = .identity
                self.timePill.backgroundColor = UIStyle.chromeColor
            }
        }
    }

    @objc func fpsStepperChanged(_ sender: UIStepper) {
        frameDrop = 61 - UInt(sender.value)
        fpsLabel.text = String(format: "%.1f FPS", 60/Double(frameDrop))
    }

    private func initializeUI() {
        timeLabel.text = "READY"
        frameCounterLabel.text = "0"
        fileSizeLabel.text = String(format: "? / %@", self.diskCapacity)
        fpsLabel.text = String(format: "%.1f FPS", 60/Double(frameDrop))
        fpsStepper.value = Double(61 - frameDrop)
        timeWriteLabel.text = timeWriteText

        sceneView.scene.rootNode.enumerateChildNodes { (node, stop) in
                node.removeFromParentNode()
        }
    }

    @objc private func updateTime() {
        var elapsed = Int64(round(Date().timeIntervalSince(self.startTime)))
        let hours: Int64 = elapsed / 3600
        elapsed = elapsed % 3600
        let mins: Int64 = elapsed / 60
        let secs: Int64 = elapsed % 60
        self.timeLabel.text = String(format: "%02d:%02d:%02d", hours, mins, secs)
    }

    private func updateSize() {
        var str: String = "?"
        if let size = try? self.outDirURL.sizeOnDisk(){
             str = size
        }
        self.fileSizeLabel.text = String(format: "%@ / %@", str, self.diskCapacity)
    }

    private func showError(msg: String) {
        DispatchQueue.main.async {
            let fileAlert = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
            fileAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
            self.present(fileAlert, animated: true, completion: nil)
        }
    }

    private func createFiles() -> Bool {
        // Create the output directory
        let recDirURL = getRecDir()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let date = dateFormatter.string(from: Date())
        outDirURL = recDirURL.appendingPathComponent(date)
        do {
            try FileManager.default.createDirectory(at: outDirURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            os_log("Cannot create the output directory: %@", type:.error, error.localizedDescription)
            return false
        }

        // Create the pose file
        guard let poseWriter = PoseWriter(outDir: outDirURL) else {return false}
        self.poseWriter = poseWriter

        self.imageWriter = ImageStreamer(outDir: outDirURL)

        // Create the depth folder
        if (hasDepth) {
            let depthDirURL = outDirURL.appendingPathComponent(depthDirName)
            guard let depthWriter = ImageWriter(outDir: depthDirURL) else {return false}
            self.depthWriter = depthWriter
        }

        if captureIMU && (motionManager != nil){
            guard let motionWriter = MotionWriter(
                    outDir: outDirURL, manager: motionManager, freq: imuFreq) else {return false}
            self.motionWriter = motionWriter
        } else {
            os_log("Will not record IMU data.")
        }

        if captureBT && (self.btManager?.state == .poweredOn) {
            guard let btWriter = BluetoothWriter(outDir: outDirURL) else {return false}
            self.btWriter = btWriter
        } else {
            os_log("Will not record Bluetooth data.")
        }

        if captureLocation {
            let status = locationManager!.authorizationStatus
            if [CLAuthorizationStatus.authorizedAlways, CLAuthorizationStatus.authorizedWhenInUse].contains(status) {
                os_log("Location recording is enabled.")
                guard let locationWriter = LocationWriter(outDir: outDirURL) else {return false}
                self.locationWriter = locationWriter
            } else {
                os_log("Will not record Location data because it was not approved.")
            }
        }

        updateDiskCapacity()
        return true
    }

    private func updateDiskCapacity() {
        do {
            let capacityValues = try self.getRecDir().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacityBytes = capacityValues.volumeAvailableCapacityForImportantUsage {
                let limit = 100
                if capacityBytes > (limit*1024*1024*1024) {
                    self.diskCapacity = String(format: "%d+ GB", limit)
                } else {
                    self.diskCapacity = ByteCountFormatter.string(fromByteCount: capacityBytes, countStyle: .file)
                }
            }
        } catch {
        }
    }

    private func getRecDir() -> URL {
        return try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    // Bluetooth methods
    internal func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            case .poweredOn:
                os_log("Bluetooth is enabled.")
            case .poweredOff:
                self.showError(msg: "Bluetooth is off - please turn it on.")
            case .unauthorized:
                self.showError(msg: "App does not have Bluetooth auth.")
            case .unsupported:
                self.showError(msg: "Device does not support Bluetooth.")
            case .unknown:
                os_log("Unknown Bluetooth error.")
            case .resetting:
                break
            @unknown default:
                break
        }
    }

    @objc private func refreshBluetooth() {
        stopBluetoooth()
        startBluetoooth()
    }

    private func startBluetoooth() {
        btManager.scanForPeripherals(
            withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey : false])
    }

    private func stopBluetoooth() {
        if self.btManager?.state == .poweredOn {
            btManager.stopScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi: NSNumber) {
        btWriter.write(peripheral: peripheral, rssi: rssi)
    }

    // Location methods
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let clErr = error as! CLError
        switch clErr.code {
            case .denied:
                self.showError(msg: "Location service has been denied - please approve it.")
                self.locationManager!.stopUpdatingLocation()
                break
            case .headingFailure:
                os_log("Location service: Couldn't find the heading.")
                break
            default:
                break
        }
    }

    func locationManager(_ manager: CLLocationManager,  didUpdateLocations locations: [CLLocation]) {
        if locationWriter != nil {
            self.writerQueue.addOperation({
                self.locationWriter?.write_multiple(locations: locations)
            })
        }
    }
}

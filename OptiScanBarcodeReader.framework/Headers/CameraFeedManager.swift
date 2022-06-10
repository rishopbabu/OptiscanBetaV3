//
//  CameraFeedManager.swift
//  OptiScanBarcodeReader
//
//  Created by Dineshkumar Kandasamy on 24/05/22.
//  Copyright © 2022 Optisol Business Solution. All rights reserved.

import UIKit
import AVFoundation
import opencv2
import CoreImage
import AudioToolbox
import Vision

/**
 This class manages all camera related functionality
 */
public class CameraFeedManager: NSObject {
    
    // MARK: Camera Related Instance Variables
    
    private var pinchGesture: UIPinchGestureRecognizer!
    private var captureDevice: AVCaptureDeviceInput?
    private lazy var videoDataOutput = AVCaptureVideoDataOutput()
    
    private weak var settingsButton: UIButton!
    private weak var touchToZoomButton: UIButton!
    private weak var outterWhiteRectView: UIView!
    private weak var blinkLabel: UILabel!
    private weak var expireLabel: UILabel!
    private weak var waterMarkLabel: UILabel!
    
    private let previewView: PreviewView
    private var islicenceExpired: Bool = false
    var overlayView: OverlayView!
        
    let sessionQueue = DispatchQueue(label: "sessionQueue")
    let session: AVCaptureSession = AVCaptureSession()
    
    var previewSize: CGSize?
    
    var isSessionRunning = false
    var cameraConfiguration: CameraConfiguration = .failed
    
    private var maskContainer: CGRect {
        CGRect(x: (((self.previewView.bounds.size.width - SFManager.shared.config.maskSize.width) - 24) / 2),
               y: (((self.previewView.bounds.size.height - SFManager.shared.config.maskSize.height) - 0) / 2),
               width: SFManager.shared.config.maskSize.width, height: SFManager.shared.config.maskSize.height)
    }
    
    public weak var delegate: CameraFeedManagerDelegate?
    
    // MARK: Initializer
    
    public init(previewView: UIView, installedDate: Date) {
        
        self.previewView = PreviewView(frame: previewView.bounds)
        previewView.addSubview(self.previewView)
        
        super.init()
        
        overlayView = OverlayView()
        // Initializes the session
        session.sessionPreset = .hd1280x720
        self.previewView.session = session
        SFManager.shared.results.successfulDetectionCount = 0
        
        
        self.previewView.previewLayer.connection?.videoOrientation = .portrait
        self.previewView.previewLayer.videoGravity = .resizeAspectFill
        
        self.previewSize = self.previewView.bounds.size
        
        overlayView.frame = self.previewView.bounds
        overlayView.backgroundColor = UIColor.clear
        overlayView.clipsToBounds = true
        let outterWhiteRectViewItem = createOverlay()
        self.outterWhiteRectView = outterWhiteRectViewItem
        
        self.previewView.addSubview(overlayView)
        self.previewView.addSubview(self.outterWhiteRectView)
        self.previewView.bringSubviewToFront(overlayView)
        self.previewView.bringSubviewToFront(self.outterWhiteRectView)
        
        self.setupBlinkLabel(installedDate)
        
        DebugPrint(message: "Start Camera Config", function: .superResolutionStart)
        
        self.attemptToConfigureSession()
        
        DebugPrint(message: "End Camera Config", function: .superResolutionStart)
        
        scanFlowConfigSetup()
        
    }
    
    //MARK: - Private methods
    
    public func updateScanFlowSettings(_ zoomSettings: ZoomOptions) {
        
        SFManager.shared.initalZoomSettings(zoomSettings)
        
        touchToZoomButton.alpha = SFManager.shared.settings.zoomMode == .touchToZoom ? 1 : 0
        
        switch SFManager.shared.settings.zoomMode {
        case .autoZoom:
            SFManager.shared.initialAutoZoomSetup()
            
        default:
            SFManager.shared.initialTouchToZoomSetup()
            
        }
        
        /// Set initial zoom factor to match
        guard let device = captureDevice?.device else { return }
        let newScaleFactor = minMaxZoom(SFManager.shared.config.defaultInitialZoomFactor * SFManager.shared.config.lastZoomFactor, device: device)
        SFManager.shared.config.lastZoomFactor = minMaxZoom(newScaleFactor, device: device)
        update(scale: SFManager.shared.config.lastZoomFactor, device: device)
        
        
    }
    
    private func scanFlowConfigSetup() {
        
        updateScanFlowSettings(.normal)
        self.setupPinchGesture()
        
    }
    
    private func getValidBarCode(_ codeFormat: Int) -> String {
        
        let codes = ["Aztec", "CODABAR", "Code 39", "Code 93", "Code 128",
                     "Data Matrix", "EAN-8", "EAN-13", "ITF", "MaxiCode",
                     "PDF417", "QR Code", "RSS 14", "RSS EXPANDED", "UPC-A",
                     "UPC-E", "UPC/EAN"]
        
        if codeFormat < codes.count {
            return codes[codeFormat]
        } else {
            return "QR Code"
        }
        
    }
    
    
    private func setupPinchGesture() {
        
        let pinchRecognizer = UIPinchGestureRecognizer(target: self, action:#selector(pinch(_:)))
        self.pinchGesture = pinchRecognizer
        self.previewView.addGestureRecognizer(pinchRecognizer)
        overlayView.frame = previewView.bounds
        overlayView.backgroundColor = UIColor.clear
        previewSize = previewView.frame.size
        previewView.addSubview(overlayView)
        
        /// Set initial zoom factor to match
        guard let device = captureDevice?.device else { return }
        let newScaleFactor = minMaxZoom(SFManager.shared.config.defaultInitialZoomFactor * SFManager.shared.config.lastZoomFactor, device: device)
        SFManager.shared.config.lastZoomFactor = minMaxZoom(newScaleFactor, device: device)
        update(scale: SFManager.shared.config.lastZoomFactor, device: device)
        
    }
    
    
    @objc
    private func pinch(_ pinch: UIPinchGestureRecognizer) {
        
        guard let device = captureDevice?.device else { return }
        
        let newScaleFactor = minMaxZoom(pinch.scale * SFManager.shared.config.lastZoomFactor, device: device)
        
        switch pinch.state {
        case .began: fallthrough
        case .changed: update(scale: newScaleFactor, device: device)
        case .ended:
            SFManager.shared.config.lastZoomFactor = minMaxZoom(newScaleFactor,device: device)
            update(scale: SFManager.shared.config.lastZoomFactor,device: device)
        default: break
        }
        
    }
    
    private func minMaxZoom(_ factor: CGFloat, device: AVCaptureDevice) -> CGFloat {
        return min(min(max(factor, SFManager.shared.config.minimumZoom), SFManager.shared.config.maximumZoom), device.activeFormat.videoMaxZoomFactor)
    }
    
    private func update(scale factor: CGFloat, device: AVCaptureDevice) {
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.ramp(toVideoZoomFactor: factor, withRate: 3)
         
        } catch {
            DebugPrint(message: "\(error.localizedDescription)", function: .updateCameraScale)
        }
    }
    
    //MARK: - Touch To Zoom
    
    /// Touch to zoom enabled to focus on the bar code integration
    ///
    private func resetZoomFactor(_ zoomMode: ZoomOptions) {
        
        guard let device = captureDevice?.device else { return }

        SFManager.shared.config.lastZoomFactor = 1.2
        
        let newScaleFactor = self.minMaxZoom(SFManager.shared.config.defaultInitialZoomFactor * SFManager.shared.config.lastZoomFactor,
                                             device: device)
        SFManager.shared.config.lastZoomFactor = self.minMaxZoom(newScaleFactor, device: device)
                
        self.update(scale: SFManager.shared.config.lastZoomFactor, device: device)
        
        switch zoomMode {
        case .autoZoom:
            break
            
        default:
            SFManager.shared.resetTouchToZoom()
        }
        
        
    }
    
    private func zoomNearToCode(_ zoomMode: ZoomOptions) {
        
        guard let device = captureDevice?.device else { return }

        if SFManager.shared.config.lastZoomFactor >= 10 {
            
            SFManager.shared.config.resetCount = SFManager.shared.config.resetCount + 1
            
            if SFManager.shared.config.resetCount > 4 {
                DebugPrint(message: "ZOOM FACTOR BEFORE RESET: \(SFManager.shared.config.lastZoomFactor)", function: .processResults)
                SFManager.shared.config.resetCount = 0
                self.resetZoomFactor(zoomMode)
            }
            
            DebugPrint(message: "ZOOM TIMER ENABLED", function: .processResults)
            
        } else {
            
            DebugPrint(message: "ZOOM CONTINUES", function: .processResults)
            
            let newScaleFactor = minMaxZoom(SFManager.shared.config.defaultInitialZoomFactor * SFManager.shared.config.lastZoomFactor, device: device)
            SFManager.shared.config.lastZoomFactor = minMaxZoom(newScaleFactor, device: device)
            update(scale: SFManager.shared.config.lastZoomFactor, device: device)
            
        }
        
    }
    
    private func enableZoom(_ zoomMode: ZoomOptions) {
            
        
        switch SFManager.shared.settings.zoomSettings.detectionState {
        case .none:
            zoomNearToCode(zoomMode)
            DebugPrint(message: "ZOOM: Continue scan", function: .processResults)
            
        case .failed:
            if SFManager.shared.config.lastZoomFactor <= 10 && SFManager.shared.config.lastZoomFactor >= 8 {
                DebugPrint(message: "ZOOM: Increased maximum zoom level", function: .processResults)
                return
            } else {
                zoomNearToCode(zoomMode)
                DebugPrint(message: "ZOOM: Increase one zoom level", function: .processResults)
            }
            
        default:
            DebugPrint(message: "ZOOM: Stop scan", function: .processResults)
            return
            
        }
        
        
//        guard SFManager.shared.settings.isDetectionFound == false else {
//            SFManager.shared.settings.isDetectionFound = false
//            return
//        }
                
        
    }
    
    
    @objc
    private func settingsButtonAction() {
        //        let controller = SettingsViewController()
        //        self.navigationController?.pushViewController(controller, animated: true)
    }
    
    @objc
    private func touchToZoomButtonAction() {
        
        if SFManager.shared.settings.isTouchToZoomEnabled == false {
            
            SFManager.shared.settings.isTouchToZoomEnabled = true
            self.enableZoom(.touchToZoom)
            
        } else if SFManager.shared.settings.isTouchToZoomEnabled == true && SFManager.shared.settings.isDetectionFound == true {
            
            SFManager.shared.settings.isTouchToZoomEnabled = false
            SFManager.shared.settings.isDetectionFound = false
            self.resetZoomFactor(.touchToZoom)
            
        } else {
            DebugPrint(message: "No Action", function: .superResolutionStart)
        }
        
    }
    
    private func setupBlinkLabel(_ installedDate: Date) {
        
        let calendar = Date()
        let calen = Calendar.current
        let days = calen.dateComponents([.day], from: installedDate, to: calendar)
        if days.day ?? 0 <= 30 && days.day ?? 0 >= 0 {
            self.islicenceExpired = false
        } else {
            self.islicenceExpired = true
        }
        
        let expireLabelItem = UILabel()
        expireLabelItem.translatesAutoresizingMaskIntoConstraints = false
        expireLabelItem.numberOfLines = 0
        expireLabelItem.alpha = 0
        expireLabelItem.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        expireLabelItem.textAlignment = .center
        expireLabelItem.text = scan_flow.texts.expire_alert
        self.expireLabel = expireLabelItem
        self.previewView.addSubview(expireLabelItem)
        
        let waterMarkLabelItem = UILabel(frame: CGRect(x: ((maskContainer.origin.x + 210) - 5),
                                                       y: maskContainer.origin.y + 300, width: 100, height: 50))
        waterMarkLabelItem.textColor = .lightGray
        waterMarkLabelItem.textAlignment = .right
        waterMarkLabelItem.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        waterMarkLabelItem.text = scan_flow.texts.water_mark
        self.waterMarkLabel = waterMarkLabelItem
        self.overlayView.addSubview(waterMarkLabelItem)
        
        let blinkLabelItem = UILabel()
        blinkLabelItem.translatesAutoresizingMaskIntoConstraints = false
        blinkLabelItem.backgroundColor = .systemGreen
        blinkLabelItem.layer.cornerRadius = 2.5
        blinkLabelItem.clipsToBounds = true
        blinkLabelItem.alpha = 0
        self.blinkLabel = blinkLabelItem
        self.previewView.addSubview(blinkLabelItem)
        
        
        let settingsButtonItem = UIButton()
        settingsButtonItem.translatesAutoresizingMaskIntoConstraints = false
        settingsButtonItem.addTarget(self, action: #selector(settingsButtonAction), for: .touchUpInside)
        settingsButtonItem.tintColor = .white
        settingsButtonItem.alpha = 0
        if #available(iOS 13.0, *) {
            settingsButtonItem.setBackgroundImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        } else {
            // Fallback on earlier versions
        }
        self.settingsButton = settingsButtonItem
        self.overlayView.addSubview(settingsButtonItem)
        
        
        let touchToZoomButtonItem = UIButton()
        touchToZoomButtonItem.translatesAutoresizingMaskIntoConstraints = false
        touchToZoomButtonItem.addTarget(self, action: #selector(touchToZoomButtonAction), for: .touchUpInside)
        touchToZoomButtonItem.alpha = SFManager.shared.settings.zoomMode == .touchToZoom ? 1 : 0
        touchToZoomButtonItem.tintColor = .white
        if #available(iOS 13.0, *) {
            touchToZoomButtonItem.setBackgroundImage(UIImage(systemName: "viewfinder.circle.fill"), for: .normal)
        } else {
            // Fallback on earlier versions
        }
        self.touchToZoomButton = touchToZoomButtonItem
        self.overlayView.addSubview(touchToZoomButtonItem)
        
        NSLayoutConstraint.activate([
            
            expireLabel.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            expireLabel.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            expireLabel.leftAnchor.constraint(equalTo: previewView.leftAnchor, constant: 30),
            expireLabel.rightAnchor.constraint(equalTo: previewView.rightAnchor, constant: -30),
            
            blinkLabel.heightAnchor.constraint(equalToConstant: 5),
            blinkLabel.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            blinkLabel.leftAnchor.constraint(equalTo: previewView.leftAnchor, constant: 30),
            blinkLabel.rightAnchor.constraint(equalTo: previewView.rightAnchor, constant: -30),
            
            settingsButton.topAnchor.constraint(equalTo: overlayView.safeAreaLayoutGuide.topAnchor, constant: 30),
            settingsButton.rightAnchor.constraint(equalTo: overlayView.safeAreaLayoutGuide.rightAnchor, constant: -30),
            settingsButton.heightAnchor.constraint(equalToConstant: 30),
            settingsButton.widthAnchor.constraint(equalToConstant: 30),
            
            touchToZoomButton.bottomAnchor.constraint(equalTo: overlayView.safeAreaLayoutGuide.bottomAnchor, constant: -60),
            touchToZoomButton.leftAnchor.constraint(equalTo: overlayView.safeAreaLayoutGuide.leftAnchor, constant: 20),
            touchToZoomButton.heightAnchor.constraint(equalToConstant: 60),
            touchToZoomButton.widthAnchor.constraint(equalToConstant: 60),
            
            
        ])
        
    }
    
    func createOverlay() -> UIView {
        
        let overlayView = UIView(frame: self.previewView.bounds)
        overlayView.backgroundColor = UIColor.clear
        
        
        let path = CGMutablePath()
        path.addRoundedRect(in: maskContainer, cornerWidth: 2, cornerHeight: 2)
        path.closeSubpath()
        
        let shape = CAShapeLayer()
        shape.path = path
        shape.lineWidth = 5.0
        shape.strokeColor = UIColor.white.cgColor
        shape.fillColor = UIColor.white.cgColor
        
        //        overlayView.layer.addSublayer(shape)
        
        path.addRect(CGRect(origin: .zero, size: overlayView.frame.size))
        
        let maskLayer = CAShapeLayer()
        maskLayer.backgroundColor = UIColor.black.cgColor
        maskLayer.path = path
        maskLayer.fillRule = CAShapeLayerFillRule.evenOdd
        
        // MARK: - Edged Corners
        
        let cornerRadius = self.previewView.layer.cornerRadius
        
        if self.previewView.layer.cornerRadius > SFManager.shared.config.cornerLength { self.previewView.layer.cornerRadius = SFManager.shared.config.cornerLength }
        if SFManager.shared.config.cornerLength > maskContainer.width / 2 { SFManager.shared.config.cornerLength = maskContainer.width / 2 }
        
        let upperLeftPoint = CGPoint(x: maskContainer.minX, y: maskContainer.minY)
        let upperRightPoint = CGPoint(x: maskContainer.maxX, y: maskContainer.minY)
        let lowerRightPoint = CGPoint(x: maskContainer.maxX, y: maskContainer.maxY)
        let lowerLeftPoint = CGPoint(x: maskContainer.minX, y: maskContainer.maxY)
        
        let upperLeftCorner = UIBezierPath()
        upperLeftCorner.move(to: upperLeftPoint.offsetBy(dx: 0, dy: SFManager.shared.config.cornerLength))
        upperLeftCorner.addArc(withCenter: upperLeftPoint.offsetBy(dx: cornerRadius, dy: cornerRadius),
                               radius: self.previewView.layer.cornerRadius, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        upperLeftCorner.addLine(to: upperLeftPoint.offsetBy(dx: SFManager.shared.config.cornerLength, dy: 0))
        
        let upperRightCorner = UIBezierPath()
        upperRightCorner.move(to: upperRightPoint.offsetBy(dx: -SFManager.shared.config.cornerLength, dy: 0))
        upperRightCorner.addArc(withCenter: upperRightPoint.offsetBy(dx: -cornerRadius, dy: cornerRadius),
                                radius: self.previewView.layer.cornerRadius, startAngle: 3 * .pi / 2, endAngle: 0, clockwise: true)
        upperRightCorner.addLine(to: upperRightPoint.offsetBy(dx: 0, dy: SFManager.shared.config.cornerLength))
        
        let lowerRightCorner = UIBezierPath()
        lowerRightCorner.move(to: lowerRightPoint.offsetBy(dx: 0, dy: -SFManager.shared.config.cornerLength))
        lowerRightCorner.addArc(withCenter: lowerRightPoint.offsetBy(dx: -cornerRadius, dy: -cornerRadius),
                                radius: self.previewView.layer.cornerRadius, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        lowerRightCorner.addLine(to: lowerRightPoint.offsetBy(dx: -SFManager.shared.config.cornerLength, dy: 0))
        
        let bottomLeftCorner = UIBezierPath()
        bottomLeftCorner.move(to: lowerLeftPoint.offsetBy(dx: SFManager.shared.config.cornerLength, dy: 0))
        bottomLeftCorner.addArc(withCenter: lowerLeftPoint.offsetBy(dx: cornerRadius, dy: -cornerRadius),
                                radius: self.previewView.layer.cornerRadius, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        bottomLeftCorner.addLine(to: lowerLeftPoint.offsetBy(dx: 0, dy: -SFManager.shared.config.cornerLength))
        
        let combinedPath = CGMutablePath()
        combinedPath.addPath(upperLeftCorner.cgPath)
        combinedPath.addPath(upperRightCorner.cgPath)
        combinedPath.addPath(lowerRightCorner.cgPath)
        combinedPath.addPath(bottomLeftCorner.cgPath)
        
        let shapeLayer = CAShapeLayer()
        shapeLayer.path = combinedPath
        shapeLayer.strokeColor = SFManager.shared.config.lineColor.cgColor
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = SFManager.shared.config.lineWidth
        shapeLayer.lineCap = SFManager.shared.config.lineCap
        
        overlayView.layer.addSublayer(shapeLayer)
        
        
        overlayView.layer.mask = maskLayer
        overlayView.clipsToBounds = true
        return overlayView
        
    }
    
    /**
     This method resumes an interrupted AVCaptureSession.
     */
    func resumeInterruptedSession(withCompletion completion: @escaping (Bool) -> ()) {
        
        sessionQueue.async {
            self.startSession()
            
            DispatchQueue.main.async {
                completion(self.isSessionRunning)
            }
        }
    }
    
    /**
     This method starts the AVCaptureSession
     **/
    public func startSession() {
        self.session.startRunning()
        self.isSessionRunning = self.session.isRunning
    }
    
    // MARK: Session Configuration Methods.
    /**
     This method requests for camera permissions and handles the configuration of the session and stores the result of configuration.
     */
    
    private func attemptToConfigureSession() {
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.cameraConfiguration = .success
            
        case .notDetermined:
            self.sessionQueue.suspend()
            self.requestCameraAccess(completion: { (granted) in
                self.sessionQueue.resume()
            })
            
        case .denied:
            self.cameraConfiguration = .permissionDenied
            
        default:
            break
        }
        
        //self.sessionQueue.async {
        //self.configureSession()
        self.newConfigureSession()
        
        //}
    }
    
    /**
     This method requests for camera permissions.
     */
    private func requestCameraAccess(completion: @escaping (Bool) -> ()) {
        
        AVCaptureDevice.requestAccess(for: .video) { (granted) in
            if !granted {
                self.cameraConfiguration = .permissionDenied
            } else {
                self.cameraConfiguration = .success
            }
            completion(granted)
        }
        
    }
    
    
    private func newConfigureSession() {
        
        let sampleBufferQueue = DispatchQueue(label: "sampleBufferQueue")
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [ String(kCVPixelBufferPixelFormatTypeKey) : kCMPixelFormat_32BGRA]
        
        /**Tries to get the default back camera.
         */
        if let camera  = AVCaptureDevice.default(for: .video) {
            //camera.isFocusModeSupported(.continuousAutoFocus)
            
            do {
                
                let videoDeviceInput = try AVCaptureDeviceInput(device: camera)
                
                self.captureDevice = videoDeviceInput
                
                if session.canAddInput(videoDeviceInput) {
                    session.addInput(videoDeviceInput)
                }
                
            } catch {
                print("Cannot create video device input")
            }
            
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                videoDataOutput.connection(with: .video)?.videoOrientation = .portrait
            }
            
            
            
            self.startSession()
            DebugPrint(message: "Session Started", function: .superResolutionStart)
            
        }
        
    }
    
    
    /**
     This method handles all the steps to configure an AVCaptureSession.
     */
    private func configureSession() {
        
        guard cameraConfiguration == .success else {
            return
        }
        
        session.beginConfiguration()
        
        // Tries to add an AVCaptureDeviceInput.
        guard addVideoDeviceInput() == true && addVideoDataOutput() == true else {
            self.cameraConfiguration = .failed
            return
        }
        
        // Tries to add an AVCaptureVideoDataOutput.
        //        guard addVideoDataOutput() else {
        //            self.cameraConfiguration = .failed
        //            return
        //        }
        
        session.commitConfiguration()
        self.cameraConfiguration = .success
        self.startSession()
        DebugPrint(message: "Session Started", function: .superResolutionStart)
        
    }
    
    /**
     This method tries to add an AVCaptureDeviceInput to the current AVCaptureSession.
     */
    //MARK: - Add  VideoDeviceInput
    
    private func addVideoDeviceInput() -> Bool {
        
        /**Tries to get the default back camera.
         */
        guard let camera  = AVCaptureDevice.default(for: .video) else {
            return false
        }
        
        do {
            
            let videoDeviceInput = try AVCaptureDeviceInput(device: camera)
            
            self.captureDevice = videoDeviceInput
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                return true
            } else {
                return false
            }
            
        } catch {
            fatalError("Cannot create video device input")
        }
        
    }
    
    /**
     This method tries to add an AVCaptureVideoDataOutput to the current AVCaptureSession.
     */
    private func addVideoDataOutput() -> Bool {
        
        DebugPrint(message: "AddVideoDataOutput", function: .superResolutionStart)
        
        let sampleBufferQueue = DispatchQueue(label: "sampleBufferQueue")
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [ String(kCVPixelBufferPixelFormatTypeKey) : kCMPixelFormat_32BGRA]
        
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            
            //            let captureMetadataOutput = AVCaptureMetadataOutput()
            //            captureMetadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            //            captureMetadataOutput.metadataObjectTypes = [AVMetadataObject.ObjectType.qr]
            //            session.addOutput(captureMetadataOutput)
            
            videoDataOutput.connection(with: .video)?.videoOrientation = .portrait
            return true
        }
        return false
    }
    
    // MARK: Notification Observer Handling
    
    func addObservers() {
        
        NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedManager.sessionRuntimeErrorOccurred(notification:)), name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedManager.sessionWasInterrupted(notification:)), name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedManager.sessionInterruptionEnded), name: NSNotification.Name.AVCaptureSessionInterruptionEnded, object: session)
        
    }
    
    func removeObservers() {
        
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionInterruptionEnded, object: session)
        
    }
    
    // MARK: Notification Observers
    
    @objc
    func sessionWasInterrupted(notification: Notification) {
        
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
           let reasonIntegerValue = userInfoValue.integerValue,
           let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            DebugPrint(message: "Capture session was interrupted with reason \(reason)", function: .longDistance)
            
            var canResumeManually = false
            if reason == .videoDeviceInUseByAnotherClient {
                canResumeManually = true
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                canResumeManually = false
            }
            
            self.delegate?.sessionWasInterrupted(canResumeManually: canResumeManually)
            
        }
    }
    
    @objc
    func sessionInterruptionEnded(notification: Notification) {
        self.delegate?.sessionInterruptionEnded()
    }
    
    @objc
    func sessionRuntimeErrorOccurred(notification: Notification) {
        
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            return
        }
        
        DebugPrint(message: "Capture session runtime error: \(error)", function: .longDistance)
        
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.startSession()
                } else {
                    DispatchQueue.main.async {
                        self.delegate?.sessionRunTimeErrorOccurred()
                    }
                }
            }
        } else {
            self.delegate?.sessionRunTimeErrorOccurred()
            
        }
    }
    
}


// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

/**
 AVCaptureVideoDataOutputSampleBufferDelegate
 */
extension CameraFeedManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private var hintsZxing:ZXDecodeHints {
        
        let formats = ZXDecodeHints()
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 1))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 2))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 3))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 4))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 5))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 6))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 7))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 8))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 9))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 10))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 11))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 12))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 13))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 14))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 15))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 16))
        formats.addPossibleFormat(ZXBarcodeFormat.init(rawValue: 17))
        return formats
        
    }
    
    
    @objc
    func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            // we got back an error!
            DebugPrint(message: error.localizedDescription, function: .longDistance)
        } else {
            DebugPrint(message: "Your image has been saved to your photos. \(contextInfo.debugDescription)", function: .imageSaved)
        }
    }
    
    /** This method delegates the CVPixelBuffer of the frame seen by the camera currently.
     */
    
    //    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    //
    //            // Get the metadata object.
    //                let metadataObj = metadataObjects[0] as! AVMetadataMachineReadableCodeObject
    //
    //                if metadataObj.type == AVMetadataObject.ObjectType.qr {
    //                    // If the found metadata is equal to the QR code metadata then update the status label's text and set the bounds
    //    //                let barCodeObject = videoPreviewLayer?.transformedMetadataObject(for: metadataObj)
    //    //                qrCodeFrameView?.frame = barCodeObject!.bounds
    //
    //                    if metadataObj.stringValue != nil {
    //                        let data = metadataObj.stringValue
    //                        print("Apple native output: \(data) Time: \(YoloV4Classifier.shared.getCurrentMillis())")
    //
    //                    }
    //                }
    //
    //        }
     
    
    //MARK: - Capture Output Delegate
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard !self.islicenceExpired else {
            self.expireLabel.alpha = 1
            return
        }
        
        SFManager.shared.config.frameCount = SFManager.shared.config.frameCount + 1
        
        if SFManager.shared.config.frameCount < 5 {
            return
        }
        
        // Converts the CMSampleBuffer to a CVPixelBuffer.
        
        DebugPrint(message: "Sample buffer to Pixel buffer", function: .captureOutput)
        
        ///Enable or disable debug with test images can be handled here
        
        isDebuggingImagesCMSampleBuffer(scan_flow.debug_mode.sample_buffer_with_test_images, sampleBuffer)
        
    }
    
    private func isDebuggingImagesCMSampleBuffer(_ isWithTestImages: Bool, _ sampleBuffer: CMSampleBuffer) {
        
        switch isWithTestImages {
        case false:
            let pixelBuffer: CVPixelBuffer? = CMSampleBufferGetImageBuffer(sampleBuffer)
            
            guard let imagePixelBuffer = pixelBuffer else {
                return
            }
            
            //            if let barcode = self.extractQRCode(fromFrame: imagePixelBuffer).0 {
            //                DebugPrint(message: "BARCODE VALUE: \(barcode)", function: .captureOutput)
            //            }
            
            SFManager.shared.results.originalImage = imagePixelBuffer.toImage()
            SFManager.shared.results.originalImageTime = YoloV4Classifier.shared.getCurrentMillis()
            lowLightHandler(imagePixelBuffer, sampleBuffer)
            
        default:
            let testImage = UIImage(named: "qr_code_low_light_long_distance3")
            let pixelBuffer = testImage?.toPixelBuffer()
            guard let imagePixelBuffer = pixelBuffer else {
                return
            }
            let sampleBuffer1 = convertCMSampleBuffer(imagePixelBuffer)
            lowLightHandler(imagePixelBuffer, sampleBuffer1)
            
        }
        
    }
    
    //MARK: - Low light integration
    
    private func lowLightHandler(_ imagePixelBuffer: CVPixelBuffer, _ pixelBuffer: CMSampleBuffer) {
    
        DebugPrint(message: "LOWLIGHT: Low Brightness image detection start", function: .captureOutput)

        let brightnessLevel = SFManager.shared.getBrightnessValue(pixelBuffer)
        
        DebugPrint(message: "LOWLIGHT: Low Brightness image detection end", function: .captureOutput)

        if brightnessLevel < 0.5 {

            DebugPrint(message: "LOWLIGHT: Before apply brightness pixels", function: .captureOutput)

            let bufferResult = imagePixelBuffer.setBrightnessContrastAndroidOpencv()
            
            let imgHighBright = bufferResult.toImage()
            
            //Test results
            SFManager.shared.results.brightnessAppliedImage = imgHighBright
            
            SFManager.shared.results.brightnessAppliedTime = YoloV4Classifier.shared.getCurrentMillis()
            
            DebugPrint(message: "LOWLIGHT: After apply brightness pixels", function: .captureOutput)

            let finalPixelBuffer = imgHighBright.toPixelBuffer()
            
            DebugPrint(message: "LOWLIGHT: Final buffer", function: .captureOutput)

            yoloClassiferHandler(finalPixelBuffer)
            
        } else {
            
            yoloClassiferHandler(imagePixelBuffer)
            
        }
        
    }
    
    //MARK: - Yolo Classifer Model
    
    private func yoloClassiferHandler(_ imagePixelBuffer: CVPixelBuffer) {
        
        YoloV4Classifier.shared.runModelNew(onFrame: imagePixelBuffer, previewSize: self.previewSize!) { result in
            
            guard let displayResult = result else {
                DebugPrint(message: "FRAMES: No results", function: .processResults)
                return
            }
            
            if displayResult.inferences.count == 0 {
                
                SFManager.shared.settings.noDetectionCount = SFManager.shared.settings.noDetectionCount + 1
                SFManager.shared.settings.zoomSettings.detectionState = .none
                
                self.delegate?.outputData(str: "", codeType: "QR Code")
                self.drawAfterPerformingCalculations(onInferences: displayResult.inferences,
                                                     withImageSize: CGSize.zero,
                                                     isValidResult: false)
                
            } else {
                
                DebugPrint(message: "FRAMES: Inferences available", function: .processResults)
                SFManager.shared.settings.noDetectionCount = 0
                
            }
            
//            if SFManager.shared.settings.isTouchToZoomEnabled == true && SFManager.shared.settings.noDetectionCount > 3 {
//                self.enableZoom(.touchToZoom)
//            }
//
//            if SFManager.shared.settings.isAutoZoomEnabled == true && SFManager.shared.settings.noDetectionCount > 3 {
//                self.enableZoom(.autoZoom)
//            }
            
            if SFManager.shared.settings.isTouchToZoomEnabled == true {
                self.enableZoom(.touchToZoom)
            }
            
            if SFManager.shared.settings.isAutoZoomEnabled == true {
                self.enableZoom(.autoZoom)
            }
            
            for inference in displayResult.inferences {
                
                self.processResult(cropImage: inference.outputImage,
                                   previewWidth: inference.previewWidth,
                                   previewHeight: inference.previewHeight,
                                   inference: inference)
                
            }
            
        }
        
    }
    
    
    private func playBeep() {
        
        if let soundPath = SFManager.shared.manageBeepSound() {
            let fileURL = NSURL(fileURLWithPath: soundPath)
            var soundID: SystemSoundID = 0
            AudioServicesCreateSystemSoundID(fileURL, &soundID)
            AudioServicesPlaySystemSound(soundID)
        } else {
            AudioServicesPlaySystemSound(SystemSoundID(1106))
        }
        
    }
    
    internal func processResult(cropImage: UIImage,
                                previewWidth: CGFloat,
                                previewHeight: CGFloat,
                                inference: Inference) {
        
        if inference.className == "QR" {
            
            var resultImage = UIImage()
            if isQrLongDistance(image: cropImage,
                                previewWidth: previewWidth,
                                previewHeight: previewHeight) {
                
                //print("QR Long Distance")
                resultImage = cropImage.upscaleQRcode()
                
                ///Test results
                SFManager.shared.results.upscaledQRImage = resultImage
                SFManager.shared.results.upscaledQRTime = YoloV4Classifier.shared.getCurrentMillis()
                
                resultImage = SuperResolution.shared.convertImgToSRImg(inputImage: resultImage) ?? UIImage()
                
                ///Test results
                SFManager.shared.results.superResolutionImage = resultImage
                SFManager.shared.results.superResolutionTime = YoloV4Classifier.shared.getCurrentMillis()
                
                //print("UPSCALE RESIZE",resultImage.size)
                
            } else {
                
                resultImage = cropImage
                ///Test results
                SFManager.shared.results.croppedQRImage = resultImage
                SFManager.shared.results.croppedQRTime = YoloV4Classifier.shared.getCurrentMillis()
                SFManager.shared.results.barCodeType = .qr_code
                
            }
            
            
            let imgSize = __CGSizeEqualToSize(resultImage.size, .zero)
            
            if !imgSize {
                
                let points = NSMutableArray()
                let mat = Mat.init(uiImage: resultImage)
                let result = WeChatQRCode().detectAndDecode(img: mat, points: points)
                DebugPrint(message: "WECHAT RESULT: \n \(result), \(result.count)", function: .processResults)
                
                if result.first != nil && result.first != "" {
                    
                    self.delegate?.outputData(str: result.first ?? "", codeType: scan_flow.code_type.qr_type)
                    YoloV4Classifier.shared.isProduction() ? nil : playBeep()
                    self.drawAfterPerformingCalculations(onInferences: [inference],
                                                         withImageSize: resultImage.size,
                                                         isValidResult: true)
                    
                    ///Internal Purpose
                    DebugPrint(message: "QR RESULT IN: \(YoloV4Classifier.shared.getCurrentMillis())", function: .processResults)
                    //AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_Vibrate))
                    //AudioServicesPlaySystemSound(SystemSoundID(scan_flow.media.alert_sound_id))
                    
                    if SFManager.shared.settings.isAutoZoomEnabled || SFManager.shared.settings.isTouchToZoomEnabled {
                        SFManager.shared.settings.isDetectionFound = true
                    }
                    SFManager.shared.results.successfulDetectionCount = SFManager.shared.results.successfulDetectionCount + 1
                    SFManager.shared.settings.zoomSettings.detectionState = .success
                    
                } else {
                    
                    self.delegate?.outputData(str: "", codeType: scan_flow.code_type.qr_type)
                    self.drawAfterPerformingCalculations(onInferences: [inference],
                                                         withImageSize: resultImage.size,
                                                         isValidResult: false)
                    
                    ///Internal Purpose
                    DebugPrint(message: "FRAMES: Decode failed", function: .processResults)
                    SFManager.shared.settings.zoomSettings.detectionState = .failed
                    
                    
                }
                
            } else {
                
                self.delegate?.outputData(str: "", codeType: scan_flow.code_type.qr_type)
                self.drawAfterPerformingCalculations(onInferences: [inference],
                                                     withImageSize: resultImage.size,
                                                     isValidResult: false)
                
                ///Internal Purpose
                DebugPrint(message: "FRAMES: Decode failed", function: .processResults)
                //if SFManager.shared.settings.isAutoZoomEnabled {
                //     SFManager.shared.settings.autoZoomMode = .stopScan
                //}
                SFManager.shared.settings.zoomSettings.detectionState = .failed
                
            }
            
        } else {
            
            let resultImage:UIImage?
            
            if isBarcodeLongDistance(image: cropImage, previewWidth: previewWidth, previewHeight: previewHeight) {
                
                resultImage = cropImage.upscaleBarcode()
                SFManager.shared.results.upscaledBARImage = resultImage
                SFManager.shared.results.upscaledBARTime = YoloV4Classifier.shared.getCurrentMillis()
                
                DebugPrint(message: "BAR Long Distance", function: .longDistance)
                
            } else {
                
                resultImage = cropImage
                SFManager.shared.results.croppedBARImage = resultImage
                SFManager.shared.results.croppedBARTime = YoloV4Classifier.shared.getCurrentMillis()
                
                DebugPrint(message: "BAR Short Distance", function: .longDistance)
                
            }
            
            let resultPixelBuffer = resultImage?.toPixelBuffer()
            
            if let barcodeResult = SFManager.shared.extractQRCode(fromFrame: resultPixelBuffer).0,
               let barcodeType = SFManager.shared.extractQRCode(fromFrame: resultPixelBuffer).1 {
                
                let image = resultImage ?? UIImage()
                let removeCodeTypePrefix = barcodeType.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                YoloV4Classifier.shared.isProduction() ? nil : playBeep()
                self.delegate?.outputData(str: barcodeResult, codeType: removeCodeTypePrefix)
                self.drawAfterPerformingCalculations(onInferences: [inference],
                                                     withImageSize: image.size,
                                                     isValidResult: true)
                
                ///Internal Purpose
                SFManager.shared.results.successfulDetectionCount = SFManager.shared.results.successfulDetectionCount + 1
                SFManager.shared.results.barCodeType = .bar_code
                if SFManager.shared.settings.isAutoZoomEnabled || SFManager.shared.settings.isTouchToZoomEnabled {
                    SFManager.shared.settings.isDetectionFound = true
                }
                SFManager.shared.settings.zoomSettings.detectionState = .success
                
            } else {
                
                let rotatedImage = self.processImage(image: resultImage ?? UIImage())
                self.decodeZxing(image: rotatedImage, inference: inference)
                
            }
            
        }
        
    }
    
    //MARK: - Decode Zxing
    
    func decodeZxing(image: UIImage, inference: Inference) {
        
        let source: ZXLuminanceSource = ZXCGImageLuminanceSource(cgImage: image.cgImage)
        let binazer = ZXHybridBinarizer(source: source)
        let bitmap = ZXBinaryBitmap(binarizer: binazer)
        let reader = ZXMultiFormatReader()
        let hints = hintsZxing
        
        if let result = try? reader.decode(bitmap, hints: hints) {
            
            let formate = result.barcodeFormat.rawValue
            let codeType = self.getValidBarCode(Int(formate))
            
            YoloV4Classifier.shared.isProduction() ? nil : playBeep()
            self.delegate?.outputData(str: result.text ?? "", codeType: codeType)
            DebugPrint(message: "BAR RESULT IN", function: .processResults)
            self.drawAfterPerformingCalculations(onInferences: [inference],
                                                 withImageSize: image.size,
                                                 isValidResult: true)
            
            ///Internal Purpose
            SFManager.shared.results.successfulDetectionCount = SFManager.shared.results.successfulDetectionCount + 1
            SFManager.shared.results.barCodeType = .bar_code
            if SFManager.shared.settings.isAutoZoomEnabled || SFManager.shared.settings.isTouchToZoomEnabled {
                SFManager.shared.settings.isDetectionFound = true
            }
            SFManager.shared.settings.zoomSettings.detectionState = .success
            
            
        } else {
            
            self.delegate?.outputData(str: "", codeType: scan_flow.code_type.bar_type)
            self.drawAfterPerformingCalculations(onInferences: [inference],
                                                 withImageSize: image.size,
                                                 isValidResult: false)
            ///Internal Purpose
            DebugPrint(message: "FRAMES: Decode failed", function: .processResults)
            SFManager.shared.settings.zoomSettings.detectionState = .failed
            
        }
        
    }
    
    
    //MARK: - Draw Bounding Box
    
    func drawAfterPerformingCalculations(onInferences inferences: [Inference],
                                         withImageSize imageSize: CGSize,
                                         isValidResult: Bool) {
        
        self.overlayView.objectOverlays = []
        
        DispatchQueue.main.async {
            // Hands off drawing to the OverlayView
            self.overlayView.setNeedsDisplay()
        }
        
        
        let displayFont = UIFont.systemFont(ofSize: 14.0, weight: .medium)
        
        guard !inferences.isEmpty else {
            return
        }
        
        var objectOverlays: [ObjectOverlay] = []
        
        for inference in inferences {
            
            DispatchQueue.main.async {
                
                // Translates bounding box rect to current view.
                var convertedRect = inference.rect
                //          print("overlayView width",self.overlayView.bounds.size.width)
                //          print("overlayView height",self.overlayView.bounds.size.height)
                //          print("inference.rect",inference.rect)
                
                if convertedRect.origin.x < 0 {
                    convertedRect.origin.x = SFManager.shared.config.edgeOffset
                }
                
                if convertedRect.origin.y < 0 {
                    convertedRect.origin.y = SFManager.shared.config.edgeOffset
                }
                
                if convertedRect.maxY > self.overlayView.bounds.maxY {
                    convertedRect.size.height = self.overlayView.bounds.maxY - convertedRect.origin.y - SFManager.shared.config.edgeOffset
                }
                
                if convertedRect.maxX > self.overlayView.bounds.maxX {
                    convertedRect.size.width = self.overlayView.bounds.maxX - convertedRect.origin.x - SFManager.shared.config.edgeOffset
                }
                
                let confidenceValue = Int(inference.confidence * 100.0)
                let string = "\(inference.className)  (\(confidenceValue)%)"
                
                let size = string.size(usingFont: displayFont)
                DebugPrint(message: "Converted Rect: \(convertedRect)", function: .drawAfterCalculation)
                
                //inference.displayColor
                
                let rectColor = isValidResult ? UIColor.opti_scan_bounding_box_color : UIColor.clear
                let objectOverlay = ObjectOverlay(name: string,
                                                  borderRect: inference.boundingRect,
                                                  nameStringSize: size,
                                                  color: rectColor,
                                                  font: displayFont)
                
                DebugPrint(message: "BOUNDING Rect: \(inference.boundingRect)", function: .drawAfterCalculation)
                
                objectOverlays.append(objectOverlay)
                
            }
            
        }
        
        DispatchQueue.main.async {
            // Hands off drawing to the OverlayView
            self.draw(objectOverlays: objectOverlays)
        }
        
    }
    
    /** Calls methods to update overlay view with detected bounding boxes and class names.
     */
    func draw(objectOverlays: [ObjectOverlay]) {
        //        print("&&&&&& &&&&&&& &&&&&&& OBJECT OVERLAY",objectOverlays)
        self.overlayView.objectOverlays = objectOverlays
        self.overlayView.clipsToBounds = true
        self.overlayView.setNeedsDisplay()
    }
    
    private func isQrLongDistance(image:UIImage,previewWidth:CGFloat,previewHeight:CGFloat) ->Bool{
        let isLong = LongDistance().isLongDistanceQRImage(cropImageWidth: image.size.width, cropImageHeight: image.size.height, previewWidth: previewWidth, previewHeight: previewHeight)
        return isLong
    }
    
    private func isBarcodeLongDistance(image:UIImage,previewWidth:CGFloat,previewHeight:CGFloat) ->Bool{
        let isLong = LongDistance().isLongDistanceBarcodeImage(cropImageWidth: image.size.width, cropImageHeight: image.size.height, previewWidth: previewWidth, previewHeight: previewHeight)
        return isLong
    }
    
    func processImage(image: UIImage) -> UIImage {
        
        let inputImageMat = Mat.init(uiImage: image)
        let lines:Mat = initMatSetup(bitmap: image)
        let angleResult = self.detectRotationAngle(binaryImage: lines)
        let rotatedImage = self.rotateImage(imageMat: inputImageMat, angle: angleResult)
        return rotatedImage
        
    }
    
    private func initMatSetup(bitmap: UIImage) -> Mat {
        
        // print("BEFORE initMatSetup: \(getCurrentMillis())")
        
        let mat = Mat.init(uiImage: bitmap)
        var rgbMat = mat
        let grayMat = mat
        var destination:Mat = Mat(rows: rgbMat.rows(), cols: rgbMat.cols(), type: rgbMat.type())
        Imgproc.cvtColor(src: rgbMat, dst: grayMat, code: ColorConversionCodes.COLOR_BGR2GRAY)
        
        destination = grayMat
        let element = Imgproc.getStructuringElement(shape: MorphShapes.MORPH_RECT, ksize: Size2i(width: 5, height: 5))
        Imgproc.erode(src: grayMat, dst: destination, kernel: element)
        
        rgbMat = destination
        let element1 = Imgproc.getStructuringElement(shape: MorphShapes.MORPH_RECT, ksize: Size2i(width: 5, height: 5))
        Imgproc.dilate(src: rgbMat, dst: destination, kernel: element1)
        
        //Detecting the edges
        let edges = mat
        Imgproc.Canny(image: destination, edges: edges, threshold1: 50.0, threshold2: 200.0)
        //Detecting the hough lines from (canny)
        let lines = mat
        Imgproc.HoughLinesP(image: edges, lines: lines, rho: 0.8, theta: .pi / 360, threshold: 50, minLineLength: 50.0, maxLineGap: 10.0)
        // print("AFTER initMatSetup: \(getCurrentMillis())")
        return lines
        
    }
    
    private func detectRotationAngle(binaryImage: Mat) -> Double {
        
        var angle:Double = 0.0
        let debugImage:Mat = binaryImage.clone()
        for x in 0..<binaryImage.cols(){
            var vec = [Double]()
            vec = binaryImage.get(row: 0, col: x)
            let x1:Double = vec[0]
            let y1:Double = vec[1]
            let x2:Double = vec[2]
            let y2:Double = vec[3]
            let start :Point2i = Point2i(x: Int32(x1), y: Int32(y1))
            let end : Point2i = Point2i(x: Int32(x2), y: Int32(y2))
            
            //Draw line on the "debug" image for visualization
            Imgproc.line(img: debugImage, pt1: start, pt2: end, color: Scalar(255.0, 255.0, 0), thickness: 5)
            
            //Calculate the angle we need
            angle = calculateAngleFromPoints(start: start, end: end);
        }
        //        print("AFTER ROTATE IMAGE: \(getCurrentMillis())")
        
        return angle;
    }
    
    
    //  From an end point and from a start point we can calculate the angle
    
    private func calculateAngleFromPoints(start: Point2i, end: Point2i) -> Double {
        
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let atan:Double = atan2(Double(deltaY), Double(deltaX))
        let val = atan * (180 / .pi)
        return val
        
    }
    
    private func rotateImage(imageMat: Mat, angle: Double) -> UIImage {
        
        DebugPrint(message: "ACTUAL DEGREE -->>> \(angle)", function: .rotateImage)
        
        var image = imageMat.toUIImage()
        
        if imageMat.size().height > imageMat.size().width {
            
            DebugPrint(message: "ACTUAL DEGREE Size -->>> \(imageMat.size())", function: .rotateImage)
            let size = imageMat.size()
            let height = Double(size.height)
            
            DispatchQueue.main.async {
                
                let imageV = UIImageView(frame: CGRect(x: 0, y: 0, width: height, height: height))
                imageV.backgroundColor = .white
                imageV.image = image
                imageV.contentMode = .center
                image = UIImage(view: imageV)
            }
            
            DebugPrint(message: "ACTUAL DEGREE Size after conversion -->>> \(image.size)", function: .rotateImage)
            
        } else {
            
            let size = imageMat.size()
            let width = Double(size.width)
            
            DispatchQueue.main.async {
                
                let imageV = UIImageView(frame: CGRect(x: 0, y: 0, width: width, height: width))
                imageV.backgroundColor = .white
                imageV.image = image
                imageV.contentMode = .center
                image = UIImage(view: imageV)
                
            }
            
            
            DebugPrint(message: "ACTUAL DEGREE Size after conversion -->>> \(image.size)", function: .rotateImage)
            
        }
        
        
        let locImageMat = Mat.init(uiImage: image)
        
        //Get the rotation matrix
        
        let imgCenter = Point2f(x: Float(locImageMat.cols()) / 2, y: Float(locImageMat.rows()) / 2)
        
        DebugPrint(message: "ROTATION PERFORM", function: .rotateImage)
        
        let rotMtx = Imgproc.getRotationMatrix2D(center: imgCenter, angle: angle, scale: 1.0)
        
        Imgproc.warpAffine(src: locImageMat, dst: locImageMat, M: rotMtx, dsize: Size2i(width:Int32(image.size.width) , height: Int32(image.size.height)))
        
        let img = locImageMat.toUIImage()
        
        return img
        
        
    }
    
    
}


import UIKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

final class CameraLabViewController: UIViewController {

    // UI
    private let preview = PreviewView()
    private let fpsLabel = UILabel()
    private let segmented = UISegmentedControl(items: ["Live Camera", "Video Source", "VCam"])
    private let couplingLabel = UILabel()
    private let coupling = UISegmentedControl(items: ["Off", "Cam on, show video", "Show cam, buf=video"])
    private let chooseButton = UIButton(type: .system)
    private let logButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let inspectorLabel = UILabel()
    private let detectionLabel = UILabel()
    private let logsView = UITextView()

    // State
    private var source: FrameSource?
    private var videoURL: URL?
    private let detector = VCamDetectionService()

    private var frameTimes: [CFTimeInterval] = []
    private var latestInfo: FrameInfo?
    private var latestResult: DetectionResult?
    private var logs: [TestLogEntry] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Camera Test Lab"
        view.backgroundColor = .systemBackground
        setupUI()
        switchSource()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        source?.stop()
    }

    // MARK: Layout

    private func setupUI() {
        preview.translatesAutoresizingMaskIntoConstraints = false

        fpsLabel.text = "FPS: –"
        fpsLabel.textColor = .systemGreen
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        fpsLabel.textAlignment = .center
        fpsLabel.layer.cornerRadius = 4
        fpsLabel.clipsToBounds = true
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(fpsLabel)

        segmented.selectedSegmentIndex = 0
        segmented.addTarget(self, action: #selector(sourceChanged), for: .valueChanged)

        couplingLabel.text = "Live coupling (real camera running → green dot):"
        couplingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        couplingLabel.textColor = .secondaryLabel
        coupling.selectedSegmentIndex = 0
        coupling.addTarget(self, action: #selector(sourceChanged), for: .valueChanged)
        coupling.apportionsSegmentWidthsByContent = true

        configure(chooseButton, "Choose Video…", #selector(chooseVideo))
        configure(logButton, "Log Snapshot", #selector(logSnapshot))
        configure(exportButton, "Export Logs", #selector(exportLogs))

        for label in [inspectorLabel, detectionLabel] {
            label.numberOfLines = 0
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        inspectorLabel.text = "Frame Inspector: –"
        detectionLabel.text = "Detection: –"

        logsView.isEditable = false
        logsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logsView.backgroundColor = .secondarySystemBackground
        logsView.layer.cornerRadius = 8
        logsView.text = "Test logs:\n"

        let buttonsRow = UIStackView(arrangedSubviews: [logButton, exportButton])
        buttonsRow.distribution = .fillEqually
        buttonsRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [
            segmented, couplingLabel, coupling, chooseButton, buttonsRow,
            inspectorLabel, detectionLabel, logsView
        ])
        stack.setCustomSpacing(2, after: couplingLabel)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(preview)
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: guide.topAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.40),

            fpsLabel.topAnchor.constraint(equalTo: preview.topAnchor, constant: 8),
            fpsLabel.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 8),
            fpsLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            fpsLabel.heightAnchor.constraint(equalToConstant: 22),

            stack.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),

            logsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    private func configure(_ button: UIButton, _ title: String, _ action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: Source management

    @objc private func sourceChanged() { switchSource() }

    private func switchSource() {
        source?.stop()
        detector.reset()
        frameTimes.removeAll()
        preview.clear()
        updateFPS()

        let newSource: FrameSource?
        if segmented.selectedSegmentIndex == 0 {
            chooseButton.isEnabled = false
            coupling.isEnabled = false        // coupling only applies to an injected source.
            newSource = CameraCaptureService()
        } else {
            chooseButton.isEnabled = true
            coupling.isEnabled = true
            guard let url = videoURL else {
                inspectorLabel.text = "Frame Inspector: pick a video to inject."
                detectionLabel.attributedText = nil
                detectionLabel.text = "Detection: –"
                source = nil
                return
            }
            // 1 = weak stand-in (BGRA, no intrinsics, PTS resets) → easily flagged.
            // 2 = realistic VCam reproduction (420v, forged intrinsics, monotonic
            //     PTS) → slips past the naive heuristics, like a real injector.
            let injector: FrameSource = segmented.selectedSegmentIndex == 2
                ? VCamInjectionService(url: url)
                : VideoFixtureService(url: url)

            // Coupling runs a REAL camera session alongside the injector so the
            // green indicator is on and "is the session live?" checks pass, while
            // the detector is fed the video — the scenario eKYC must catch.
            switch coupling.selectedSegmentIndex {
            case 1:  newSource = CoupledInjectionService(injector: injector, mode: .showVideo)
            case 2:  newSource = CoupledInjectionService(injector: injector, mode: .showCameraBufferVideo)
            default: newSource = injector
            }
        }
        newSource?.delegate = self
        source = newSource
        newSource?.start()
    }

    // MARK: Video picking

    @objc private func chooseVideo() {
        let sheet = UIAlertController(title: "Inject video from", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photos", style: .default) { [weak self] _ in self?.pickFromPhotos() })
        sheet.addAction(UIAlertAction(title: "Files", style: .default) { [weak self] _ in self?.pickFromFiles() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = chooseButton
        present(sheet, animated: true)
    }

    private func pickFromPhotos() {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pickFromFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie])
        picker.delegate = self
        present(picker, animated: true)
    }

    private func importVideo(from url: URL, scoped: Bool) -> URL? {
        if scoped, !url.startAccessingSecurityScopedResource() { return nil }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func applyPickedVideo(_ url: URL) {
        videoURL = url
        // Keep an injection tab if one is already selected (Video Source or VCam);
        // only jump off Live Camera.
        if segmented.selectedSegmentIndex == 0 { segmented.selectedSegmentIndex = 1 }
        switchSource()
    }

    // MARK: Logging

    @objc private func logSnapshot() {
        guard let info = latestInfo, let result = latestResult else { return }
        let entry = TestLogEntry(
            timestamp: Date(),
            sourceKind: source?.kind.rawValue ?? "-",
            verdict: result.verdict.rawValue,
            score: result.injectionScore,
            format: info.pixelFormat,
            resolution: info.resolution,
            hasIntrinsics: info.hasCameraIntrinsics)
        logs.append(entry)
        logsView.text += entry.line + "\n"
        let bottom = NSRange(location: logsView.text.count, length: 0)
        logsView.scrollRangeToVisible(bottom)
    }

    @objc private func exportLogs() {
        guard !logs.isEmpty else { return }
        let text = logs.map(\.line).joined(separator: "\n")
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = exportButton
        present(activity, animated: true)
    }

    // MARK: UI updates

    private func updateFPS() {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1.0 }
        fpsLabel.text = "FPS: \(frameTimes.count)"
    }

    private func render(_ info: FrameInfo, _ result: DetectionResult) {
        inspectorLabel.text = """
        Frame Inspector
        format: \(info.pixelFormat)   res: \(info.resolution)   planes: \(info.planeCount)
        bytesPerRow[0]: \(info.bytesPerRowPlane0)   pts: \(String(format: "%.3f", info.presentationTime))s
        intrinsics: \(info.hasCameraIntrinsics ? "yes" : "no")
        attachments: \(info.attachmentKeys.isEmpty ? "none" : info.attachmentKeys.joined(separator: ", "))
        """

        let color: UIColor
        switch result.verdict {
        case .liveSensor: color = .systemGreen
        case .injected:   color = .systemRed
        case .uncertain:  color = .systemOrange
        }
        let header = "Detection: \(result.verdict.rawValue)  (score \(String(format: "%.2f", result.injectionScore)))\n"
        let body = result.reasons.map { "• " + $0 }.joined(separator: "\n")
        let attr = NSMutableAttributedString(
            string: header,
            attributes: [.foregroundColor: color, .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)])
        attr.append(NSAttributedString(
            string: body,
            attributes: [.foregroundColor: UIColor.label, .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        detectionLabel.attributedText = attr
    }
}

// MARK: - FrameSourceDelegate

extension CameraLabViewController: FrameSourceDelegate {
    func frameSource(_ source: FrameSource, didOutput packet: FramePacket) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.source === source else { return }
            self.updateFPS()
            if let info = FrameInspector.inspect(packet.sampleBuffer) {
                let result = self.detector.evaluate(info)
                self.latestInfo = info
                self.latestResult = result
                self.render(info, result)
            }
            // Verify sampleBuffer, but display previewOverride when set: in the
            // coupled "show camera" demo the human sees the live camera while the
            // detector is being fed the injected video.
            self.preview.enqueue(packet.previewOverride ?? packet.sampleBuffer)
        }
    }

    func frameSource(_ source: FrameSource, didFailWith error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.inspectorLabel.text = "Frame Inspector: \(error.localizedDescription)"
        }
    }
}

// MARK: - Picker delegates

extension CameraLabViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { return }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let self, let url, let copied = self.importVideo(from: url, scoped: false) else { return }
            DispatchQueue.main.async { self.applyPickedVideo(copied) }
        }
    }
}

extension CameraLabViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let copied = importVideo(from: url, scoped: true) else { return }
        applyPickedVideo(copied)
    }
}

import UIKit
import ImageIO

private enum PhotoSourceType {
    case presets
    case immich

    var title: String {
        switch self {
        case .presets: return "Presets"
        case .immich: return "Immich"
        }
    }
}

private enum TransitionMode: Int {
    case fade
    case slide
    case zoom
    case dissolve

    static let all: [TransitionMode] = [.fade, .slide, .zoom, .dissolve]

    var title: String {
        switch self {
        case .fade: return "Fade"
        case .slide: return "Slide"
        case .zoom: return "Zoom"
        case .dissolve: return "Dissolve"
        }
    }
}

private enum PlaybackOrder: Int {
    case sequential
    case random

    var title: String {
        switch self {
        case .sequential: return "Sequential"
        case .random: return "Random"
        }
    }
}

final class ViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()
    private let topPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let bottomPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let playPauseButton = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private let settingsPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let settingsTabs = UISegmentedControl(items: ["Presets", "Immich", "Playback"])
    private let settingsContent = UIView()
    private let statusLabel = UILabel()
    private let immichTextView = UITextView()
    private let intervalSlider = UISlider()
    private let intervalValueLabel = UILabel()
    private let transitionControl = UISegmentedControl(items: TransitionMode.all.map { $0.title })
    private let orderControl = UISegmentedControl(items: [PlaybackOrder.sequential.title, PlaybackOrder.random.title])
    private let cacheSizeControl = UISegmentedControl(items: ["100 MB", "300 MB", "500 MB"])
    private let cacheStatusLabel = UILabel()
    private let imageCache = NSCache<NSURL, UIImage>()
    private let immichClient = ImmichShareClient()

    private let cacheSizeOptionsMB = [100, 300, 500]
    private let maxConcurrentRemoteLoads = 1
    private var photos: [FramePhoto] = FramePhoto.presets()
    private var currentIndex = 0
    private var isPlaying = true
    private var timer: Timer?
    private var panelsVisible = true
    private var settingsVisible = false
    private var sourceType: PhotoSourceType = .presets
    private var transitionMode: TransitionMode = .fade
    private var playbackOrder: PlaybackOrder = .sequential
    private var interval: TimeInterval = 8
    private var cacheSizeMB = 300
    private var currentImageRequestID = UUID()
    private var currentPhotoReadyForTiming = false
    private var remoteImageTasks: [URL: URLSessionDataTask] = [:]
    private var remoteImageCompletions: [URL: [(UIImage?) -> Void]] = [:]
    private var remoteImageNeedsDecode: [URL: Bool] = [:]
    private var cachedFileCosts: [URL: Int] = [:]
    private var cachedFileURLs: [URL: URL] = [:]
    private var deferredPrefetchURLs = Set<URL>()
    private var randomIndexQueue: [Int] = []

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureImageCache()
        clearImageCache()
        buildInterface()
        showPhoto(at: 0, animated: false)
        updatePlaybackSummary()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
    }

    private func buildInterface() {
        view.backgroundColor = .black

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        view.addSubview(imageView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(togglePanels))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)

        buildTopPanel()
        buildBottomPanel()
        buildSettingsPanel()

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func buildTopPanel() {
        topPanel.translatesAutoresizingMaskIntoConstraints = false
        topPanel.layer.cornerRadius = 14
        topPanel.clipsToBounds = true
        view.addSubview(topPanel)

        titleLabel.text = "RevivalFrame"
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white

        detailLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = UIColor(white: 0.82, alpha: 1)
        detailLabel.numberOfLines = 2

        let settingsButton = makeControlButton(title: "Settings", action: #selector(toggleSettings))
        let labelStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 3

        let row = UIStackView(arrangedSubviews: [labelStack, settingsButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        topPanel.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            topPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            topPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            topPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),

            row.leadingAnchor.constraint(equalTo: topPanel.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: topPanel.contentView.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topPanel.contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: topPanel.contentView.bottomAnchor, constant: -12)
        ])
    }

    private func buildBottomPanel() {
        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.layer.cornerRadius = 16
        bottomPanel.clipsToBounds = true
        view.addSubview(bottomPanel)

        let previousButton = makeControlButton(title: "Prev", action: #selector(previousPhoto))
        playPauseButton.setTitle("Pause", for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        styleControlButton(playPauseButton)
        let nextButton = makeControlButton(title: "Next", action: #selector(nextPhoto))
        let shuffleButton = makeControlButton(title: "Shuffle", action: #selector(shufflePhoto))

        summaryLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        summaryLabel.textColor = UIColor(white: 0.84, alpha: 1)
        summaryLabel.numberOfLines = 1

        let bottomStack = UIStackView(arrangedSubviews: [
            previousButton,
            playPauseButton,
            nextButton,
            shuffleButton,
            summaryLabel
        ])
        bottomStack.axis = .horizontal
        bottomStack.alignment = .center
        bottomStack.spacing = 10
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.contentView.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            bottomPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            bottomPanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottomPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            bottomStack.leadingAnchor.constraint(equalTo: bottomPanel.contentView.leadingAnchor, constant: 14),
            bottomStack.trailingAnchor.constraint(equalTo: bottomPanel.contentView.trailingAnchor, constant: -14),
            bottomStack.topAnchor.constraint(equalTo: bottomPanel.contentView.topAnchor, constant: 12),
            bottomStack.bottomAnchor.constraint(equalTo: bottomPanel.contentView.bottomAnchor, constant: -12)
        ])
    }

    private func buildSettingsPanel() {
        settingsPanel.translatesAutoresizingMaskIntoConstraints = false
        settingsPanel.layer.cornerRadius = 18
        settingsPanel.clipsToBounds = true
        settingsPanel.isHidden = true
        settingsPanel.alpha = 0
        view.addSubview(settingsPanel)

        let heading = UILabel()
        heading.text = "Settings"
        heading.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        heading.textColor = .white

        let closeButton = makeControlButton(title: "Done", action: #selector(toggleSettings))
        let headingRow = UIStackView(arrangedSubviews: [heading, closeButton])
        headingRow.axis = .horizontal
        headingRow.alignment = .center
        headingRow.spacing = 16

        settingsTabs.selectedSegmentIndex = 0
        settingsTabs.addTarget(self, action: #selector(settingsTabChanged), for: .valueChanged)
        settingsTabs.tintColor = .white

        settingsContent.translatesAutoresizingMaskIntoConstraints = false
        settingsContent.backgroundColor = .clear

        statusLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = UIColor(white: 0.82, alpha: 1)
        statusLabel.numberOfLines = 3
        statusLabel.text = "Presets are ready."

        let stack = UIStackView(arrangedSubviews: [headingRow, settingsTabs, settingsContent, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsPanel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            settingsPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            settingsPanel.topAnchor.constraint(equalTo: topPanel.bottomAnchor, constant: 12),
            settingsPanel.widthAnchor.constraint(equalToConstant: 430),
            settingsPanel.bottomAnchor.constraint(lessThanOrEqualTo: bottomPanel.topAnchor, constant: -12),

            stack.leadingAnchor.constraint(equalTo: settingsPanel.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: settingsPanel.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: settingsPanel.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: settingsPanel.contentView.bottomAnchor, constant: -16),
            settingsContent.heightAnchor.constraint(equalToConstant: 335)
        ])

        showPresetsSettings()
    }

    private func makeControlButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        styleControlButton(button)
        return button
    }

    private func styleControlButton(_ button: UIButton) {
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        button.backgroundColor = UIColor(white: 1, alpha: 0.14)
        button.layer.cornerRadius = 8
    }

    private func makeSettingsLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = UIColor(white: 0.83, alpha: 1)
        label.numberOfLines = 0
        return label
    }

    private func makeSettingsButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        button.backgroundColor = UIColor(red: 0.22, green: 0.42, blue: 0.64, alpha: 1)
        button.layer.cornerRadius = 9
        return button
    }

    private func replaceSettingsContent(with content: UIView) {
        settingsContent.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        settingsContent.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: settingsContent.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: settingsContent.trailingAnchor),
            content.topAnchor.constraint(equalTo: settingsContent.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: settingsContent.bottomAnchor)
        ])
    }

    private func showPresetsSettings() {
        let useButton = makeSettingsButton(title: "Use Preset Landscapes", action: #selector(usePresets))
        let stack = UIStackView(arrangedSubviews: [
            makeSettingsLabel("Default source"),
            makeSettingsLabel("Four generated landscape photos are available offline and are useful for checking playback, transitions, and full-screen framing."),
            useButton
        ])
        stack.axis = .vertical
        stack.spacing = 10
        replaceSettingsContent(with: stack)
    }

    private func showImmichSettings() {
        let label = makeSettingsLabel("Shared album link")
        immichTextView.delegate = self
        immichTextView.font = UIFont.systemFont(ofSize: 13)
        immichTextView.textColor = .black
        immichTextView.backgroundColor = .white
        immichTextView.layer.cornerRadius = 8
        immichTextView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        immichTextView.autocorrectionType = .no
        immichTextView.autocapitalizationType = .none
        immichTextView.keyboardType = .URL

        let loadButton = makeSettingsButton(title: "Load Immich Album", action: #selector(loadImmich))
        let stack = UIStackView(arrangedSubviews: [
            label,
            immichTextView,
            makeSettingsLabel("Paste an Immich shared album URL. RevivalFrame reads the shared link directly and displays the album photos."),
            loadButton
        ])
        stack.axis = .vertical
        stack.spacing = 10
        immichTextView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        replaceSettingsContent(with: stack)
    }

    private func showPlaybackSettings() {
        transitionControl.selectedSegmentIndex = transitionMode.rawValue
        transitionControl.removeTarget(nil, action: nil, for: .valueChanged)
        transitionControl.addTarget(self, action: #selector(transitionChanged), for: .valueChanged)
        transitionControl.tintColor = .white

        orderControl.selectedSegmentIndex = playbackOrder.rawValue
        orderControl.removeTarget(nil, action: nil, for: .valueChanged)
        orderControl.addTarget(self, action: #selector(orderChanged), for: .valueChanged)
        orderControl.tintColor = .white

        intervalSlider.minimumValue = 5
        intervalSlider.maximumValue = 60
        intervalSlider.value = Float(interval)
        intervalSlider.removeTarget(nil, action: nil, for: .valueChanged)
        intervalSlider.addTarget(self, action: #selector(intervalChanged), for: .valueChanged)

        intervalValueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        intervalValueLabel.textColor = .white
        intervalValueLabel.text = "\(Int(interval))s"

        let intervalRow = UIStackView(arrangedSubviews: [intervalSlider, intervalValueLabel])
        intervalRow.axis = .horizontal
        intervalRow.alignment = .center
        intervalRow.spacing = 10
        intervalValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        cacheSizeControl.selectedSegmentIndex = cacheSizeOptionsMB.firstIndex(of: cacheSizeMB) ?? 1
        cacheSizeControl.removeTarget(nil, action: nil, for: .valueChanged)
        cacheSizeControl.addTarget(self, action: #selector(cacheSizeChanged), for: .valueChanged)
        cacheSizeControl.tintColor = .white

        cacheStatusLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        cacheStatusLabel.textColor = UIColor(white: 0.78, alpha: 1)
        cacheStatusLabel.numberOfLines = 2
        updateCacheStatus()

        let stack = UIStackView(arrangedSubviews: [
            makeSettingsLabel("Transition"),
            transitionControl,
            makeSettingsLabel("Display order"),
            orderControl,
            makeSettingsLabel("Photo duration"),
            intervalRow,
            makeSettingsLabel("Immich cache size"),
            cacheSizeControl,
            cacheStatusLabel
        ])
        stack.axis = .vertical
        stack.spacing = 8
        replaceSettingsContent(with: stack)
    }

    private func scheduleNextPhotoTimer() {
        timer?.invalidate()
        guard isPlaying else { return }
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(timerAdvanced), userInfo: nil, repeats: false)
    }

    private func applyPhotos(_ newPhotos: [FramePhoto], source: PhotoSourceType, status: String) {
        cancelRemoteImageLoads()
        sourceType = source
        photos = newPhotos.isEmpty ? FramePhoto.presets() : newPhotos
        currentIndex = 0
        resetRandomQueue()
        statusLabel.text = status
        showPhoto(at: 0, animated: true)
        updatePlaybackSummary()
    }

    private func showPhoto(at index: Int, animated: Bool) {
        guard photos.indices.contains(index) else { return }
        timer?.invalidate()
        currentPhotoReadyForTiming = false
        let photo = photos[index]
        detailLabel.text = "\(sourceType.title) | \(index + 1) of \(photos.count) | \(photo.title)"
        currentImageRequestID = UUID()
        let requestID = currentImageRequestID

        if let image = photo.image {
            displayPlaybackImage(image, animated: animated)
            prefetchUpcomingPhotos(after: index)
            return
        }

        guard let remoteURL = photo.remoteURL else {
            displayPlaybackImage(FramePhoto.placeholder(title: "Photo unavailable", subtitle: photo.title), animated: animated)
            prefetchUpcomingPhotos(after: index)
            return
        }

        if let cached = imageCache.object(forKey: remoteURL as NSURL) {
            displayPlaybackImage(cached, animated: animated)
            removeCachedImage(for: remoteURL)
            prefetchUpcomingPhotos(after: index)
            return
        }

        if cachedFileURLs[remoteURL] == nil {
            display(image: FramePhoto.placeholder(title: "Loading photo", subtitle: photo.title), animated: animated)
        }
        loadRemoteImage(remoteURL) { [weak self] image in
            guard let self = self else { return }
            guard self.currentImageRequestID == requestID else { return }
            guard let image = image else {
                self.displayPlaybackImage(FramePhoto.placeholder(title: "Photo unavailable", subtitle: photo.title), animated: true)
                return
            }

            self.displayPlaybackImage(image, animated: true)
            self.removeCachedImage(for: remoteURL)
            self.prefetchUpcomingPhotos(after: index)
        }
        prefetchUpcomingPhotos(after: index)
    }

    private func configureImageCache() {
        imageCache.countLimit = 1
        imageCache.totalCostLimit = 0
        prepareTemporaryCacheDirectory()
    }

    private func loadRemoteImage(_ url: URL, shouldDecode: Bool = true, completion: @escaping (UIImage?) -> Void) {
        if let cached = imageCache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }

        if let fileURL = cachedFileURLs[url] {
            DispatchQueue.global(qos: .userInitiated).async {
                let image = self.downsampledImage(at: fileURL)
                DispatchQueue.main.async {
                    if let image = image {
                        self.imageCache.setObject(image, forKey: url as NSURL)
                    }
                    completion(image)
                }
            }
            return
        }

        if remoteImageCompletions[url] != nil {
            remoteImageCompletions[url]?.append(completion)
            remoteImageNeedsDecode[url] = (remoteImageNeedsDecode[url] ?? false) || shouldDecode
            return
        }

        remoteImageCompletions[url] = [completion]
        remoteImageNeedsDecode[url] = shouldDecode
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self = self else { return }
            var cost = 1
            var storedFileURL: URL?
            if let data = data,
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                cost = max(1, data.count)
                let fileURL = self.temporaryCacheFileURL(for: url)
                do {
                    try data.write(to: fileURL, options: .atomic)
                    storedFileURL = fileURL
                } catch {
                    storedFileURL = nil
                }
            }

            DispatchQueue.main.async {
                var loadedImage: UIImage?
                if let fileURL = storedFileURL {
                    self.storeCachedFile(at: fileURL, for: url, cost: cost)
                    if self.remoteImageNeedsDecode[url] == true {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let image = self.downsampledImage(at: fileURL)
                            DispatchQueue.main.async {
                                if let image = image {
                                    self.imageCache.setObject(image, forKey: url as NSURL)
                                }
                                let completions = self.remoteImageCompletions.removeValue(forKey: url) ?? []
                                self.remoteImageNeedsDecode.removeValue(forKey: url)
                                self.remoteImageTasks.removeValue(forKey: url)
                                self.updateCacheStatus()
                                completions.forEach { $0(image) }
                                self.prefetchUpcomingPhotos(after: self.currentIndex)
                            }
                        }
                        return
                    }
                }
                let completions = self.remoteImageCompletions.removeValue(forKey: url) ?? []
                self.remoteImageNeedsDecode.removeValue(forKey: url)
                self.remoteImageTasks.removeValue(forKey: url)
                self.updateCacheStatus()
                completions.forEach { $0(loadedImage) }
                self.prefetchUpcomingPhotos(after: self.currentIndex)
            }
        }
        remoteImageTasks[url] = task
        task.resume()
        updateCacheStatus()
    }

    private func prefetchUpcomingPhotos(after index: Int) {
        guard photos.count > 1, cachedImageBytes < cacheLimitBytes else {
            updateCacheStatus()
            return
        }

        while cachedImageBytes < cacheLimitBytes && remoteImageTasks.count < maxConcurrentRemoteLoads {
            guard let url = nextPrefetchURL(after: index) else { break }
            loadRemoteImage(url, shouldDecode: false) { _ in }
        }
        updateCacheStatus()
    }

    private func nextPrefetchURL(after index: Int) -> URL? {
        guard photos.count > 1 else { return nil }
        if playbackOrder == .random {
            ensureRandomQueue()
            for next in randomIndexQueue {
                if let url = photos[next].remoteURL,
                   cachedFileURLs[url] == nil,
                   remoteImageTasks[url] == nil,
                   !deferredPrefetchURLs.contains(url) {
                    return url
                }
            }
            return nil
        }

        for offset in 1..<photos.count {
            let next = (index + offset) % photos.count
            if let url = photos[next].remoteURL,
               cachedFileURLs[url] == nil,
               remoteImageTasks[url] == nil,
               !deferredPrefetchURLs.contains(url) {
                return url
            }
        }
        return nil
    }

    private func cancelRemoteImageLoads() {
        remoteImageTasks.values.forEach { $0.cancel() }
        remoteImageTasks.removeAll()
        remoteImageCompletions.removeAll()
        remoteImageNeedsDecode.removeAll()
        updateCacheStatus()
    }

    private func updateCacheStatus() {
        guard isViewLoaded else { return }
        cacheStatusLabel.text = "Temp cache \(formatBytes(cachedImageBytes)) / \(cacheSizeMB) MB. Active downloads: \(remoteImageTasks.count). Played files are deleted immediately."
    }

    private var cacheLimitBytes: Int {
        return cacheSizeMB * 1024 * 1024
    }

    private var cachedImageBytes: Int {
        return cachedFileCosts.values.reduce(0, +)
    }

    private func storeCachedFile(at fileURL: URL, for url: URL, cost: Int) {
        guard cost <= cacheLimitBytes,
              cachedImageBytes + cost <= cacheLimitBytes else {
            try? FileManager.default.removeItem(at: fileURL)
            deferredPrefetchURLs.insert(url)
            updateCacheStatus()
            return
        }

        cachedFileURLs[url] = fileURL
        cachedFileCosts[url] = cost
        deferredPrefetchURLs.remove(url)
        updateCacheStatus()
    }

    private func removeCachedImage(for url: URL) {
        imageCache.removeObject(forKey: url as NSURL)
        if let fileURL = cachedFileURLs.removeValue(forKey: url) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        cachedFileCosts.removeValue(forKey: url)
        deferredPrefetchURLs.removeAll()
        updateCacheStatus()
    }

    private func clearImageCache() {
        imageCache.removeAllObjects()
        cachedFileCosts.removeAll()
        cachedFileURLs.removeAll()
        deferredPrefetchURLs.removeAll()
        try? FileManager.default.removeItem(at: temporaryCacheDirectory)
        prepareTemporaryCacheDirectory()
        updateCacheStatus()
    }

    private var temporaryCacheDirectory: URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent("RevivalFrameTempPhotoCache", isDirectory: true)
    }

    private func prepareTemporaryCacheDirectory() {
        try? FileManager.default.createDirectory(at: temporaryCacheDirectory, withIntermediateDirectories: true, attributes: nil)
    }

    private func temporaryCacheFileURL(for url: URL) -> URL {
        let hash = url.absoluteString.unicodeScalars.reduce(UInt64(1469598103934665603)) { result, scalar in
            (result ^ UInt64(scalar.value)) &* UInt64(1099511628211)
        }
        return temporaryCacheDirectory.appendingPathComponent(String(hash, radix: 16)).appendingPathExtension("img")
    }

    private func downsampledImage(at fileURL: URL) -> UIImage? {
        let pixelSize = 2200
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else {
            return nil
        }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(pixelSize)
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1024.0 / 1024.0
        return String(format: "%.1f MB", mb)
    }

    private func resetRandomQueue() {
        randomIndexQueue.removeAll()
        ensureRandomQueue()
    }

    private func ensureRandomQueue() {
        guard playbackOrder == .random, photos.count > 1, randomIndexQueue.isEmpty else { return }
        var indices = Array(photos.indices).filter { $0 != currentIndex }
        for index in stride(from: indices.count - 1, through: 1, by: -1) {
            let swapIndex = Int(arc4random_uniform(UInt32(index + 1)))
            if index != swapIndex {
                indices.swapAt(index, swapIndex)
            }
        }
        randomIndexQueue = indices
    }

    private func displayPlaybackImage(_ image: UIImage, animated: Bool) {
        display(image: image, animated: animated) { [weak self] in
            self?.currentPhotoReadyForTiming = true
            self?.scheduleNextPhotoTimer()
        }
    }

    private func display(image: UIImage, animated: Bool, completion: (() -> Void)? = nil) {
        guard animated else {
            imageView.image = image
            completion?()
            return
        }

        switch transitionMode {
        case .fade, .dissolve:
            let duration: TimeInterval = transitionMode == .dissolve ? 1.1 : 0.65
            UIView.transition(with: imageView, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.imageView.image = image
            } completion: { _ in
                completion?()
            }
        case .slide:
            let nextImageView = overlayImageView(image: image)
            nextImageView.transform = CGAffineTransform(translationX: view.bounds.width * 0.08, y: 0)
            nextImageView.alpha = 0
            UIView.animate(withDuration: 0.7, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: {
                nextImageView.transform = .identity
                nextImageView.alpha = 1
                self.imageView.alpha = 0
            }, completion: { _ in
                self.imageView.image = image
                self.imageView.alpha = 1
                nextImageView.removeFromSuperview()
                completion?()
            })
        case .zoom:
            let nextImageView = overlayImageView(image: image)
            nextImageView.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
            nextImageView.alpha = 0
            UIView.animate(withDuration: 0.8, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: {
                nextImageView.transform = .identity
                nextImageView.alpha = 1
                self.imageView.alpha = 0
            }, completion: { _ in
                self.imageView.image = image
                self.imageView.alpha = 1
                nextImageView.removeFromSuperview()
                completion?()
            })
        }
    }

    private func overlayImageView(image: UIImage) -> UIImageView {
        let nextImageView = UIImageView(frame: imageView.frame)
        nextImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        nextImageView.contentMode = .scaleAspectFit
        nextImageView.backgroundColor = .black
        nextImageView.image = image
        view.insertSubview(nextImageView, aboveSubview: imageView)
        return nextImageView
    }

    private func nextIndex() -> Int {
        guard photos.count > 1 else { return 0 }
        if playbackOrder == .random {
            ensureRandomQueue()
            if randomIndexQueue.isEmpty {
                return currentIndex
            }
            return randomIndexQueue.removeFirst()
        }
        return (currentIndex + 1) % photos.count
    }

    private func updatePlaybackSummary() {
        summaryLabel.text = "\(sourceType.title) | \(transitionMode.title) | \(playbackOrder.title) | \(Int(interval))s"
        intervalValueLabel.text = "\(Int(interval))s"
    }

    private func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        if visible {
            settingsPanel.isHidden = false
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.settingsPanel.alpha = visible ? 1 : 0
        }, completion: { _ in
            self.settingsPanel.isHidden = !visible
        })
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: view)
        if topPanel.frame.contains(point) || bottomPanel.frame.contains(point) {
            return false
        }
        if settingsVisible && settingsPanel.frame.contains(point) {
            return false
        }
        return true
    }

    @objc private func timerAdvanced() {
        currentIndex = nextIndex()
        showPhoto(at: currentIndex, animated: true)
    }

    @objc private func previousPhoto() {
        guard !photos.isEmpty else { return }
        currentIndex = (currentIndex - 1 + photos.count) % photos.count
        showPhoto(at: currentIndex, animated: true)
    }

    @objc private func nextPhoto() {
        guard !photos.isEmpty else { return }
        currentIndex = nextIndex()
        showPhoto(at: currentIndex, animated: true)
    }

    @objc private func shufflePhoto() {
        guard !photos.isEmpty else { return }
        currentIndex = nextIndex()
        showPhoto(at: currentIndex, animated: true)
    }

    @objc private func togglePlayback() {
        isPlaying.toggle()
        playPauseButton.setTitle(isPlaying ? "Pause" : "Play", for: .normal)
        if isPlaying && currentPhotoReadyForTiming {
            scheduleNextPhotoTimer()
        } else {
            timer?.invalidate()
        }
    }

    @objc private func togglePanels() {
        panelsVisible.toggle()
        let alpha: CGFloat = panelsVisible ? 1 : 0
        UIView.animate(withDuration: 0.25) {
            self.topPanel.alpha = alpha
            self.bottomPanel.alpha = alpha
            self.settingsPanel.alpha = self.panelsVisible && self.settingsVisible ? 1 : 0
        }
    }

    @objc private func toggleSettings() {
        view.endEditing(true)
        setSettingsVisible(!settingsVisible)
    }

    @objc private func settingsTabChanged() {
        view.endEditing(true)
        switch settingsTabs.selectedSegmentIndex {
        case 0: showPresetsSettings()
        case 1: showImmichSettings()
        default: showPlaybackSettings()
        }
    }

    @objc private func usePresets() {
        cancelRemoteImageLoads()
        clearImageCache()
        applyPhotos(FramePhoto.presets(), source: .presets, status: "Loaded 4 preset landscape photos.")
    }

    @objc private func loadImmich() {
        view.endEditing(true)
        let link = immichTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.text = "Loading Immich shared album..."
        immichClient.loadSharedAlbum(link) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let album):
                    let photos = album.photoURLs.map { FramePhoto(title: $0.lastPathComponent.isEmpty ? $0.absoluteString : $0.lastPathComponent, image: nil, remoteURL: $0) }
                    self.applyPhotos(photos, source: .immich, status: "Loaded \(photos.count) of \(album.assetCount) Immich photo(s).")
                case .failure(let error):
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    @objc private func transitionChanged() {
        transitionMode = TransitionMode(rawValue: transitionControl.selectedSegmentIndex) ?? .fade
        updatePlaybackSummary()
    }

    @objc private func orderChanged() {
        playbackOrder = PlaybackOrder(rawValue: orderControl.selectedSegmentIndex) ?? .sequential
        cancelRemoteImageLoads()
        clearImageCache()
        resetRandomQueue()
        prefetchUpcomingPhotos(after: currentIndex)
        statusLabel.text = "Display order changed to \(playbackOrder.title). Cache rebuilt for this order."
        updatePlaybackSummary()
    }

    @objc private func intervalChanged() {
        interval = TimeInterval(max(5, Int(intervalSlider.value.rounded())))
        updatePlaybackSummary()
    }

    @objc private func cacheSizeChanged() {
        let index = max(0, min(cacheSizeControl.selectedSegmentIndex, cacheSizeOptionsMB.count - 1))
        cacheSizeMB = cacheSizeOptionsMB[index]
        configureImageCache()
        clearImageCache()
        cancelRemoteImageLoads()
        statusLabel.text = "Image cache set to \(cacheSizeMB) MB."
        showPhoto(at: currentIndex, animated: false)
    }
}

private struct FramePhoto {
    let title: String
    let image: UIImage?
    let remoteURL: URL?

    static func presets() -> [FramePhoto] {
        return [
            FramePhoto(title: "Pacific Coast", image: landscape(title: "Pacific Coast", top: color(12, 45, 84), middle: color(44, 128, 178), bottom: color(240, 156, 92), sun: color(255, 199, 89)), remoteURL: nil),
            FramePhoto(title: "Alpine Morning", image: landscape(title: "Alpine Morning", top: color(122, 178, 224), middle: color(199, 224, 235), bottom: color(143, 178, 140), sun: color(255, 235, 158)), remoteURL: nil),
            FramePhoto(title: "Desert Light", image: landscape(title: "Desert Light", top: color(56, 56, 102), middle: color(204, 110, 97), bottom: color(240, 184, 117), sun: color(255, 179, 97)), remoteURL: nil),
            FramePhoto(title: "Forest Lake", image: landscape(title: "Forest Lake", top: color(15, 46, 46), middle: color(41, 107, 107), bottom: color(26, 82, 71), sun: color(217, 245, 209)), remoteURL: nil)
        ]
    }

    static func placeholder(title: String, subtitle: String) -> UIImage {
        let base = landscape(title: title, top: color(12, 29, 51), middle: color(51, 107, 148), bottom: color(20, 71, 61), sun: color(242, 194, 89))
        UIGraphicsBeginImageContextWithOptions(base.size, true, base.scale)
        base.draw(in: CGRect(origin: .zero, size: base.size))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30, weight: .regular),
            .foregroundColor: UIColor(white: 0.86, alpha: 1)
        ]
        subtitle.draw(in: CGRect(x: 100, y: 980, width: 1400, height: 50), withAttributes: attributes)
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? base
        UIGraphicsEndImageContext()
        return image
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        return UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    private static func landscape(title: String, top: UIColor, middle: UIColor, bottom: UIColor, sun: UIColor) -> UIImage {
        let size = CGSize(width: 1800, height: 1100)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        guard let context = UIGraphicsGetCurrentContext() else { return UIImage() }

        let colors = [top.cgColor, middle.cgColor, bottom.cgColor] as CFArray
        let locations: [CGFloat] = [0, 0.52, 1]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size.height), options: [])
        }

        context.setFillColor(sun.cgColor)
        context.fillEllipse(in: CGRect(x: 1240, y: 150, width: 230, height: 230))

        drawMountain(context, points: [CGPoint(x: -40, y: 850), CGPoint(x: 430, y: 380), CGPoint(x: 900, y: 850)], color: UIColor(white: 0.12, alpha: 1))
        drawMountain(context, points: [CGPoint(x: 520, y: 850), CGPoint(x: 1060, y: 320), CGPoint(x: 1710, y: 850)], color: UIColor(white: 0.08, alpha: 1))
        drawMountain(context, points: [CGPoint(x: 1200, y: 850), CGPoint(x: 1530, y: 530), CGPoint(x: 1860, y: 850)], color: UIColor(white: 0.05, alpha: 1))

        context.setFillColor(UIColor(red: 0.02, green: 0.11, blue: 0.10, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 830, width: size.width, height: 270))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 76, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        title.draw(in: CGRect(x: 96, y: 885, width: 1200, height: 100), withAttributes: attributes)

        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }

    private static func drawMountain(_ context: CGContext, points: [CGPoint], color: UIColor) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        points.dropFirst().forEach { context.addLine(to: $0) }
        context.closePath()
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
}

private struct ImmichAlbum {
    let name: String
    let assetCount: Int
    let photoURLs: [URL]
}

private enum ImmichError: LocalizedError {
    case invalidLink
    case missingAlbum
    case noPhotos
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "Enter a valid Immich shared album link."
        case .missingAlbum: return "This Immich share link does not expose an album."
        case .noPhotos: return "No photos were found in this Immich shared album."
        case .invalidResponse: return "Immich returned an unexpected response."
        }
    }
}

private final class ImmichShareClient {
    private struct SharedLinkResponse: Decodable {
        struct Album: Decodable {
            let id: String
        }
        let album: Album?
    }

    private struct AlbumResponse: Decodable {
        struct Asset: Decodable {
            let id: String
            let type: String
        }
        let albumName: String?
        let assetCount: Int?
        let assets: [Asset]
    }

    func loadSharedAlbum(_ shareLink: String, completion: @escaping (Result<ImmichAlbum, Error>) -> Void) {
        do {
            let parsed = try parseShareLink(shareLink)
            getJSON(parsed.sharedLinkInfoURL) { (sharedResult: Result<SharedLinkResponse, Error>) in
                switch sharedResult {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let sharedInfo):
                    guard let albumId = sharedInfo.album?.id, !albumId.isEmpty else {
                        completion(.failure(ImmichError.missingAlbum))
                        return
                    }
                    self.loadAlbum(parsed: parsed, albumId: albumId, completion: completion)
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func loadAlbum(parsed: ParsedImmichShare, albumId: String, completion: @escaping (Result<ImmichAlbum, Error>) -> Void) {
        getJSON(parsed.albumURL(albumId: albumId)) { (albumResult: Result<AlbumResponse, Error>) in
            switch albumResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let album):
                let photoURLs = album.assets
                    .filter { $0.type == "IMAGE" }
                    .map { parsed.originalURL(assetId: $0.id) }
                guard !photoURLs.isEmpty else {
                    completion(.failure(ImmichError.noPhotos))
                    return
                }
                completion(.success(ImmichAlbum(
                    name: album.albumName ?? "Immich album",
                    assetCount: album.assetCount ?? photoURLs.count,
                    photoURLs: photoURLs
                )))
            }
        }
    }

    private func getJSON<T: Decodable>(_ url: URL, completion: @escaping (Result<T, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                completion(.failure(ImmichError.invalidResponse))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(T.self, from: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func parseShareLink(_ value: String) throws -> ParsedImmichShare {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else {
            throw ImmichError.invalidLink
        }

        let segments = url.pathComponents.filter { $0 != "/" }
        guard let shareIndex = segments.firstIndex(of: "share"),
              segments.indices.contains(shareIndex + 1) else {
            throw ImmichError.invalidLink
        }

        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = components.port
        guard let baseURL = base.url else {
            throw ImmichError.invalidLink
        }

        return ParsedImmichShare(baseURL: baseURL, key: segments[shareIndex + 1])
    }
}

private struct ParsedImmichShare {
    let baseURL: URL
    let key: String

    var sharedLinkInfoURL: URL {
        return url(path: "/api/shared-links/me")
    }

    func albumURL(albumId: String) -> URL {
        return url(path: "/api/albums/\(albumId)")
    }

    func originalURL(assetId: String) -> URL {
        return url(path: "/api/assets/\(assetId)/original")
    }

    private func url(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        return components.url!
    }
}

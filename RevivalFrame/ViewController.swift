import UIKit
import ImageIO

private enum PhotoSourceType {
    case presets
    case immich
    case smb

    var title: String {
        switch self {
        case .presets: return "Presets"
        case .immich: return "Immich"
        case .smb: return "SMB"
        }
    }
}

private enum TransitionMode: Int {
    case fade
    case slide
    case zoom
    case dissolve
    case kenBurns

    static let all: [TransitionMode] = [.fade, .slide, .zoom, .dissolve, .kenBurns]

    var title: String {
        switch self {
        case .fade: return "Fade"
        case .slide: return "Slide"
        case .zoom: return "Zoom"
        case .dissolve: return "Dissolve"
        case .kenBurns: return "Ken Burns"
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

final class ViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate, URLSessionDownloadDelegate {
    private let blurredBackgroundImageView = UIImageView()
    private let blurredBackgroundOverlay = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let imageView = UIImageView()
    private let topPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let bottomPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let playPauseButton = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private let deferredLoadingLabel = UILabel()
    private let settingsPanel = UIVisualEffectView(effect: UIBlurEffect(style: .extraLight))
    private let settingsTabs = UISegmentedControl(items: ["Presets", "Immich", "SMB", "Playback"])
    private let settingsContent = UIView()
    private let statusLabel = UILabel()
    private let immichTextView = UITextView()
    private let immichPasswordField = UITextField()
    private let smbURLField = UITextField()
    private let smbPortField = UITextField()
    private let smbShareNameField = UITextField()
    private let smbUsernameField = UITextField()
    private let smbPasswordField = UITextField()
    private let smbDirectoryTableView = UITableView(frame: .zero, style: .plain)
    private let smbPathLabel = UILabel()
    private let smbConnectButton = UIButton(type: .system)
    private let smbBackButton = UIButton(type: .system)
    private let smbApplyButton = UIButton(type: .system)
    private let intervalSlider = UISlider()
    private let intervalValueLabel = UILabel()
    private let transitionControl = UISegmentedControl(items: TransitionMode.all.map { $0.title })
    private let orderControl = UISegmentedControl(items: [PlaybackOrder.sequential.title, PlaybackOrder.random.title])
    private let cacheSizeControl = UISegmentedControl(items: ["100 MB", "300 MB", "500 MB"])
    private let cacheStatusLabel = UILabel()
    private let downloadRateLabel = UILabel()
    private let imageCache = NSCache<NSURL, UIImage>()
    private let immichClient = ImmichShareClient()

    private let cacheSizeOptionsMB = [100, 300, 500]
    private let maxConcurrentRemoteLoads = 2
    private let prefetchWindowCount = 4
    private let smbLoader = SMBPhotoLoader()
    private var photos: [FramePhoto] = FramePhoto.presets()
    private var currentIndex = 0
    private var requestedIndex = 0
    private var isPlaying = true
    private var timer: Timer?
    private var panelsAutoHideTimer: Timer?
    private var panelsVisible = true
    private var settingsVisible = false
    private var sourceType: PhotoSourceType = .presets
    private var transitionMode: TransitionMode = .fade
    private var playbackOrder: PlaybackOrder = .sequential
    private var interval: TimeInterval = 8
    private var cacheSizeMB = 300
    private var currentImageRequestID = UUID()
    private var currentPhotoReadyForTiming = false
    private var waitingForPreparedPhoto = false
    private var remoteImageTasks: [URL: URLSessionTask] = [:]
    private var remoteImageCompletions: [URL: [(UIImage?) -> Void]] = [:]
    private var remoteImageNeedsDecode: [URL: Bool] = [:]
    private var remoteTaskURLs: [Int: URL] = [:]
    private var cachedFileCosts: [URL: Int] = [:]
    private var cachedFileURLs: [URL: URL] = [:]
    private var deferredPrefetchURLs = Set<URL>()
    private var activeDownloadBytes: [URL: Int64] = [:]
    private var activeDownloadStartTimes: [URL: TimeInterval] = [:]
    private var lastDownloadRateBytesPerSecond: Double = 0
    private var lastDownloadRateUpdate: TimeInterval = 0
    private var downloadRateTimer: Timer?
    private var deferredLoadingTimer: Timer?
    private var deferredLoadingStep = 0
    private var randomIndexQueue: [Int] = []
    private var randomPlaybackHistory: [Int] = []
    private var kenBurnsDirection = CGPoint(x: 1, y: 1)
    private var smbConnection: SMBConnection?
    private var smbCurrentDirectory: SMBDirectory?
    private var selectedSMBDirectories: [String: SMBDirectory] = [:]
    private var smbDirectoryStack: [SMBDirectory] = []
    private var isApplyingSMBFolder = false
    private var activeSMBApplyID = UUID()
    private var smbApplyTimeoutTimer: Timer?
    private var pendingSMBApplyID: UUID?
    private var pendingSMBApplyFirstURL: URL?
    private var settingsPanelLeadingConstraint: NSLayoutConstraint?
    private var settingsPanelTrailingConstraint: NSLayoutConstraint?
    private var settingsPanelWidthConstraint: NSLayoutConstraint?
    private var settingsContentHeightConstraint: NSLayoutConstraint?
    private var smbDirectoryHeightConstraint: NSLayoutConstraint?
    private var immichTextViewHeightConstraint: NSLayoutConstraint?
    private var immichPasswordFieldHeightConstraint: NSLayoutConstraint?
    private var intervalValueWidthConstraint: NSLayoutConstraint?
    private var smbURLFieldHeightConstraint: NSLayoutConstraint?
    private var smbPortFieldHeightConstraint: NSLayoutConstraint?
    private var smbShareNameFieldHeightConstraint: NSLayoutConstraint?
    private var smbPortFieldWidthConstraint: NSLayoutConstraint?
    private var smbUsernameFieldHeightConstraint: NSLayoutConstraint?
    private var smbPasswordFieldHeightConstraint: NSLayoutConstraint?
    private var smbConnectButtonHeightConstraint: NSLayoutConstraint?
    private var smbBackButtonHeightConstraint: NSLayoutConstraint?
    private var smbApplyButtonHeightConstraint: NSLayoutConstraint?

    private lazy var remoteDownloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }()

    private var settingsGroupedBackground: UIColor {
        return UIColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1)
    }

    private var settingsPrimaryText: UIColor {
        return UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    }

    private var settingsSecondaryText: UIColor {
        return UIColor(red: 0.43, green: 0.43, blue: 0.46, alpha: 1)
    }

    private var settingsSeparator: UIColor {
        return UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)
    }

    private var settingsBlue: UIColor {
        return UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)
    }

    private var settingsPlaceholderText: UIColor {
        return UIColor(red: 0.58, green: 0.58, blue: 0.61, alpha: 1)
    }

    private enum Preferences {
        static let sourceType = "sourceType"
        static let immichLink = "immichLink"
        static let smbURL = "smbURL"
        static let smbPort = "smbPort"
        static let smbShareName = "smbShareName"
        static let smbUsername = "smbUsername"
        static let transitionMode = "transitionMode"
        static let playbackOrder = "playbackOrder"
        static let interval = "interval"
        static let cacheSizeMB = "cacheSizeMB"
        static let settingsTab = "settingsTab"
    }

    private enum FeedbackIcon {
        case play
        case pause
        case next
        case previous
    }

    private let panelsAutoHideInterval: TimeInterval = 15

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("RevivalFrame startup: ViewController viewDidLoad begin")
        loadPreferences()
        configureImageCache()
        clearImageCache()
        buildInterface()
        NSLog("RevivalFrame startup: interface built")
        showPhoto(at: 0, animated: false)
        NSLog("RevivalFrame startup: first photo requested")
        updatePlaybackSummary()
        restoreLastSourceIfNeeded()
        NSLog("RevivalFrame startup: ViewController viewDidLoad end")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        panelsAutoHideTimer?.invalidate()
        smbApplyTimeoutTimer?.invalidate()
        downloadRateTimer?.invalidate()
        downloadRateTimer = nil
        stopDeferredLoadingIndicator()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSettingsLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self = self else { return }
            if self.settingsTabs.selectedSegmentIndex == 2 {
                self.showSMBSettings()
            } else {
                self.updateSettingsLayout()
            }
        }
    }

    private func buildInterface() {
        view.backgroundColor = .black

        blurredBackgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        blurredBackgroundImageView.contentMode = .scaleAspectFill
        blurredBackgroundImageView.clipsToBounds = true
        blurredBackgroundImageView.backgroundColor = .black
        view.addSubview(blurredBackgroundImageView)

        blurredBackgroundOverlay.translatesAutoresizingMaskIntoConstraints = false
        blurredBackgroundOverlay.alpha = 0.92
        view.addSubview(blurredBackgroundOverlay)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        view.addSubview(imageView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(togglePanels))
        tap.cancelsTouchesInView = false
        tap.delegate = self

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        tap.require(toFail: doubleTap)

        let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        leftSwipe.direction = .left
        leftSwipe.cancelsTouchesInView = false
        leftSwipe.delegate = self

        let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        rightSwipe.direction = .right
        rightSwipe.cancelsTouchesInView = false
        rightSwipe.delegate = self

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(leftSwipe)
        view.addGestureRecognizer(rightSwipe)

        buildTopPanel()
        buildBottomPanel()
        buildDeferredLoadingLabel()
        buildSettingsPanel()

        NSLayoutConstraint.activate([
            blurredBackgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurredBackgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurredBackgroundImageView.topAnchor.constraint(equalTo: view.topAnchor),
            blurredBackgroundImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            blurredBackgroundOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurredBackgroundOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurredBackgroundOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            blurredBackgroundOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func buildDeferredLoadingLabel() {
        deferredLoadingLabel.translatesAutoresizingMaskIntoConstraints = false
        deferredLoadingLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        deferredLoadingLabel.textColor = UIColor(white: 1, alpha: 0.76)
        deferredLoadingLabel.shadowColor = UIColor(white: 0, alpha: 0.65)
        deferredLoadingLabel.shadowOffset = CGSize(width: 0, height: 1)
        deferredLoadingLabel.text = "Loading..."
        deferredLoadingLabel.alpha = 0
        deferredLoadingLabel.isHidden = true
        view.addSubview(deferredLoadingLabel)

        NSLayoutConstraint.activate([
            deferredLoadingLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            deferredLoadingLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)
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
        forceLightAppearance(settingsPanel)
        forceLightAppearance(settingsPanel.contentView)
        settingsPanel.translatesAutoresizingMaskIntoConstraints = false
        settingsPanel.layer.cornerRadius = 12
        settingsPanel.clipsToBounds = true
        settingsPanel.isHidden = true
        settingsPanel.alpha = 0
        settingsPanel.backgroundColor = settingsGroupedBackground
        settingsPanel.contentView.backgroundColor = settingsGroupedBackground
        view.addSubview(settingsPanel)

        let heading = UILabel()
        heading.text = "Settings"
        heading.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = settingsPrimaryText

        let closeButton = makeSettingsPlainButton(title: "Done", action: #selector(toggleSettings), weight: .semibold)
        let headingRow = UIStackView(arrangedSubviews: [heading, closeButton])
        headingRow.axis = .horizontal
        headingRow.alignment = .center
        headingRow.spacing = 16

        settingsTabs.selectedSegmentIndex = 0
        settingsTabs.addTarget(self, action: #selector(settingsTabChanged), for: .valueChanged)
        configureSettingsSegmentedControl(settingsTabs)

        settingsContent.translatesAutoresizingMaskIntoConstraints = false
        settingsContent.backgroundColor = settingsGroupedBackground
        forceLightAppearance(settingsContent)

        statusLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = settingsSecondaryText
        statusLabel.numberOfLines = 3
        statusLabel.text = "Presets are ready."

        let stack = UIStackView(arrangedSubviews: [headingRow, settingsTabs, settingsContent, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsPanel.contentView.addSubview(stack)

        settingsPanelLeadingConstraint = settingsPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18)
        settingsPanelTrailingConstraint = settingsPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18)
        settingsPanelWidthConstraint = settingsPanel.widthAnchor.constraint(equalToConstant: 430)
        settingsContentHeightConstraint = settingsContent.heightAnchor.constraint(equalToConstant: 335)

        NSLayoutConstraint.activate([
            settingsPanelTrailingConstraint!,
            settingsPanelWidthConstraint!,
            settingsPanel.topAnchor.constraint(equalTo: topPanel.bottomAnchor, constant: 12),
            settingsPanel.bottomAnchor.constraint(lessThanOrEqualTo: bottomPanel.topAnchor, constant: -12),

            stack.leadingAnchor.constraint(equalTo: settingsPanel.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: settingsPanel.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: settingsPanel.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: settingsPanel.contentView.bottomAnchor, constant: -16),
            settingsContentHeightConstraint!
        ])

        settingsTabs.selectedSegmentIndex = UserDefaults.standard.integer(forKey: Preferences.settingsTab)
        showSelectedSettingsTab()
        updateSettingsLayout()
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
        forceLightAppearance(label)
        label.text = text
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = settingsSecondaryText
        label.numberOfLines = 0
        return label
    }

    private func makeSettingsTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        forceLightAppearance(label)
        label.text = text.uppercased()
        label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = settingsSecondaryText
        label.numberOfLines = 1
        return label
    }

    private func makeSettingsGroup(_ arrangedSubviews: [UIView], fillVertically: Bool = true) -> UIView {
        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        forceLightAppearance(container)
        container.backgroundColor = .white
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 0.5
        container.layer.borderColor = settingsSeparator.cgColor
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12)
        ])
        let bottomConstraint = fillVertically
            ? stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
            : stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12)
        bottomConstraint.isActive = true
        return container
    }

    private func verticalSettingsGroups(_ groups: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: groups)
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.distribution = .fill
        return stack
    }

    private func horizontalSettingsGroups(_ groups: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: groups)
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .top
        stack.distribution = .fill
        return stack
    }

    private func makeSettingsPlainButton(title: String, action: Selector, weight: UIFont.Weight = .regular) -> UIButton {
        let button = UIButton(type: .system)
        forceLightAppearance(button)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setTitleColor(settingsBlue, for: .normal)
        button.setTitleColor(UIColor(red: 0, green: 0.48, blue: 1, alpha: 0.35), for: .disabled)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: weight)
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        button.backgroundColor = .clear
        return button
    }

    private func forceLightAppearance(_ view: UIView) {
        if #available(iOS 13.0, *) {
            view.overrideUserInterfaceStyle = .light
        }
    }

    private func configureSettingsSegmentedControl(_ control: UISegmentedControl) {
        forceLightAppearance(control)
        control.tintColor = settingsBlue
        control.backgroundColor = .white
        control.setTitleTextAttributes([
            .foregroundColor: settingsBlue,
            .font: UIFont.systemFont(ofSize: 15, weight: .regular)
        ], for: .normal)
        control.setTitleTextAttributes([
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 15, weight: .regular)
        ], for: .selected)
        if #available(iOS 13.0, *) {
            control.selectedSegmentTintColor = settingsBlue
        }
    }

    private func makeSettingsButton(title: String, action: Selector) -> UIButton {
        return makeSettingsPlainButton(title: title, action: action)
    }

    private func configureSettingsButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.removeTarget(nil, action: nil, for: .touchUpInside)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setTitleColor(settingsBlue, for: .normal)
        button.setTitleColor(UIColor(red: 0, green: 0.48, blue: 1, alpha: 0.35), for: .disabled)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .regular)
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        button.backgroundColor = .clear
        button.layer.cornerRadius = 0
    }

    private func configureSMBTextField(_ field: UITextField, placeholder: String, secure: Bool = false) {
        forceLightAppearance(field)
        field.font = UIFont.systemFont(ofSize: 16)
        field.textColor = settingsPrimaryText
        field.backgroundColor = .white
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: settingsPlaceholderText
        ])
        field.tintColor = settingsBlue
        field.keyboardAppearance = .light
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.textContentType = nil
        field.clearButtonMode = .whileEditing
        field.isSecureTextEntry = secure
        if secure {
            field.keyboardType = .asciiCapable
            field.textContentType = .oneTimeCode
            field.passwordRules = nil
        }
    }

    private func replaceSettingsContent(with content: UIView, fillVertically: Bool = false) {
        settingsContent.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        settingsContent.addSubview(content)
        let bottomConstraint = fillVertically
            ? content.bottomAnchor.constraint(equalTo: settingsContent.bottomAnchor)
            : content.bottomAnchor.constraint(lessThanOrEqualTo: settingsContent.bottomAnchor)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: settingsContent.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: settingsContent.trailingAnchor),
            content.topAnchor.constraint(equalTo: settingsContent.topAnchor),
            bottomConstraint
        ])
    }

    private func showPresetsSettings() {
        let useButton = makeSettingsButton(title: "Use Preset Landscapes", action: #selector(usePresets))
        let stack = UIStackView(arrangedSubviews: [
            makeSettingsTitleLabel("Default source"),
            makeSettingsGroup([
                makeSettingsLabel("Four warm sample photos are available offline and are useful for checking playback, transitions, and full-screen framing."),
                useButton
            ])
        ])
        stack.axis = .vertical
        stack.spacing = 8
        replaceSettingsContent(with: stack)
    }

    private func showImmichSettings() {
        forceLightAppearance(immichTextView)
        immichTextView.delegate = self
        immichTextView.font = UIFont.systemFont(ofSize: 16)
        immichTextView.textColor = settingsPrimaryText
        immichTextView.backgroundColor = .white
        immichTextView.layer.cornerRadius = 6
        immichTextView.layer.borderWidth = 0.5
        immichTextView.layer.borderColor = settingsSeparator.cgColor
        immichTextView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        immichTextView.autocorrectionType = .no
        immichTextView.autocapitalizationType = .none
        immichTextView.keyboardType = .URL
        immichTextView.keyboardAppearance = .light
        immichTextView.tintColor = settingsBlue
        immichTextView.text = UserDefaults.standard.string(forKey: Preferences.immichLink) ?? immichTextView.text
        configureSMBTextField(immichPasswordField, placeholder: "Shared album password", secure: true)

        let loadButton = makeSettingsButton(title: "Load Immich Album", action: #selector(loadImmich))
        let stack = UIStackView(arrangedSubviews: [
            makeSettingsTitleLabel("Shared album link"),
            makeSettingsGroup([
                immichTextView,
                makeSettingsLabel("Password"),
                immichPasswordField,
                makeSettingsLabel("Paste an Immich shared album URL. If the shared link is password protected, enter its password before loading."),
                loadButton
            ])
        ])
        stack.axis = .vertical
        stack.spacing = 8
        if immichTextViewHeightConstraint == nil {
            immichTextViewHeightConstraint = immichTextView.heightAnchor.constraint(equalToConstant: 96)
            immichTextViewHeightConstraint?.isActive = true
        }
        if immichPasswordFieldHeightConstraint == nil {
            immichPasswordFieldHeightConstraint = immichPasswordField.heightAnchor.constraint(equalToConstant: 36)
            immichPasswordFieldHeightConstraint?.isActive = true
        }
        replaceSettingsContent(with: stack)
    }

    private func showSMBSettings() {
        configureSMBTextField(smbURLField, placeholder: "server or smb://server")
        configureSMBTextField(smbPortField, placeholder: "445")
        configureSMBTextField(smbShareNameField, placeholder: "Share Name")
        configureSMBTextField(smbUsernameField, placeholder: "SMB username")
        configureSMBTextField(smbPasswordField, placeholder: "SMB password", secure: true)
        smbURLField.keyboardType = .URL
        smbPortField.keyboardType = .numberPad
        smbURLField.text = UserDefaults.standard.string(forKey: Preferences.smbURL) ?? smbURLField.text
        smbPortField.text = UserDefaults.standard.string(forKey: Preferences.smbPort) ?? "445"
        smbShareNameField.text = UserDefaults.standard.string(forKey: Preferences.smbShareName) ?? smbShareNameField.text
        smbUsernameField.text = UserDefaults.standard.string(forKey: Preferences.smbUsername) ?? smbUsernameField.text
        populateSMBFieldsFromStoredURLIfNeeded()

        configureSettingsButton(smbConnectButton, title: "Connect", action: #selector(connectSMB))
        configureSettingsButton(smbBackButton, title: "Back", action: #selector(backSMBDirectory))
        configureSettingsButton(smbApplyButton, title: "Load", action: #selector(applySelectedSMBFolder))
        updateSMBActionButtons()

        smbPathLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        smbPathLabel.textColor = settingsSecondaryText
        smbPathLabel.numberOfLines = 2
        updateSMBPathLabel()

        forceLightAppearance(smbDirectoryTableView)
        smbDirectoryTableView.dataSource = self
        smbDirectoryTableView.delegate = self
        smbDirectoryTableView.backgroundColor = .white
        smbDirectoryTableView.separatorColor = settingsSeparator
        smbDirectoryTableView.layer.cornerRadius = 6
        smbDirectoryTableView.layer.borderWidth = 0.5
        smbDirectoryTableView.layer.borderColor = settingsSeparator.cgColor
        smbDirectoryTableView.clipsToBounds = true
        smbDirectoryTableView.tableFooterView = UIView()

        let smbURLLabel = makeSettingsLabel("SMB URL")
        smbURLLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let smbURLRow = UIStackView(arrangedSubviews: [smbURLLabel, smbURLField])
        smbURLRow.axis = .horizontal
        smbURLRow.alignment = .center
        smbURLRow.spacing = 8
        smbURLRow.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let portLabel = makeSettingsLabel("Port")
        portLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        if smbPortFieldWidthConstraint == nil {
            smbPortFieldWidthConstraint = smbPortField.widthAnchor.constraint(equalToConstant: 84)
            smbPortFieldWidthConstraint?.isActive = true
        }
        let portPair = UIStackView(arrangedSubviews: [portLabel, smbPortField])
        portPair.axis = .horizontal
        portPair.alignment = .center
        portPair.spacing = 6

        let shareNameLabel = makeSettingsLabel("Share Name")
        shareNameLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        let shareNamePair = UIStackView(arrangedSubviews: [shareNameLabel, smbShareNameField])
        shareNamePair.axis = .horizontal
        shareNamePair.alignment = .center
        shareNamePair.spacing = 6

        let serverDetailsRow = UIStackView(arrangedSubviews: [portPair, shareNamePair])
        serverDetailsRow.axis = .horizontal
        serverDetailsRow.alignment = .center
        serverDetailsRow.spacing = 10
        serverDetailsRow.distribution = .fill
        serverDetailsRow.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let credentialsRow = UIStackView(arrangedSubviews: [smbUsernameField, smbPasswordField])
        credentialsRow.axis = .horizontal
        credentialsRow.spacing = 8
        credentialsRow.distribution = .fillEqually

        let buttonRow = UIStackView(arrangedSubviews: [smbConnectButton, smbBackButton, smbApplyButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        if smbConnectButtonHeightConstraint == nil {
            smbConnectButtonHeightConstraint = smbConnectButton.heightAnchor.constraint(equalToConstant: 34)
            smbBackButtonHeightConstraint = smbBackButton.heightAnchor.constraint(equalToConstant: 34)
            smbApplyButtonHeightConstraint = smbApplyButton.heightAnchor.constraint(equalToConstant: 34)
            smbConnectButtonHeightConstraint?.isActive = true
            smbBackButtonHeightConstraint?.isActive = true
            smbApplyButtonHeightConstraint?.isActive = true
        }

        let connected = smbConnection != nil
        let landscape = view.bounds.width > view.bounds.height

        let formGroup = makeSettingsGroup([
            smbURLRow,
            serverDetailsRow,
            makeSettingsLabel("Credentials"),
            credentialsRow,
            buttonRow
        ], fillVertically: !(landscape && connected))

        let directoryGroup = makeSettingsGroup([
            makeSMBDirectoryHeaderRow(),
            smbPathLabel,
            smbDirectoryTableView
        ])

        let smbContent: UIView
        if landscape && connected {
            let horizontalGroups = horizontalSettingsGroups([directoryGroup, formGroup])
            formGroup.widthAnchor.constraint(equalToConstant: 360).isActive = true
            smbContent = horizontalGroups
        } else {
            smbContent = verticalSettingsGroups([formGroup, directoryGroup])
        }
        let stack = UIStackView(arrangedSubviews: [
            makeSettingsTitleLabel("SMB source"),
            smbContent
        ])
        stack.axis = .vertical
        stack.spacing = 8

        if !(landscape && connected) {
            stack.alignment = .fill
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        if smbURLFieldHeightConstraint == nil {
            smbURLFieldHeightConstraint = smbURLField.heightAnchor.constraint(equalToConstant: 36)
            smbPortFieldHeightConstraint = smbPortField.heightAnchor.constraint(equalToConstant: 36)
            smbShareNameFieldHeightConstraint = smbShareNameField.heightAnchor.constraint(equalToConstant: 36)
            smbUsernameFieldHeightConstraint = smbUsernameField.heightAnchor.constraint(equalToConstant: 36)
            smbPasswordFieldHeightConstraint = smbPasswordField.heightAnchor.constraint(equalToConstant: 36)
            smbURLFieldHeightConstraint?.isActive = true
            smbPortFieldHeightConstraint?.isActive = true
            smbShareNameFieldHeightConstraint?.isActive = true
            smbUsernameFieldHeightConstraint?.isActive = true
            smbPasswordFieldHeightConstraint?.isActive = true
        }
        smbDirectoryHeightConstraint?.isActive = false
        smbDirectoryHeightConstraint = smbDirectoryTableView.heightAnchor.constraint(equalToConstant: connected ? (landscape ? 280 : 260) : 80)
        smbDirectoryHeightConstraint?.isActive = true

        let scrollView = UIScrollView()
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        replaceSettingsContent(with: scrollView, fillVertically: true)
        smbDirectoryTableView.reloadData()
        updateSettingsLayout()
    }

    private func populateSMBFieldsFromStoredURLIfNeeded() {
        guard let rawServer = smbURLField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawServer.isEmpty else {
            return
        }

        let candidate = rawServer.lowercased().hasPrefix("smb://") ? rawServer : "smb://\(rawServer)"
        guard let components = URLComponents(string: candidate),
              let host = components.host,
              !host.isEmpty else {
            return
        }

        smbURLField.text = host
        if let port = components.port,
           UserDefaults.standard.object(forKey: Preferences.smbPort) == nil {
            smbPortField.text = "\(port)"
        }

        let share = components.path.split(separator: "/").map(String.init).first ?? ""
        if !share.isEmpty,
           (smbShareNameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            smbShareNameField.text = share
        }
    }

    private func makeSMBDirectoryHeaderRow() -> UIStackView {
        let title = makeSettingsLabel("Connected folders")
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let selectAllButton = makeSettingsPlainButton(title: "Select All", action: #selector(selectAllVisibleSMBDirectories))
        let excludeAllButton = makeSettingsPlainButton(title: "Exclude All", action: #selector(excludeAllVisibleSMBDirectories))
        selectAllButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        excludeAllButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        let hasVisibleFolders = (smbCurrentDirectory?.children.isEmpty == false) && !isApplyingSMBFolder
        selectAllButton.isEnabled = hasVisibleFolders
        excludeAllButton.isEnabled = hasVisibleFolders

        let row = UIStackView(arrangedSubviews: [title, selectAllButton, excludeAllButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func showPlaybackSettings() {
        transitionControl.selectedSegmentIndex = transitionMode.rawValue
        transitionControl.removeTarget(nil, action: nil, for: .valueChanged)
        transitionControl.addTarget(self, action: #selector(transitionChanged), for: .valueChanged)
        configureSettingsSegmentedControl(transitionControl)

        orderControl.selectedSegmentIndex = playbackOrder.rawValue
        orderControl.removeTarget(nil, action: nil, for: .valueChanged)
        orderControl.addTarget(self, action: #selector(orderChanged), for: .valueChanged)
        configureSettingsSegmentedControl(orderControl)

        intervalSlider.minimumValue = 5
        intervalSlider.maximumValue = 60
        intervalSlider.value = Float(interval)
        intervalSlider.removeTarget(nil, action: nil, for: .valueChanged)
        intervalSlider.addTarget(self, action: #selector(intervalChanged), for: .valueChanged)
        intervalSlider.tintColor = settingsBlue

        intervalValueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        intervalValueLabel.textColor = settingsPrimaryText
        intervalValueLabel.text = "\(Int(interval))s"

        let intervalRow = UIStackView(arrangedSubviews: [intervalSlider, intervalValueLabel])
        intervalRow.axis = .horizontal
        intervalRow.alignment = .center
        intervalRow.spacing = 10
        if intervalValueWidthConstraint == nil {
            intervalValueWidthConstraint = intervalValueLabel.widthAnchor.constraint(equalToConstant: 44)
            intervalValueWidthConstraint?.isActive = true
        }

        cacheSizeControl.selectedSegmentIndex = cacheSizeOptionsMB.firstIndex(of: cacheSizeMB) ?? 1
        cacheSizeControl.removeTarget(nil, action: nil, for: .valueChanged)
        cacheSizeControl.addTarget(self, action: #selector(cacheSizeChanged), for: .valueChanged)
        configureSettingsSegmentedControl(cacheSizeControl)

        cacheStatusLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        cacheStatusLabel.textColor = settingsSecondaryText
        cacheStatusLabel.numberOfLines = 2
        updateCacheStatus()

        downloadRateLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        downloadRateLabel.textColor = settingsSecondaryText
        downloadRateLabel.numberOfLines = 1
        updateDownloadRateLabel()

        let stack = UIStackView(arrangedSubviews: [
            makeSettingsTitleLabel("Playback"),
            makeSettingsGroup([
                makeSettingsLabel("Transition"),
                transitionControl,
                makeSettingsLabel("Display order"),
                orderControl,
                makeSettingsLabel("Photo duration"),
                intervalRow,
                makeSettingsLabel("Cache size"),
                cacheSizeControl,
                cacheStatusLabel,
                downloadRateLabel
            ])
        ])
        stack.axis = .vertical
        stack.spacing = 8
        replaceSettingsContent(with: stack)
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Preferences.transitionMode) != nil {
            transitionMode = TransitionMode(rawValue: defaults.integer(forKey: Preferences.transitionMode)) ?? transitionMode
        }
        if defaults.object(forKey: Preferences.playbackOrder) != nil {
            playbackOrder = PlaybackOrder(rawValue: defaults.integer(forKey: Preferences.playbackOrder)) ?? playbackOrder
        }
        if defaults.object(forKey: Preferences.interval) != nil {
            interval = TimeInterval(max(5, defaults.integer(forKey: Preferences.interval)))
        }
        if defaults.object(forKey: Preferences.cacheSizeMB) != nil {
            let savedCacheSize = defaults.integer(forKey: Preferences.cacheSizeMB)
            if cacheSizeOptionsMB.contains(savedCacheSize) {
                cacheSizeMB = savedCacheSize
            }
        }
        if let savedSource = defaults.string(forKey: Preferences.sourceType) {
            if savedSource == PhotoSourceType.immich.title {
                sourceType = .immich
            } else if savedSource == PhotoSourceType.smb.title {
                sourceType = .smb
            }
        }
    }

    private func savePlaybackPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(transitionMode.rawValue, forKey: Preferences.transitionMode)
        defaults.set(playbackOrder.rawValue, forKey: Preferences.playbackOrder)
        defaults.set(Int(interval), forKey: Preferences.interval)
        defaults.set(cacheSizeMB, forKey: Preferences.cacheSizeMB)
    }

    private func saveSourcePreference(_ source: PhotoSourceType) {
        UserDefaults.standard.set(source.title, forKey: Preferences.sourceType)
    }

    private func restoreLastSourceIfNeeded() {
        guard sourceType == .immich,
              let link = UserDefaults.standard.string(forKey: Preferences.immichLink),
              !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        immichTextView.text = link
        loadImmichFromStoredLink(link, password: "", automatic: true)
    }

    private func showSelectedSettingsTab() {
        switch settingsTabs.selectedSegmentIndex {
        case 0: showPresetsSettings()
        case 1: showImmichSettings()
        case 2: showSMBSettings()
        default: showPlaybackSettings()
        }
        updateSettingsLayout()
    }

    private func updateSettingsLayout() {
        guard isViewLoaded else { return }
        let smbTabActive = settingsTabs.selectedSegmentIndex == 2
        let connectedSMB = smbConnection != nil
        let landscape = view.bounds.width > view.bounds.height
        let expandedLandscapeSMB = smbTabActive && connectedSMB && landscape

        settingsPanelLeadingConstraint?.isActive = expandedLandscapeSMB
        settingsPanelWidthConstraint?.isActive = !expandedLandscapeSMB
        settingsPanelTrailingConstraint?.isActive = true

        if smbTabActive && connectedSMB {
            settingsContentHeightConstraint?.constant = landscape ? 335 : min(560, max(420, view.bounds.height - 430))
            smbDirectoryHeightConstraint?.constant = landscape ? 280 : min(380, max(240, (settingsContentHeightConstraint?.constant ?? 420) - 170))
        } else {
            settingsContentHeightConstraint?.constant = 335
            smbDirectoryHeightConstraint?.constant = 80
        }
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
        requestedIndex = 0
        resetRandomQueue()
        statusLabel.text = status
        showPhoto(at: 0, animated: true)
        updatePlaybackSummary()
    }

    private func showPhoto(at index: Int, animated: Bool, allowLoadingPlaceholder: Bool = true, updateDetailImmediately: Bool = false) {
        guard photos.indices.contains(index) else { return }
        timer?.invalidate()
        currentPhotoReadyForTiming = false
        let photo = photos[index]
        if allowLoadingPlaceholder || updateDetailImmediately {
            stopDeferredLoadingIndicator()
        }
        if updateDetailImmediately {
            requestedIndex = index
            updateDetailLabel(for: index)
        }
        currentImageRequestID = UUID()
        let requestID = currentImageRequestID

        if let image = photo.image {
            currentIndex = index
            requestedIndex = index
            waitingForPreparedPhoto = false
            stopDeferredLoadingIndicator()
            updateDetailLabel(for: index)
            displayPlaybackImage(image, animated: animated)
            prefetchUpcomingPhotos(after: index)
            return
        }

        if let imageName = photo.imageName, let image = UIImage(named: imageName) {
            currentIndex = index
            requestedIndex = index
            waitingForPreparedPhoto = false
            stopDeferredLoadingIndicator()
            updateDetailLabel(for: index)
            displayPlaybackImage(image, animated: animated)
            prefetchUpcomingPhotos(after: index)
            return
        }

        guard let remoteURL = photo.remoteURL else {
            currentIndex = index
            requestedIndex = index
            waitingForPreparedPhoto = false
            stopDeferredLoadingIndicator()
            updateDetailLabel(for: index)
            displayPlaybackImage(FramePhoto.placeholder(title: "Photo unavailable", subtitle: photo.title), animated: animated)
            prefetchUpcomingPhotos(after: index)
            return
        }
        let smbApplyIDForPhoto = pendingSMBApplyFirstURL == remoteURL ? pendingSMBApplyID : nil

        if let cached = imageCache.object(forKey: remoteURL as NSURL) {
            currentIndex = index
            requestedIndex = index
            waitingForPreparedPhoto = false
            stopDeferredLoadingIndicator()
            updateDetailLabel(for: index)
            displayPlaybackImage(cached, animated: animated) { [weak self] in
                self?.finishSMBApplyIfNeeded(for: remoteURL, applyID: smbApplyIDForPhoto)
            }
            cleanupCacheAroundCurrentIndex()
            prefetchUpcomingPhotos(after: index)
            return
        }

        if cachedFileURLs[remoteURL] == nil && allowLoadingPlaceholder {
            display(image: FramePhoto.placeholder(title: "Loading photo", subtitle: photo.title), animated: animated)
        } else if cachedFileURLs[remoteURL] == nil {
            waitingForPreparedPhoto = true
            statusLabel.text = "Preparing next photo: \(photo.title)"
            startDeferredLoadingIndicator()
        }
        loadRemoteImage(remoteURL) { [weak self] image in
            guard let self = self else { return }
            guard self.currentImageRequestID == requestID else { return }
            guard let image = image else {
                self.waitingForPreparedPhoto = false
                self.stopDeferredLoadingIndicator()
                if allowLoadingPlaceholder {
                    self.currentIndex = index
                    self.requestedIndex = index
                    self.updateDetailLabel(for: index)
                    self.displayPlaybackImage(FramePhoto.placeholder(title: "Photo unavailable", subtitle: photo.title), animated: true) { [weak self] in
                        self?.finishSMBApplyIfNeeded(for: remoteURL, applyID: smbApplyIDForPhoto)
                    }
                } else {
                    self.statusLabel.text = "Skipping unavailable photo: \(photo.title)"
                    self.skipUnavailablePhoto(after: index)
                }
                return
            }

            self.currentIndex = index
            self.requestedIndex = index
            self.waitingForPreparedPhoto = false
            self.stopDeferredLoadingIndicator()
            self.updateDetailLabel(for: index)
            self.displayPlaybackImage(image, animated: true) { [weak self] in
                self?.finishSMBApplyIfNeeded(for: remoteURL, applyID: smbApplyIDForPhoto)
            }
            self.cleanupCacheAroundCurrentIndex()
            self.prefetchUpcomingPhotos(after: index)
        }
        prefetchUpcomingPhotos(after: index)
    }

    private func updateDetailLabel(for index: Int) {
        guard photos.indices.contains(index) else { return }
        let photo = photos[index]
        detailLabel.text = "\(sourceType.title) | \(index + 1) of \(photos.count) | \(photo.title)"
    }

    private func startDeferredLoadingIndicator() {
        guard isPlaying else { return }
        deferredLoadingStep = 0
        updateDeferredLoadingText()
        deferredLoadingLabel.isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.deferredLoadingLabel.alpha = 1
        }
        guard deferredLoadingTimer == nil else { return }
        deferredLoadingTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.deferredLoadingStep = (self.deferredLoadingStep + 1) % 4
            self.updateDeferredLoadingText()
        }
    }

    private func stopDeferredLoadingIndicator() {
        deferredLoadingTimer?.invalidate()
        deferredLoadingTimer = nil
        guard !deferredLoadingLabel.isHidden || deferredLoadingLabel.alpha > 0 else { return }
        UIView.animate(withDuration: 0.15, animations: {
            self.deferredLoadingLabel.alpha = 0
        }, completion: { _ in
            self.deferredLoadingLabel.isHidden = true
        })
    }

    private func updateDeferredLoadingText() {
        let dots = String(repeating: ".", count: deferredLoadingStep)
        deferredLoadingLabel.text = "Loading\(dots)"
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

        if url.scheme?.lowercased() == "smb" {
            loadSMBImage(url, shouldDecode: shouldDecode, completion: completion)
            return
        }

        if remoteImageCompletions[url] != nil {
            remoteImageCompletions[url]?.append(completion)
            remoteImageNeedsDecode[url] = (remoteImageNeedsDecode[url] ?? false) || shouldDecode
            return
        }

        remoteImageCompletions[url] = [completion]
        remoteImageNeedsDecode[url] = shouldDecode
        beginDownloadTracking(for: url)
        let task = remoteDownloadSession.downloadTask(with: url)
        remoteTaskURLs[task.taskIdentifier] = url
        remoteImageTasks[url] = task
        task.resume()
        updateCacheStatus()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = remoteTaskURLs[downloadTask.taskIdentifier] else { return }
        recordDownloadProgress(for: url, totalBytesWritten: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let url = remoteTaskURLs[downloadTask.taskIdentifier] else { return }
        var storedFileURL: URL?
        var cost = 1
        if let http = downloadTask.response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            let fileURL = temporaryCacheFileURL(for: url)
            do {
                try? FileManager.default.removeItem(at: fileURL)
                try FileManager.default.moveItem(at: location, to: fileURL)
                cost = max(1, ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue) ?? 1)
                storedFileURL = fileURL
            } catch {
                NSLog("RevivalFrame HTTP cache move failed for %@: %@", url.absoluteString, error.localizedDescription)
                storedFileURL = nil
            }
        }
        finishRemoteDownload(for: url, taskIdentifier: downloadTask.taskIdentifier, storedFileURL: storedFileURL, cost: cost)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            guard let url = remoteTaskURLs[task.taskIdentifier] else { return }
            finishRemoteDownload(for: url, taskIdentifier: task.taskIdentifier, storedFileURL: nil, cost: 1)
        }
    }

    private func finishRemoteDownload(for url: URL, taskIdentifier: Int, storedFileURL: URL?, cost: Int) {
        remoteTaskURLs.removeValue(forKey: taskIdentifier)
        finishDownloadTracking(for: url, finalBytes: cost)

        let loadedImage: UIImage? = nil
        if let fileURL = storedFileURL {
            if remoteImageNeedsDecode[url] == true {
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = self.downsampledImage(at: fileURL)
                    DispatchQueue.main.async {
                        self.storeCachedFile(at: fileURL, for: url, cost: cost)
                        if let image = image {
                            self.imageCache.setObject(image, forKey: url as NSURL)
                        } else {
                            self.statusLabel.text = "Unable to decode photo: \(url.lastPathComponent)"
                            NSLog("RevivalFrame HTTP decode failed for %@", url.absoluteString)
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

        let completions = remoteImageCompletions.removeValue(forKey: url) ?? []
        remoteImageNeedsDecode.removeValue(forKey: url)
        remoteImageTasks.removeValue(forKey: url)
        updateCacheStatus()
        completions.forEach { $0(loadedImage) }
        prefetchUpcomingPhotos(after: currentIndex)
    }

    private func loadSMBImage(_ url: URL, shouldDecode: Bool, completion: @escaping (UIImage?) -> Void) {
        guard let connection = smbConnection else {
            completion(nil)
            return
        }

        if remoteImageCompletions[url] != nil {
            remoteImageCompletions[url]?.append(completion)
            remoteImageNeedsDecode[url] = (remoteImageNeedsDecode[url] ?? false) || shouldDecode
            return
        }

        remoteImageCompletions[url] = [completion]
        remoteImageNeedsDecode[url] = shouldDecode
        let requestedFileURL = temporaryCacheFileURL(for: url)
        let smbPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        beginDownloadTracking(for: url)
        smbLoader.downloadFile(at: smbPath, connection: connection, destination: requestedFileURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let downloadedFileURL):
                    let cost = max(1, ((try? FileManager.default.attributesOfItem(atPath: downloadedFileURL.path)[.size] as? NSNumber)?.intValue) ?? 1)
                    self.finishDownloadTracking(for: url, finalBytes: cost)
                    if self.remoteImageNeedsDecode[url] == true {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let image = self.downsampledImage(at: downloadedFileURL)
                            DispatchQueue.main.async {
                                if let image = image {
                                    self.imageCache.setObject(image, forKey: url as NSURL)
                                } else {
                                    self.statusLabel.text = "Unable to decode SMB photo: \(url.lastPathComponent)"
                                    NSLog("RevivalFrame SMB decode failed for %@", url.path)
                                }
                                self.storeCachedFile(at: downloadedFileURL, for: url, cost: cost)
                                let completions = self.remoteImageCompletions.removeValue(forKey: url) ?? []
                                self.remoteImageNeedsDecode.removeValue(forKey: url)
                                self.updateCacheStatus()
                                completions.forEach { $0(image) }
                                self.prefetchUpcomingPhotos(after: self.currentIndex)
                            }
                        }
                        return
                    }
                    self.storeCachedFile(at: downloadedFileURL, for: url, cost: cost)
                    let completions = self.remoteImageCompletions.removeValue(forKey: url) ?? []
                    self.remoteImageNeedsDecode.removeValue(forKey: url)
                    self.updateCacheStatus()
                    completions.forEach { $0(nil) }
                    self.prefetchUpcomingPhotos(after: self.currentIndex)
                case .failure(let error):
                    self.finishDownloadTracking(for: url, finalBytes: 0)
                    self.statusLabel.text = "Unable to load SMB photo: \(url.lastPathComponent)"
                    NSLog("RevivalFrame SMB download failed for %@: %@", url.path, error.localizedDescription)
                    let completions = self.remoteImageCompletions.removeValue(forKey: url) ?? []
                    self.remoteImageNeedsDecode.removeValue(forKey: url)
                    self.updateCacheStatus()
                    completions.forEach { $0(nil) }
                }
            }
        }
        updateCacheStatus()
    }

    private func prefetchUpcomingPhotos(after index: Int) {
        guard photos.count > 1, cachedImageBytes < cacheLimitBytes else {
            updateCacheStatus()
            return
        }

        while cachedImageBytes < cacheLimitBytes && remoteImageCompletions.count < maxConcurrentRemoteLoads {
            guard let url = nextPrefetchURL(after: index, windowCount: prefetchWindowCount) else { break }
            loadRemoteImage(url, shouldDecode: false) { _ in }
        }
        updateCacheStatus()
    }

    private func nextPrefetchURL(after index: Int, windowCount: Int) -> URL? {
        guard photos.count > 1 else { return nil }
        if playbackOrder == .random {
            ensureRandomQueue()
            for next in randomIndexQueue.prefix(windowCount) {
                if let url = photos[next].remoteURL,
                   cachedFileURLs[url] == nil,
                   remoteImageTasks[url] == nil,
                   remoteImageCompletions[url] == nil,
                   !deferredPrefetchURLs.contains(url) {
                    return url
                }
            }
            return nil
        }

        for offset in 1...min(windowCount, photos.count - 1) {
            let next = (index + offset) % photos.count
            if let url = photos[next].remoteURL,
               cachedFileURLs[url] == nil,
               remoteImageTasks[url] == nil,
               remoteImageCompletions[url] == nil,
               !deferredPrefetchURLs.contains(url) {
                return url
            }
        }
        return nil
    }

    private func cancelRemoteImageLoads() {
        waitingForPreparedPhoto = false
        stopDeferredLoadingIndicator()
        remoteImageTasks.values.forEach { $0.cancel() }
        remoteImageTasks.removeAll()
        remoteImageCompletions.removeAll()
        remoteImageNeedsDecode.removeAll()
        remoteTaskURLs.removeAll()
        activeDownloadBytes.removeAll()
        activeDownloadStartTimes.removeAll()
        lastDownloadRateBytesPerSecond = 0
        lastDownloadRateUpdate = 0
        stopDownloadRateTimerIfIdle()
        updateCacheStatus()
        updateDownloadRateLabel()
    }

    private func updateCacheStatus() {
        guard isViewLoaded else { return }
        cacheStatusLabel.text = "Temp cache \(formatBytes(cachedImageBytes)) / \(cacheSizeMB) MB. Active downloads: \(remoteImageCompletions.count). Protected window: \(prefetchWindowCount + 2) photos."
        updateDownloadRateLabel()
    }

    private func beginDownloadTracking(for url: URL) {
        activeDownloadBytes[url] = 0
        activeDownloadStartTimes[url] = CFAbsoluteTimeGetCurrent()
        startDownloadRateTimerIfNeeded()
        updateDownloadRateLabel()
    }

    private func recordDownloadProgress(for url: URL, totalBytesWritten: Int64) {
        activeDownloadBytes[url] = max(0, totalBytesWritten)
        updateCurrentDownloadRate()
        updateDownloadRateLabel()
    }

    private func finishDownloadTracking(for url: URL, finalBytes: Int) {
        if let start = activeDownloadStartTimes[url] {
            let elapsed = max(0.1, CFAbsoluteTimeGetCurrent() - start)
            lastDownloadRateBytesPerSecond = Double(max(0, finalBytes)) / elapsed
            lastDownloadRateUpdate = CFAbsoluteTimeGetCurrent()
        }
        activeDownloadBytes.removeValue(forKey: url)
        activeDownloadStartTimes.removeValue(forKey: url)
        stopDownloadRateTimerIfIdle()
        updateDownloadRateLabel()
    }

    private func updateCurrentDownloadRate() {
        let now = CFAbsoluteTimeGetCurrent()
        var totalRate = 0.0
        for (url, bytes) in activeDownloadBytes {
            guard let start = activeDownloadStartTimes[url] else { continue }
            let elapsed = max(0.1, now - start)
            totalRate += Double(bytes) / elapsed
        }
        if totalRate > 0 {
            lastDownloadRateBytesPerSecond = totalRate
            lastDownloadRateUpdate = now
        }
    }

    private func updateDownloadRateLabel() {
        guard isViewLoaded else { return }
        updateCurrentDownloadRate()
        if !activeDownloadBytes.isEmpty {
            downloadRateLabel.text = "Download rate \(formatRate(lastDownloadRateBytesPerSecond)) now."
        } else if lastDownloadRateUpdate > 0, CFAbsoluteTimeGetCurrent() - lastDownloadRateUpdate < 10 {
            downloadRateLabel.text = "Download rate \(formatRate(lastDownloadRateBytesPerSecond)) last."
        } else {
            downloadRateLabel.text = "Download rate idle."
        }
    }

    private func startDownloadRateTimerIfNeeded() {
        guard downloadRateTimer == nil else { return }
        downloadRateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateDownloadRateLabel()
        }
    }

    private func stopDownloadRateTimerIfIdle() {
        guard activeDownloadBytes.isEmpty else { return }
        downloadRateTimer?.invalidate()
        downloadRateTimer = nil
    }

    private var cacheLimitBytes: Int {
        return cacheSizeMB * 1024 * 1024
    }

    private var cachedImageBytes: Int {
        return cachedFileCosts.values.reduce(0, +)
    }

    private func storeCachedFile(at fileURL: URL, for url: URL, cost: Int) {
        cleanupCacheAroundCurrentIndex(extraProtectedURL: url)
        guard cost <= cacheLimitBytes else {
            try? FileManager.default.removeItem(at: fileURL)
            deferredPrefetchURLs.insert(url)
            updateCacheStatus()
            return
        }
        if cachedImageBytes + cost > cacheLimitBytes {
            evictCacheFiles(keeping: protectedRemoteURLs(extra: [url]), targetFreeBytes: cost)
        }
        guard cachedImageBytes + cost <= cacheLimitBytes else {
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

    private func cleanupCacheAroundCurrentIndex(extraProtectedURL: URL? = nil) {
        evictCacheFiles(keeping: protectedRemoteURLs(extra: extraProtectedURL.map { [$0] } ?? []), targetFreeBytes: 0)
        updateCacheStatus()
    }

    private func protectedRemoteURLs(extra: [URL] = []) -> Set<URL> {
        var protected = Set(extra)
        guard !photos.isEmpty else { return protected }

        let previous = (currentIndex - 1 + photos.count) % photos.count
        [previous, currentIndex].forEach { index in
            if photos.indices.contains(index), let url = photos[index].remoteURL {
                protected.insert(url)
            }
        }

        if playbackOrder == .random {
            ensureRandomQueue()
            for index in randomIndexQueue.prefix(prefetchWindowCount) {
                if photos.indices.contains(index), let url = photos[index].remoteURL {
                    protected.insert(url)
                }
            }
        } else if photos.count > 1 {
            for offset in 1...min(prefetchWindowCount, photos.count - 1) {
                let index = (currentIndex + offset) % photos.count
                if let url = photos[index].remoteURL {
                    protected.insert(url)
                }
            }
        }
        return protected
    }

    private func evictCacheFiles(keeping protected: Set<URL>, targetFreeBytes: Int) {
        guard !cachedFileURLs.isEmpty else { return }
        let targetLimit = max(0, cacheLimitBytes - targetFreeBytes)
        for url in Array(cachedFileURLs.keys) where cachedImageBytes > targetLimit && !protected.contains(url) {
            removeCachedImage(for: url)
        }
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

    private func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1024.0 / 1024.0)
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024.0)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    private func resetRandomQueue() {
        randomIndexQueue.removeAll()
        randomPlaybackHistory.removeAll()
        ensureRandomQueue()
    }

    private func ensureRandomQueue(excluding excludedIndex: Int? = nil) {
        guard playbackOrder == .random, photos.count > 1, randomIndexQueue.isEmpty else { return }
        let excludedIndex = excludedIndex ?? currentIndex
        var indices = Array(photos.indices).filter { $0 != excludedIndex }
        for index in stride(from: indices.count - 1, through: 1, by: -1) {
            let swapIndex = Int(arc4random_uniform(UInt32(index + 1)))
            if index != swapIndex {
                indices.swapAt(index, swapIndex)
            }
        }
        randomIndexQueue = indices
    }

    private func displayPlaybackImage(_ image: UIImage, animated: Bool, completion: (() -> Void)? = nil) {
        display(image: image, animated: animated) { [weak self] in
            guard let self = self else { return }
            self.recordDisplayedIndex(self.currentIndex)
            self.currentPhotoReadyForTiming = true
            self.scheduleNextPhotoTimer()
            self.schedulePanelsAutoHide(reset: false)
            completion?()
        }
    }

    private func recordDisplayedIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        if playbackOrder == .random {
            if randomPlaybackHistory.last != index {
                randomPlaybackHistory.append(index)
            }
            if randomPlaybackHistory.count > 200 {
                randomPlaybackHistory.removeFirst(randomPlaybackHistory.count - 200)
            }
        } else {
            randomPlaybackHistory.removeAll()
        }
    }

    private func display(image: UIImage, animated: Bool, completion: (() -> Void)? = nil) {
        imageView.layer.removeAllAnimations()
        blurredBackgroundImageView.layer.removeAllAnimations()
        imageView.transform = .identity
        imageView.contentMode = transitionMode == .kenBurns ? .scaleAspectFill : .scaleAspectFit

        guard animated else {
            updateBlurredBackground(with: image, animated: false)
            imageView.image = image
            if transitionMode == .kenBurns {
                startKenBurnsAnimation()
            }
            completion?()
            return
        }

        updateBlurredBackground(with: image, animated: true)
        switch transitionMode {
        case .fade, .kenBurns:
            UIView.transition(with: imageView, duration: 1.5, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.imageView.image = image
            } completion: { _ in
                if self.transitionMode == .kenBurns {
                    self.startKenBurnsAnimation()
                }
                completion?()
            }
        case .dissolve:
            UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: {
                self.imageView.alpha = 0
            }, completion: { _ in
                self.imageView.image = image
                UIView.animate(withDuration: 1.2, delay: 0.15, options: [.curveEaseInOut, .allowUserInteraction], animations: {
                    self.imageView.alpha = 1
                }, completion: { _ in
                    completion?()
                })
            })
        case .slide:
            let nextImageView = overlayImageView(image: image)
            nextImageView.transform = randomSlideTransform()
            nextImageView.alpha = 0
            UIView.animate(withDuration: 1.6, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: {
                nextImageView.transform = .identity
                nextImageView.alpha = 1
                self.imageView.alpha = 0
            }, completion: { _ in
                self.imageView.image = image
                self.imageView.alpha = 1
                self.imageView.transform = .identity
                self.imageView.contentMode = .scaleAspectFit
                nextImageView.removeFromSuperview()
                completion?()
            })
        case .zoom:
            let nextImageView = overlayImageView(image: image)
            nextImageView.transform = CGAffineTransform(scaleX: 1.16, y: 1.16)
            nextImageView.alpha = 0
            UIView.animate(withDuration: 1.7, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: {
                nextImageView.transform = .identity
                nextImageView.alpha = 1
                self.imageView.alpha = 0
            }, completion: { _ in
                self.imageView.image = image
                self.imageView.alpha = 1
                self.imageView.transform = .identity
                self.imageView.contentMode = .scaleAspectFit
                nextImageView.removeFromSuperview()
                completion?()
            })
        }
    }

    private func updateBlurredBackground(with image: UIImage, animated: Bool) {
        blurredBackgroundImageView.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
        guard animated else {
            blurredBackgroundImageView.image = image
            return
        }
        UIView.transition(with: blurredBackgroundImageView, duration: 1.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.blurredBackgroundImageView.image = image
        }
    }

    private func startKenBurnsAnimation() {
        imageView.layer.removeAllAnimations()
        imageView.contentMode = .scaleAspectFill
        imageView.transform = kenBurnsStartTransform()
        UIView.animate(withDuration: max(interval * 1.6, interval + 6), delay: 0, options: [.curveLinear, .allowUserInteraction], animations: {
            self.imageView.transform = self.kenBurnsEndTransform()
        }, completion: nil)
    }

    private func kenBurnsStartTransform() -> CGAffineTransform {
        let direction = Int(arc4random_uniform(4))
        switch direction {
        case 0:
            kenBurnsDirection = CGPoint(x: -1, y: -1)
        case 1:
            kenBurnsDirection = CGPoint(x: 1, y: -1)
        case 2:
            kenBurnsDirection = CGPoint(x: -1, y: 1)
        default:
            kenBurnsDirection = CGPoint(x: 1, y: 1)
        }
        return .identity
    }

    private func kenBurnsEndTransform() -> CGAffineTransform {
        let translateX = view.bounds.width * 0.02
        let translateY = view.bounds.height * 0.02
        return CGAffineTransform(translationX: kenBurnsDirection.x * translateX, y: kenBurnsDirection.y * translateY).scaledBy(x: 1.08, y: 1.08)
    }

    private func randomSlideTransform() -> CGAffineTransform {
        let horizontalDistance = view.bounds.width * 0.14
        let verticalDistance = view.bounds.height * 0.14
        let directions: [CGPoint] = [
            CGPoint(x: 1, y: 0),
            CGPoint(x: -1, y: 0),
            CGPoint(x: 0, y: 1),
            CGPoint(x: 0, y: -1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: -1, y: 1),
            CGPoint(x: 1, y: -1),
            CGPoint(x: -1, y: -1)
        ]
        let direction = directions.randomElement() ?? CGPoint(x: 1, y: 0)
        return CGAffineTransform(translationX: direction.x * horizontalDistance, y: direction.y * verticalDistance)
    }

    private func overlayImageView(image: UIImage) -> UIImageView {
        let nextImageView = UIImageView(frame: imageView.frame)
        nextImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        nextImageView.contentMode = .scaleAspectFit
        nextImageView.backgroundColor = .clear
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

    private func nextRandomRequestedIndex() -> Int {
        guard photos.count > 1 else { return 0 }
        ensureRandomQueue(excluding: requestedIndex)
        if randomIndexQueue.isEmpty {
            return requestedIndex
        }
        return randomIndexQueue.removeFirst()
    }

    private func sequentialNextIndex(from index: Int) -> Int {
        guard photos.count > 1 else { return 0 }
        return (index + 1) % photos.count
    }

    private func sequentialPreviousIndex(from index: Int) -> Int {
        guard photos.count > 1 else { return 0 }
        return (index - 1 + photos.count) % photos.count
    }

    private func showManuallyRequestedPhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        if playbackOrder == .random {
            recordDisplayedIndex(index)
        }
        showPhoto(at: index, animated: true, allowLoadingPlaceholder: true, updateDetailImmediately: true)
    }

    private func skipUnavailablePhoto(after failedIndex: Int) {
        guard isPlaying, photos.count > 1 else {
            currentPhotoReadyForTiming = true
            scheduleNextPhotoTimer()
            return
        }
        let fallbackIndex: Int
        if playbackOrder == .random {
            fallbackIndex = nextIndex()
        } else {
            fallbackIndex = (failedIndex + 1) % photos.count
        }
        guard fallbackIndex != currentIndex else {
            currentPhotoReadyForTiming = true
            scheduleNextPhotoTimer()
            return
        }
        showPhoto(at: fallbackIndex, animated: true, allowLoadingPlaceholder: false)
    }

    private func updatePlaybackSummary() {
        summaryLabel.text = "\(sourceType.title) | \(transitionMode.title) | \(playbackOrder.title) | \(Int(interval))s"
        intervalValueLabel.text = "\(Int(interval))s"
    }

    private func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        if visible {
            panelsAutoHideTimer?.invalidate()
            panelsAutoHideTimer = nil
        } else {
            schedulePanelsAutoHide(reset: true)
        }
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
        showPhoto(at: nextIndex(), animated: true, allowLoadingPlaceholder: false)
    }

    @objc private func previousPhoto() {
        guard !photos.isEmpty else { return }
        if playbackOrder == .random, randomPlaybackHistory.count >= 2 {
            let targetIndex = randomPlaybackHistory[randomPlaybackHistory.count - 2]
            randomPlaybackHistory.removeLast()
            showPhoto(at: targetIndex, animated: true, allowLoadingPlaceholder: true, updateDetailImmediately: true)
            return
        }
        showManuallyRequestedPhoto(at: sequentialPreviousIndex(from: requestedIndex))
    }

    @objc private func nextPhoto() {
        guard !photos.isEmpty else { return }
        if playbackOrder == .random {
            showManuallyRequestedPhoto(at: nextRandomRequestedIndex())
        } else {
            showManuallyRequestedPhoto(at: sequentialNextIndex(from: requestedIndex))
        }
    }

    @objc private func shufflePhoto() {
        guard !photos.isEmpty else { return }
        if playbackOrder == .random {
            showManuallyRequestedPhoto(at: nextRandomRequestedIndex())
        } else {
            showManuallyRequestedPhoto(at: sequentialNextIndex(from: requestedIndex))
        }
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left:
            nextPhoto()
            showFeedbackIcon(.next, position: CGPoint(x: view.bounds.width * 0.76, y: view.bounds.midY))
        case .right:
            previousPhoto()
            showFeedbackIcon(.previous, position: CGPoint(x: view.bounds.width * 0.24, y: view.bounds.midY))
        default:
            break
        }
    }

    @objc private func handleDoubleTap() {
        togglePlayback()
        showFeedbackIcon(isPlaying ? .play : .pause, position: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    @objc private func togglePlayback() {
        isPlaying.toggle()
        playPauseButton.setTitle(isPlaying ? "Pause" : "Play", for: .normal)
        if isPlaying && currentPhotoReadyForTiming {
            scheduleNextPhotoTimer()
            schedulePanelsAutoHide(reset: true)
            if waitingForPreparedPhoto {
                startDeferredLoadingIndicator()
            }
        } else {
            timer?.invalidate()
            panelsAutoHideTimer?.invalidate()
            panelsAutoHideTimer = nil
            stopDeferredLoadingIndicator()
        }
    }

    @objc private func togglePanels() {
        setPanelsVisible(!panelsVisible, animated: true, rescheduleAutoHide: true)
    }

    private func setPanelsVisible(_ visible: Bool, animated: Bool, rescheduleAutoHide: Bool = false) {
        panelsVisible = visible
        let alpha: CGFloat = visible ? 1 : 0
        let changes = {
            self.topPanel.alpha = alpha
            self.bottomPanel.alpha = alpha
            self.settingsPanel.alpha = self.panelsVisible && self.settingsVisible ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: changes)
        } else {
            changes()
        }

        if visible && rescheduleAutoHide {
            schedulePanelsAutoHide(reset: true)
        } else if !visible {
            panelsAutoHideTimer?.invalidate()
            panelsAutoHideTimer = nil
        }
    }

    private func schedulePanelsAutoHide(reset: Bool) {
        if reset {
            panelsAutoHideTimer?.invalidate()
            panelsAutoHideTimer = nil
        } else if panelsAutoHideTimer != nil {
            return
        }
        guard isPlaying, panelsVisible, !settingsVisible, currentPhotoReadyForTiming else { return }
        panelsAutoHideTimer = Timer.scheduledTimer(withTimeInterval: panelsAutoHideInterval, repeats: false) { [weak self] _ in
            guard let self = self,
                  self.isPlaying,
                  self.panelsVisible,
                  !self.settingsVisible else { return }
            self.setPanelsVisible(false, animated: true)
        }
    }

    private func showFeedbackIcon(_ icon: FeedbackIcon, position: CGPoint) {
        let size: CGFloat = 118
        let container = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        container.center = position
        container.isUserInteractionEnabled = false
        container.backgroundColor = UIColor(white: 0, alpha: 0.34)
        container.layer.cornerRadius = size / 2
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.35
        container.layer.shadowRadius = 18
        container.layer.shadowOffset = CGSize(width: 0, height: 6)

        let imageView = UIImageView(image: feedbackIconImage(icon))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 58),
            imageView.heightAnchor.constraint(equalToConstant: 58)
        ])

        container.alpha = 0
        container.transform = CGAffineTransform(scaleX: 0.56, y: 0.56)
        view.addSubview(container)
        view.bringSubviewToFront(container)

        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
            container.alpha = 1
            container.transform = CGAffineTransform(scaleX: 1.0, y: 1.0)
        }, completion: { _ in
            UIView.animate(withDuration: 0.34, delay: 0.08, options: [.curveEaseIn, .allowUserInteraction], animations: {
                container.alpha = 0
                container.transform = CGAffineTransform(scaleX: 1.36, y: 1.36)
            }, completion: { _ in
                container.removeFromSuperview()
            })
        })
    }

    private func feedbackIconImage(_ icon: FeedbackIcon) -> UIImage {
        let size = CGSize(width: 72, height: 72)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        UIColor.white.setFill()

        switch icon {
        case .play:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 25, y: 18))
            path.addLine(to: CGPoint(x: 25, y: 54))
            path.addLine(to: CGPoint(x: 54, y: 36))
            path.close()
            path.fill()
        case .pause:
            UIBezierPath(roundedRect: CGRect(x: 22, y: 18, width: 9, height: 36), cornerRadius: 2).fill()
            UIBezierPath(roundedRect: CGRect(x: 41, y: 18, width: 9, height: 36), cornerRadius: 2).fill()
        case .next:
            drawSkipIcon(flipped: false)
        case .previous:
            drawSkipIcon(flipped: true)
        }

        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }

    private func drawSkipIcon(flipped: Bool) {
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        if flipped {
            context?.translateBy(x: 72, y: 0)
            context?.scaleBy(x: -1, y: 1)
        }

        let first = UIBezierPath()
        first.move(to: CGPoint(x: 16, y: 18))
        first.addLine(to: CGPoint(x: 16, y: 54))
        first.addLine(to: CGPoint(x: 38, y: 36))
        first.close()
        first.fill()

        let second = UIBezierPath()
        second.move(to: CGPoint(x: 34, y: 18))
        second.addLine(to: CGPoint(x: 34, y: 54))
        second.addLine(to: CGPoint(x: 56, y: 36))
        second.close()
        second.fill()

        UIBezierPath(roundedRect: CGRect(x: 58, y: 18, width: 5, height: 36), cornerRadius: 1.5).fill()
        context?.restoreGState()
    }

    @objc private func toggleSettings() {
        view.endEditing(true)
        setSettingsVisible(!settingsVisible)
    }

    @objc private func settingsTabChanged() {
        view.endEditing(true)
        UserDefaults.standard.set(settingsTabs.selectedSegmentIndex, forKey: Preferences.settingsTab)
        showSelectedSettingsTab()
    }

    @objc private func usePresets() {
        disconnectSMB()
        cancelRemoteImageLoads()
        clearImageCache()
        saveSourcePreference(.presets)
        applyPhotos(FramePhoto.presets(), source: .presets, status: "Loaded 4 preset landscape photos.")
    }

    @objc private func loadImmich() {
        view.endEditing(true)
        disconnectSMB()
        let link = immichTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = immichPasswordField.text ?? ""
        UserDefaults.standard.set(link, forKey: Preferences.immichLink)
        saveSourcePreference(.immich)
        loadImmichFromStoredLink(link, password: password, automatic: false)
    }

    private func loadImmichFromStoredLink(_ link: String, password: String, automatic: Bool) {
        statusLabel.text = "Loading Immich shared album..."
        immichClient.loadSharedAlbum(link, password: password) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let album):
                    let photos = album.photoURLs.map { FramePhoto(title: $0.lastPathComponent.isEmpty ? $0.absoluteString : $0.lastPathComponent, image: nil, remoteURL: $0) }
                    let prefix = automatic ? "Restored" : "Loaded"
                    self.applyPhotos(photos, source: .immich, status: "\(prefix) \(photos.count) of \(album.assetCount) Immich photo(s).")
                case .failure(let error):
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    @objc private func connectSMB() {
        view.endEditing(true)
        guard !isApplyingSMBFolder else { return }

        guard let smbInput = makeSMBConnectionInput() else {
            updateSMBActionButtons()
            return
        }

        let username = (smbUsernameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = smbPasswordField.text ?? ""
        if !username.isEmpty && password.isEmpty {
            statusLabel.text = "Enter the SMB password for this username."
            updateSMBActionButtons()
            return
        }

        cancelRemoteImageLoads()
        clearImageCache()
        disconnectSMB()

        UserDefaults.standard.set(smbInput.server, forKey: Preferences.smbURL)
        UserDefaults.standard.set(smbInput.port, forKey: Preferences.smbPort)
        UserDefaults.standard.set(smbInput.shareName, forKey: Preferences.smbShareName)
        UserDefaults.standard.set(username, forKey: Preferences.smbUsername)
        saveSourcePreference(.smb)
        statusLabel.text = "Connecting SMB..."
        smbConnectButton.isEnabled = false
        smbApplyButton.isEnabled = false

        smbLoader.connect(to: smbInput.urlString, username: username, password: password) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let connection):
                    self.sourceType = .smb
                    self.smbConnection = connection
                    self.smbDirectoryStack = [connection.rootDirectory]
                    self.smbCurrentDirectory = connection.rootDirectory
                    self.selectedSMBDirectories.removeAll()
                    if self.settingsTabs.selectedSegmentIndex == 2 {
                        self.showSMBSettings()
                    } else {
                        self.smbDirectoryTableView.reloadData()
                        self.updateSMBPathLabel()
                    }
                    self.statusLabel.text = "Connected SMB. Tap folders to select; tap Open to browse."
                    self.updatePlaybackSummary()
                    self.updateSMBActionButtons()
                case .failure(let error):
                    self.smbCurrentDirectory = nil
                    self.selectedSMBDirectories.removeAll()
                    self.smbDirectoryStack.removeAll()
                    self.smbDirectoryTableView.reloadData()
                    self.updateSMBPathLabel()
                    self.updateSettingsLayout()
                    self.statusLabel.text = error.localizedDescription
                    self.updateSMBActionButtons()
                }
            }
        }
    }

    private struct SMBConnectionInput {
        let urlString: String
        let server: String
        let port: String
        let shareName: String
    }

    private func makeSMBConnectionInput() -> SMBConnectionInput? {
        let rawServer = (smbURLField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawServer.isEmpty else {
            statusLabel.text = "Enter an SMB server address."
            return nil
        }

        let serverCandidate = rawServer.lowercased().hasPrefix("smb://") ? rawServer : "smb://\(rawServer)"
        guard let components = URLComponents(string: serverCandidate),
              let host = components.host,
              !host.isEmpty else {
            statusLabel.text = "Enter a valid SMB server address."
            return nil
        }

        let portText = (smbPortField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !portText.isEmpty else {
            statusLabel.text = "Enter an SMB port, usually 445."
            return nil
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            statusLabel.text = "Enter a valid SMB port from 1 to 65535."
            return nil
        }

        let existingPathParts = components.path
            .split(separator: "/")
            .map(String.init)
        let enteredShare = (smbShareNameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shareName = enteredShare.isEmpty ? (existingPathParts.first ?? "") : enteredShare
        guard !shareName.isEmpty else {
            statusLabel.text = "Enter an SMB Share Name."
            return nil
        }

        let subpath = enteredShare.isEmpty ? existingPathParts.dropFirst().joined(separator: "/") : ""
        var output = URLComponents()
        output.scheme = "smb"
        output.host = host
        output.port = port
        output.path = subpath.isEmpty ? "/\(shareName)" : "/\(shareName)/\(subpath)"
        guard let urlString = output.url?.absoluteString else {
            statusLabel.text = "Enter a valid SMB server, port, and Share Name."
            return nil
        }

        smbURLField.text = host
        smbPortField.text = "\(port)"
        smbShareNameField.text = shareName
        return SMBConnectionInput(urlString: urlString, server: host, port: "\(port)", shareName: shareName)
    }

    @objc private func backSMBDirectory() {
        guard !isApplyingSMBFolder else { return }
        guard smbDirectoryStack.count > 1 else { return }
        smbDirectoryStack.removeLast()
        smbCurrentDirectory = smbDirectoryStack.last
        smbDirectoryTableView.reloadData()
        updateSMBPathLabel()
    }

    @objc private func applySelectedSMBFolder() {
        guard !isApplyingSMBFolder else { return }
        guard let connection = smbConnection,
              let currentDirectory = smbCurrentDirectory else {
            statusLabel.text = "Connect SMB and select a folder first."
            return
        }
        let directories = selectedSMBDirectories.values.sorted {
            $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
        }
        let directoriesToLoad = directories.isEmpty ? [currentDirectory] : directories
        let applyID = UUID()
        activeSMBApplyID = applyID
        isApplyingSMBFolder = true
        updateSMBActionButtons()
        startSMBApplyTimeout(for: applyID)
        cancelRemoteImageLoads()
        clearImageCache()
        statusLabel.text = directoriesToLoad.count == 1 ? "Loading SMB photos..." : "Loading SMB photos from \(directoriesToLoad.count) folders..."
        smbLoader.loadPhotos(in: directoriesToLoad, connection: connection) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.activeSMBApplyID == applyID else { return }
                switch result {
                case .success(let photos):
                    self.pendingSMBApplyID = applyID
                    self.pendingSMBApplyFirstURL = photos.first?.remoteURL
                    let sourceName = directoriesToLoad.count == 1 ? directoriesToLoad[0].name : "\(directoriesToLoad.count) folders"
                    self.applyPhotos(photos, source: .smb, status: "Loaded \(photos.count) SMB photo(s) from \(sourceName).")
                case .failure(let error):
                    self.finishSMBApply()
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }

    private func disconnectSMB() {
        activeSMBApplyID = UUID()
        pendingSMBApplyID = nil
        pendingSMBApplyFirstURL = nil
        finishSMBApply()
        if let connection = smbConnection {
            smbLoader.disconnect(connection)
        }
        smbConnection = nil
        smbCurrentDirectory = nil
        selectedSMBDirectories.removeAll()
        smbDirectoryStack.removeAll()
        smbDirectoryTableView.reloadData()
        updateSMBPathLabel()
        updateSMBActionButtons()
    }

    private func updateSMBPathLabel() {
        guard isViewLoaded else { return }
        if let directory = smbCurrentDirectory {
            let selectedCount = selectedSMBDirectories.count
            if selectedCount > 0 {
                smbPathLabel.text = "\(directory.displayPath)\n\(selectedCount) folder(s) selected."
            } else {
                smbPathLabel.text = "\(directory.displayPath)\nTap folders to select; tap Open to browse."
            }
        } else {
            smbPathLabel.text = "Not connected."
        }
        updateSMBActionButtons()
    }

    private func updateSMBActionButtons() {
        guard isViewLoaded else { return }
        smbConnectButton.isEnabled = !isApplyingSMBFolder
        smbBackButton.isEnabled = smbDirectoryStack.count > 1 && !isApplyingSMBFolder
        smbApplyButton.isEnabled = smbCurrentDirectory != nil && !isApplyingSMBFolder
        smbDirectoryTableView.allowsSelection = !isApplyingSMBFolder
    }

    private func startSMBApplyTimeout(for applyID: UUID) {
        smbApplyTimeoutTimer?.invalidate()
        smbApplyTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard self.isApplyingSMBFolder, self.activeSMBApplyID == applyID else { return }
            self.activeSMBApplyID = UUID()
            self.cancelRemoteImageLoads()
            self.finishSMBApply()
            self.statusLabel.text = "SMB loading timed out. Please try Load again."
        }
    }

    private func finishSMBApply() {
        smbApplyTimeoutTimer?.invalidate()
        smbApplyTimeoutTimer = nil
        pendingSMBApplyID = nil
        pendingSMBApplyFirstURL = nil
        isApplyingSMBFolder = false
        updateSMBActionButtons()
    }

    private func finishSMBApplyIfNeeded(for url: URL, applyID: UUID?) {
        guard isApplyingSMBFolder,
              let applyID = applyID,
              pendingSMBApplyID == applyID,
              pendingSMBApplyFirstURL == url else { return }
        finishSMBApply()
    }

    @objc private func transitionChanged() {
        transitionMode = TransitionMode(rawValue: transitionControl.selectedSegmentIndex) ?? .fade
        savePlaybackPreferences()
        updatePlaybackSummary()
    }

    @objc private func orderChanged() {
        playbackOrder = PlaybackOrder(rawValue: orderControl.selectedSegmentIndex) ?? .sequential
        savePlaybackPreferences()
        cancelRemoteImageLoads()
        clearImageCache()
        resetRandomQueue()
        prefetchUpcomingPhotos(after: currentIndex)
        statusLabel.text = "Display order changed to \(playbackOrder.title). Cache rebuilt for this order."
        updatePlaybackSummary()
    }

    @objc private func intervalChanged() {
        interval = TimeInterval(max(5, Int(intervalSlider.value.rounded())))
        savePlaybackPreferences()
        updatePlaybackSummary()
    }

    @objc private func cacheSizeChanged() {
        let index = max(0, min(cacheSizeControl.selectedSegmentIndex, cacheSizeOptionsMB.count - 1))
        cacheSizeMB = cacheSizeOptionsMB[index]
        configureImageCache()
        clearImageCache()
        cancelRemoteImageLoads()
        savePlaybackPreferences()
        statusLabel.text = "Image cache set to \(cacheSizeMB) MB."
        showPhoto(at: currentIndex, animated: false)
    }

    @objc private func selectAllVisibleSMBDirectories() {
        guard !isApplyingSMBFolder,
              let children = smbCurrentDirectory?.children,
              !children.isEmpty else { return }
        children.forEach { selectedSMBDirectories[$0.path] = $0 }
        smbDirectoryTableView.reloadData()
        updateSMBPathLabel()
        statusLabel.text = "\(selectedSMBDirectories.count) SMB folder(s) selected."
    }

    @objc private func excludeAllVisibleSMBDirectories() {
        guard !isApplyingSMBFolder,
              let children = smbCurrentDirectory?.children,
              !children.isEmpty else { return }
        children.forEach { selectedSMBDirectories.removeValue(forKey: $0.path) }
        smbDirectoryTableView.reloadData()
        updateSMBPathLabel()
        statusLabel.text = selectedSMBDirectories.isEmpty ? "No folders selected. Load will use the current folder." : "\(selectedSMBDirectories.count) SMB folder(s) selected."
    }

    private func smbSelectionIndicatorImage(selected: Bool) -> UIImage {
        let size = CGSize(width: 18, height: 18)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        guard let context = UIGraphicsGetCurrentContext() else {
            return UIImage()
        }
        context.setLineWidth(1.6)
        if selected {
            context.setFillColor(settingsBlue.cgColor)
            context.fillEllipse(in: rect)
        } else {
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.72).cgColor)
            context.strokeEllipse(in: rect)
        }
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard tableView == smbDirectoryTableView else { return 0 }
        return smbCurrentDirectory?.children.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "SMBDirectoryCell"
        let cell = (tableView.dequeueReusableCell(withIdentifier: identifier) as? SMBDirectoryCell) ?? SMBDirectoryCell(reuseIdentifier: identifier)
        if let child = smbCurrentDirectory?.children[indexPath.row] {
            let selected = selectedSMBDirectories[child.path] != nil
            cell.configure(
                name: child.name,
                path: child.displayPath,
                selectedImage: smbSelectionIndicatorImage(selected: selected),
                row: indexPath.row,
                target: self,
                toggleAction: #selector(toggleSMBDirectorySelectionFromButton(_:)),
                enabled: !isApplyingSMBFolder
            )
            cell.selectionStyle = .default
        } else {
            cell.configure(
                name: "",
                path: "",
                selectedImage: UIImage(),
                row: indexPath.row,
                target: self,
                toggleAction: #selector(toggleSMBDirectorySelectionFromButton(_:)),
                enabled: false
            )
            cell.selectionStyle = .none
        }
        cell.accessoryType = .disclosureIndicator
        forceLightAppearance(cell)
        forceLightAppearance(cell.contentView)
        cell.backgroundColor = .white
        cell.contentView.backgroundColor = .white
        cell.applyTextColors(primary: settingsPrimaryText, secondary: settingsSecondaryText)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isApplyingSMBFolder else { return }
        guard tableView == smbDirectoryTableView,
              let child = smbCurrentDirectory?.children[indexPath.row] else {
            return
        }
        openSMBDirectory(child)
    }

    @objc private func toggleSMBDirectorySelectionFromButton(_ sender: UIButton) {
        guard !isApplyingSMBFolder else { return }
        toggleSMBDirectorySelection(at: sender.tag)
    }

    private func toggleSMBDirectorySelection(at row: Int) {
        guard let children = smbCurrentDirectory?.children,
              children.indices.contains(row) else {
            return
        }
        let child = children[row]
        if selectedSMBDirectories[child.path] == nil {
            selectedSMBDirectories[child.path] = child
        } else {
            selectedSMBDirectories.removeValue(forKey: child.path)
        }
        smbDirectoryTableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
        updateSMBPathLabel()
        statusLabel.text = selectedSMBDirectories.isEmpty ? "No folders selected. Load will use the current folder." : "\(selectedSMBDirectories.count) SMB folder(s) selected."
    }

    @objc private func openSMBDirectoryFromAccessory(_ sender: UIButton) {
        guard !isApplyingSMBFolder else { return }
        let row = sender.tag
        guard let children = smbCurrentDirectory?.children,
              children.indices.contains(row) else {
            return
        }
        openSMBDirectory(children[row])
    }

    private func openSMBDirectory(_ child: SMBDirectory) {
        guard let connection = smbConnection else { return }
        statusLabel.text = "Loading SMB folder..."
        smbLoader.loadDirectory(path: child.path, displayPath: child.displayPath, connection: connection) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let loadedDirectory):
                    self.smbDirectoryStack.append(loadedDirectory)
                    self.smbCurrentDirectory = loadedDirectory
                    self.smbDirectoryTableView.reloadData()
                    self.updateSMBPathLabel()
                    self.statusLabel.text = "Tap a folder to browse. Tap the circle to select it."
                case .failure(let error):
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
    }
}

private final class SMBDirectoryCell: UITableViewCell {
    private let selectButton = UIButton(type: .custom)
    private let nameLabel = UILabel()
    private let pathLabel = UILabel()
    private let labelsStack = UIStackView()

    init(reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        buildInterface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildInterface()
    }

    private func buildInterface() {
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.contentMode = .center
        contentView.addSubview(selectButton)

        nameLabel.font = UIFont.systemFont(ofSize: 17, weight: .regular)
        nameLabel.numberOfLines = 1
        pathLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        pathLabel.numberOfLines = 1

        labelsStack.axis = .vertical
        labelsStack.spacing = 2
        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.addArrangedSubview(nameLabel)
        labelsStack.addArrangedSubview(pathLabel)
        contentView.addSubview(labelsStack)

        NSLayoutConstraint.activate([
            selectButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            selectButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            selectButton.widthAnchor.constraint(equalToConstant: 32),
            selectButton.heightAnchor.constraint(equalToConstant: 44),

            labelsStack.leadingAnchor.constraint(equalTo: selectButton.trailingAnchor, constant: 6),
            labelsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            labelsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            labelsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    func configure(name: String, path: String, selectedImage: UIImage, row: Int, target: Any, toggleAction: Selector, enabled: Bool) {
        nameLabel.text = name
        pathLabel.text = path
        selectButton.setImage(selectedImage, for: .normal)
        selectButton.tag = row
        selectButton.isEnabled = enabled
        selectButton.removeTarget(nil, action: nil, for: .touchUpInside)
        selectButton.addTarget(target, action: toggleAction, for: .touchUpInside)
        contentView.alpha = enabled ? 1 : 0.5
    }

    func applyTextColors(primary: UIColor, secondary: UIColor) {
        nameLabel.textColor = primary
        pathLabel.textColor = secondary
    }
}

private struct FramePhoto {
    let title: String
    let image: UIImage?
    let remoteURL: URL?
    let imageName: String?

    init(title: String, image: UIImage?, remoteURL: URL?, imageName: String? = nil) {
        self.title = title
        self.image = image
        self.remoteURL = remoteURL
        self.imageName = imageName
    }

    static func presets() -> [FramePhoto] {
        return [
            FramePhoto(title: "Lake Memory", image: nil, remoteURL: nil, imageName: "PresetLakeDock"),
            FramePhoto(title: "Lakeshore Walk", image: nil, remoteURL: nil, imageName: "PresetLakeshoreWalk"),
            FramePhoto(title: "Golden Pier", image: nil, remoteURL: nil, imageName: "PresetGoldenPier"),
            FramePhoto(title: "Home Frame", image: nil, remoteURL: nil, imageName: "PresetHomeFrame")
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

private struct SMBConnection {
    let displayName: String
    let client: SMB2ClientWrapper
    let rootDirectory: SMBDirectory
}

private struct SMBDirectory {
    let name: String
    let displayPath: String
    let path: String
    let children: [SMBDirectory]
}

private enum SMBError: LocalizedError {
    case invalidURL
    case noPhotos(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid SMB server, port, and Share Name."
        case .noPhotos(let folder):
            return "No supported photo files were found in \(folder)."
        }
    }
}

private final class SMBPhotoLoader {
    private let supportedExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp"])
    private let queue = DispatchQueue(label: "com.revivalframe.smb")

    func connect(to rawURL: String, username: String, password: String, completion: @escaping (Result<SMBConnection, Error>) -> Void) {
        do {
            _ = try parseSMBURL(rawURL)
        } catch {
            completion(.failure(error))
            return
        }

        queue.async {
            do {
                let client = try SMB2ClientWrapper(urlString: rawURL, username: username, password: password)
                let root = try self.loadDirectorySync(path: client.rootPath, displayPath: client.displayName, client: client)
                completion(.success(SMBConnection(displayName: client.displayName, client: client, rootDirectory: root)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func disconnect(_ connection: SMBConnection) {
        queue.async {
            connection.client.disconnect()
        }
    }

    func loadDirectory(path: String, displayPath: String, connection: SMBConnection, completion: @escaping (Result<SMBDirectory, Error>) -> Void) {
        queue.async {
            do {
                completion(.success(try self.loadDirectorySync(path: path, displayPath: displayPath, client: connection.client)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func loadPhotos(in directory: SMBDirectory, connection: SMBConnection, completion: @escaping (Result<[FramePhoto], Error>) -> Void) {
        loadPhotos(in: [directory], connection: connection, completion: completion)
    }

    func loadPhotos(in directories: [SMBDirectory], connection: SMBConnection, completion: @escaping (Result<[FramePhoto], Error>) -> Void) {
        queue.async {
            do {
                let photos = try directories.flatMap { directory in
                    try self.photoURLsRecursively(in: directory, client: connection.client)
                }
                    .map { FramePhoto(title: $0.lastPathComponent, image: nil, remoteURL: $0) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                guard !photos.isEmpty else {
                    let displayPath = directories.count == 1 ? directories[0].displayPath : "\(directories.count) selected folders"
                    throw SMBError.noPhotos(displayPath)
                }
                completion(.success(photos))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func downloadFile(at path: String, connection: SMBConnection, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                try connection.client.downloadFile(atPath: path, toLocalPath: destination.path)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func loadDirectorySync(path: String, displayPath: String, client: SMB2ClientWrapper) throws -> SMBDirectory {
        let files = try client.contentsOfDirectory(atPath: path)
        let children = files
            .filter { $0.directory }
            .filter { $0.name.caseInsensitiveCompare("#recycle") != .orderedSame }
            .map { file -> SMBDirectory in
                let childDisplayPath = displayPath.appendingPathComponentForDisplay(file.name)
                return SMBDirectory(
                    name: file.name,
                    displayPath: childDisplayPath,
                    path: file.path,
                    children: []
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let name = URL(string: displayPath)?.lastPathComponent ?? displayPath
        return SMBDirectory(name: name.isEmpty ? displayPath : name, displayPath: displayPath, path: path, children: children)
    }

    private func photoURLsRecursively(in directory: SMBDirectory, client: SMB2ClientWrapper) throws -> [URL] {
        let paths = try client.photoPathsRecursively(atPath: directory.path, supportedExtensions: supportedExtensions)
        return paths.compactMap { path in
            var components = URLComponents()
            components.scheme = "smb"
            components.host = "revivalframe"
            components.path = path.hasPrefix("/") ? path : "/\(path)"
            return components.url
        }
    }

    private func parseSMBURL(_ value: String) throws -> ParsedSMBURL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "smb",
              let host = components.host,
              !host.isEmpty else {
            throw SMBError.invalidURL
        }

        let parts = components.path.split(separator: "/").map(String.init)
        guard let share = parts.first, !share.isEmpty else {
            throw SMBError.invalidURL
        }

        let hostAndPort = components.port.map { "\(host):\($0)" } ?? host
        let subpath = parts.dropFirst().joined(separator: "/")
        let displayName = subpath.isEmpty ? "smb://\(hostAndPort)/\(share)" : "smb://\(hostAndPort)/\(share)/\(subpath)"
        return ParsedSMBURL(host: host, hostAndPort: hostAndPort, share: share, subpath: subpath, displayName: displayName)
    }
}

private struct ParsedSMBURL {
    let host: String
    let hostAndPort: String
    let share: String
    let subpath: String
    let displayName: String
}

private extension String {
    var isIPv4Address: Bool {
        var address = in_addr()
        return withCString { inet_aton($0, &address) } == 1
    }

    var pathExtensionLowercased: String {
        return (self as NSString).pathExtension.lowercased()
    }

    func appendingPathComponentForDisplay(_ component: String) -> String {
        let trimmed = trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let child = component.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(trimmed)/\(child)"
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
    case passwordRequired

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "Enter a valid Immich shared album link."
        case .missingAlbum: return "This Immich share link does not expose an album."
        case .noPhotos: return "No photos were found in this Immich shared album."
        case .invalidResponse: return "Immich returned an unexpected response."
        case .passwordRequired: return "This Immich shared album needs a password."
        }
    }
}

private final class ImmichShareClient {
    private struct SharedLinkResponse: Decodable {
        struct Album: Decodable {
            let id: String
            let albumName: String?
            let assetCount: Int?
        }
        let album: Album?
        let key: String?
        let token: String?
    }

    private struct AlbumResponse: Decodable {
        struct Asset: Decodable {
            let id: String
            let type: String
        }
        let albumName: String?
        let assetCount: Int?
        let assets: [Asset]?
    }

    private struct SearchResponse: Decodable {
        struct AssetResults: Decodable {
            let total: Int?
            let count: Int?
            let items: [AlbumResponse.Asset]
        }
        let assets: AssetResults
    }

    func loadSharedAlbum(_ shareLink: String, password: String, completion: @escaping (Result<ImmichAlbum, Error>) -> Void) {
        do {
            let parsed = try parseShareLink(shareLink)
            loadSharedLinkInfo(parsed: parsed, password: password) { sharedResult in
                switch sharedResult {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let sharedInfo):
                    guard let albumId = sharedInfo.album?.id, !albumId.isEmpty else {
                        completion(.failure(ImmichError.missingAlbum))
                        return
                    }
                    let authenticated = parsed.authenticated(withKey: sharedInfo.key, token: sharedInfo.token)
                    self.loadAlbum(parsed: authenticated, albumId: albumId, fallbackName: sharedInfo.album?.albumName, fallbackAssetCount: sharedInfo.album?.assetCount, completion: completion)
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func loadSharedLinkInfo(parsed: ParsedImmichShare, password: String, completion: @escaping (Result<SharedLinkResponse, Error>) -> Void) {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPassword.isEmpty {
            getJSON(parsed.sharedLinkInfoURL) { (result: Result<SharedLinkResponse, Error>) in
                completion(result)
            }
            return
        }

        var request = URLRequest(url: parsed.sharedLinkLoginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["password": trimmedPassword], options: [])
        sendJSON(request, completion: completion)
    }

    private func loadAlbum(parsed: ParsedImmichShare, albumId: String, fallbackName: String?, fallbackAssetCount: Int?, completion: @escaping (Result<ImmichAlbum, Error>) -> Void) {
        getJSON(parsed.albumURL(albumId: albumId)) { (albumResult: Result<AlbumResponse, Error>) in
            switch albumResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let album):
                if let assets = album.assets, !assets.isEmpty {
                    let photoURLs = assets
                        .filter { $0.type == "IMAGE" }
                        .map { parsed.originalURL(assetId: $0.id) }
                    self.completeAlbum(name: album.albumName ?? fallbackName, assetCount: album.assetCount ?? fallbackAssetCount, photoURLs: photoURLs, completion: completion)
                    return
                }
                self.loadAlbumAssets(parsed: parsed, albumId: albumId, albumName: album.albumName ?? fallbackName, assetCount: album.assetCount ?? fallbackAssetCount, completion: completion)
            }
        }
    }

    private func loadAlbumAssets(parsed: ParsedImmichShare, albumId: String, albumName: String?, assetCount: Int?, completion: @escaping (Result<ImmichAlbum, Error>) -> Void) {
        var request = URLRequest(url: parsed.searchMetadataURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["albumIds": [albumId]], options: [])
        sendJSON(request) { (searchResult: Result<SearchResponse, Error>) in
            switch searchResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let search):
                let photoURLs = search.assets.items
                    .filter { $0.type == "IMAGE" }
                    .map { parsed.originalURL(assetId: $0.id) }
                self.completeAlbum(name: albumName, assetCount: assetCount ?? search.assets.total ?? search.assets.count, photoURLs: photoURLs, completion: completion)
            }
        }
    }

    private func completeAlbum(name: String?, assetCount: Int?, photoURLs: [URL], completion: @escaping (Result<ImmichAlbum, Error>) -> Void) {
        guard !photoURLs.isEmpty else {
            completion(.failure(ImmichError.noPhotos))
            return
        }
        completion(.success(ImmichAlbum(
            name: name ?? "Immich album",
            assetCount: assetCount ?? photoURLs.count,
            photoURLs: photoURLs
        )))
    }

    private func getJSON<T: Decodable>(_ url: URL, completion: @escaping (Result<T, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        sendJSON(request, completion: completion)
    }

    private func sendJSON<T: Decodable>(_ request: URLRequest, completion: @escaping (Result<T, Error>) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let http = response as? HTTPURLResponse else {
                completion(.failure(ImmichError.invalidResponse))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                completion(.failure(ImmichError.passwordRequired))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
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
        let key: ParsedImmichShare.Credential
        if let shareIndex = segments.firstIndex(of: "share"),
           segments.indices.contains(shareIndex + 1) {
            key = .key(segments[shareIndex + 1])
        } else if let slugIndex = segments.firstIndex(of: "s"),
                  segments.indices.contains(slugIndex + 1) {
            key = .slug(segments[slugIndex + 1])
        } else {
            throw ImmichError.invalidLink
        }

        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = components.port
        guard let baseURL = base.url else {
            throw ImmichError.invalidLink
        }

        return ParsedImmichShare(baseURL: baseURL, credential: key)
    }
}

private struct ParsedImmichShare {
    enum Credential {
        case key(String)
        case slug(String)
        case token(String)
    }

    let baseURL: URL
    let credential: Credential

    var sharedLinkInfoURL: URL {
        return url(path: "/api/shared-links/me")
    }

    var sharedLinkLoginURL: URL {
        return url(path: "/api/shared-links/login")
    }

    func albumURL(albumId: String) -> URL {
        return url(path: "/api/albums/\(albumId)")
    }

    func originalURL(assetId: String) -> URL {
        return url(path: "/api/assets/\(assetId)/original")
    }

    var searchMetadataURL: URL {
        return url(path: "/api/search/metadata")
    }

    func authenticated(withKey key: String?, token: String?) -> ParsedImmichShare {
        if let key = key, !key.isEmpty {
            return ParsedImmichShare(baseURL: baseURL, credential: .key(key))
        }
        guard let token = token, !token.isEmpty else { return self }
        return ParsedImmichShare(baseURL: baseURL, credential: .token(token))
    }

    private func url(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        switch credential {
        case .key(let value):
            components.queryItems = [URLQueryItem(name: "key", value: value)]
        case .slug(let value):
            components.queryItems = [URLQueryItem(name: "slug", value: value)]
        case .token(let value):
            components.queryItems = [URLQueryItem(name: "token", value: value)]
        }
        return components.url!
    }
}

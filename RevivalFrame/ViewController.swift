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

final class ViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate {
    private let imageView = UIImageView()
    private let topPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let bottomPanel = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let playPauseButton = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private let settingsPanel = UIVisualEffectView(effect: UIBlurEffect(style: .extraLight))
    private let settingsTabs = UISegmentedControl(items: ["Presets", "Immich", "SMB", "Playback"])
    private let settingsContent = UIView()
    private let statusLabel = UILabel()
    private let immichTextView = UITextView()
    private let smbURLField = UITextField()
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
    private let imageCache = NSCache<NSURL, UIImage>()
    private let immichClient = ImmichShareClient()

    private let cacheSizeOptionsMB = [100, 300, 500]
    private let maxConcurrentRemoteLoads = 1
    private let smbLoader = SMBPhotoLoader()
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
    private var kenBurnsDirection = CGPoint(x: 1, y: 1)
    private var smbConnection: SMBConnection?
    private var smbCurrentDirectory: SMBDirectory?
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

    private enum Preferences {
        static let sourceType = "sourceType"
        static let immichLink = "immichLink"
        static let smbURL = "smbURL"
        static let smbUsername = "smbUsername"
        static let transitionMode = "transitionMode"
        static let playbackOrder = "playbackOrder"
        static let interval = "interval"
        static let cacheSizeMB = "cacheSizeMB"
        static let settingsTab = "settingsTab"
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadPreferences()
        configureImageCache()
        clearImageCache()
        buildInterface()
        showPhoto(at: 0, animated: false)
        updatePlaybackSummary()
        restoreLastSourceIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        smbApplyTimeoutTimer?.invalidate()
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

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
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
        settingsPanel.layer.cornerRadius = 12
        settingsPanel.clipsToBounds = true
        settingsPanel.isHidden = true
        settingsPanel.alpha = 0
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
        settingsTabs.tintColor = settingsBlue
        settingsTabs.backgroundColor = .white

        settingsContent.translatesAutoresizingMaskIntoConstraints = false
        settingsContent.backgroundColor = settingsGroupedBackground

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
        label.text = text
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = settingsSecondaryText
        label.numberOfLines = 0
        return label
    }

    private func makeSettingsTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = settingsSecondaryText
        label.numberOfLines = 1
        return label
    }

    private func makeSettingsGroup(_ arrangedSubviews: [UIView]) -> UIView {
        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = .white
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 0.5
        container.layer.borderColor = settingsSeparator.cgColor
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
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
        stack.alignment = .fill
        stack.distribution = .fill
        return stack
    }

    private func makeSettingsPlainButton(title: String, action: Selector, weight: UIFont.Weight = .regular) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.setTitleColor(settingsBlue, for: .normal)
        button.setTitleColor(UIColor(red: 0, green: 0.48, blue: 1, alpha: 0.35), for: .disabled)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: weight)
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        button.backgroundColor = .clear
        return button
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
        field.font = UIFont.systemFont(ofSize: 16)
        field.textColor = settingsPrimaryText
        field.backgroundColor = .white
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.isSecureTextEntry = secure
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
                makeSettingsLabel("Four generated landscape photos are available offline and are useful for checking playback, transitions, and full-screen framing."),
                useButton
            ])
        ])
        stack.axis = .vertical
        stack.spacing = 8
        replaceSettingsContent(with: stack)
    }

    private func showImmichSettings() {
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
        immichTextView.text = UserDefaults.standard.string(forKey: Preferences.immichLink) ?? immichTextView.text

        let loadButton = makeSettingsButton(title: "Load Immich Album", action: #selector(loadImmich))
        let stack = UIStackView(arrangedSubviews: [
            makeSettingsTitleLabel("Shared album link"),
            makeSettingsGroup([
                immichTextView,
                makeSettingsLabel("Paste an Immich shared album URL. RevivalFrame reads the shared link directly and displays the album photos."),
                loadButton
            ])
        ])
        stack.axis = .vertical
        stack.spacing = 8
        immichTextView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        replaceSettingsContent(with: stack)
    }

    private func showSMBSettings() {
        configureSMBTextField(smbURLField, placeholder: "smb://server/share/folder")
        configureSMBTextField(smbUsernameField, placeholder: "SMB username")
        configureSMBTextField(smbPasswordField, placeholder: "SMB password", secure: true)
        smbURLField.keyboardType = .URL
        smbURLField.text = UserDefaults.standard.string(forKey: Preferences.smbURL) ?? smbURLField.text
        smbUsernameField.text = UserDefaults.standard.string(forKey: Preferences.smbUsername) ?? smbUsernameField.text

        configureSettingsButton(smbConnectButton, title: "Connect", action: #selector(connectSMB))
        configureSettingsButton(smbBackButton, title: "Back", action: #selector(backSMBDirectory))
        configureSettingsButton(smbApplyButton, title: "Load", action: #selector(applySelectedSMBFolder))
        updateSMBActionButtons()

        smbPathLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        smbPathLabel.textColor = settingsSecondaryText
        smbPathLabel.numberOfLines = 2
        updateSMBPathLabel()

        smbDirectoryTableView.dataSource = self
        smbDirectoryTableView.delegate = self
        smbDirectoryTableView.backgroundColor = .white
        smbDirectoryTableView.separatorColor = settingsSeparator
        smbDirectoryTableView.layer.cornerRadius = 6
        smbDirectoryTableView.layer.borderWidth = 0.5
        smbDirectoryTableView.layer.borderColor = settingsSeparator.cgColor
        smbDirectoryTableView.clipsToBounds = true
        smbDirectoryTableView.tableFooterView = UIView()

        let credentialsRow = UIStackView(arrangedSubviews: [smbUsernameField, smbPasswordField])
        credentialsRow.axis = .horizontal
        credentialsRow.spacing = 8
        credentialsRow.distribution = .fillEqually

        let buttonRow = UIStackView(arrangedSubviews: [smbConnectButton, smbBackButton, smbApplyButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .center
        buttonRow.distribution = .fillEqually
        smbConnectButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        smbBackButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        smbApplyButton.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let formGroup = makeSettingsGroup([
            makeSettingsLabel("SMB URL"),
            smbURLField,
            makeSettingsLabel("Credentials"),
            credentialsRow,
            buttonRow
        ])

        let directoryGroup = makeSettingsGroup([
            makeSettingsLabel("Connected folders"),
            smbPathLabel,
            smbDirectoryTableView
        ])

        let connected = smbConnection != nil
        let landscape = view.bounds.width > view.bounds.height
        let stack = UIStackView(arrangedSubviews: [
            makeSettingsTitleLabel("SMB source"),
            landscape && connected ? horizontalSettingsGroups([formGroup, directoryGroup]) : verticalSettingsGroups([formGroup, directoryGroup])
        ])
        stack.axis = .vertical
        stack.spacing = 8

        if landscape && connected {
            formGroup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        } else {
            stack.alignment = .fill
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        smbURLField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        smbUsernameField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        smbPasswordField.heightAnchor.constraint(equalToConstant: 36).isActive = true
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

    private func showPlaybackSettings() {
        transitionControl.selectedSegmentIndex = transitionMode.rawValue
        transitionControl.removeTarget(nil, action: nil, for: .valueChanged)
        transitionControl.addTarget(self, action: #selector(transitionChanged), for: .valueChanged)
        transitionControl.tintColor = settingsBlue
        transitionControl.backgroundColor = .white

        orderControl.selectedSegmentIndex = playbackOrder.rawValue
        orderControl.removeTarget(nil, action: nil, for: .valueChanged)
        orderControl.addTarget(self, action: #selector(orderChanged), for: .valueChanged)
        orderControl.tintColor = settingsBlue
        orderControl.backgroundColor = .white

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
        intervalValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        cacheSizeControl.selectedSegmentIndex = cacheSizeOptionsMB.firstIndex(of: cacheSizeMB) ?? 1
        cacheSizeControl.removeTarget(nil, action: nil, for: .valueChanged)
        cacheSizeControl.addTarget(self, action: #selector(cacheSizeChanged), for: .valueChanged)
        cacheSizeControl.tintColor = settingsBlue
        cacheSizeControl.backgroundColor = .white

        cacheStatusLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        cacheStatusLabel.textColor = settingsSecondaryText
        cacheStatusLabel.numberOfLines = 2
        updateCacheStatus()

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
                cacheStatusLabel
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
        loadImmichFromStoredLink(link, automatic: true)
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
        let smbApplyIDForPhoto = pendingSMBApplyFirstURL == remoteURL ? pendingSMBApplyID : nil

        if let cached = imageCache.object(forKey: remoteURL as NSURL) {
            displayPlaybackImage(cached, animated: animated) { [weak self] in
                self?.finishSMBApplyIfNeeded(for: remoteURL, applyID: smbApplyIDForPhoto)
            }
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
                self.displayPlaybackImage(FramePhoto.placeholder(title: "Photo unavailable", subtitle: photo.title), animated: true) { [weak self] in
                    self?.finishSMBApplyIfNeeded(for: remoteURL, applyID: smbApplyIDForPhoto)
                }
                return
            }

            self.displayPlaybackImage(image, animated: true) { [weak self] in
                self?.finishSMBApplyIfNeeded(for: remoteURL, applyID: smbApplyIDForPhoto)
            }
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
                let loadedImage: UIImage? = nil
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
        smbLoader.downloadFile(at: smbPath, connection: connection, destination: requestedFileURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let downloadedFileURL):
                    let cost = max(1, ((try? FileManager.default.attributesOfItem(atPath: downloadedFileURL.path)[.size] as? NSNumber)?.intValue) ?? 1)
                    if self.remoteImageNeedsDecode[url] == true {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let image = self.downsampledImage(at: downloadedFileURL)
                            DispatchQueue.main.async {
                                self.storeCachedFile(at: downloadedFileURL, for: url, cost: cost)
                                if let image = image {
                                    self.imageCache.setObject(image, forKey: url as NSURL)
                                } else {
                                    self.statusLabel.text = "Unable to decode SMB photo: \(url.lastPathComponent)"
                                    NSLog("RevivalFrame SMB decode failed for %@", url.path)
                                }
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
                   remoteImageCompletions[url] == nil,
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
               remoteImageCompletions[url] == nil,
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
        cacheStatusLabel.text = "Temp cache \(formatBytes(cachedImageBytes)) / \(cacheSizeMB) MB. Active downloads: \(remoteImageCompletions.count). Played files are deleted immediately."
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

    private func displayPlaybackImage(_ image: UIImage, animated: Bool, completion: (() -> Void)? = nil) {
        display(image: image, animated: animated) { [weak self] in
            guard let self = self else { return }
            self.currentPhotoReadyForTiming = true
            self.scheduleNextPhotoTimer()
            completion?()
        }
    }

    private func display(image: UIImage, animated: Bool, completion: (() -> Void)? = nil) {
        imageView.layer.removeAllAnimations()
        imageView.transform = .identity
        imageView.contentMode = transitionMode == .kenBurns ? .scaleAspectFill : .scaleAspectFit

        guard animated else {
            imageView.image = image
            if transitionMode == .kenBurns {
                startKenBurnsAnimation()
            }
            completion?()
            return
        }

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
        UserDefaults.standard.set(link, forKey: Preferences.immichLink)
        saveSourcePreference(.immich)
        loadImmichFromStoredLink(link, automatic: false)
    }

    private func loadImmichFromStoredLink(_ link: String, automatic: Bool) {
        statusLabel.text = "Loading Immich shared album..."
        immichClient.loadSharedAlbum(link) { [weak self] result in
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
        cancelRemoteImageLoads()
        clearImageCache()
        disconnectSMB()

        let url = (smbURLField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let username = (smbUsernameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = smbPasswordField.text ?? ""
        UserDefaults.standard.set(url, forKey: Preferences.smbURL)
        UserDefaults.standard.set(username, forKey: Preferences.smbUsername)
        saveSourcePreference(.smb)
        statusLabel.text = "Connecting SMB..."
        smbConnectButton.isEnabled = false
        smbApplyButton.isEnabled = false

        smbLoader.connect(to: url, username: username, password: password) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let connection):
                    self.sourceType = .smb
                    self.smbConnection = connection
                    self.smbDirectoryStack = [connection.rootDirectory]
                    self.smbCurrentDirectory = connection.rootDirectory
                    if self.settingsTabs.selectedSegmentIndex == 2 {
                        self.showSMBSettings()
                    } else {
                        self.smbDirectoryTableView.reloadData()
                        self.updateSMBPathLabel()
                    }
                    self.statusLabel.text = "Connected SMB. Select a folder, then apply it for playback."
                    self.updatePlaybackSummary()
                    self.updateSMBActionButtons()
                case .failure(let error):
                    self.smbCurrentDirectory = nil
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
              let directory = smbCurrentDirectory else {
            statusLabel.text = "Connect SMB and select a folder first."
            return
        }
        let applyID = UUID()
        activeSMBApplyID = applyID
        isApplyingSMBFolder = true
        updateSMBActionButtons()
        startSMBApplyTimeout(for: applyID)
        cancelRemoteImageLoads()
        clearImageCache()
        statusLabel.text = "Loading SMB photos..."
        smbLoader.loadPhotos(in: directory, connection: connection) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.activeSMBApplyID == applyID else { return }
                switch result {
                case .success(let photos):
                    self.pendingSMBApplyID = applyID
                    self.pendingSMBApplyFirstURL = photos.first?.remoteURL
                    self.applyPhotos(photos, source: .smb, status: "Loaded \(photos.count) SMB photo(s) from \(directory.name).")
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
        smbDirectoryStack.removeAll()
        smbDirectoryTableView.reloadData()
        updateSMBPathLabel()
        updateSMBActionButtons()
    }

    private func updateSMBPathLabel() {
        guard isViewLoaded else { return }
        if let directory = smbCurrentDirectory {
            smbPathLabel.text = directory.displayPath
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

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard tableView == smbDirectoryTableView else { return 0 }
        return smbCurrentDirectory?.children.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "SMBDirectoryCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        if let child = smbCurrentDirectory?.children[indexPath.row] {
            cell.textLabel?.text = child.name
            cell.detailTextLabel?.text = child.displayPath
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.textLabel?.text = ""
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
        }
        cell.backgroundColor = .white
        cell.textLabel?.textColor = settingsPrimaryText
        cell.detailTextLabel?.textColor = settingsSecondaryText
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isApplyingSMBFolder else { return }
        guard tableView == smbDirectoryTableView,
              let child = smbCurrentDirectory?.children[indexPath.row] else {
            return
        }
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
                    self.statusLabel.text = "Select a folder, then apply it for playback."
                case .failure(let error):
                    self.statusLabel.text = error.localizedDescription
                }
            }
        }
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
            return "Enter an SMB URL like smb://server/share/folder."
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
        queue.async {
            do {
                let photos = try self.photoURLsRecursively(in: directory, client: connection.client)
                    .map { FramePhoto(title: $0.lastPathComponent, image: nil, remoteURL: $0) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                guard !photos.isEmpty else {
                    throw SMBError.noPhotos(directory.displayPath)
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

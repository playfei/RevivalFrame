import UIKit

final class LicensesViewController: UIViewController {
    private let accentColor = UIColor(red: 0.12, green: 0.43, blue: 0.84, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
        }
        view.backgroundColor = UIColor(white: 0.97, alpha: 1)
        buildInterface()
    }

    private func buildInterface() {
        let titleLabel = UILabel()
        titleLabel.text = "License & Open Source"
        titleLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = UIColor(white: 0.08, alpha: 1)

        let versionLabel = UILabel()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        versionLabel.text = "RevivalFrame \(version) (\(build))"
        versionLabel.font = UIFont.systemFont(ofSize: 13)
        versionLabel.textColor = UIColor(white: 0.4, alpha: 1)

        let doneButton = UIButton(type: .system)
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let heading = UIStackView(arrangedSubviews: [titleLabel, UIView(), doneButton])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 12

        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.backgroundColor = .white
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        textView.attributedText = noticeText()
        textView.linkTextAttributes = [.foregroundColor: accentColor]
        textView.accessibilityLabel = "License and open source notices"

        let stack = UIStackView(arrangedSubviews: [heading, versionLabel, textView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])
    }

    private func noticeText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor(white: 0.18, alpha: 1)
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor(white: 0.08, alpha: 1)
        ]

        func append(_ text: String, attributes: [NSAttributedString.Key: Any] = body) {
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        func appendLink(_ title: String, url: String) {
            var attributes = body
            attributes[.link] = URL(string: url)
            result.append(NSAttributedString(string: title, attributes: attributes))
        }

        append("RevivalFrame\n", attributes: heading)
        append("RevivalFrame is currently provided at no charge, but it is proprietary software and is not open source. Except for the third-party software identified below, all rights are reserved. The App is licensed—not sold—under the applicable App Store terms.\n\n")

        append("libsmb2\n", attributes: heading)
        append("RevivalFrame includes and links with libsmb2, a userspace SMB2/SMB3 client library, under the GNU Lesser General Public License version 2.1. RevivalFrame elects to satisfy its distribution obligations under LGPL 2.1; this does not limit any ‘or later version’ option stated in individual upstream files. libsmb2 is free software and is provided without warranty. Kerberos support is not enabled in this build.\n\n")
        append("You may obtain, study, modify, and redistribute libsmb2 under the LGPL. You may reverse engineer the combined work to the extent needed to debug your modifications to libsmb2. Version-specific corresponding source and relinking materials are available from the RevivalFrame website or by contacting jackandjoe99@hotmail.com.\n\n")
        appendLink("License and compliance materials", url: "https://www.revivalframe.com/license")
        append("\n")
        appendLink("GNU LGPL 2.1", url: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")
        append("\n")
        appendLink("libsmb2 upstream project", url: "https://github.com/sahlberg/libsmb2")
        append("\n\n")

        append("RSA MD4 notice\n", attributes: heading)
        append("Copyright © 1990–1992 RSA Data Security, Inc. All rights reserved.\n\nLicense to copy and use this software is granted provided that it is identified as the ‘RSA Data Security, Inc. MD4 Message-Digest Algorithm’ in all material mentioning or referencing this software or this function.\n\nLicense is also granted to make and use derivative works provided that such works are identified as ‘derived from the RSA Data Security, Inc. MD4 Message-Digest Algorithm’ in all material mentioning or referencing the derived work.\n\nRSA Data Security, Inc. makes no representations concerning either the merchantability of this software or the suitability of this software for any particular purpose. It is provided ‘as is’ without express or implied warranty of any kind.\n\nThese notices must be retained in any copies of any part of this documentation and/or software.\n\n")

        append("Contact\n", attributes: heading)
        append("License questions and requests for compliance materials: ")
        appendLink("jackandjoe99@hotmail.com", url: "mailto:jackandjoe99@hotmail.com")
        append("\n")
        return result
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

//
//  ActionsSettingsViewController.swift
//  FlowVision
//

import Settings
import Cocoa

final class ActionsSettingsViewController: NSViewController, SettingsPane {
    let paneIdentifier = Settings.PaneIdentifier.actions
    let paneTitle = NSLocalizedString("Actions", comment: "操作（设置里的面板）")
    let toolbarItemIcon = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "")!

    override var nibName: NSNib.Name? { "ActionsSettingsViewController" }
    
    @IBOutlet weak var radioEnterKeyRename: NSButton!
    @IBOutlet weak var radioEnterKeyOpen: NSButton!
    
    private var quickRenameRuleField = NSTextField()
    private var photoFolder1PathField = NSTextField()
    private var photoFolder1ShortcutPopup = NSPopUpButton()
    private var videoShiftArrowSwitchFileCheckbox = NSButton()
    
    private let shortcutCandidates: [String] = {
        let letters = (65...90).compactMap { UnicodeScalar($0).map { String($0) } }
        let digits = (0...9).map(String.init)
        let functionKeys = (1...12).map { "F\($0)" }
        return letters + digits + functionKeys
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        radioEnterKeyOpen.state = globalVar.isEnterKeyToOpen ? .on : .off
        radioEnterKeyRename.state = globalVar.isEnterKeyToOpen ? .off : .on
        
        setupInlineFileActionSettingsPanel()
    }

    @IBAction func enterKeyToOpenToggled(_ sender: NSButton) {
        let tag = sender.tag
        if tag == 0 {
            globalVar.isEnterKeyToOpen = false
        } else if tag == 1 {
            globalVar.isEnterKeyToOpen = true
        }
        UserDefaults.standard.set(globalVar.isEnterKeyToOpen, forKey: "isEnterKeyToOpen")
    }
    
    private func setupInlineFileActionSettingsPanel() {
        guard let grid = view.subviews.compactMap({ $0 as? NSGridView }).first else { return }

        let profileTitle = NSLocalizedString("Profile Switching:", comment: "配置切换：")
        let targetRow = (0..<grid.numberOfRows).first { rowIndex in
            guard let label = grid.cell(atColumnIndex: 0, rowIndex: rowIndex).contentView as? NSTextField else { return false }
            return label.stringValue == profileTitle
        } ?? max(0, grid.numberOfRows - 1)

        if let leftLabel = grid.cell(atColumnIndex: 0, rowIndex: targetRow).contentView as? NSTextField {
            leftLabel.stringValue = NSLocalizedString("File Actions:", comment: "文件操作：")
        }

        let panel = NSStackView()
        panel.orientation = .vertical
        panel.spacing = 6
        panel.alignment = .leading
        panel.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        panel.translatesAutoresizingMaskIntoConstraints = false
        
        let renameRow = NSStackView()
        renameRow.orientation = .horizontal
        renameRow.spacing = 8
        renameRow.alignment = .centerY
        
        let renameLabel = NSTextField(labelWithString: NSLocalizedString("Quick Rename Rule:", comment: "快速重命名规则："))
        renameLabel.setContentHuggingPriority(.required, for: .horizontal)
        quickRenameRuleField = NSTextField()
        quickRenameRuleField.stringValue = globalVar.quickRenameRule
        quickRenameRuleField.translatesAutoresizingMaskIntoConstraints = false
        
        let applyButton = NSButton(title: NSLocalizedString("Apply", comment: "应用"), target: self, action: #selector(applyInlineFileActionSettings))
        applyButton.bezelStyle = .rounded
        applyButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        
        renameRow.addArrangedSubview(renameLabel)
        renameRow.addArrangedSubview(quickRenameRuleField)
        renameRow.addArrangedSubview(applyButton)
        quickRenameRuleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        
        let folderRow = NSStackView()
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        folderRow.alignment = .centerY
        
        let folderLabel = NSTextField(labelWithString: NSLocalizedString("Photo Folder 1:", comment: "图片文件夹1："))
        folderLabel.setContentHuggingPriority(.required, for: .horizontal)
        photoFolder1PathField = NSTextField()
        photoFolder1PathField.stringValue = globalVar.photoFolder1Path
        photoFolder1PathField.lineBreakMode = .byTruncatingMiddle
        
        let selectFolderButton = NSButton(title: NSLocalizedString("Select Folder", comment: "选择文件夹"), target: self, action: #selector(selectPhotoFolder1Inline))
        selectFolderButton.bezelStyle = .rounded
        selectFolderButton.widthAnchor.constraint(equalToConstant: 106).isActive = true
        
        folderRow.addArrangedSubview(folderLabel)
        folderRow.addArrangedSubview(photoFolder1PathField)
        folderRow.addArrangedSubview(selectFolderButton)
        photoFolder1PathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        
        let shortcutRow = NSStackView()
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 8
        shortcutRow.alignment = .centerY
        
        let shortcutLabel = NSTextField(labelWithString: NSLocalizedString("Copy Shortcut:", comment: "复制快捷键："))
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        
        photoFolder1ShortcutPopup = NSPopUpButton()
        photoFolder1ShortcutPopup.addItems(withTitles: shortcutCandidates)
        let selectedShortcut = globalVar.photoFolder1CopyShortcut.uppercased()
        photoFolder1ShortcutPopup.selectItem(withTitle: shortcutCandidates.contains(selectedShortcut) ? selectedShortcut : "N")
        photoFolder1ShortcutPopup.target = self
        photoFolder1ShortcutPopup.action = #selector(applyInlineFileActionSettings)
        
        videoShiftArrowSwitchFileCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Video Shift+←/→ Next/Prev", comment: "视频 Shift+左右 上/下文件"), target: self, action: #selector(applyInlineFileActionSettings))
        videoShiftArrowSwitchFileCheckbox.state = globalVar.videoShiftArrowSwitchFile ? .on : .off
        
        let videoSwitchRow = NSStackView()
        videoSwitchRow.orientation = .horizontal
        videoSwitchRow.spacing = 8
        videoSwitchRow.alignment = .centerY
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 116).isActive = true
        videoSwitchRow.addArrangedSubview(spacer)
        videoSwitchRow.addArrangedSubview(videoShiftArrowSwitchFileCheckbox)

        shortcutRow.addArrangedSubview(shortcutLabel)
        shortcutRow.addArrangedSubview(photoFolder1ShortcutPopup)
        
        panel.addArrangedSubview(renameRow)
        panel.addArrangedSubview(folderRow)
        panel.addArrangedSubview(shortcutRow)
        panel.addArrangedSubview(videoSwitchRow)

        guard let container = grid.cell(atColumnIndex: 1, rowIndex: targetRow).contentView as? NSView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
    
    @objc private func selectPhotoFolder1Inline() {
        
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            photoFolder1PathField.stringValue = url.path
            applyInlineFileActionSettings()
        }
    }
    
    @objc private func applyInlineFileActionSettings() {
        let renameRule = quickRenameRuleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        globalVar.quickRenameRule = renameRule.isEmpty ? "{folder}_{index}" : renameRule
        UserDefaults.standard.set(globalVar.quickRenameRule, forKey: "quickRenameRule")
        
        let folderPath = photoFolder1PathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folderPath.isEmpty {
            globalVar.photoFolder1Path = folderPath
            UserDefaults.standard.set(folderPath, forKey: "photoFolder1Path")
        }
        
        if let title = photoFolder1ShortcutPopup.selectedItem?.title, !title.isEmpty {
            globalVar.photoFolder1CopyShortcut = title.uppercased()
            UserDefaults.standard.set(globalVar.photoFolder1CopyShortcut, forKey: "photoFolder1CopyShortcut")
        }
        
        globalVar.videoShiftArrowSwitchFile = (videoShiftArrowSwitchFileCheckbox.state == .on)
        UserDefaults.standard.set(globalVar.videoShiftArrowSwitchFile, forKey: "videoShiftArrowSwitchFile")
    }
}

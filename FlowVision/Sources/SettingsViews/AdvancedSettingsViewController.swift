//
//  GeneralSettingsViewController.swift
//  FlowVision
//

import Cocoa
import Settings

final class AdvancedSettingsViewController: NSViewController, SettingsPane {
	let paneIdentifier = Settings.PaneIdentifier.advanced
	let paneTitle = NSLocalizedString("Advanced", comment: "高级")
	let toolbarItemIcon = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "")!

	override var nibName: NSNib.Name? { "AdvancedSettingsViewController" }
    
    @IBOutlet weak var memUseLimitSlider: NSSlider!
    @IBOutlet weak var memUseLimitLabel: NSTextField!
    
    @IBOutlet weak var thumbThreadNumStepper: NSStepper!
    @IBOutlet weak var thumbThreadNumLabel: NSTextField!
    
    @IBOutlet weak var folderSearchDepthStepper: NSStepper!
    @IBOutlet weak var folderSearchDepthLabel: NSTextField!
    
    @IBOutlet weak var thumbThreadNumStepper_External: NSStepper!
    @IBOutlet weak var thumbThreadNumLabel_External: NSTextField!
    
    @IBOutlet weak var folderSearchDepthStepper_External: NSStepper!
    @IBOutlet weak var folderSearchDepthLabel_External: NSTextField!
    
    @IBOutlet weak var useFFmpegRadioButton: NSButton!
    @IBOutlet weak var doNotUseFFmpegRadioButton: NSButton!
    
    @IBOutlet weak var searchDepthWarningText: NSTextField!
    @IBOutlet weak var searchDepthWarningText_External: NSTextField!
    
    private var externalFolderThumbnailCacheSizeLabel: NSTextField?

	override func viewDidLoad() {
		super.viewDidLoad()

        // 初始化 slider、stepper 和标签
        // Initialize slider, stepper and labels
        memUseLimitSlider.integerValue = globalVar.memUseLimit
        updateMemUseLimitLabel(value: Double(globalVar.memUseLimit))
        
        thumbThreadNumStepper.integerValue = globalVar.thumbThreadNum
        updateThumbThreadNumLabel(value: globalVar.thumbThreadNum)
        
        folderSearchDepthStepper.integerValue = globalVar.folderSearchDepth
        updateFolderSearchDepthLabel(value: globalVar.folderSearchDepth)
        
        thumbThreadNumStepper_External.integerValue = globalVar.thumbThreadNum_External
        updateThumbThreadNumLabel_External(value: globalVar.thumbThreadNum_External)
        
        folderSearchDepthStepper_External.integerValue = globalVar.folderSearchDepth_External
        updateFolderSearchDepthLabel_External(value: globalVar.folderSearchDepth_External)
        
        if folderSearchDepthStepper.integerValue == 0 {
            searchDepthWarningText.textColor = .systemRed
        } else {
            searchDepthWarningText.textColor = .systemGray
        }
        
        if folderSearchDepthStepper_External.integerValue == 0 {
            searchDepthWarningText_External.textColor = .systemRed
        } else {
            searchDepthWarningText_External.textColor = .systemGray
        }
        
        // 初始化 Radio Buttons
        // Initialize Radio Buttons
        updateFFmpegRadioButtons()

        // MARK: RTL support
        for stepper in [thumbThreadNumStepper, folderSearchDepthStepper, thumbThreadNumStepper_External, folderSearchDepthStepper_External] {
            if let container = stepper?.superview {
                convertToLeadingLayoutForRTL(container)
            }
        }
        if let container = memUseLimitSlider.superview {
            convertToLeadingLayoutForRTL(container)
        }
        
        setupExternalFolderThumbnailCacheControls()
	}
    
    override func viewWillAppear() {
        super.viewWillAppear()
        updateExternalFolderThumbnailCacheSizeLabel()
    }

    @IBAction func memUseLimitSliderChanged(_ sender: NSSlider) {
        let newValue = sender.integerValue
        globalVar.memUseLimit = newValue
        UserDefaults.standard.set(newValue, forKey: "memUseLimit")
        updateMemUseLimitLabel(value: Double(newValue))
    }
    
    private func updateMemUseLimitLabel(value: Double) {
        // 将 slider 的值转换为合适的显示内容
        // Convert slider value to appropriate display format
        let formattedValue: String
        if value < 1000 {
            formattedValue = "\(Int(value)) MB"
        } else {
            formattedValue = String(format: "%.0f GB", value / 1000.0)
        }
        memUseLimitLabel.stringValue = formattedValue
    }
    
    @IBAction func thumbThreadNumStepperChanged(_ sender: NSStepper) {
        let newThumbThreadNum = sender.integerValue
        globalVar.thumbThreadNum = newThumbThreadNum
        UserDefaults.standard.set(newThumbThreadNum, forKey: "thumbThreadNum")
        updateThumbThreadNumLabel(value: newThumbThreadNum)
    }
    
    private func updateThumbThreadNumLabel(value: Int) {
        // 更新 thumbThreadNumLabel 的显示内容
        // Update thumbThreadNumLabel display content
        thumbThreadNumLabel.stringValue = "\(value)"
    }
    
    @IBAction func folderSearchDepthStepperChanged(_ sender: NSStepper) {
        let newFolderSearchDepth = sender.integerValue
        globalVar.folderSearchDepth = newFolderSearchDepth
        UserDefaults.standard.set(newFolderSearchDepth, forKey: "folderSearchDepth")
        updateFolderSearchDepthLabel(value: newFolderSearchDepth)
        
        if folderSearchDepthStepper.integerValue == 0 {
            searchDepthWarningText.textColor = .systemRed
        } else {
            searchDepthWarningText.textColor = .systemGray
        }
    }
    
    private func updateFolderSearchDepthLabel(value: Int) {
        // 更新 folderSearchDepthLabel 的显示内容
        // Update folderSearchDepthLabel display content
        folderSearchDepthLabel.stringValue = "\(value)"
    }
    
    @IBAction func thumbThreadNumStepperChanged_External(_ sender: NSStepper) {
        let newThumbThreadNum_External = sender.integerValue
        globalVar.thumbThreadNum_External = newThumbThreadNum_External
        UserDefaults.standard.set(newThumbThreadNum_External, forKey: "thumbThreadNum_External")
        updateThumbThreadNumLabel_External(value: newThumbThreadNum_External)
    }
    
    private func updateThumbThreadNumLabel_External(value: Int) {
        // 更新 thumbThreadNumLabel 的显示内容
        // Update thumbThreadNumLabel display content
        thumbThreadNumLabel_External.stringValue = "\(value)"
    }
    
    @IBAction func folderSearchDepthStepperChanged_External(_ sender: NSStepper) {
        let newFolderSearchDepth_External = sender.integerValue
        globalVar.folderSearchDepth_External = newFolderSearchDepth_External
        UserDefaults.standard.set(newFolderSearchDepth_External, forKey: "folderSearchDepth_External")
        updateFolderSearchDepthLabel_External(value: newFolderSearchDepth_External)
        
        if folderSearchDepthStepper_External.integerValue == 0 {
            searchDepthWarningText_External.textColor = .systemRed
        } else {
            searchDepthWarningText_External.textColor = .systemGray
        }
    }
    
    private func updateFolderSearchDepthLabel_External(value: Int) {
        // 更新 folderSearchDepthLabel 的显示内容
        // Update folderSearchDepthLabel display content
        folderSearchDepthLabel_External.stringValue = "\(value)"
    }
    
    @IBAction func ffmpegRadioButtonChanged(_ sender: NSButton) {
        if sender == useFFmpegRadioButton {
            globalVar.doNotUseFFmpeg = false
        } else if sender == doNotUseFFmpegRadioButton {
            globalVar.doNotUseFFmpeg = true
        }
        UserDefaults.standard.set(globalVar.doNotUseFFmpeg, forKey: "doNotUseFFmpeg")
        updateFFmpegRadioButtons()
    }
    private func updateFFmpegRadioButtons() {
        // 根据全局变量设置 Radio Buttons 的状态
        // Set Radio Buttons state based on global variable
        useFFmpegRadioButton.state = globalVar.doNotUseFFmpeg ? .off : .on
        doNotUseFFmpegRadioButton.state = globalVar.doNotUseFFmpeg ? .on : .off
    }
    
    private func setupExternalFolderThumbnailCacheControls() {
        guard let gridView = view.subviews.compactMap({ $0 as? NSGridView }).first,
              gridView.numberOfRows > 14 else {
            return
        }
        
        let label = NSTextField(labelWithString: NSLocalizedString("External Thumbnail Cache:", comment: "外接卷缩略图缓存"))
        label.alignment = .right
        
        let checkbox = NSButton(checkboxWithTitle: NSLocalizedString("Cache external thumbnails locally", comment: "本地缓存外接卷缩略图"), target: self, action: #selector(externalFolderThumbnailCacheToggled(_:)))
        checkbox.state = globalVar.cacheExternalFolderThumbnails ? .on : .off
        
        let sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        externalFolderThumbnailCacheSizeLabel = sizeLabel
        
        let clearButton = NSButton(title: NSLocalizedString("Clear", comment: "清理"), target: self, action: #selector(clearExternalFolderThumbnailCache(_:)))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        
        let sizeRow = NSStackView(views: [sizeLabel, clearButton])
        sizeRow.orientation = .horizontal
        sizeRow.alignment = .centerY
        sizeRow.spacing = 8
        
        let container = NSStackView(views: [checkbox, sizeRow])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        
        let row = gridView.insertRow(at: 14, with: [label, container])
        row.topPadding = 4
        row.bottomPadding = 4
        view.setFrameSize(NSSize(width: view.frame.width, height: view.frame.height + 52))
        updateExternalFolderThumbnailCacheSizeLabel()
    }
    
    @objc private func externalFolderThumbnailCacheToggled(_ sender: NSButton) {
        globalVar.cacheExternalFolderThumbnails = (sender.state == .on)
        UserDefaults.standard.set(globalVar.cacheExternalFolderThumbnails, forKey: "cacheExternalFolderThumbnails")
    }
    
    @objc private func clearExternalFolderThumbnailCache(_ sender: NSButton) {
        FolderThumbnailDiskCache.clear()
        ExternalMediaThumbnailDiskCache.clear()
        updateExternalFolderThumbnailCacheSizeLabel()
    }
    
    private func updateExternalFolderThumbnailCacheSizeLabel() {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let totalSize = FolderThumbnailDiskCache.sizeInBytes()
            + ExternalMediaThumbnailDiskCache.sizeInBytes()
        let sizeText = formatter.string(fromByteCount: totalSize)
        externalFolderThumbnailCacheSizeLabel?.stringValue = String(format: NSLocalizedString("Local cache: %@", comment: "本地缓存大小"), sizeText)
    }
    
}

//
//  Manager.swift
//  AudioKitSynthOne
//
//  Created by AudioKit Contributors on 7/8/17.
//  Copyright © 2017 AudioKit. All rights reserved.
//

import AudioKit
import UIKit
import Disk

protocol EmbeddedViewsDelegate: AnyObject {
    func switchToChildPanel(_ newView: ChildPanel, isOnTop: Bool)
}

public class Manager: UpdatableViewController {

    @IBOutlet weak var topContainerView: UIView!
    @IBOutlet weak var bottomContainerView: UIView!

    @IBOutlet weak var keyboardView: KeyboardView!
    @IBOutlet weak var keyboardBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var topPanelheight: NSLayoutConstraint!

    @IBOutlet weak var midiButton: SynthButton!
    @IBOutlet weak var holdButton: SynthButton!
    @IBOutlet weak var monoButton: SynthButton!
	@IBOutlet weak var keyboardToggle: SynthButton!
    @IBOutlet weak var octaveStepper: Stepper!
    @IBOutlet weak var configKeyboardButton: SynthButton!
    @IBOutlet weak var bluetoothButton: AKBluetoothMIDIButton!
    @IBOutlet weak var modWheelSettings: SynthButton!
    @IBOutlet weak var midiLearnToggle: SynthButton!
    @IBOutlet weak var pitchBend: AKVerticalPad!
    @IBOutlet weak var modWheelPad: AKVerticalPad!
    @IBOutlet weak var linkButton: AKLinkButton!

    weak var embeddedViewsDelegate: EmbeddedViewsDelegate?

    var topChildPanel: ChildPanel?
    var bottomChildPanel: ChildPanel?
    var prevBottomChildPanel: ChildPanel?
    var isPresetsDisplayed: Bool = false
    var activePreset = Preset()

    var midiChannelIn: MIDIChannel = 0
    var midiInputs = [MIDIInput]()
    var omniMode = true
    var notesFromMIDI = Set<MIDINoteNumber>()
    var appSettings = AppSettings()
    var isDevView = false

    var sustainMode = false
    var sustainer: SDSustainer!
    var pcJustTriggered = false
    var midiKnobs = [MIDIKnob]()
    var signedMailingList = false
    let mainStoryboard = UIStoryboard(name: "Main", bundle: Bundle.main)

    // AudioBus
    private var audioUnitPropertyListener: AudioUnitPropertyListener!
    var midiInput: ABMIDIReceiverPort?

    // MARK: - Define child view controllers

    // swiftlint:disable force_cast

    lazy var envelopesPanel: EnvelopesPanelController = {
        let envelopesStoryboard = UIStoryboard(name: "Envelopes", bundle: Bundle.main)
        return envelopesStoryboard.instantiateInitialViewController() as! EnvelopesPanelController
    }()

    lazy var generatorsPanel: GeneratorsPanelController = {
        let generatorsStoryboard = UIStoryboard(name: "Generators", bundle: Bundle.main)
        return generatorsStoryboard.instantiateInitialViewController() as! GeneratorsPanelController
    }()

    lazy var devViewController: DevViewController = {
        let devStoryboard = UIStoryboard(name: "Dev", bundle: Bundle.main)
        var viewController = devStoryboard.instantiateInitialViewController() as! DevViewController
        viewController.delegate = self
        return viewController
    }()

    lazy var touchPadPanel: TouchPadPanelController = {
        let touchPadStoryboard = UIStoryboard(name: "TouchPad", bundle: Bundle.main)
        return touchPadStoryboard.instantiateInitialViewController() as! TouchPadPanelController
    }()

    lazy var fxPanel: EffectsPanelController = {
        let effectsStoryboard = UIStoryboard(name: "Effects", bundle: Bundle.main)
        return effectsStoryboard.instantiateInitialViewController() as! EffectsPanelController
    }()

    lazy var sequencerPanel: SequencerPanelController = {
        let sequencerStoryboard = UIStoryboard(name: "Sequencer", bundle: Bundle.main)
        return sequencerStoryboard.instantiateInitialViewController() as! SequencerPanelController
    }()

    lazy var tuningsPanel: TuningsPanelController = {
        let tuningsStoryboard = UIStoryboard(name: "Tunings", bundle: Bundle.main)
        return tuningsStoryboard.instantiateInitialViewController() as! TuningsPanelController
    }()

    lazy var presetsViewController: PresetsViewController = {
        let presetsStoryboard = UIStoryboard(name: "Presets", bundle: Bundle.main)
        return presetsStoryboard.instantiateInitialViewController() as! PresetsViewController
    }()

    // swiftlint:enable force_cast

    // MARK: - viewDidLoad

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Conductor start
        conductor.start()
        sustainer = SDSustainer(conductor.synth)

        keyboardView?.delegate = self
        keyboardView?.polyphonicMode = conductor.synth.getSynthParameter(.isMono) < 1 ? true : false

        // Set Header as Delegate
        if let headerVC = self.children.first as? HeaderViewController {
            headerVC.delegate = self
            headerVC.headerDelegate = self
        }

        // Set AKKeyboard octave range
        octaveStepper.minValue = -2
        octaveStepper.maxValue = 4

        // Make bluetooth button look pretty
        bluetoothButton.centerPopupIn(view: view)
        bluetoothButton.layer.cornerRadius = 2
        bluetoothButton.layer.borderWidth = 1

        #if ABLETON_ENABLED_1
        linkButton.centerPopupIn(view: view)
        #endif

        // Setup Callbacks
        setupCallbacks()

        // Load Presets
        displayPresetsController()

        DispatchQueue.global(qos: .userInteractive).async {
            AudioKit.midi.createVirtualInputPort(95_433, name: "AudioKit Synth One")
            AudioKit.midi.openInput()
            AudioKit.midi.openOutput("AudioKit Synth One")
        }
        AudioKit.midi.addListener(self)

        // Pre-load views and Set initial subviews
        switchToChildPanel(.effects, isOnTop: true)
        switchToChildPanel(.envelopes, isOnTop: true)
        switchToChildPanel(.generators, isOnTop: true)
        switchToChildPanel(.sequencer, isOnTop: false)

        // Pre-load dev panel view
        add(asChildViewController: devViewController, isTopContainer: true)
        devViewController.view.removeFromSuperview()

        // IAA MIDI
        var callbackStruct = AudioOutputUnitMIDICallbacks(
            userData: nil,
            MIDIEventProc: { (_, status, data1, data2, _) in
                AudioKit.midi.sendMessage([MIDIByte(status), MIDIByte(data1), MIDIByte(data2)])
            },
            MIDISysExProc: { (_, _, _) in
                print("Not handling sysex")
            }
        )

        guard let outputAudioUnit = AudioKit.engine.outputNode.audioUnit else {
            AKLog("ERROR: can't create outputAudioUnit")
            return
        }

        let connectIAAMDI = AudioUnitSetProperty(outputAudioUnit,
                                                 kAudioOutputUnitProperty_MIDICallbacks,
                                                 kAudioUnitScope_Global,
                                                 0,
                                                 &callbackStruct,
                                                 UInt32(MemoryLayout<AudioOutputUnitMIDICallbacks>.size))
        if connectIAAMDI != 0 {
            AKLog("Something bad happened")
        }

        // Setup AudioBus MIDI Input
        setupAudioBusInput()
		
		holdButton.accessibilityValue = self.keyboardView.holdMode ? NSLocalizedString("On", comment: "On") : NSLocalizedString("Off", comment: "Off")
		monoButton.accessibilityValue = self.keyboardView.polyphonicMode ? NSLocalizedString("Off", comment: "Off") : NSLocalizedString("On", comment: "On")
		
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Load App Settings
        if Disk.exists("settings.json", in: .documents) {
            loadSettingsFromDevice()
        } else {
            setDefaultsFromAppSettings()
            saveAppSettings()
        }

        // Set Mailing List Button
        signedMailingList = appSettings.signedMailingList
        if let headerVC = self.children.first as? HeaderViewController {
            headerVC.updateMailingListButton(appSettings.signedMailingList)
        }

        // Load Banks
        if Disk.exists("banks.json", in: .documents) {
            loadBankSettings()
        } else {
            createInitBanks()
        }

        // Check preset versions
        let currentPresetVersion = AppSettings().presetsVersion
        if appSettings.presetsVersion < currentPresetVersion {
            presetsViewController.upgradePresets()
            // Save appSettings
            appSettings.presetsVersion = currentPresetVersion
            saveAppSettings()
        }

        presetsViewController.loadBanks()

        // Set Initial Preset from last used Bank & Preset
        self.presetsViewController.didSelectBank(index: self.appSettings.currentBankIndex)
        self.presetsViewController.didSelectPreset(index: self.appSettings.currentPresetIndex)

        // Show email list if first run
        if appSettings.firstRun && !appSettings.signedMailingList && Private.MailChimpAPIKey != "***REMOVED***" {
            performSegue(withIdentifier: "SegueToMailingList", sender: self)
            appSettings.firstRun = false
        }

        // On four runs show dialog and request review
        if appSettings.launches == 5 && !appSettings.isPreRelease { reviewPopUp() }
        if appSettings.launches % 17 == 0 && !appSettings.isPreRelease && appSettings.launches > 0 { requestReview() }

        // Push Notifications request
        if appSettings.launches == 9 && !appSettings.pushNotifications { pushPopUp() }
        if appSettings.launches % 18 == 0 &&
            !appSettings.pushNotifications &&
            !appSettings.isPreRelease &&
            appSettings.launches > 0 {
            pushPopUp()
        }

        // Keyboard show or hide on launch
        keyboardToggle.value = appSettings.showKeyboard

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            self.keyboardToggle.callback(self.appSettings.showKeyboard)
        }

        // Increase number of launches
        appSettings.launches += 1
        saveAppSettingValues()

        appendMIDIKnobs(from: generatorsPanel)
        appendMIDIKnobs(from: envelopesPanel)
        appendMIDIKnobs(from: fxPanel)
        appendMIDIKnobs(from: sequencerPanel)
        appendMIDIKnobs(from: devViewController)
        appendMIDIKnobs(from: tuningsPanel)

        setupLinkStuff()
    }

    // Make edge gestures more responsive
    public override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return UIRectEdge.all
    }

    private func appendMIDIKnobs(from controller: UIViewController) {
        for view in controller.view.subviews {
            guard let midiKnob = view as? MIDIKnob else { continue }
            midiKnobs.append(midiKnob)
        }
    }
    func stopAllNotes() {
        self.keyboardView.allNotesOff()
        conductor.synth.stopAllNotes()
    }

    override func updateUI(_ parameter: S1Parameter, control inputControl: S1Control?, value: Double) {

        // Even though isMono is a dsp parameter it needs special treatment because this vc's state depends on it
        guard let s = conductor.synth else {
            AKLog("ParentViewController can't update global UI because synth is not instantiated")
            return
        }
        let isMono = s.getSynthParameter(.isMono)

        if isMono != monoButton.value {
            monoButton.value = isMono
            self.keyboardView.polyphonicMode = isMono > 0 ? false : true
		
        }

        if parameter == .cutoff {
            if inputControl === modWheelPad || activePreset.modWheelRouting != 0 {
                return
            }
            let mmin = 40.0
            let mmax = 7_600.0
            let scaledValue01 = (0...1).clamp(1 - ((log(value) - log(mmin)) / (log(mmax) - log(mmin))))
            modWheelPad.setVerticalValue01(scaledValue01)
        }
    }

    func dependentParameterDidChange(_ dependentParameter: DependentParameter) {
        switch dependentParameter.parameter {

        case .lfo1Rate:
            if dependentParameter.payload == conductor.lfo1RateModWheelID {
                return
            }
            if activePreset.modWheelRouting == 1 {
                modWheelPad.setVerticalValue01(Double(dependentParameter.normalizedValue))
            }

        case .lfo2Rate:
            if dependentParameter.payload == conductor.lfo2RateModWheelID {
                return
            }
            if activePreset.modWheelRouting == 2 {
                modWheelPad.setVerticalValue01(Double(dependentParameter.normalizedValue))
            }

        case .pitchbend:
            if dependentParameter.payload == conductor.pitchBendID {
                return
            }
            pitchBend.setVerticalValue01(Double(dependentParameter.normalizedValue))

        default:
            _ = 0
        }
    }
}

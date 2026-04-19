//
//  CompanionPanelSoundFeedback.swift
//  claude-cursor
//
//  Short UI feedback clips for the menu bar companion panel only (not for
//  programmatic state changes from other surfaces).
//

import AVFoundation

@MainActor
final class CompanionPanelSoundFeedback {
    static let shared = CompanionPanelSoundFeedback()

    private var enterSoundPlayer: AVAudioPlayer?
    private var eshopSoundPlayer: AVAudioPlayer?

    private init() {}

    func playEnterSound() {
        playBundledMP3(named: "enter", player: &enterSoundPlayer)
    }

    func playEshopSound() {
        playBundledMP3(named: "eshop", player: &eshopSoundPlayer)
    }

    private func playBundledMP3(named resourceName: String, player: inout AVAudioPlayer?) {
        if player == nil {
            guard let soundFileURL = Bundle.main.url(forResource: resourceName, withExtension: "mp3") else {
                return
            }
            do {
                let audioPlayer = try AVAudioPlayer(contentsOf: soundFileURL)
                audioPlayer.prepareToPlay()
                player = audioPlayer
            } catch {
                return
            }
        }
        guard let audioPlayer = player else { return }
        audioPlayer.stop()
        audioPlayer.currentTime = 0
        audioPlayer.play()
    }
}

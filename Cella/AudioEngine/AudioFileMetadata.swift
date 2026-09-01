//
//  AudioFileMetadata.swift
//  Cella
//
//  Real audio file metadata (bitrate, sample rate, format) extracted via AVAsset
//  for the Quality / Bitrate pills in the NowPlayingBar.
//

import Foundation
import AVFoundation

struct AudioFileMetadata: Equatable {
    /// Estimated bitrate in kilobits per second, when available.
    let bitrateKbps: Int?

    /// Sample rate in Hz.
    let sampleRateHz: Double?

    /// Human-readable codec/brand (e.g. "AAC", "FLAC", "ALAC", "MP3").
    let codec: String?

    /// Duration in seconds.
    let duration: Double?

    var bitrateLabel: String? {
        guard let bitrateKbps else { return nil }
        return "\(bitrateKbps)kbps"
    }

    var sampleRateLabel: String? {
        guard let sampleRateHz else { return nil }
        let khz = sampleRateHz / 1000
        return khz == khz.rounded() ? "\(Int(khz))kHz" : String(format: "%.1fkHz", khz)
    }

    /// Coarse quality classification from bitrate + codec.
    var qualityLabel: String {
        if let codec = codec?.uppercased() {
            if codec.contains("FLAC") || codec.contains("ALAC") { return "Lossless" }
        }
        guard let bitrateKbps else { return "Standard" }
        switch bitrateKbps {
        case 1411...:
            return "Lossless"
        case 320...:
            return "High"
        case 192...:
            return "Good"
        case 128...:
            return "Standard"
        default:
            return "Low"
        }
    }

    var hasData: Bool {
        bitrateKbps != nil || sampleRateHz != nil || codec != nil
    }
}

enum AudioFileMetadataLoader {
    /// Loads metadata for a local audio file asynchronously.
    static func load(for url: URL) async -> AudioFileMetadata {
        let asset = AVURLAsset(url: url)
        var bitrate: Int?
        var sampleRate: Double?
        var codec: String?
        var duration: Double?

        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            duration = nil
        }

        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if let track = tracks.first {
                do {
                    let descs = try await track.load(.formatDescriptions)
                    if let audioDesc = descs.compactMap({ $0 as? CMAudioFormatDescription }).first,
                       let ascb = audioDesc.audioStreamBasicDescription {
                        sampleRate = ascb.mSampleRate
                        codec = codecName(for: ascb.mFormatID)
                    }
                    let dataRate = try await track.load(.estimatedDataRate)
                    if dataRate > 0 { bitrate = Int(dataRate / 1000) }
                } catch {
                    // fall through
                }
            }
        } catch {
            // fall through
        }

        return AudioFileMetadata(
            bitrateKbps: bitrate,
            sampleRateHz: sampleRate,
            codec: codec,
            duration: duration
        )
    }

    private static func codecName(for fourCC: FourCharCode) -> String? {
        switch fourCC {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAMR: return "AMR"
        default:
            let c1 = (fourCC >> 24) & 0xFF
            let c2 = (fourCC >> 16) & 0xFF
            let c3 = (fourCC >> 8) & 0xFF
            let c4 = fourCC & 0xFF
            if c1 > 32, c2 > 32, c3 > 32, c4 > 32,
               let s = String(bytes: [UInt8(c1), UInt8(c2), UInt8(c3), UInt8(c4)], encoding: .ascii) {
                return s
            }
            return nil
        }
    }
}

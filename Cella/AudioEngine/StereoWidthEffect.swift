//
//  StereoWidthEffect.swift
//  Cella
//
//  Real-time M/S stereo width processor — replaces the old player-swap
//  widen system. Processes the live output buffer in-place:
//
//      mid = (L + R) * 0.5
//      side = (L - R) * 0.5 * width
//      L' = mid + side
//      R' = mid - side
//
//  width = 1.0 → original stereo.  width = 2.0 → full M/S decode.
//  No player swapping, no silent gaps, no crossfade/seek conflicts.
//

import AVFoundation

enum StereoWidthEffect {

    /// Current width factor. Updated by the ramp timer before each render.
    /// 1.0 = unmodified stereo, >1 = wider image.
    static var currentWidth: Float = 1.0

    /// Processes an AVAudioPCMBuffer in-place for stereo widening.
    static func process(_ buffer: AVAudioPCMBuffer) {
        guard currentWidth != 1.0 else { return }

        let width = currentWidth
        let fmt = buffer.format

        if fmt.channelCount == 2, let chData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            let l = chData[0]
            let r = chData[1]
            for i in 0..<frames {
                let lv = l[i]
                let rv = r[i]
                let mid = (lv + rv) * 0.5
                let side = (lv - rv) * 0.5 * width
                l[i] = mid + side
                r[i] = mid - side
            }
        } else if fmt.channelCount == 1, let chData = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            let m = chData[0]
            for i in 0..<frames {
                m[i] = m[i] * (1.0 + width * 0.5)
            }
        }
    }
}

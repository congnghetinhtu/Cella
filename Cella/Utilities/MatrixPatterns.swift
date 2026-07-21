//
//  MatrixPatterns.swift
//  Cella
//
//  Predefined dot matrix patterns for the emotion screen.
//  Each pattern is a 2D array of Bool (rows × columns).
//  `true` = active dot (#D9D9D9), `false` = inactive dot (#333333).
//

import Foundation

enum MatrixPatterns {
    /// Grid dimensions
    static let rows = 5
    static let columns = 9

    /// Normal Smiley Face
    static let smileyFace: [[Bool]] = [
        [false, false, false, false, false, false, false, false, false],
        [false, false, true,  false, false, false, true,  false, false],
        [false, false, false, false, false, false, false, false, false],
        [false, true,  false, false, false, false, false, true,  false],
        [false, false, true,  true,  true,  true,  true,  false, false],
    ]
    
    /// Smiley Face Blinking (Eyes closed)
    static let smileyBlink: [[Bool]] = [
        [false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false],
        [false, true,  false, false, false, false, false, true,  false],
        [false, false, true,  true,  true,  true,  true,  false, false],
    ]
    
    /// Singing / Humming State 1 (Small 'O' mouth)
    static let smileySing1: [[Bool]] = [
        [false, false, false, false, false, false, false, false, false],
        [false, false, true,  false, false, false, true,  false, false],
        [false, false, false, false, false, false, false, false, false],
        [false, false, false, false, true,  false, false, false, false],
        [false, false, false, true,  false, true,  false, false, false],
    ]
    
    /// Singing / Humming State 2 (Wide open mouth)
    static let smileySing2: [[Bool]] = [
        [false, false, false, false, false, false, false, false, false],
        [false, false, true,  false, false, false, true,  false, false],
        [false, false, false, false, false, false, false, false, false],
        [false, false, true,  true,  true,  true,  true,  false, false],
        [false, false, false, true,  true,  true,  false, false, false],
    ]
    
    /// Skip Forward Pattern (Next Track Icon)
    static let skipForward: [[Bool]] = [
        [false, false, false, false, false, false, false, false, false],
        [false, true,  false, false, true,  false, false, true,  false],
        [false, false, true,  false, false, true,  false, true,  false],
        [false, true,  false, false, true,  false, false, true,  false],
        [false, false, false, false, false, false, false, false, false],
    ]
    
    /// Skip Backward Pattern (Previous Track Icon)
    static let skipBackward: [[Bool]] = [
        [false, false, false, false, false, false, false, false, false],
        [false, true,  false, false, true,  false, false, true,  false],
        [false, true,  false, true,  false, false, true,  false, false],
        [false, true,  false, false, true,  false, false, true,  false],
        [false, false, false, false, false, false, false, false, false],
    ]

    /// Analyzing Pattern (pulsing dots)
    static let analyzing: [[Bool]] = [
        [false, true,  false, false, true,  false, false, true,  false],
        [false, false, false, false, false, false, false, false, false],
        [true,  false, true,  false, true,  false, true,  false, true ],
        [false, false, false, false, false, false, false, false, false],
        [false, true,  false, false, true,  false, false, true,  false],
    ]

    /// AutoMix Pattern (two faces overlapping)
    static let autoMix: [[Bool]] = [
        [false, false, true,  false, false, false, true,  false, false],
        [false, true,  false, false, false, false, false, true,  false],
        [false, false, true,  false, false, false, true,  false, false],
        [false, true,  false, true,  false, true,  false, true,  false],
        [false, false, true,  true,  true,  true,  true,  false, false],
    ]

    /// Loading Pattern (sequential dots)
    static let loading: [[Bool]] = [
        [true,  false, false, false, false, false, false, false, false],
        [false, true,  false, false, false, false, false, false, false],
        [false, false, true,  false, false, false, false, false, false],
        [false, false, false, true,  false, false, false, false, false],
        [false, false, false, false, true,  false, false, false, false],
    ]

    // MARK: - Mood Patterns (4 frames each for smooth sequential animation)

    // Energetic / Happy — excited bouncing face
    static let moodEnergeticHappy: [[[Bool]]] = [
        [ // frame 0: big grin, eyes wide (excited!)
            [false, true,  false, false, false, false, false, true,  false],
            [true,  false, false, false, false, false, false, false, true ],
            [false, false, false, false, false, false, false, false, false],
            [true,  true,  true,  true,  true,  true,  true,  true,  true ],
            [false, true,  true,  true,  true,  true,  true,  true,  false],
        ],
        [ // frame 1: eyes squint, mouth wide open (laughing)
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, true,  true,  true,  true,  true,  true,  true,  false],
            [false, false, true,  true,  true,  true,  true,  false, false],
        ],
        [ // frame 2: eyes pop open, mouth O (surprise!)
            [true,  false, false, false, false, false, false, false, true ],
            [false, true,  false, false, false, false, false, true,  false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, true,  true,  true,  false, false, false],
            [false, false, false, false, true,  false, false, false, false],
        ],
        [ // frame 3: big grin, eyes half (happy sigh)
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [true,  true,  true,  true,  true,  true,  true,  true,  true ],
            [false, true,  true,  true,  true,  true,  true,  true,  false],
        ],
    ]

    // Energetic / Angry — shaking eyes, frown, fast
    static let moodEnergeticAngry: [[[Bool]]] = [
        [ // frame 0: angry eyes, frown
            [true,  true,  false, false, false, false, false, true,  true ],
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, true,  true,  false, false, false, true,  true,  false],
        ],
        [ // frame 1: eyes wide, mouth tight
            [false, true,  true,  false, false, false, true,  true,  false],
            [true,  false, false, true,  false, true,  false, false, true ],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  false, false, false, true,  false, false],
        ],
        [ // frame 2: eyes squint, frown deep
            [true,  true,  true,  false, false, false, true,  true,  true ],
            [false, false, false, true,  false, true,  false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [true,  false, false, true,  true,  true,  false, false, true ],
        ],
        [ // frame 3: eyes open, mouth open
            [false, false, true,  false, false, false, true,  false, false],
            [true,  true,  false, false, false, false, false, true,  true ],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  true,  true,  true,  true,  false, false],
        ],
    ]

    // Calm / Happy — slow blink, gentle smile, slow
    static let moodCalmHappy: [[[Bool]]] = [
        [ // frame 0: eyes open, smile
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  true,  true,  true,  true,  false, false],
        ],
        [ // frame 1: eyes half, smile wider
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, true,  false, true,  false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, true,  false, true,  true,  true,  false, true,  false],
        ],
        [ // frame 2: eyes closed, smile same
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, true,  false, true,  true,  true,  false, true,  false],
        ],
        [ // frame 3: eyes open, smile soft
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  true,  true,  true,  true,  false, false],
        ],
    ]

    // Calm / Sad — teardrop falling, slow
    static let moodCalmSad: [[[Bool]]] = [
        [ // frame 0: teardrop at eye
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, true,  false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, true,  false, false, false, false, false, true,  false],
        ],
        [ // frame 1: teardrop mid
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, true,  false, false, false, false, false],
            [false, true,  false, false, false, false, false, true,  false],
        ],
        [ // frame 2: teardrop at mouth
            [false, false, false, false, false, false, false, false, false],
            [false, false, true,  false, false, false, true,  false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, true,  false, true,  false, true,  false, true,  false],
        ],
        [ // frame 3: teardrop gone, eyes droop
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, true,  false, true,  false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, false, false, false, false, false, false, false, false],
            [false, true,  false, false, false, false, false, true,  false],
        ],
    ]

}

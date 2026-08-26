//
//  AppTab.swift
//  Cella
//
//  Defines the top-level navigation tabs.
//

import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case motions = "Cella Motions"
    case cella = "Cella"
    case enhancedLRC = "Enhanced LRC"
    case config = "Config"

    var id: String { rawValue }
}

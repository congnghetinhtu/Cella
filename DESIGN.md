---
name: Cella
description: macOS music player with living automix console — chameleon themes, soft floating surfaces, reactive dot matrix
colors:
  dark-accent: "#FF8038"
  dark-bg: "#0D0D0D"
  dark-screen: "#231A16"
  dark-dot-inactive: "#3E2D24"
  dark-text-primary: "#D9D9D9"
  dark-text-secondary: "#666666"
  dark-tab-unselected: "#6B4F3A"
  seafoam-accent: "#93E9BE"
  seafoam-bg: "#0D1210"
  seafoam-screen: "#1A2420"
  seafoam-dot-inactive: "#2D3A33"
  seafoam-text-primary: "#D9E8E0"
  seafoam-text-secondary: "#668878"
  seafoam-tab-unselected: "#5A7A6A"
  bipolar-accent: "#FF5C8A"
  bipolar-bg: "#080612"
  bipolar-screen: "#14102A"
  bipolar-dot-inactive: "#1E1830"
  bipolar-text-primary: "#FFF0F5"
  bipolar-text-secondary: "#998AAA"
  bipolar-tab-unselected: "#6A5B88"
  halo-pink: "#FF7EB3"
  halo-lavender: "#8B7EFA"
  halo-sky: "#56CCF2"
  halo-mint: "#6EE7B7"
  halo-yellow: "#FACC15"
  halo-orange: "#FB923C"
  halo-green: "#4ADE80"
  halo-tangerine: "#FF9A5C"
  trail-fire: "#FF8038"
  trail-amber: "#FFAA33"
  trail-crimson: "#FF5533"
  trail-gold: "#FFCC44"
  trail-rust: "#FF6622"
typography:
  display:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "clamp(18pt, 2.5vw, 56pt)"
    fontWeight: 400
    lineHeight: 1.2
  body:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: 1.4
  label:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "12pt"
    fontWeight: 500
    lineHeight: 1.2
  mono:
    fontFamily: "SF Mono, SF Pro, monospaced"
    fontSize: "11pt"
    fontWeight: 500
    lineHeight: 1.3
rounded:
  sm: "5px"
  md: "8px"
  lg: "12px"
  xl: "14px"
  card: "18px"
  capsule: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "16px"
  lg: "28px"
  xl: "40px"
components:
  button-primary:
    backgroundColor: "{colors.dark-accent}"
    textColor: "#FFFFFF"
    rounded: "{rounded.capsule}"
    padding: "14px 32px"
  card:
    backgroundColor: "{colors.dark-screen}"
    textColor: "{colors.dark-text-primary}"
    rounded: "{rounded.card}"
    padding: "28px"
  pill-badge:
    backgroundColor: "{colors.dark-accent}"
    textColor: "#FFFFFF"
    rounded: "{rounded.capsule}"
    padding: "6px 14px"
  tab-pill:
    backgroundColor: "{colors.dark-screen}"
    textColor: "{colors.dark-tab-unselected}"
    rounded: "{rounded.capsule}"
    padding: "10px 18px"
  dot-inactive:
    backgroundColor: "{colors.dark-dot-inactive}"
    textColor: "transparent"
    rounded: "{rounded.capsule}"
    padding: "0"
---

# Design System: Cella

## Overview

**Creative North Star: "The Living Console"**

Cella's visual system is a control surface that breathes. Dark, focused backgrounds host soft floating surfaces that respond to music — the dot matrix pulses, the line visualizer trails, and the color palette shifts entirely between themes. Each theme (Dark, Seafoam, Bipolar) is a distinct personality, not a recolor; the system is chameleon by design.

The aesthetic is nocturnal precision meets organic warmth: deep, near-black backgrounds with carefully calibrated accent colors that feel alive when music flows. Components float above the darkness — soft-edged, gently bounded, never heavy. The dot matrix display is the emotional core: a 9x5 grid of circles that animate between states with spring physics, reacting to player state, mood, and analysis data.

**Key Characteristics:**
- Three chameleon themes that transform personality, not just palette
- Soft floating surfaces with subtle borders over near-black depth
- Reactive dot matrix as emotional feedback center
- Spring-based motion language (snappy for UI, smooth for content)
- High contrast accent on dark — accents appear only when music flows

## Colors

The palette is chameleon: three complete theme worlds (Dark, Seafoam, Bipolar), each with a full set of coordinated surfaces, text, and accent colors. The system switches themes entirely — not just recolors.

### Primary (per theme)

- **Warm Fire** (#FF8038): Dark theme accent. Active dots, selected tabs, progress indicators, button fills. The dominant interactive color — orange glow against charcoal warmth.
- **Seafoam Mist** (#93E9BE): Seafoam theme accent. Same roles — mint glow against cool dark green.
- **Blush** (#FF5C8A): Bipolar theme accent. Pink glow against deep indigo-violet.

### Neutral

- **Deep Void** (#0D0D0D / #0D1210 / #080612): App background. Near-black with warm/cool/violet undertones per theme. The deepest layer — content floats above it.
- **Surface** (#231A16 / #1A2420 / #14102A): Card and screen background. Slightly lifted from void — where cards, panels, and the emotion screen live.
- **Text Primary** (#D9D9D9 / #D9E8E0 / #FFF0F5): High-readability text on dark surfaces.
- **Text Secondary** (#666666 / #668878 / #998AAA): Muted labels, descriptions, status text.
- **Tab Unselected** (#6B4F3A / #5A7A6A / #6A5B88): Inactive tab text — intentionally muted, clearly subordinate to accent.

### Halo and Trail (accent support)

- **Halo colors** — four luminous variants that adapt to theme (pink/lavender/sky/tangerine for colorful; green/mint/yellow/orange for neutral). Used for glow effects, gradient accents, and decorative highlights.
- **Trail palette** — five-color gradient arrays for the line visualizer. Each theme has a distinct trail: warm fire (orange/amber/crimson/gold/rust), ocean (mint/teal/cyan/green/teal), pastel rainbow (pink/tangerine/lavender/sky/mint).

### Named Rules

**The Chameleon Rule.** Theme switching replaces the entire color world — accent, surface, text, halo, trail. Never mix colors across themes; a Dark-theme card must not contain a Seafoam-text element.

**The Accent Scarcity Rule.** The theme accent color (dot active, button fill, selected tab) appears on 15% or less of any given screen. Its glow is the point — flooding the surface with it kills the contrast that makes it alive.

## Typography

**Display Font:** SF Pro (with system fallback)
**Body Font:** SF Pro (with system fallback)
**Mono Font:** SF Mono (for technical readouts, queue metadata, timestamps)

**Character:** System-native, clean, and quiet. The type hierarchy stays invisible — it never competes with the visual system (dot matrix, line visualizer). SF Pro Rounded appears in display contexts (emotion screen labels, mood indicators) for a softer, more organic feel.

### Hierarchy

- **Display** (regular, 18-56pt, line-height 1.2): Mood labels, large status text on emotion screen. Appears only in the player's emotional center.
- **Title** (semibold, 15-18pt, line-height 1.3): Section headers, card titles, prominent labels. The workhorse for hierarchy.
- **Body** (regular, 13pt, line-height 1.4): Descriptions, settings text, secondary content.
- **Label** (medium, 11-12pt, line-height 1.2): Tab labels, badges, metadata, compact UI text.
- **Mono** (medium, 10-11pt, line-height 1.3): Timestamps, queue track numbers, technical indicators, BPM/key readouts.

### Named Rules

**The Silent Hierarchy Rule.** Typography establishes order but never calls attention to itself. Weight and size do the work; color stays within the theme's text palette (primary or secondary). No decorative type treatments.

## Layout

The interface is a vertical stack centered in the window: emotion screen (21:9 aspect ratio container), player indicator, and tab bar. The emotion screen dominates — it is the product. Configuration, queue, and cluster views live in side panels or card grids with consistent 16pt grid spacing.

- **Window:** macOS native, fullscreen-capable, hidden title bar
- **Center column:** Emotion screen (dot matrix or line visualizer) + player indicator
- **Card grid:** 16pt spacing, max-width 800pt for config, 272pt for cluster panels
- **Content padding:** 40pt horizontal, 28pt vertical (config); 28pt horizontal (cluster)
- **Dot matrix:** 9x5 grid, 36pt dot diameter, 24pt spacing between dots
- **Emotion screen:** 21:9 aspect ratio, 16pt corner radius, contains the dot matrix or line visualizer

### Named Rules

**The Center-Stage Rule.** The emotion screen occupies the visual center and the majority of screen real estate. All other UI elements are subordinate — they orbit it, not compete with it.

## Elevation and Depth

No shadows. Depth is conveyed through tonal layering: the darkest layer (app background) sits behind slightly lighter surfaces (cards, screens), which sit behind accent elements (dots, buttons). The gap between layers is small but perceptible — everything feels like it is floating in a dark medium, not stacked on paper.

### Named Rules

**The Floating Surface Rule.** Cards and panels float above the background via color lift alone (background to screen to surface). No drop shadows, no elevation artifacts. The darkness itself provides depth.

## Shapes

Form language is dual-mode: soft rectangles for containers, capsules for interactive elements.

- **Cards:** 14-18pt corner radius, subtle 1pt border at 10% text opacity. Rounded rectangles — not sharp, not fully round.
- **Buttons:** Full capsule (999pt radius). Primary buttons use the theme accent as fill with white text. No border.
- **Pills / Badges:** Capsule shape. Accent fill for active state, surface background for inactive. Small, compact, no decoration.
- **Tab bar:** Capsule container with capsule selection pill. The selection pill slides with a spring animation (snappy: response 0.25, damping 0.8).
- **Dot matrix dots:** Perfect circles (36pt). Active dots show the trail palette color at 90% opacity; inactive dots show the dot-inactive color at 60% opacity.
- **Emotion screen:** 16pt corner radius rounded rectangle, clipped. The screen itself is the largest shape in the interface.

### Named Rules

**The Soft Boundary Rule.** Every bounded element (card, screen, button, pill) has a visible corner radius. Nothing is sharp-edged except thin dividers. The minimum radius is 5pt; the maximum is the capsule for fully rounded controls.

## Components

### Primary Button

- **Shape:** Full capsule (999pt radius)
- **Primary:** Theme accent fill (#FF8038 / #93E9BE / #FF5C8A), white text, 14pt vertical / 32pt horizontal padding
- **Hover/Focus:** Spring animation to full opacity. No scale transform.
- **Disabled:** 50% opacity, no interaction

### Card / Container

- **Corner Style:** 18pt radius (config cards), 12-14pt radius (cluster panels, sub-cards)
- **Background:** Theme surface color (#231A16 / #1A2420 / #14102A)
- **Border:** 1pt stroke at 10% text opacity
- **Shadow Strategy:** None. Tonal lift from app background provides depth.
- **Internal Padding:** 28pt (config cards), 20-28pt (cluster panels)

### Pill / Badge

- **Style:** Capsule shape, theme accent fill, white text
- **Active:** Full accent fill with text
- **Inactive:** Surface background with theme text color (no accent)
- **Sizes:** Small (6pt/14pt padding), Medium (8pt/16pt padding)

### Tab Bar (TopTabBar)

- **Style:** Capsule container on surface background, horizontal pill tabs
- **Typography:** 14pt medium for tab labels, 10-12pt for secondary indicators
- **Default:** Theme unselected text on surface background
- **Hover:** Subtle brightness shift
- **Active:** Selection pill (capsule, accent fill) slides behind the selected tab with spring animation
- **Scroll/Drag:** Trackpad scroll or drag switches tabs with accumulated delta threshold

### Dot Matrix Display

- **Grid:** 9 columns x 5 rows, 36pt dots, 24pt spacing
- **Active dot:** Trail palette color (cycling through 5 colors per theme), 90% opacity
- **Inactive dot:** Theme dot-inactive color, 60% opacity
- **Animation:** Spring-based (snappy) on state change. Breathing animation when idle. Pulse animation during analysis.
- **Patterns:** 9x5 pixel bitmaps for smiley (normal/blink/sing1/sing2), skip forward/backward, analyzing, autoMix, loading, 4 mood animations (4 frames each)

### Line Visualizer

- **Shape:** Catmull-Rom spline path with energy-reactive trail
- **Trail color:** Smooth interpolation through 5-color trail palette
- **Stars:** Floating particles (8 in colorful theme, 4 in neutral) with twinkle animation
- **Clipping:** 16pt rounded rectangle mask
- **Behavior:** Head position advances with energy-proportional speed. Regenerates path on track change.

### Player Indicator

- **Style:** Centered text, 12pt regular weight, theme secondary text color
- **Height:** 20pt fixed
- **Animation:** Opacity transition (snappy spring)

### Import Button (ConfigView hero)

- **Shape:** Capsule, theme accent fill, white text
- **Icon:** SF Symbol "folder.badge.plus" (16pt medium)
- **Label:** "Import Playlist" (15pt medium)
- **Padding:** 32pt horizontal, 14pt vertical

### Stat Pill (ConfigView)

- **Shape:** Capsule, surface background
- **Icon:** SF Symbol (12pt)
- **Value:** 13pt semibold
- **Label:** 12pt regular, secondary text
- **Padding:** 6pt horizontal, 2pt vertical

## Do's and Don'ts

### Do:

- **Do** keep the emotion screen as the visual center — it is the product, everything else orbits it.
- **Do** use the full theme palette when switching themes — accent, surface, text, halo, trail all change together.
- **Do** use capsule shape for all interactive elements (buttons, pills, badges, selection indicators).
- **Do** use spring animations for UI interactions (snappy: response 0.25, damping 0.8) and content transitions (smooth: response 0.35, damping 0.85).
- **Do** keep accent color scarce — it should glow, not flood.
- **Do** use tonal layering for depth — never shadows.

### Don't:

- **Don't** mix colors across themes. A Dark-theme card must never contain a Seafoam or Bipolar accent.
- **Don't** use drop shadows or elevation artifacts. Depth comes from color lift alone.
- **Don't** use sharp corners on any bounded element. Minimum radius is 5pt; prefer 14-18pt for cards, capsule for controls.
- **Don't** make typography decorative. Weight and size establish hierarchy; color stays within the theme text palette.
- **Don't** compete with the emotion screen. Side panels, config cards, and navigation are subordinate — quieter, smaller, lower contrast.
- **Don't** use accent color for large background fills. It is an interactive highlight, not a surface color.

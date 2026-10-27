//
//  FieldViewControl.swift — interlaced I4 in the control bar (docs/INTERLACED_FINDINGS.md §3, §14).
//
//  The field-view pulldown for ONE window, beside the display-transform control and modelled on it: reads this window's
//  `WindowChrome`, writes only through `DeckRegistry.setFieldView`. Shown only while the window's source offers the views
//  (a woven interlaced file); with anything else there is nothing here, so a progressive source's control bar is unchanged.
//
//  ⚠️ EVERY VIEW BUT WEAVE IS DISPLAY ONLY, AND THE BADGE SAYS SO. The scopes, SDI and export read the woven frame; a user
//  looking at one field while the waveform shows two must be told which is which. The badge is a sibling of the menu, not
//  its label, for the Bypass badge's measured reason (a borderless menu strips its label's colours).
//

import SwiftUI
import FileScan

struct FieldViewControl: View {
    let deck: WindowDeck
    @ObservedObject var chrome: WindowChrome

    private var view: FieldView { chrome.fieldView }

    var body: some View {
        HStack(spacing: 5) {
            if let badge = view.badge {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal")
                        .imageScale(.small)
                    Text(badge)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .fixedSize()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.appYellow))
                .foregroundStyle(.black)
                .accessibilityLabel("Window view: \(view.inspectorText(chrome.fieldOrder))")
                .accessibilityIdentifier("fieldViewBadge")
                .accessibilityAddTraits(.isStaticText)
            }
            Menu {
                ForEach(FieldView.allCases, id: \.self) { v in
                    if v == .field1 { Divider() }
                    Toggle(isOn: binding(for: v)) {
                        Text(DisplayTransformControl.rowLabel(v.menuTitle, v.detail(chrome.fieldOrder)))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal")
                    Text(view.menuTitle)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .fixedSize()
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("fieldViewControl")
            .accessibilityLabel("Fields: \(view.menuTitle)")
        }
        .help(view == .weave
              ? "Fields: Weave — both fields woven, as stored"
              : "Fields: \(view.inspectorText(chrome.fieldOrder)). Scopes, SDI and export read the woven frame.")
    }

    private func binding(for v: FieldView) -> Binding<Bool> {
        Binding(
            get: { view == v },
            set: { isOn in
                guard isOn else { return }   // unchecking a radio item is not a command
                DeckRegistry.shared.setFieldView(v, on: deck)
            }
        )
    }
}

/// The on-picture marker (§14.8, Robbie's decision 7, 2026-10-27): the field view's name in the picture's top-trailing
/// corner while a field view is on, so it is there in full screen and with the controls hidden, where the badge is not.
///
/// ⚠️ SWIFTUI, ON THE PICTURE SURFACE'S OVERLAY, NEVER METAL. ContentView attaches it beside the framing guides, whose bounds
/// are the displayed picture rect; it is not in the HUD, so hiding the controls leaves it. Drawn over the drawable by the
/// window server, it cannot reach the offscreen ring, the scopes, the v210 convert or the export.
struct FieldViewMarker: View {
    @ObservedObject var chrome: WindowChrome

    private var marker: String? { chrome.fieldViewOffered ? chrome.fieldView.marker : nil }

    var body: some View {
        Group {
            if let marker {
                text(marker)
            }
        }
        // One line per change, Field 1 → Field 2 included (the view's identity survives a text change, so onAppear
        // would log only the first).
        .onChange(of: marker) { _, new in
            print(new.map { "[FIELDS] marker shown — \($0) (window only)" } ?? "[FIELDS] marker hidden")
        }
    }

    private func text(_ marker: String) -> some View {
        Text(marker)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.appYellow)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
            .opacity(0.85)
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityLabel("Field view marker: \(marker)")
            .accessibilityIdentifier("fieldViewMarker")
            .accessibilityAddTraits(.isStaticText)
    }
}

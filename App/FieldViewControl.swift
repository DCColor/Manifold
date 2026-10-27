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

// MIT License
// Copyright (c) 2021-2026 LinearMouse

import SwiftUI

struct ScrollingSettings: View {
    @ObservedObject private var state = ScrollingSettingsState.shared

    var body: some View {
        DetailView {
            VStack(alignment: .leading) {
                Header()

                Form {
                    if state.direction == .horizontal {
                        Section(header: Text("Default Action")) {
                            Picker("Horizontal wheel", selection: $state.horizontalAction) {
                                Text("Side-scrolling").tag(Scheme.Scrolling.HorizontalAction.scroll)
                                Text("Pinch zoom").tag(Scheme.Scrolling.HorizontalAction.pinchZoom)
                                Text("Pinch zoom (reversed)").tag(Scheme.Scrolling.HorizontalAction.pinchZoomReversed)
                            }
                            .modifier(PickerViewModifier())
                        }
                        .modifier(SectionViewModifier())
                    }

                    ReverseScrollingSection()

                    if state.showsHighResolutionWheelControl {
                        LogitechHighResolutionWheelSection()
                    }

                    ScrollingModeSection()

                    ModifierKeysSection()
                }
                .modifier(FormViewModifier())
            }
        }
        .onAppear {
            state.refreshHighResolutionWheelInfo()
        }
    }
}

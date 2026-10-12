import SwiftUI
import MacroSIPCore

/// 8.7 Auto-answer: mode, delay, honour Call-Info answer-after.
struct AutoAnswerPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneContainer {
            FormGroup(content: {
                FormRow(label: L.autoAnswerMode) {
                    SegmentedTabs(items: [
                        .init(value: AutoAnswerMode.off, title: L.autoAnswerOff),
                        .init(value: AutoAnswerMode.all, title: L.autoAnswerAll),
                        .init(value: AutoAnswerMode.contactsOnly, title: L.autoAnswerContactsOnly),
                    ], selection: model.binding(\.autoAnswer.mode))
                    .frame(width: 270)
                }
                FormDivider()
                FormRow(label: L.autoAnswerDelay) {
                    HStack(spacing: 6) {
                        NumberStepperField(value: model.binding(\.autoAnswer.delaySeconds), width: 44,
                                           isValid: { (1...60).contains($0) },
                                           step: { min(60, max(1, $0 + $1)) })
                        Text(L.unitSeconds).font(.system(size: 12)).foregroundStyle(Theme.label2)
                    }
                }
                FormDivider()
                FormRow(label: L.autoAnswerHonour, help: L.autoAnswerHonourHelp) {
                    Toggle("", isOn: model.binding(\.autoAnswer.honourCallInfo)).labelsHidden().toggleStyle(.switch)
                }
            }, footerView: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.autoAnswerFooter).fixedSize(horizontal: false, vertical: true)
                    Text(L.autoAnswerServerOnly).fixedSize(horizontal: false, vertical: true)
                }
            })
        }
    }
}

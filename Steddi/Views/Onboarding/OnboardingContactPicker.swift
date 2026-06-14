import SwiftUI
import ContactsUI
import Contacts

/// Bridges `CNContactPickerViewController` into SwiftUI for the onboarding
/// emergency-contact beat.
///
/// Presented via `.sheet`; the wrapper restricts the picker to contacts that
/// actually have a phone number and pulls the first number off the selection.
/// `onPicked` fires with the chosen number (or `nil` if the user cancelled),
/// and the wrapper dismisses itself either way.
///
/// Named `Onboarding…` to stay clear of any other contact-picker bridge.
struct OnboardingContactPicker: UIViewControllerRepresentable {
    /// Called with the selected phone number, or `nil` on cancel.
    var onPicked: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Only surface contacts with at least one phone number, and pre-select
        // the number property so a tap returns a phone-bearing contact.
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    /// Delegate callbacks arrive on the main thread from UIKit, but the protocol
    /// itself isn't main-actor-isolated, so the methods are `nonisolated` and hop
    /// onto the main actor before touching the SwiftUI-facing closure.
    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPicked: @MainActor (String?) -> Void

        init(onPicked: @escaping @MainActor (String?) -> Void) {
            self.onPicked = onPicked
        }

        nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let number = contact.phoneNumbers.first?.value.stringValue
            let cb = onPicked
            Task { @MainActor in cb(number) }
        }

        nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            let cb = onPicked
            Task { @MainActor in cb(nil) }
        }
    }
}

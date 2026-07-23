import SwiftUI
import UIKit

/// Installs a non-blocking window gesture that dismisses the keyboard when a
/// tap lands outside any text input. The gesture does not consume the tap, so
/// buttons, sliders, menus, and list rows keep their normal behavior.
struct KeyboardDismissController: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let window = uiView.window else { return }
            if context.coordinator.gesture?.view === window { return }
            if let existing = context.coordinator.gesture {
                existing.view?.removeGestureRecognizer(existing)
            }

            let gesture = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.dismissKeyboard)
            )
            gesture.cancelsTouchesInView = false
            gesture.delegate = context.coordinator
            window.addGestureRecognizer(gesture)
            context.coordinator.gesture = gesture
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let gesture = coordinator.gesture {
            gesture.view?.removeGestureRecognizer(gesture)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        fileprivate weak var gesture: UITapGestureRecognizer?

        @objc fileprivate func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView {
                    return false
                }
                view = current.superview
            }
            return true
        }
    }
}

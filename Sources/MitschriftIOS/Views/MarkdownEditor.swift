import SwiftUI
import UIKit

/// Markdown-Editor für das Protokoll auf Basis von `UITextView`, damit die Formatierungsleiste über
/// der Tastatur an der Cursorposition arbeiten kann (SwiftUI-`TextEditor` kennt unter iOS 17 keine Auswahl).
struct MarkdownEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(Theme.paper)
        view.tintColor = UIColor(Theme.coral)
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .default
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.textContainerInset = UIEdgeInsets(top: 12, left: Theme.gutter - 5, bottom: 24, right: Theme.gutter - 5)
        view.inputAccessoryView = context.coordinator.makeToolbar()
        view.text = text
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        weak var textView: UITextView?

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        /// Formatierungsleiste: Überschrift, Aufzählung, Aufgabe, fett, kursiv, Tastatur schließen.
        func makeToolbar() -> UIToolbar {
            let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            toolbar.barTintColor = UIColor(Theme.ink)
            toolbar.tintColor = UIColor(Theme.paper)
            toolbar.isTranslucent = false
            func item(_ title: String, _ selector: Selector, label: String) -> UIBarButtonItem {
                let item = UIBarButtonItem(title: title, style: .plain, target: self, action: selector)
                item.accessibilityLabel = label
                return item
            }
            let bold = item("B", #selector(bold), label: "Fett")
            bold.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 17, weight: .bold)], for: .normal)
            let italic = item("I", #selector(italic), label: "Kursiv")
            italic.setTitleTextAttributes([.font: UIFont.italicSystemFont(ofSize: 17)], for: .normal)
            toolbar.items = [
                item("Überschrift", #selector(heading), label: "Überschrift"),
                .fixedSpace(12),
                item("•", #selector(bullet), label: "Aufzählung"),
                .fixedSpace(12),
                item("☐", #selector(task), label: "Aufgabe"),
                .fixedSpace(12),
                bold,
                .fixedSpace(12),
                italic,
                .flexibleSpace(),
                UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self, action: #selector(dismissKeyboard)),
            ]
            return toolbar
        }

        @objc private func heading() { setLinePrefix("## ") }
        @objc private func bullet() { setLinePrefix("- ") }
        @objc private func task() { setLinePrefix("- [ ] ") }
        @objc private func bold() { wrapSelection(with: "**") }
        @objc private func italic() { wrapSelection(with: "_") }
        @objc private func dismissKeyboard() { textView?.resignFirstResponder() }

        /// Setzt den Zeilenanfang der aktuellen Zeile auf das Präfix; ein vorhandenes Präfix wird ersetzt,
        /// dasselbe Präfix entfernt (Umschalten).
        private func setLinePrefix(_ prefix: String) {
            guard let textView, let text = textView.text as NSString? else { return }
            let selection = textView.selectedRange
            let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
            var line = text.substring(with: lineRange)
            let newline = line.hasSuffix("\n")
            if newline { line.removeLast() }
            let known = ["- [x] ", "- [X] ", "- [ ] ", "- ", "* ", "### ", "## ", "# "]
            var body = line
            var existing = ""
            if let found = known.first(where: { line.hasPrefix($0) }) {
                existing = found
                body = String(line.dropFirst(found.count))
            }
            let replacement = (existing == prefix ? body : prefix + body) + (newline ? "\n" : "")
            textView.textStorage.replaceCharacters(in: lineRange, with: replacement)
            let delta = replacement.utf16.count - lineRange.length
            textView.selectedRange = NSRange(location: max(lineRange.location, selection.location + delta), length: 0)
            textViewDidChange(textView)
        }

        /// Umschließt die Auswahl mit dem Zeichen; ohne Auswahl wird ein Paar eingefügt und der Cursor dazwischen gesetzt.
        private func wrapSelection(with marker: String) {
            guard let textView, let text = textView.text as NSString? else { return }
            let selection = textView.selectedRange
            let selected = text.substring(with: selection)
            if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.count >= marker.count * 2 {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                textView.textStorage.replaceCharacters(in: selection, with: inner)
                textView.selectedRange = NSRange(location: selection.location, length: inner.utf16.count)
            } else {
                textView.textStorage.replaceCharacters(in: selection, with: marker + selected + marker)
                textView.selectedRange = NSRange(location: selection.location + marker.utf16.count, length: selected.utf16.count)
            }
            textViewDidChange(textView)
        }
    }
}

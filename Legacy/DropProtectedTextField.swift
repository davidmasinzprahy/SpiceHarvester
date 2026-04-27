//
//  DropProtectedTextField.swift
//  SpiceHarvester
//
//  Created by David Mašín on 26.06.2025.
//

import SwiftUI
import AppKit

struct DropProtectedTextField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.stringValue = text
        tf.isEditable = true
        tf.isBezeled = true
        tf.drawsBackground = true
        tf.isSelectable = true

        // Zakázat přímý drag & drop
        tf.unregisterDraggedTypes()

        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DropProtectedTextField

        init(_ parent: DropProtectedTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }
    }
}

import SwiftUI

struct NoteRenameConflictDialogModifier: ViewModifier {
    @Binding var conflict: NoteRenameConflict?
    let onResolve: (RenameConflictResolution) -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "目标位置已有同名笔记",
            isPresented: Binding(
                get: { conflict != nil },
                set: { if !$0 { conflict = nil } }
            ),
            presenting: conflict
        ) { _ in
            Button("保留两者") { onResolve(.keepBoth) }
                .accessibilityIdentifier("rename-keep-both")
            Button("覆盖已有笔记", role: .destructive) { onResolve(.replace) }
                .accessibilityIdentifier("rename-replace")
            Button("取消", role: .cancel) { onCancel() }
                .accessibilityIdentifier("rename-cancel")
        } message: { value in
            Text("“\((value.targetPath as NSString).lastPathComponent)”已经存在。")
        }
    }
}

extension View {
    func noteRenameConflictDialog(
        conflict: Binding<NoteRenameConflict?>,
        onResolve: @escaping (RenameConflictResolution) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(NoteRenameConflictDialogModifier(
            conflict: conflict,
            onResolve: onResolve,
            onCancel: onCancel
        ))
    }
}

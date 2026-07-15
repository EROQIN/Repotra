import SwiftUI

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renameTarget: NoteNode?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索标题、路径和正文", text: Binding(
                    get: { model.searchQuery },
                    set: { model.setSearchQuery($0) }
                ))
                .textFieldStyle(.plain)
                if !model.searchQuery.isEmpty {
                    Button { model.setSearchQuery("") } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 10)

            if model.searchQuery.isEmpty {
                List(selection: $model.selectedPath) {
                    OutlineGroup(model.tree, children: \.children) { node in
                        sidebarRow(node)
                    }
                }
                .onChange(of: model.selectedPath) { _, path in
                    guard let path, model.selectedNode?.isDirectory == false else { return }
                    Task { await model.select(path: path) }
                }
            } else if model.searchResults.isEmpty {
                ContentUnavailableView.search(text: model.searchQuery)
            } else {
                List(model.searchResults) { result in
                    Button {
                        Task { await model.select(path: result.relativePath) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).fontWeight(.medium)
                            Text(result.relativePath).font(.caption).foregroundStyle(.secondary)
                            Text(result.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.45)
            HStack(spacing: 14) {
                Button { Task { await model.createNote() } } label: {
                    Label("新建笔记", systemImage: "square.and.pencil")
                }
                Button { Task { await model.createFolder() } } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("新建文件夹")
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 42)
        }
        .background(.bar)
        .sheet(item: $renameTarget) { node in
            VStack(alignment: .leading, spacing: 16) {
                Text("重命名").font(.headline)
                TextField("名称", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(node) }
                HStack {
                    Spacer()
                    Button("取消") { renameTarget = nil }
                    Button("重命名") { commitRename(node) }
                        .buttonStyle(.borderedProminent)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 380)
        }
    }

    private func sidebarRow(_ node: NoteNode) -> some View {
        Label(node.title, systemImage: node.isDirectory ? "folder" : "doc.text")
            .tag(node.relativePath)
            .contentShape(Rectangle())
            .draggable(node.relativePath)
            .dropDestination(for: String.self) { paths, _ in
                guard node.isDirectory, let path = paths.first, path != node.relativePath else { return false }
                Task { await model.move(path: path, into: node.relativePath) }
                return true
            }
            .contextMenu {
                if node.isDirectory {
                    Button("新建笔记") { Task { await model.createNote(in: node.relativePath) } }
                    Button("新建文件夹") { Task { await model.createFolder(in: node.relativePath) } }
                    Divider()
                } else {
                    Button(model.stickyWindows.pinnedPaths.contains(node.relativePath) ? "取消钉住" : "钉到桌面") {
                        Task {
                            await model.select(path: node.relativePath)
                            await model.togglePinnedSelectedNote()
                        }
                    }
                    Divider()
                }
                Button("重命名…") {
                    renameText = node.name
                    renameTarget = node
                }
                Button("移到废纸篓", role: .destructive) { Task { await model.delete(path: node.relativePath) } }
            }
    }

    private func commitRename(_ node: NoteNode) {
        let value = renameText
        renameTarget = nil
        Task { await model.rename(path: node.relativePath, to: value) }
    }
}

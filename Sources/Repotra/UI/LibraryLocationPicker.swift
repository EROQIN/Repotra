import SwiftUI

struct LibraryLocationPicker: View {
    @Environment(AppModel.self) private var model
    @State private var currentURL = FileManager.default.homeDirectoryForCurrentUser
    @State private var directories: [URL] = []
    @State private var newFolderName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            directoryList
            Divider()
            newFolderRow
            Divider()
            actionRow
        }
        .frame(width: 680, height: 520)
        .onAppear {
            if let libraryURL = model.libraryURL {
                currentURL = libraryURL
            }
            reload()
        }
        .alert("无法访问文件夹", isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择 Repotra 资料库")
                .font(.title2.bold())
            HStack {
                Button {
                    navigate(to: currentURL.deletingLastPathComponent())
                } label: {
                    Label("上一级", systemImage: "chevron.up")
                }
                .disabled(currentURL.path == "/")

                Button {
                    navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                } label: {
                    Label("个人文件夹", systemImage: "house")
                }

                Text(currentURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var directoryList: some View {
        Group {
            if directories.isEmpty {
                ContentUnavailableView(
                    "没有子文件夹",
                    systemImage: "folder",
                    description: Text("可以选择当前文件夹，或在下方新建文件夹。")
                )
            } else {
                List(directories, id: \.standardizedFileURL) { url in
                    Button {
                        navigate(to: url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "folder.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RepotraHoverButtonStyle())
                    .accessibilityLabel("打开文件夹 \(url.lastPathComponent)")
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newFolderRow: some View {
        HStack {
            TextField("新文件夹名称", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createFolder)
            Button("新建文件夹", action: createFolder)
                .disabled(trimmedFolderName.isEmpty)
        }
        .padding(16)
    }

    private var actionRow: some View {
        HStack {
            Text("Markdown 文件和 Repotra 配置会保存在所选文件夹中。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消", role: .cancel) { model.dismissLibraryPicker() }
                .keyboardShortcut(.cancelAction)
            Button("使用此文件夹") {
                let url = currentURL
                Task { await model.selectLibrary(url) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var trimmedFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func navigate(to url: URL) {
        currentURL = url.standardizedFileURL
        reload()
    }

    private func reload() {
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .localizedNameKey]
            directories = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            .filter { url in
                (try? url.resourceValues(forKeys: keys).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            directories = []
            errorMessage = error.localizedDescription
        }
    }

    private func createFolder() {
        let name = trimmedFolderName
        guard !name.isEmpty, !name.contains("/") else { return }
        let url = currentURL.appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            newFolderName = ""
            navigate(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

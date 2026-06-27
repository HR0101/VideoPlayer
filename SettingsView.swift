import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appSettings: AppSettings
    @State private var newExcludedWord: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("プレイヤー画面設定").foregroundStyle(Color.appGold)) {
                    Picker("動画リストの表示形式", selection: $appSettings.upNextDisplayStyle) {
                        Text("自動 (画面幅に応じる)").tag(0)
                        Text("リスト表示").tag(1)
                        Text("グリッド表示").tag(2)
                    }
                    
                    Toggle("デフォルトで「同じアルバム」のみ表示", isOn: $appSettings.showSameAlbumOnlyDefault)
                        .tint(Color.appGold)
                        
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ショート動画の表示サイズ: \(Int(appSettings.shortsVideoFillScale * 100))%")
                        Slider(value: $appSettings.shortsVideoFillScale, in: 0.0...1.0)
                            .tint(Color.appGold)
                        HStack {
                            Text("横幅全画面").font(.caption).foregroundStyle(.gray)
                            Spacer()
                            Text("縦全画面").font(.caption).foregroundStyle(.gray)
                        }
                    }
                }
                .listRowBackground(Color.appDarkSurface)
                
                Section(header: Text("タイトル表示設定").foregroundStyle(Color.appGold), footer: Text("指定した文字列が含まれる場合、タイトルから除外します。").foregroundStyle(.gray)) {
                    HStack {
                        TextField("除外する文字列を追加 (例: IMG_)", text: $newExcludedWord)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .onSubmit {
                                addExcludedWord()
                            }
                        Button(action: addExcludedWord) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.appGold)
                        }
                    }
                    
                    ForEach(appSettings.excludedTitleWords, id: \.self) { word in
                        Text(word)
                            .foregroundStyle(.white)
                    }
                    .onDelete { indexSet in
                        appSettings.excludedTitleWords.remove(atOffsets: indexSet)
                    }
                }
                .listRowBackground(Color.appDarkSurface)
                Section(header: Text("サムネイル生成").foregroundStyle(Color.appGold)) {
                    Picker("サムネイルの取得位置", selection: $appSettings.thumbnailOption) {
                        ForEach(ThumbnailOption.allCases) { option in
                            Text(option.description).tag(option)
                        }
                    }
                }
                .listRowBackground(Color.appDarkSurface)
            }
            .navigationTitle("設定")
            .scrollContentBackground(.hidden)
            .background(AppBackground())
        }
    }
    
    private func addExcludedWord() {
        let trimmed = newExcludedWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !appSettings.excludedTitleWords.contains(trimmed) {
            appSettings.excludedTitleWords.append(trimmed)
            newExcludedWord = ""
        }
    }
}

import SwiftUI

struct ServerConnectingView: View {
  let title: String

  @EnvironmentObject var serverBrowser: ServerBrowser
  @State private var showNotFound = false
  @State private var searchAttempt = 0

  var body: some View {
    NavigationStack {
      ZStack {
        AppBackground()
        if showNotFound {
          notFoundView
        } else {
          searchingView
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbarBackground(Color.appDarkBackground, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
    }
    .onAppear {
      scheduleNotFoundFallback()
    }
  }

  private var notFoundView: some View {
    VStack(spacing: 20) {
      Image(systemName: "wifi.slash")
        .font(.system(size: 60))
        .foregroundStyle(.gray)
      Text("サーバーに接続されていません")
        .font(.headline)
        .foregroundStyle(.white)
      Text("MacでAllServerForMacを起動し、\n同じWi-Fiに接続してください")
        .font(.subheadline)
        .foregroundStyle(.gray)
        .multilineTextAlignment(.center)

      Button {
        retryBrowsing()
      } label: {
        Label("もう一度探す", systemImage: "arrow.clockwise")
          .font(.subheadline.weight(.bold))
          .foregroundStyle(Color.appDarkBackground)
          .padding(.horizontal, 24)
          .padding(.vertical, 12)
          .background(AppTheme.goldGradient)
          .clipShape(Capsule())
      }
      .padding(.top, 8)
    }
  }

  private var searchingView: some View {
    VStack(spacing: 24) {
      ZStack {
        Circle()
          .stroke(Color.appGold.opacity(0.2), lineWidth: 3)
          .frame(width: 56, height: 56)
        ProgressView()
          .scaleEffect(1.4)
          .tint(Color.appGold)
      }
      Text("サーバーを探しています...")
        .font(.headline)
        .foregroundStyle(.white)
    }
  }

  private func retryBrowsing() {
    Haptics.light()
    serverBrowser.stopBrowsing()
    serverBrowser.startBrowsing()
    withAnimation {
      showNotFound = false
    }
    searchAttempt += 1
    scheduleNotFoundFallback()
  }

  /// 一定時間サーバーが見つからなければ未接続表示へ切り替えます．
  private func scheduleNotFoundFallback() {
    let attempt = searchAttempt
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
      guard attempt == searchAttempt else {
        return
      }
      withAnimation {
        showNotFound = true
      }
    }
  }
}

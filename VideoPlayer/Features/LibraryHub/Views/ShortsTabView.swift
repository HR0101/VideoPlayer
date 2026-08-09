import SwiftUI

struct ShortsTabView: View {
  @EnvironmentObject var serverManager: ServerConnectionViewModel
  @EnvironmentObject var navState: AppNavigationState

  var body: some View {
    if let server = serverManager.server, let address = server.address {
      NavigationStack {
        RemoteVideoListView(
          serverName: "ショート",
          serverAddress: address,
          albumID: "SHORTS",
          allServerAlbums: serverManager.albums,
          initialVideoToPlay: navState.targetShortsVideo
        )
      }
    } else {
      ServerConnectingView(title: "ショート")
    }
  }
}

import SwiftUI

struct HomeTabView: View {
  @EnvironmentObject var serverManager: ServerConnectionViewModel

  var body: some View {
    if let server = serverManager.server, let address = server.address {
      NavigationStack {
        RemoteVideoListView(
          serverName: "ホーム",
          serverAddress: address,
          albumID: "HOME",
          allServerAlbums: serverManager.albums
        )
      }
    } else {
      ServerConnectingView(title: "ホーム")
    }
  }
}

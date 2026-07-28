import Foundation
import MediaServerKit

@MainActor
final class AppNavigationState: ObservableObject {
  @Published var selectedTab = 0
  @Published var targetShortsVideo: RemoteVideoInfo?
  @Published var shortsJumpTrigger = UUID()
}

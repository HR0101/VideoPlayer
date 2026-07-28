import Foundation

enum RemoteSortOrder: String, CaseIterable, Identifiable {
  case importDescending = "追加日が新しい順"
  case importAscending = "追加日が古い順"
  case creationDescending = "撮影日が新しい順"
  case creationAscending = "撮影日が古い順"
  case durationDescending = "長さが長い順"
  case durationAscending = "長さが短い順"
  case nameAscending = "名前順 (A→Z)"
  case nameDescending = "名前順 (Z→A)"
  case lastOpenedDescending = "最後に開いた日が新しい順"
  case lastOpenedAscending = "最後に開いた日が古い順"
  case modifiedDescending = "変更日が新しい順"
  case modifiedAscending = "変更日が古い順"
  case sizeDescending = "サイズが大きい順"
  case sizeAscending = "サイズが小さい順"

  var id: String {
    rawValue
  }
}

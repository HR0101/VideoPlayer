import SwiftUI

struct DownloadStatusOverlay: View {
  @EnvironmentObject var downloadManager: DownloadManager

  var body: some View {
    VStack(spacing: 10) {
      if let errorMessage = downloadManager.errorMessage {
        errorView(message: errorMessage)
      }

      if let successMessage = downloadManager.successMessage {
        successView(message: successMessage)
      }

      if downloadManager.isDownloading {
        progressView
      }
    }
    .animation(
      .spring(response: 0.4, dampingFraction: 0.8),
      value: downloadManager.isDownloading
    )
  }

  private func errorView(message: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      Text(message)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .lineLimit(2)
      Spacer()
      Button {
        withAnimation {
          downloadManager.errorMessage = nil
        }
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white.opacity(0.7))
      }
    }
    .padding(14)
    .glassCard(cornerRadius: AppTheme.radiusM)
    .overlay {
      RoundedRectangle(cornerRadius: AppTheme.radiusM, style: .continuous)
        .strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
    }
    .environment(\.colorScheme, .dark)
    .padding(.horizontal)
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        withAnimation {
          downloadManager.errorMessage = nil
        }
      }
    }
  }

  private func successView(message: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .symbolEffect(.bounce, value: message)
      Text(message)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
      Spacer()
    }
    .padding(14)
    .glassCard(cornerRadius: AppTheme.radiusM)
    .environment(\.colorScheme, .dark)
    .padding(.horizontal)
  }

  private var progressView: some View {
    HStack(spacing: 15) {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("ダウンロード中…")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.appTextSecondary)
          Spacer()
          Text("\(Int(downloadManager.progress * 100))%")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(Color.appGold)
        }

        Text(downloadManager.currentFilename)
          .font(.subheadline.bold())
          .foregroundStyle(.white)
          .lineLimit(1)

        ProgressView(value: downloadManager.progress)
          .progressViewStyle(.linear)
          .tint(Color.appGold)
      }

      Button {
        downloadManager.cancelDownload()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.white.opacity(0.4))
      }
    }
    .padding(14)
    .glassCard(cornerRadius: AppTheme.radiusM)
    .environment(\.colorScheme, .dark)
    .padding(.horizontal)
  }
}

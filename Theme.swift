import SwiftUI
import UIKit

// MARK: - アプリ全体のデザインシステム
// 「ダーク × ゴールド」のプレミアム・シアタールック。
// 色・角丸・グラデーション・カードスタイル・アニメーションをここに集約する。

// MARK: - カラーパレット
extension Color {
    // 基調のダーク（わずかに青みを帯びた黒）
    static let appDarkBackground = Color(red: 0.04, green: 0.04, blue: 0.07)
    static let appDarkSurface    = Color(red: 0.10, green: 0.10, blue: 0.15)
    static let appDarkElevated   = Color(red: 0.15, green: 0.15, blue: 0.21)

    // シャンパンゴールド 3 階調
    static let appGold      = Color(red: 0.87, green: 0.74, blue: 0.46)
    static let appGoldLight = Color(red: 0.97, green: 0.89, blue: 0.66)
    static let appGoldDeep  = Color(red: 0.68, green: 0.53, blue: 0.28)

    // テキスト階層
    static let appTextSecondary = Color.white.opacity(0.65)
    static let appTextTertiary  = Color.white.opacity(0.40)
}

// MARK: - 定数（角丸・スペーシング）
enum AppTheme {
    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 16
    static let radiusL: CGFloat = 22

    /// メタリックな金のグラデーション（ボタン・バッジ用）
    static let goldGradient = LinearGradient(
        colors: [.appGoldLight, .appGold, .appGoldDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// カード縁取り用の繊細なストローク
    static let cardStroke = LinearGradient(
        colors: [.white.opacity(0.18), .white.opacity(0.03)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// サムネイル下部の文字用スクリム
    static let bottomScrim = LinearGradient(
        stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .black.opacity(0.25), location: 0.55),
            .init(color: .black.opacity(0.85), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// プレイヤー上部の文字用スクリム
    static let topScrim = LinearGradient(
        colors: [.black.opacity(0.75), .black.opacity(0.35), .clear],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - 画面共通の背景
/// 深い闇に、左上から金のグロー・右下から青のグローをほのかに灯す
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.appDarkBackground

            RadialGradient(
                colors: [Color.appGold.opacity(0.13), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )

            RadialGradient(
                colors: [Color(red: 0.25, green: 0.30, blue: 0.55).opacity(0.18), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - ガラスカード
private struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}

extension View {
    /// すりガラス + 繊細な縁取り + 浮遊感のある影
    func glassCard(cornerRadius: CGFloat = AppTheme.radiusL) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - 押下アニメーション
/// カードやサムネイルを押した時に沈み込む ButtonStyle（ハプティクス付き）
struct PressableCardStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.soft() }
            }
    }
}

// MARK: - ハプティクス
enum Haptics {
    static func soft()   { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

// MARK: - シマー（スケルトンローディング）
private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.7)
                    .offset(x: proxy.size.width * phase)
                }
                .allowsHitTesting(false)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
    }
}

extension View {
    /// ローディング中のプレースホルダに光の帯を走らせる
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

/// スケルトン用の無地カード
struct SkeletonCard: View {
    var cornerRadius: CGFloat = AppTheme.radiusL

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .shimmer()
    }
}

// MARK: - セクションヘッダー
struct SectionHeaderView: View {
    let title: String
    let icon: String
    var accessory: AnyView? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.appDarkBackground)
                .frame(width: 26, height: 26)
                .background(AppTheme.goldGradient)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.appGold.opacity(0.35), radius: 6, x: 0, y: 2)

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .tracking(0.5)

            Spacer()

            if let accessory {
                accessory
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 件数バッジ
struct CountBadge: View {
    let count: Int
    var tint: LinearGradient = AppTheme.goldGradient

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(Color.appDarkBackground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint)
            .clipShape(Capsule())
    }
}

// MARK: - ライブインジケータ（接続中サーバー）
struct LiveIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.4))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.6 : 0.8)
                    .opacity(pulse ? 0 : 0.8)
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }
            Text("オンライン")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.green.opacity(0.9))
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - 時間フォーマット共通化
extension TimeInterval {
    /// 65秒 → "1:05"、3725秒 → "1:02:05"
    var mediaDurationText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

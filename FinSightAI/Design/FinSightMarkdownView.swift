import MarkdownUI
import SwiftUI

enum FinSightMarkdownStyleVariant {
    case aiInsight
    case simulatorExplanation
    case dashboardPreview
}

struct FinSightMarkdownView: View {
    let markdown: String
    var style: FinSightMarkdownStyleVariant = .aiInsight
    var foregroundStyle: Color? = nil
    var tint: Color? = nil
    var onOpenLink: ((URL) -> OpenURLAction.Result)? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        let trimmedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)

        Group {
            if trimmedMarkdown.isEmpty {
                EmptyView()
            } else {
                Markdown(trimmedMarkdown)
                    .markdownTheme(.finSight(configuration))
                    .textSelection(.enabled)
                    .tint(configuration.linkColor)
                    .environment(
                        \.openURL,
                        OpenURLAction { url in
                            if let onOpenLink {
                                return onOpenLink(url)
                            }
                            return .systemAction(url)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var configuration: FinSightMarkdownStyleConfiguration {
        let defaults = style.defaultConfiguration
        return FinSightMarkdownStyleConfiguration(
            textColor: foregroundStyle ?? defaults.textColor,
            headingColor: defaults.headingColor,
            linkColor: tint ?? defaults.linkColor,
            inlineCodeBackground: defaults.inlineCodeBackground,
            codeBlockBackground: defaults.codeBlockBackground,
            quoteBackground: defaults.quoteBackground,
            quoteBorder: defaults.quoteBorder,
            paragraphBottomMargin: defaults.paragraphBottomMargin,
            headingTopMargin: defaults.headingTopMargin,
            headingBottomMargin: defaults.headingBottomMargin,
            heading2Scale: defaults.heading2Scale,
            heading3Scale: defaults.heading3Scale,
            baseFontSize: defaults.baseFontSize
        )
    }
}

struct FinSightStreamingRefreshControl: View {
    enum RefreshButtonStyle {
        case prominent
        case bordered
    }

    let isRefreshing: Bool
    let action: () -> Void
    var buttonTitle: String = "Refresh"
    var progressText: String = "Updating..."
    var buttonStyleKind: RefreshButtonStyle = .bordered

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if isRefreshing {
                HStack(spacing: AppTheme.Spacing.xs) {
                    FinSightTypingIndicator()
                        .scaleEffect(0.72)
                    Text(progressText)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
            }
            if buttonStyleKind == .prominent {
                Button(buttonTitle, action: action)
                    .disabled(isRefreshing)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
            } else {
                Button(buttonTitle, action: action)
                    .disabled(isRefreshing)
                    .buttonStyle(.bordered)
                    .tint(AppTheme.primary)
            }
        }
    }
}

private struct FinSightMarkdownStyleConfiguration {
    let textColor: Color
    let headingColor: Color
    let linkColor: Color
    let inlineCodeBackground: Color
    let codeBlockBackground: Color
    let quoteBackground: Color
    let quoteBorder: Color
    let paragraphBottomMargin: CGFloat
    let headingTopMargin: CGFloat
    let headingBottomMargin: CGFloat
    let heading2Scale: Double
    let heading3Scale: Double
    let baseFontSize: Double
}

private extension FinSightMarkdownStyleVariant {
    var defaultConfiguration: FinSightMarkdownStyleConfiguration {
        switch self {
        case .aiInsight:
            FinSightMarkdownStyleConfiguration(
                textColor: AppTheme.mutedInk,
                headingColor: AppTheme.ink,
                linkColor: AppTheme.primary,
                inlineCodeBackground: AppTheme.surfaceAccent,
                codeBlockBackground: AppTheme.surfaceAccent.opacity(0.9),
                quoteBackground: AppTheme.surface.opacity(0.75),
                quoteBorder: AppTheme.primary.opacity(0.35),
                paragraphBottomMargin: 14,
                headingTopMargin: 18,
                headingBottomMargin: 10,
                heading2Scale: 1.12,
                heading3Scale: 1.0,
                baseFontSize: 16
            )
        case .simulatorExplanation:
            FinSightMarkdownStyleConfiguration(
                textColor: AppTheme.mutedInk,
                headingColor: AppTheme.ink,
                linkColor: AppTheme.primary,
                inlineCodeBackground: AppTheme.surfaceAccent,
                codeBlockBackground: AppTheme.surfaceAccent.opacity(0.88),
                quoteBackground: AppTheme.surfaceAccent.opacity(0.68),
                quoteBorder: AppTheme.primary.opacity(0.4),
                paragraphBottomMargin: 14,
                headingTopMargin: 18,
                headingBottomMargin: 10,
                heading2Scale: 1.08,
                heading3Scale: 0.98,
                baseFontSize: 16
            )
        case .dashboardPreview:
            FinSightMarkdownStyleConfiguration(
                textColor: AppTheme.ink,
                headingColor: AppTheme.ink,
                linkColor: AppTheme.primary,
                inlineCodeBackground: AppTheme.surface.opacity(0.9),
                codeBlockBackground: AppTheme.surface.opacity(0.92),
                quoteBackground: AppTheme.surface.opacity(0.86),
                quoteBorder: AppTheme.primary.opacity(0.32),
                paragraphBottomMargin: 12,
                headingTopMargin: 14,
                headingBottomMargin: 8,
                heading2Scale: 1.0,
                heading3Scale: 0.94,
                baseFontSize: 15
            )
        }
    }
}

private extension Theme {
    static func finSight(_ configuration: FinSightMarkdownStyleConfiguration) -> Theme {
        Theme()
            .text {
                ForegroundColor(configuration.textColor)
                FontSize(configuration.baseFontSize)
            }
            .strong {
                FontWeight(.semibold)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(configuration.linkColor)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(configuration.inlineCodeBackground)
            }
            .heading1 { heading in
                themedHeading(
                    heading,
                    fontScale: configuration.heading2Scale + 0.12,
                    configuration: configuration
                )
            }
            .heading2 { heading in
                themedHeading(
                    heading,
                    fontScale: configuration.heading2Scale,
                    configuration: configuration
                )
            }
            .heading3 { heading in
                themedHeading(
                    heading,
                    fontScale: configuration.heading3Scale,
                    configuration: configuration
                )
            }
            .heading4 { heading in
                themedHeading(
                    heading,
                    fontScale: 0.92,
                    configuration: configuration
                )
            }
            .heading5 { heading in
                themedHeading(
                    heading,
                    fontScale: 0.88,
                    configuration: configuration
                )
            }
            .heading6 { heading in
                themedHeading(
                    heading,
                    fontScale: 0.84,
                    configuration: configuration
                )
            }
            .paragraph { paragraph in
                paragraph.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 0, bottom: configuration.paragraphBottomMargin)
            }
            .list { list in
                list.label
                    .markdownMargin(top: 0, bottom: configuration.paragraphBottomMargin)
            }
            .listItem { item in
                item.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownMargin(top: .em(0.35))
            }
            .blockquote { quote in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.quoteBorder)
                        .frame(width: 4)
                    quote.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.18))
                        .markdownTextStyle {
                            ForegroundColor(configuration.textColor)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                }
                .background(configuration.quoteBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .markdownMargin(top: 0, bottom: configuration.paragraphBottomMargin)
            }
            .codeBlock { codeBlock in
                ScrollView(.horizontal, showsIndicators: false) {
                    codeBlock.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.18))
                        .padding(14)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.88))
                        }
                }
                .background(configuration.codeBlockBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .markdownMargin(top: 0, bottom: configuration.paragraphBottomMargin)
            }
    }

    private static func themedHeading(
        _ heading: BlockConfiguration,
        fontScale: Double,
        configuration: FinSightMarkdownStyleConfiguration
    ) -> some View {
        heading.label
            .relativeLineSpacing(.em(0.12))
            .markdownMargin(
                top: configuration.headingTopMargin,
                bottom: configuration.headingBottomMargin
            )
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(fontScale))
                ForegroundColor(configuration.headingColor)
            }
    }
}

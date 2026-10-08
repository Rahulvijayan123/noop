import SwiftUI
import MarkdownUI
import StrandDesign

/// The MarkdownUI theme for Coach replies.
///
/// LLM chat replies (OpenAI / Anthropic / Gemini) arrive as GitHub-flavored
/// Markdown — overwhelmingly bold, bullet/numbered lists, `###` headings, and the
/// occasional table for a weekly plan. This theme renders that set in the Strand
/// look, sized for a chat bubble: headings are capped near body size (a `#` must
/// not shout inside a 560pt bubble), and tables get hairline borders.
extension Theme {
    static let strand = Theme()
        // Base body text — mirrors StrandFont.body (16 / regular). Headings are sized relative to it.
        .text {
            ForegroundColor(StrandPalette.textPrimary)
            FontSize(16)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(StrandPalette.textPrimary)
            BackgroundColor(StrandPalette.surfaceInset)
        }
        .link {
            ForegroundColor(StrandPalette.accent)
        }
        // Headings: h1–h3 at the headline role (body size, semibold), h4–h6 at the label size, so a
        // heading inside a reply never shouts.
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1))
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.875))
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.875))
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(12)
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.2))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .markdownTextStyle {
                    ForegroundColor(StrandPalette.textSecondary)
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(StrandPalette.accent.opacity(0.6))
                        .frame(width: 3)
                }
                .markdownMargin(top: 4, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                    }
                    .padding(10)
            }
            .background(StrandPalette.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .markdownMargin(top: 4, bottom: 8)
        }
        .thematicBreak {
            StrandPalette.hairline
                .frame(height: 1)
                .markdownMargin(top: 10, bottom: 10)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: StrandPalette.hairline))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, StrandPalette.surfaceInset)
                )
                .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    FontSize(.em(0.9))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .relativeLineSpacing(.em(0.2))
        }
}

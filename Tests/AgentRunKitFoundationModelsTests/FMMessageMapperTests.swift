#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import Testing

    @Suite(.serialized) struct FMMessageMapperTests {
        @Test func singleUserMessage() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = try FMMessageMapper.map([.user("Hello")])
            #expect(mapped.prompt == "Hello")
            #expect(mapped.instructions == nil)
        }

        @Test func systemMessageExtractedAsInstructions() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = try FMMessageMapper.map([
                .system("You are helpful"),
                .user("Hi"),
            ])
            #expect(mapped.instructions == "You are helpful")
            #expect(mapped.prompt == "Hi")
        }

        @Test func multipleSystemMessagesJoinedWithNewline() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = try FMMessageMapper.map([
                .system("First instruction"),
                .system("Second instruction"),
                .user("Question"),
            ])
            #expect(mapped.instructions == "First instruction\nSecond instruction")
        }

        @Test func textOnlyMultimodalUserMessage() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = try FMMessageMapper.map([
                .userMultimodal([
                    .text("Describe this"),
                    .text("in detail"),
                ]),
            ])
            #expect(mapped.prompt == "Describe this\nin detail")
        }

        @Test func noSystemMessageYieldsNilInstructions() throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = try FMMessageMapper.map([.user("Just a question")])
            #expect(mapped.instructions == nil)
        }

        @Test func multipleUserMessagesThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([
                    .user("First question"),
                    .user("Second question"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func systemMessageAfterUserThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([
                    .user("Question"),
                    .system("Late instruction"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func assistantMessageThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([
                    .user("First"),
                    .assistant(AssistantMessage(content: "Response")),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func toolMessageThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([
                    .user("First"),
                    .tool(id: "1", name: "test", content: "result"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func emptyHistoryThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func systemOnlyHistoryThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([.system("System")])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func emptyUserTextThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([.user(" \n\t ")])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func nonTextMultimodalPartsThrow() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let data = Data([0x01, 0x02])
            let nonTextParts: [ContentPart] = [
                .imageURL("https://example.com/image.jpg"),
                .imageBase64(data: data, mimeType: "image/png"),
                .videoBase64(data: data, mimeType: "video/mp4"),
                .pdfBase64(data: data),
                .audioBase64(data: data, format: .mp3),
            ]

            for part in nonTextParts {
                #expect {
                    _ = try FMMessageMapper.map([
                        .userMultimodal([part]),
                    ])
                } throws: { error in
                    isUnsupportedFoundationModelsMappingError(error)
                }

                #expect {
                    _ = try FMMessageMapper.map([
                        .userMultimodal([.text("Describe this"), part]),
                    ])
                } throws: { error in
                    isUnsupportedFoundationModelsMappingError(error)
                }
            }
        }

        @Test func whitespaceOnlyMultimodalThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([
                    .userMultimodal([.text(" "), .text("\n")]),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func multimodalPlusUserThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([
                    .userMultimodal([.text("First question")]),
                    .user("Second question"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @Test func assistantToolAndFollowUpThrows() {
            guard #available(macOS 26, iOS 26, *) else { return }
            #expect {
                _ = try FMMessageMapper.map([
                    .system("System"),
                    .user("First"),
                    .assistant(AssistantMessage(content: "Response")),
                    .tool(id: "1", name: "test", content: "result"),
                    .user("Follow up"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }
    }

#endif

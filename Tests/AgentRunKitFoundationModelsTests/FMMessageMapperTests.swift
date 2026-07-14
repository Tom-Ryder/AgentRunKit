#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Foundation
    import Testing

    @Suite(.serialized) struct FMMessageMapperTests {
        @available(macOS 26, iOS 26, *)
        @Test func singleUserMessage() throws {
            let mapped = try FMMessageMapper.map([.user("Hello")])
            #expect(mapped.prompt == "Hello")
            #expect(mapped.instructions == nil)
        }

        @available(macOS 26, iOS 26, *)
        @Test func systemMessageExtractedAsInstructions() throws {
            let mapped = try FMMessageMapper.map([
                .system("You are helpful"),
                .user("Hi"),
            ])
            #expect(mapped.instructions == "You are helpful")
            #expect(mapped.prompt == "Hi")
        }

        @available(macOS 26, iOS 26, *)
        @Test func multipleSystemMessagesJoinedWithNewline() throws {
            let mapped = try FMMessageMapper.map([
                .system("First instruction"),
                .system("Second instruction"),
                .user("Question"),
            ])
            #expect(mapped.instructions == "First instruction\nSecond instruction")
        }

        @available(macOS 26, iOS 26, *)
        @Test func textOnlyMultimodalUserMessage() throws {
            let mapped = try FMMessageMapper.map([
                .userMultimodal([
                    .text("Describe this"),
                    .text("in detail"),
                ]),
            ])
            #expect(mapped.prompt == "Describe this\nin detail")
        }

        @available(macOS 26, iOS 26, *)
        @Test func noSystemMessageYieldsNilInstructions() throws {
            let mapped = try FMMessageMapper.map([.user("Just a question")])
            #expect(mapped.instructions == nil)
        }

        @available(macOS 26, iOS 26, *)
        @Test func multipleUserMessagesThrows() {
            #expect {
                _ = try FMMessageMapper.map([
                    .user("First question"),
                    .user("Second question"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func systemMessageAfterUserThrows() {
            #expect {
                _ = try FMMessageMapper.map([
                    .user("Question"),
                    .system("Late instruction"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func assistantMessageThrows() {
            #expect {
                _ = try FMMessageMapper.map([
                    .user("First"),
                    .assistant(AssistantMessage(content: "Response")),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func toolMessageThrows() {
            #expect {
                _ = try FMMessageMapper.map([
                    .user("First"),
                    .tool(id: "1", name: "test", content: "result"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func emptyHistoryThrows() {
            #expect {
                _ = try FMMessageMapper.map([])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func systemOnlyHistoryThrows() {
            #expect {
                _ = try FMMessageMapper.map([.system("System")])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func emptyUserTextThrows() {
            #expect {
                _ = try FMMessageMapper.map([.user(" \n\t ")])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func nonTextMultimodalPartsThrow() {
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

        @available(macOS 26, iOS 26, *)
        @Test func whitespaceOnlyMultimodalThrows() {
            #expect {
                _ = try FMMessageMapper.map([
                    .userMultimodal([.text(" "), .text("\n")]),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func multimodalPlusUserThrows() {
            #expect {
                _ = try FMMessageMapper.map([
                    .userMultimodal([.text("First question")]),
                    .user("Second question"),
                ])
            } throws: { error in
                isUnsupportedFoundationModelsMappingError(error)
            }
        }

        @available(macOS 26, iOS 26, *)
        @Test func assistantToolAndFollowUpThrows() {
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

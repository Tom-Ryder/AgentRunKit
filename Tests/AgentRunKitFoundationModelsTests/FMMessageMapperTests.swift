#if canImport(FoundationModels)

    import AgentRunKit
    @testable import AgentRunKitFoundationModels
    import Testing

    @Suite struct FMMessageMapperTests {
        @Test func singleUserMessage() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([.user("Hello")])
            #expect(mapped.prompt == "Hello")
            #expect(mapped.instructions == nil)
        }

        @Test func systemMessageExtractedAsInstructions() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([
                .system("You are helpful"),
                .user("Hi"),
            ])
            #expect(mapped.instructions == "You are helpful")
            #expect(mapped.prompt == "Hi")
        }

        @Test func multipleSystemMessagesJoinedWithNewline() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([
                .system("First instruction"),
                .system("Second instruction"),
                .user("Question"),
            ])
            #expect(mapped.instructions == "First instruction\nSecond instruction")
        }

        @Test func multimodalUserExtractsTextOnly() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([
                .userMultimodal([
                    .text("Describe this"),
                    .imageURL("https://example.com/image.jpg"),
                    .text("in detail"),
                ]),
            ])
            #expect(mapped.prompt == "Describe this\nin detail")
        }

        @Test func noSystemMessageYieldsNilInstructions() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([.user("Just a question")])
            #expect(mapped.instructions == nil)
        }

        @Test func multipleUserMessagesUsesLast() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([
                .user("First question"),
                .user("Second question"),
            ])
            #expect(mapped.prompt == "Second question")
        }

        @Test func assistantAndToolMessagesIgnored() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([
                .system("System"),
                .user("First"),
                .assistant(AssistantMessage(content: "Response")),
                .tool(id: "1", name: "test", content: "result"),
                .user("Follow up"),
            ])
            #expect(mapped.instructions == "System")
            #expect(mapped.prompt == "Follow up")
        }

        @Test func emptyMessagesYieldsEmptyPrompt() {
            guard #available(macOS 26, iOS 26, *) else { return }
            let mapped = FMMessageMapper.map([])
            #expect(mapped.prompt == "")
            #expect(mapped.instructions == nil)
        }
    }

#endif

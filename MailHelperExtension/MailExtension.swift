//
//  MailExtension.swift
//  MailHelperExtension
//
//  Created by Isaac IBM on 6/11/2025.
//

import MailKit

internal final class MailExtension: NSObject, MEExtension {
    internal func handlerForContentBlocker() -> MEContentBlocker {
        // Use a shared instance for all messages, since there's
        // no state associated with a content blocker.
        return ContentBlocker.shared
    }

    internal func handlerForMessageActions() -> MEMessageActionHandler {
        // Use a shared instance for all messages, since there's
        // no state associated with performing actions.
        return MessageActionHandler.shared
    }

    internal func handler(for session: MEComposeSession) -> MEComposeSessionHandler {
        // Create a unique instance, since each compose window is separate.
        return ComposeSessionHandler()
    }

    internal func handlerForMessageSecurity() -> MEMessageSecurityHandler {
        // Use a shared instance for all messages, since there's
        // no state associated with the security handler.
        return MessageSecurityHandler.shared
    }

}

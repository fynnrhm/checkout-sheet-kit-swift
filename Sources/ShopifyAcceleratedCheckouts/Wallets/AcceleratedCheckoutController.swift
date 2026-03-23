/*
 MIT License

 Copyright 2023 - Present, Shopify Inc.

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

import ShopifyCheckoutSheetKit
import SwiftUI

/// UI-agnostic entry point for accelerated checkout wallet logic.
///
/// Use this controller when you want to build your own SwiftUI or UIKit buttons while reusing
/// the SDK's checkout initialization, loading state, and wallet-specific business logic.
@available(iOS 16.0, *)
@MainActor
public final class AcceleratedCheckoutController: ObservableObject {
    @Published public private(set) var renderState: RenderState {
        didSet {
            eventHandlers.renderStateDidChange?(renderState)
        }
    }

    /// Shared Shop Pay controller for custom buttons.
    public let shopPay: ShopPayController

    /// Shared Apple Pay controller for custom buttons.
    /// This is `nil` when no Apple Pay configuration was provided.
    public let applePay: ApplePayController?

    /// Shared lifecycle handlers for both wallet controllers.
    ///
    /// Assigning a value here updates the event handlers for `shopPay` and `applePay`.
    public var eventHandlers: EventHandlers {
        didSet {
            shopPay.eventHandlers = eventHandlers
            applePay?.eventHandlers = eventHandlers
            eventHandlers.renderStateDidChange?(renderState)
        }
    }

    private let identifier: CheckoutIdentifier
    private let shopSettingsLoader: ShopSettingsLoader

    /// Creates a controller for a cart-backed accelerated checkout flow.
    ///
    /// - Parameters:
    ///   - cartID: The cart ID to check out.
    ///   - configuration: Common accelerated checkout configuration.
    ///   - applePayConfiguration: Apple Pay configuration for custom Apple Pay buttons.
    ///   - eventHandlers: Shared lifecycle handlers for both wallets.
    public convenience init(
        cartID: String,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration? = nil,
        eventHandlers: EventHandlers = .init()
    ) {
        self.init(
            identifier: .cart(cartID: cartID).parse(),
            configuration: configuration,
            applePayConfiguration: applePayConfiguration,
            eventHandlers: eventHandlers
        )
    }

    /// Creates a controller for a product variant-backed accelerated checkout flow.
    ///
    /// - Parameters:
    ///   - variantID: The product variant ID to check out.
    ///   - quantity: The quantity to add when creating the cart.
    ///   - configuration: Common accelerated checkout configuration.
    ///   - applePayConfiguration: Apple Pay configuration for custom Apple Pay buttons.
    ///   - eventHandlers: Shared lifecycle handlers for both wallets.
    public convenience init(
        variantID: String,
        quantity: Int,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration? = nil,
        eventHandlers: EventHandlers = .init()
    ) {
        self.init(
            identifier: .variant(variantID: variantID, quantity: quantity).parse(),
            configuration: configuration,
            applePayConfiguration: applePayConfiguration,
            eventHandlers: eventHandlers
        )
    }

    init(
        identifier: CheckoutIdentifier,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration? = nil,
        eventHandlers: EventHandlers = .init(),
        storefront: StorefrontAPIProtocol? = nil
    ) {
        self.identifier = identifier
        shopSettingsLoader = ShopSettingsLoader(
            configuration: configuration,
            storefront: storefront
        )
        shopPay = ShopPayController(
            identifier: identifier,
            configuration: configuration,
            eventHandlers: eventHandlers,
            storefront: storefront
        )

        if let applePayConfiguration {
            applePay = ApplePayController(
                identifier: identifier,
                configuration: configuration,
                applePayConfiguration: applePayConfiguration,
                eventHandlers: eventHandlers,
                shopSettingsLoader: shopSettingsLoader
            )
        } else {
            applePay = nil
        }

        if case let .invariant(reason) = identifier {
            ShopifyAcceleratedCheckouts.logger.error(reason)
            renderState = .error(reason: reason)
        } else {
            renderState = .loading
        }

        self.eventHandlers = eventHandlers
        eventHandlers.renderStateDidChange?(renderState)
    }

    /// Preloads shop settings so custom UI can react to the same loading and error states
    /// as `AcceleratedCheckoutButtons`.
    public func prepare() async {
        guard identifier.isValid() else { return }

        if case .rendered = renderState {
            return
        }

        do {
            renderState = .loading
            _ = try await shopSettingsLoader.load()
            try await applePay?.prepare()
            renderState = .rendered
        } catch {
            let reason = "Error loading shop settings: \(error)"
            ShopifyAcceleratedCheckouts.logger.error(reason)
            renderState = .error(reason: reason)
        }
    }
}

/// Controller for wiring a custom Shop Pay button to Shopify Accelerated Checkouts.
@available(iOS 16.0, *)
@MainActor
public final class ShopPayController {
    public var eventHandlers: EventHandlers {
        didSet {
            controller.eventHandlers = eventHandlers
        }
    }

    private let controller: ShopPayViewController

    init(
        identifier: CheckoutIdentifier,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        eventHandlers: EventHandlers = .init(),
        storefront: StorefrontAPIProtocol? = nil
    ) {
        controller = ShopPayViewController(
            identifier: identifier,
            configuration: configuration,
            eventHandlers: eventHandlers
        )

        if let storefront {
            controller.storefront = storefront
        }

        self.eventHandlers = eventHandlers
    }

    /// Starts the Shop Pay checkout flow.
    public func onPress() async {
        await controller.onPress()
    }
}

/// Controller for wiring a custom Apple Pay button to Shopify Accelerated Checkouts.
@available(iOS 16.0, *)
@MainActor
public final class ApplePayController {
    public var eventHandlers: EventHandlers {
        didSet {
            applyEventHandlers()
        }
    }

    private let identifier: CheckoutIdentifier
    private let configuration: ShopifyAcceleratedCheckouts.Configuration
    private let applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration
    private let shopSettingsLoader: ShopSettingsLoader
    private let controllerFactory: (CheckoutIdentifier, ApplePayConfigurationWrapper) -> ApplePayViewController

    private var controller: ApplePayViewController?

    init(
        identifier: CheckoutIdentifier,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration,
        eventHandlers: EventHandlers = .init(),
        shopSettingsLoader: ShopSettingsLoader,
        controllerFactory: @escaping (CheckoutIdentifier, ApplePayConfigurationWrapper) -> ApplePayViewController = {
            ApplePayViewController(identifier: $0, configuration: $1)
        }
    ) {
        self.identifier = identifier
        self.configuration = configuration
        self.applePayConfiguration = applePayConfiguration
        self.eventHandlers = eventHandlers
        self.shopSettingsLoader = shopSettingsLoader
        self.controllerFactory = controllerFactory
    }

    /// Preloads Apple Pay dependencies so custom UI can react before the user taps the button.
    public func prepare() async throws {
        _ = try await resolveController()
    }

    /// Starts the Apple Pay checkout flow.
    public func onPress() async {
        do {
            let controller = try await resolveController()
            await controller.onPress()
        } catch {
            ShopifyAcceleratedCheckouts.logger.error(
                "[startPayment] Failed to prepare Apple Pay: \(error)"
            )
            eventHandlers.checkoutDidFail?(
                .sdkError(underlying: error, recoverable: false)
            )
        }
    }

    private func resolveController() async throws -> ApplePayViewController {
        guard identifier.isValid() else {
            throw ShopifyAcceleratedCheckouts.Error.cartAcquisition(identifier: identifier)
        }

        if let controller {
            return controller
        }

        let shopSettings = try await shopSettingsLoader.load()
        let controller = controllerFactory(
            identifier,
            ApplePayConfigurationWrapper(
                common: configuration,
                applePay: applePayConfiguration,
                shopSettings: shopSettings
            )
        )
        self.controller = controller
        applyEventHandlers()
        return controller
    }

    private func applyEventHandlers() {
        controller?.onCheckoutComplete = eventHandlers.checkoutDidComplete
        controller?.onCheckoutFail = eventHandlers.checkoutDidFail
        controller?.onCheckoutCancel = eventHandlers.checkoutDidCancel
        controller?.onShouldRecoverFromError = eventHandlers.shouldRecoverFromError
        controller?.onCheckoutClickLink = eventHandlers.checkoutDidClickLink
        controller?.onCheckoutWebPixelEvent = eventHandlers.checkoutDidEmitWebPixelEvent
    }
}

@available(iOS 16.0, *)
@MainActor
final class ShopSettingsLoader {
    private let storefront: StorefrontAPIProtocol
    private var shopSettings: ShopSettings?

    init(
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        storefront: StorefrontAPIProtocol? = nil
    ) {
        if let storefront {
            self.storefront = storefront
        } else {
            self.storefront = StorefrontAPI(
                storefrontDomain: configuration.storefrontDomain,
                storefrontAccessToken: configuration.storefrontAccessToken
            )
        }
    }

    func load() async throws -> ShopSettings {
        if let shopSettings {
            return shopSettings
        }

        let settings = ShopSettings(from: try await storefront.shop())
        shopSettings = settings
        return settings
    }
}

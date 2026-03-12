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

import PassKit
import ShopifyCheckoutSheetKit
import UIKit

/// UIKit equivalent of `AcceleratedCheckoutButtons` that renders Shop Pay and Apple Pay buttons.
///
/// Note:
/// - The order of `wallets` controls the display order of buttons.
/// - The default wallets are `[.shopPay, .applePay]`.
/// - Provide an `applePayConfiguration` when rendering `.applePay`.
@available(iOS 16.0, *)
@MainActor
public final class AcceleratedCheckoutButtonsView: UIView {
    typealias StorefrontFactory = (ShopifyAcceleratedCheckouts.Configuration) -> StorefrontAPIProtocol
    typealias ShopPayControllerFactory = (
        CheckoutIdentifier,
        ShopifyAcceleratedCheckouts.Configuration,
        EventHandlers
    ) -> ShopPayViewController
    typealias ApplePayControllerFactory = (
        CheckoutIdentifier,
        ApplePayConfigurationWrapper
    ) -> ApplePayViewController

    public var wallets: [Wallet] = [.shopPay, .applePay] {
        didSet { rebuildWalletButtonsIfPossible() }
    }

    private var eventHandlers: EventHandlers = .init() {
        didSet { applyEventHandlersToControllers() }
    }

    private var cornerRadius: CGFloat?
    private var applePayButtonType: PKPaymentButtonType = .plain
    private var applePayButtonStyle: PKPaymentButtonStyle = .black

    private let identifier: CheckoutIdentifier
    private let configuration: ShopifyAcceleratedCheckouts.Configuration
    private let applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration?
    private let storefrontFactory: StorefrontFactory
    private let shopPayControllerFactory: ShopPayControllerFactory
    private let applePayControllerFactory: ApplePayControllerFactory

    private let stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    private var didStartLoading = false
    private var loadShopSettingsTask: Task<Void, Never>?
    private var shopSettings: ShopSettings?
    private var shopPayController: ShopPayViewController?
    private var applePayController: ApplePayViewController?
    private weak var shopPayButton: UIButton?
    private weak var applePayButton: PKPaymentButton?

    private var currentRenderState: RenderState = .loading {
        didSet {
            eventHandlers.renderStateDidChange?(currentRenderState)
        }
    }

    /// Initializes accelerated checkout buttons with a cart ID.
    ///
    /// - Parameters:
    ///   - cartID: The cart ID to checkout (must start with `gid://shopify/Cart/`).
    ///   - configuration: Common accelerated checkout configuration.
    ///   - applePayConfiguration: Optional Apple Pay configuration. Required when `.applePay` is rendered.
    public convenience init(
        cartID: String,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration? = nil
    ) {
        self.init(
            identifier: CheckoutIdentifier.cart(cartID: cartID).parse(),
            configuration: configuration,
            applePayConfiguration: applePayConfiguration
        )
    }

    /// Initializes accelerated checkout buttons with a variant ID and quantity.
    ///
    /// - Parameters:
    ///   - variantID: The variant ID to checkout (must start with `gid://shopify/ProductVariant/`).
    ///   - quantity: The quantity of the variant to checkout.
    ///   - configuration: Common accelerated checkout configuration.
    ///   - applePayConfiguration: Optional Apple Pay configuration. Required when `.applePay` is rendered.
    public convenience init(
        variantID: String,
        quantity: Int,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration? = nil
    ) {
        self.init(
            identifier: CheckoutIdentifier.variant(variantID: variantID, quantity: quantity).parse(),
            configuration: configuration,
            applePayConfiguration: applePayConfiguration
        )
    }

    init(
        identifier: CheckoutIdentifier,
        configuration: ShopifyAcceleratedCheckouts.Configuration,
        applePayConfiguration: ShopifyAcceleratedCheckouts.ApplePayConfiguration?,
        storefrontFactory: @escaping StorefrontFactory = { config in
            StorefrontAPI(
                storefrontDomain: config.storefrontDomain,
                storefrontAccessToken: config.storefrontAccessToken
            )
        },
        shopPayControllerFactory: @escaping ShopPayControllerFactory = { identifier, configuration, eventHandlers in
            ShopPayViewController(
                identifier: identifier,
                configuration: configuration,
                eventHandlers: eventHandlers
            )
        },
        applePayControllerFactory: @escaping ApplePayControllerFactory = { identifier, configuration in
            ApplePayViewController(
                identifier: identifier,
                configuration: configuration
            )
        }
    ) {
        self.identifier = identifier
        self.configuration = configuration
        self.applePayConfiguration = applePayConfiguration
        self.storefrontFactory = storefrontFactory
        self.shopPayControllerFactory = shopPayControllerFactory
        self.applePayControllerFactory = applePayControllerFactory
        super.init(frame: .zero)
        setupUI()

        if case let .invariant(reason) = identifier {
            ShopifyAcceleratedCheckouts.logger.error(reason)
            currentRenderState = .error(reason: reason)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadShopSettingsTask?.cancel()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        eventHandlers.renderStateDidChange?(currentRenderState)
        startLoadingShopSettingsIfNeeded()
    }

    // MARK: - Modifiers

    /// Sets wallets to render and their display order.
    @discardableResult
    public func wallets(_ wallets: [Wallet]) -> Self {
        self.wallets = wallets
        return self
    }

    /// Sets corner radius for all rendered wallet buttons.
    @discardableResult
    public func cornerRadius(_ radius: CGFloat) -> Self {
        cornerRadius = radius
        applyCornerRadiusToButtons()
        return self
    }

    /// Sets the Apple Pay button type.
    @discardableResult
    public func applePayLabel(_ label: PKPaymentButtonType) -> Self {
        applePayButtonType = label
        rebuildWalletButtonsIfPossible()
        return self
    }

    /// Sets the Apple Pay button style.
    @discardableResult
    public func applePayButtonStyle(_ style: PKPaymentButtonStyle) -> Self {
        applePayButtonStyle = style
        rebuildWalletButtonsIfPossible()
        return self
    }

    /// Adds an action to perform when the checkout completes successfully.
    @discardableResult
    public func onComplete(_ action: @escaping (CheckoutCompletedEvent) -> Void) -> Self {
        var handlers = eventHandlers
        handlers.checkoutDidComplete = action
        eventHandlers = handlers
        return self
    }

    /// Adds an action to perform when the checkout encounters an error.
    @discardableResult
    public func onFail(_ action: @escaping (CheckoutError) -> Void) -> Self {
        var handlers = eventHandlers
        handlers.checkoutDidFail = action
        eventHandlers = handlers
        return self
    }

    /// Adds an action to perform when the checkout is cancelled.
    @discardableResult
    public func onCancel(_ action: @escaping () -> Void) -> Self {
        var handlers = eventHandlers
        handlers.checkoutDidCancel = action
        eventHandlers = handlers
        return self
    }

    /// Adds an action to determine if checkout should recover from an error.
    @discardableResult
    public func onShouldRecoverFromError(_ action: @escaping (CheckoutError) -> Bool) -> Self {
        var handlers = eventHandlers
        handlers.shouldRecoverFromError = action
        eventHandlers = handlers
        return self
    }

    /// Adds an action to perform when a checkout link is clicked.
    @discardableResult
    public func onClickLink(_ action: @escaping (URL) -> Void) -> Self {
        var handlers = eventHandlers
        handlers.checkoutDidClickLink = action
        eventHandlers = handlers
        return self
    }

    /// Adds an action to perform when a web pixel event is emitted.
    @discardableResult
    public func onWebPixelEvent(_ action: @escaping (PixelEvent) -> Void) -> Self {
        var handlers = eventHandlers
        handlers.checkoutDidEmitWebPixelEvent = action
        eventHandlers = handlers
        return self
    }

    /// Adds an action to perform when the render state changes.
    @discardableResult
    public func onRenderStateChange(_ action: @escaping (RenderState) -> Void) -> Self {
        var handlers = eventHandlers
        handlers.renderStateDidChange = action
        eventHandlers = handlers
        if window != nil {
            action(currentRenderState)
        }
        return self
    }

    // MARK: - Setup

    private func setupUI() {
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func startLoadingShopSettingsIfNeeded() {
        guard !didStartLoading else { return }
        didStartLoading = true
        loadShopSettingsTask = Task { [weak self] in
            await self?.loadShopSettings()
        }
    }

    private func loadShopSettings() async {
        guard identifier.isValid() else { return }

        do {
            currentRenderState = .loading
            let storefront = storefrontFactory(configuration)
            let shop = try await storefront.shop()
            let settings = ShopSettings(from: shop)
            shopSettings = settings
            if let reason = renderWalletButtons(using: settings) {
                currentRenderState = .error(reason: reason)
            } else {
                currentRenderState = .rendered
            }
        } catch {
            guard !(error is CancellationError) else { return }
            let reason = "Error loading shop settings: \(error)"
            ShopifyAcceleratedCheckouts.logger.error(reason)
            currentRenderState = .error(reason: reason)
        }
    }

    // MARK: - Rendering

    private func rebuildWalletButtonsIfPossible() {
        guard let shopSettings else { return }
        if let reason = renderWalletButtons(using: shopSettings) {
            currentRenderState = .error(reason: reason)
        } else {
            currentRenderState = .rendered
        }
    }

    @discardableResult
    private func renderWalletButtons(using shopSettings: ShopSettings) -> String? {
        clearButtons()
        var renderError: String?

        for wallet in wallets {
            switch wallet {
            case .shopPay:
                let controller = shopPayControllerFactory(identifier, configuration, eventHandlers)
                shopPayController = controller

                let button = makeShopPayButton()
                shopPayButton = button
                stackView.addArrangedSubview(button)

            case .applePay:
                guard let applePayConfiguration else {
                    let reason =
                        "Apple Pay configuration is required when rendering Wallet.applePay."
                    ShopifyAcceleratedCheckouts.logger.error(reason)
                    renderError = reason
                    continue
                }

                let wrapper = ApplePayConfigurationWrapper(
                    common: configuration,
                    applePay: applePayConfiguration,
                    shopSettings: shopSettings
                )
                let controller = applePayControllerFactory(identifier, wrapper)
                applePayController = controller

                let button = makeApplePayButton()
                applePayButton = button
                stackView.addArrangedSubview(button)
            }
        }

        applyEventHandlersToControllers()
        return renderError
    }

    private func clearButtons() {
        shopPayController = nil
        applePayController = nil
        shopPayButton = nil
        applePayButton = nil

        for subview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }

    private func makeShopPayButton() -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .shopPayBlue
        button.accessibilityLabel = "Shop Pay"
        button.accessibilityIdentifier = "shop-pay-button"
        button.clipsToBounds = true
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = resolvedCornerRadius
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.addTarget(self, action: #selector(handleShopPayButtonTap), for: .touchUpInside)

        if let image = UIImage(named: "shop-pay-logo", in: .acceleratedCheckouts, compatibleWith: nil) {
            let imageView = UIImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFit
            imageView.isUserInteractionEnabled = false
            button.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.heightAnchor.constraint(equalToConstant: 24),
                imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                imageView.leadingAnchor.constraint(greaterThanOrEqualTo: button.leadingAnchor, constant: 16),
                imageView.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -16)
            ])
        }

        return button
    }

    private func makeApplePayButton() -> PKPaymentButton {
        let button = PKPaymentButton(
            paymentButtonType: applePayButtonType,
            paymentButtonStyle: applePayButtonStyle
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.cornerRadius = resolvedCornerRadius
        button.accessibilityIdentifier = "apple-pay-button"
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.addTarget(self, action: #selector(handleApplePayButtonTap), for: .touchUpInside)
        return button
    }

    private func applyCornerRadiusToButtons() {
        shopPayButton?.layer.cornerRadius = resolvedCornerRadius
        applePayButton?.cornerRadius = resolvedCornerRadius
    }

    private var resolvedCornerRadius: CGFloat {
        let defaultCornerRadius: CGFloat = 8
        guard let cornerRadius else { return defaultCornerRadius }
        return cornerRadius >= 0 ? cornerRadius : defaultCornerRadius
    }

    private func applyEventHandlersToControllers() {
        shopPayController?.eventHandlers = eventHandlers

        applePayController?.onCheckoutComplete = eventHandlers.checkoutDidComplete
        applePayController?.onCheckoutFail = eventHandlers.checkoutDidFail
        applePayController?.onCheckoutCancel = eventHandlers.checkoutDidCancel
        applePayController?.onShouldRecoverFromError = eventHandlers.shouldRecoverFromError
        applePayController?.onCheckoutClickLink = eventHandlers.checkoutDidClickLink
        applePayController?.onCheckoutWebPixelEvent = eventHandlers.checkoutDidEmitWebPixelEvent
    }

    // MARK: - Actions

    @objc private func handleShopPayButtonTap() {
        guard let shopPayController else { return }
        Task { await shopPayController.onPress() }
    }

    @objc private func handleApplePayButtonTap() {
        guard let applePayController else { return }
        Task { await applePayController.onPress() }
    }
}

private extension UIColor {
    static let shopPayBlue = UIColor(red: 84 / 255, green: 51 / 255, blue: 235 / 255, alpha: 1)
}

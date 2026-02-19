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

@testable import ShopifyAcceleratedCheckouts
import UIKit
import XCTest

@available(iOS 17.0, *)
@MainActor
final class AcceleratedCheckoutButtonsViewTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func test_onRenderStateChange_withInvalidCartID_emitsErrorState() {
        let expectation = expectation(description: "onRenderStateChange should emit error")
        var receivedStates: [RenderState] = []

        let view = AcceleratedCheckoutButtonsView(
            cartID: "invalid-cart-id",
            configuration: .testConfiguration
        )
        .onRenderStateChange { state in
            receivedStates.append(state)
            if case .error = state {
                expectation.fulfill()
            }
        }

        window = attachToWindow(view)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(receivedStates.contains { if case .error = $0 { return true }; return false })
    }

    func test_wallets_shopPayOnly_rendersShopPayButtonAndRenderedState() {
        let expectation = expectation(description: "onRenderStateChange should emit rendered")
        let storefront = ShopStorefrontAPI(shopResult: .success(makeMockShop()))
        var receivedStates: [RenderState] = []

        let view = AcceleratedCheckoutButtonsView(
            identifier: .cart(cartID: "gid://Shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            applePayConfiguration: nil,
            storefrontFactory: { _ in storefront }
        )
        .wallets([.shopPay])
        .onRenderStateChange { state in
            receivedStates.append(state)
            if state == .rendered {
                expectation.fulfill()
            }
        }

        window = attachToWindow(view)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(findSubview(withIdentifier: "shop-pay-button", in: view))
        XCTAssertNil(findSubview(withIdentifier: "apple-pay-button", in: view))
        XCTAssertTrue(receivedStates.contains(.rendered))
    }

    func test_wallets_withApplePayWithoutConfiguration_emitsErrorAndSkipsApplePayButton() {
        let expectation = expectation(description: "onRenderStateChange should emit error")
        let storefront = ShopStorefrontAPI(shopResult: .success(makeMockShop()))
        var receivedStates: [RenderState] = []

        let view = AcceleratedCheckoutButtonsView(
            identifier: .cart(cartID: "gid://Shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            applePayConfiguration: nil,
            storefrontFactory: { _ in storefront }
        )
        .wallets([.shopPay, .applePay])
        .onRenderStateChange { state in
            receivedStates.append(state)
            if case .error = state {
                expectation.fulfill()
            }
        }

        window = attachToWindow(view)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(findSubview(withIdentifier: "shop-pay-button", in: view))
        XCTAssertNil(findSubview(withIdentifier: "apple-pay-button", in: view))
        XCTAssertTrue(receivedStates.contains { if case .error = $0 { return true }; return false })
    }

    func test_applePayButtonStyle_withApplePayConfiguration_rendersApplePayButton() {
        let expectation = expectation(description: "onRenderStateChange should emit rendered")
        let storefront = ShopStorefrontAPI(shopResult: .success(makeMockShop()))
        var receivedStates: [RenderState] = []
        let applePayConfiguration = ShopifyAcceleratedCheckouts.ApplePayConfiguration(
            merchantIdentifier: "merchant.test.id",
            contactFields: []
        )

        let view = AcceleratedCheckoutButtonsView(
            identifier: .cart(cartID: "gid://Shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            applePayConfiguration: applePayConfiguration,
            storefrontFactory: { _ in storefront }
        )
        .wallets([.applePay])
        .applePayButtonStyle(.whiteOutline)
        .onRenderStateChange { state in
            receivedStates.append(state)
            if state == .rendered {
                expectation.fulfill()
            }
        }

        window = attachToWindow(view)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(findSubview(withIdentifier: "apple-pay-button", in: view))
        XCTAssertTrue(receivedStates.contains(.rendered))
    }

    private func attachToWindow(_ view: UIView) -> UIWindow {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .white
        viewController.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.topAnchor, constant: 16)
        ])

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        return window
    }

    private func findSubview(withIdentifier identifier: String, in rootView: UIView) -> UIView? {
        if rootView.accessibilityIdentifier == identifier {
            return rootView
        }

        for subview in rootView.subviews {
            if let match = findSubview(withIdentifier: identifier, in: subview) {
                return match
            }
        }

        return nil
    }

    private func makeMockShop() -> StorefrontAPI.Shop {
        return StorefrontAPI.Shop(
            name: "Mock Shop",
            description: nil,
            primaryDomain: StorefrontAPI.ShopDomain(
                host: "test-shop.myshopify.com",
                sslEnabled: true,
                url: GraphQLScalars.URL(URL(string: "https://test-shop.myshopify.com")!)
            ),
            shipsToCountries: ["US", "CA"],
            paymentSettings: StorefrontAPI.ShopPaymentSettings(
                supportedDigitalWallets: ["APPLE_PAY", "SHOP_PAY"],
                acceptedCardBrands: [.visa, .mastercard],
                countryCode: "US"
            ),
            moneyFormat: "${{amount}}"
        )
    }
}

@available(iOS 17.0, *)
private final class ShopStorefrontAPI: MockStorefrontAPI {
    private let shopResult: Result<StorefrontAPI.Shop, Error>

    init(shopResult: Result<StorefrontAPI.Shop, Error>) {
        self.shopResult = shopResult
    }

    override func shop() async throws -> StorefrontAPI.Shop {
        try shopResult.get()
    }
}

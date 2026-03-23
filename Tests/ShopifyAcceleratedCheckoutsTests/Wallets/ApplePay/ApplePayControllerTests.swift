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
import ShopifyCheckoutSheetKit
import XCTest

@available(iOS 17.0, *)
@MainActor
final class ApplePayControllerTests: XCTestCase {
    final class MockApplePayViewController: ApplePayViewController {
        private(set) var onPressCallCount = 0

        override func onPress() async {
            onPressCallCount += 1
        }
    }

    func test_prepare_cachesShopSettingsAndWrappedController() async throws {
        let storefront = TestStorefrontAPI()
        storefront.shopResult = .success(.testShop)

        let loader = ShopSettingsLoader(
            configuration: .testConfiguration,
            storefront: storefront
        )

        var createdControllers: [MockApplePayViewController] = []
        let controller = ApplePayController(
            identifier: .cart(cartID: "gid://shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            applePayConfiguration: .testConfiguration,
            shopSettingsLoader: loader,
            controllerFactory: { identifier, configuration in
                let controller = MockApplePayViewController(
                    identifier: identifier,
                    configuration: configuration
                )
                createdControllers.append(controller)
                return controller
            }
        )

        try await controller.prepare()
        try await controller.prepare()

        XCTAssertEqual(storefront.shopCallCount, 1)
        XCTAssertEqual(createdControllers.count, 1)
    }

    func test_onPress_whenPreparationSucceeds_delegatesToWrappedController() async {
        let storefront = TestStorefrontAPI()
        storefront.shopResult = .success(.testShop)

        let loader = ShopSettingsLoader(
            configuration: .testConfiguration,
            storefront: storefront
        )

        var createdController: MockApplePayViewController?
        let controller = ApplePayController(
            identifier: .cart(cartID: "gid://shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            applePayConfiguration: .testConfiguration,
            shopSettingsLoader: loader,
            controllerFactory: { identifier, configuration in
                let controller = MockApplePayViewController(
                    identifier: identifier,
                    configuration: configuration
                )
                createdController = controller
                return controller
            }
        )

        await controller.onPress()

        XCTAssertEqual(storefront.shopCallCount, 1)
        XCTAssertEqual(createdController?.onPressCallCount, 1)
    }

    func test_onPress_whenPreparationFails_callsCheckoutDidFail() async {
        let storefront = TestStorefrontAPI()
        let expectedError = NSError(domain: "Test", code: 1)
        storefront.shopResult = .failure(expectedError)

        let loader = ShopSettingsLoader(
            configuration: .testConfiguration,
            storefront: storefront
        )

        var receivedError: CheckoutError?
        let controller = ApplePayController(
            identifier: .cart(cartID: "gid://shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            applePayConfiguration: .testConfiguration,
            eventHandlers: EventHandlers(checkoutDidFail: { error in
                receivedError = error
            }),
            shopSettingsLoader: loader
        )

        await controller.onPress()

        guard case let .sdkError(underlying, recoverable)? = receivedError else {
            return XCTFail("Expected sdkError")
        }

        XCTAssertFalse(recoverable)
        XCTAssertEqual((underlying as NSError).domain, expectedError.domain)
    }
}

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
import XCTest

@available(iOS 16.0, *)
@MainActor
final class AcceleratedCheckoutControllerTests: XCTestCase {
    func test_prepare_withValidIdentifier_setsRenderedAndCachesShopSettings() async {
        let storefront = TestStorefrontAPI()
        storefront.shopResult = .success(.testShop)

        let controller = AcceleratedCheckoutController(
            identifier: .cart(cartID: "gid://shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            storefront: storefront
        )

        XCTAssertEqual(controller.renderState, .loading)

        await controller.prepare()
        await controller.prepare()

        XCTAssertEqual(controller.renderState, .rendered)
        XCTAssertEqual(storefront.shopCallCount, 1)
    }

    func test_prepare_withInvalidIdentifier_keepsErrorStateAndSkipsShopLoad() async {
        let storefront = TestStorefrontAPI()

        let controller = AcceleratedCheckoutController(
            identifier: .cart(cartID: "invalid-cart-id").parse(),
            configuration: .testConfiguration,
            storefront: storefront
        )

        await controller.prepare()

        XCTAssertEqual(storefront.shopCallCount, 0)

        guard case let .error(reason) = controller.renderState else {
            return XCTFail("Expected error render state")
        }

        XCTAssertTrue(reason.contains("Invalid 'cartID' format"))
    }

    func test_prepare_whenShopSettingsLoadFails_setsErrorState() async {
        let storefront = TestStorefrontAPI()
        storefront.shopResult = .failure(NSError(domain: "Test", code: 1))

        let controller = AcceleratedCheckoutController(
            identifier: .cart(cartID: "gid://shopify/Cart/test-cart-id").parse(),
            configuration: .testConfiguration,
            storefront: storefront
        )

        await controller.prepare()

        guard case let .error(reason) = controller.renderState else {
            return XCTFail("Expected error render state")
        }

        XCTAssertTrue(reason.contains("Error loading shop settings"))
        XCTAssertEqual(storefront.shopCallCount, 1)
    }

    func test_eventHandlers_whenUpdated_emitsCurrentRenderState() {
        let controller = AcceleratedCheckoutController(
            identifier: .cart(cartID: "invalid-cart-id").parse(),
            configuration: .testConfiguration
        )

        var receivedState: RenderState?
        controller.eventHandlers = EventHandlers(renderStateDidChange: { state in
            receivedState = state
        })

        XCTAssertEqual(receivedState, controller.renderState)
    }
}

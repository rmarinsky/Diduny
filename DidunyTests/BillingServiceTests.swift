@testable import Diduny
import Foundation
import Testing

@MainActor
struct BillingServiceTests {
    @Test("Annual checkout sends the yearly interval and uses the server payment URL")
    func annualCheckout() async {
        let service = BillingService(baseURL: { "https://proxy.example" }) { request in
            #expect(request.url?.path == "/api/v1/billing/checkout")
            #expect(request.httpMethod == "POST")
            #expect(String(data: request.httpBody ?? Data(), encoding: .utf8) == #"{"billingInterval":"yearly"}"#)
            return (Data(#"{"paymentUrl":"https://proxy.example/billing/checkout/test"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let url = await service.checkout(.yearly)
        #expect(url?.absoluteString == "https://proxy.example/billing/checkout/test")
        #expect(service.errorMessage == nil)
    }

    @Test("Checkout rejects an unexpected payment host")
    func rejectsUntrustedCheckout() async {
        let service = BillingService(baseURL: { "https://proxy.example" }) { request in
            (Data(#"{"paymentUrl":"https://untrusted.example/payment"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await service.checkout(.yearly) == nil)
        #expect(service.errorMessage != nil)
        #expect(!service.isLoading)
    }

    @Test("Annual catalog charges ten months for twelve months of access")
    func annualCatalog() throws {
        let plans = try JSONDecoder().decode(
            [BillingPlan].self,
            from: Data(#"[{"billingInterval":"monthly","amount":150,"currency":"UAH","productName":"Pro"},{"billingInterval":"yearly","amount":1500,"currency":"UAH","productName":"Pro yearly"}]"#
                .utf8)
        )
        #expect(plans[1].amount == plans[0].amount * 10)
        #expect(plans[1].billingInterval == .yearly)
    }

    @Test("Changing account resets loading without accepting the old account response")
    func accountChangeDuringRefresh() async throws {
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        let service = BillingService(baseURL: { "https://proxy.example" }) { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let task = Task { await service.refresh() }
        while pending == nil {
            await Task.yield()
        }
        service.reset()
        #expect(!service.isLoading)
        let url = try #require(URL(string: "https://proxy.example"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        pending?.resume(returning: (
            Data(#"{"plan":"pro","status":"active","cancelAtPeriodEnd":false,"plans":[]}"#.utf8), response
        ))
        await task.value
        #expect(service.state == nil)
    }
    @Test("Resuming a cached expired subscription accepts a fresh payment response")
    func expiredResumeCheckout() async {
        let service = BillingService(baseURL: { "https://proxy.example" }) { request in
            (Data(#"{"paymentUrl":"https://proxy.example/billing/checkout/renew"}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let url = await service.setRenewal(enabled: true)
        #expect(url?.absoluteString == "https://proxy.example/billing/checkout/renew")
        #expect(service.errorMessage == nil)
    }

}

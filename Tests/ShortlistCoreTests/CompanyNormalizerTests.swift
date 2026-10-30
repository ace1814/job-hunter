import XCTest
@testable import ShortlistCore

final class CompanyNormalizerTests: XCTestCase {
    private func n(_ name: String) -> String { CompanyNormalizer.normalize(name) }

    // MARK: Legal forms and noise

    func test_legalFormsAreStripped() {
        XCTAssertEqual(n("Razorpay Software Pvt. Ltd."), "razorpay")
        XCTAssertEqual(n("Razorpay"), "razorpay")
        XCTAssertEqual(n("Infosys Limited"), "infosys")
        XCTAssertEqual(n("Zoho Corporation Private Limited"), "zoho")
        XCTAssertEqual(n("Stripe, Inc."), "stripe")
        XCTAssertEqual(n("Cisco Systems"), "cisco")
        XCTAssertEqual(n("Google India Pvt Ltd"), "google")
    }

    func test_ampersandAndCompanyWords() {
        XCTAssertEqual(n("Bain & Company"), "bain")
        XCTAssertEqual(n("Bain & Co."), "bain")
        XCTAssertEqual(n("Procter & Gamble"), "procter and gamble")
    }

    func test_domainsParenthesesAndAccents() {
        XCTAssertEqual(n("Amazon.com"), "amazon")
        XCTAssertEqual(n("Meta (formerly Facebook)"), "meta")
        XCTAssertEqual(n("Nestlé"), "nestle")
        XCTAssertEqual(n("The Walt Disney Company"), "walt disney")
    }

    /// Only kind-of-company words go. The name itself always survives.
    func test_theNameIsNeverStrippedAway() {
        XCTAssertEqual(n("Technologies"), "technologies")
        XCTAssertEqual(n("Global Labs"), "global")
        XCTAssertEqual(n("Tech Mahindra"), "tech mahindra")
    }

    func test_placeholderEmployersAreEmpty() {
        XCTAssertEqual(n("Self-employed"), "")
        XCTAssertEqual(n("Stealth Startup"), "")
        XCTAssertEqual(n("Freelance"), "")
        XCTAssertEqual(n("N/A"), "")
        XCTAssertEqual(n("   "), "")
    }

    func test_differentCompaniesStayApart() {
        XCTAssertNotEqual(n("Meta"), n("Metabase"))
        XCTAssertNotEqual(n("Swiggy"), n("Swiggy Instamart"))
    }
}
